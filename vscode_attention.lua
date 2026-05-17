-- Surfaces Claude Code permission prompts across all VS Code windows.
--
-- Key trick: VS Code (Electron/Chromium) only populates its AX tree when an
-- assistive client is active. We set AXManualAccessibility on the Code app at
-- startup, which makes the tree traversable without enabling editor-level
-- accessibility settings.
--
-- Detection: walk each window's AX tree synchronously looking for the
-- "Tell Claude what to do instead" element. Full-tree walks are ~900 ms, so
-- we cache the Claude panel subtree per window and only do a full walk on
-- cold starts or after cache invalidation. At most one cold walk per poll
-- tick keeps the main thread from blocking.

local M = {}

local CONFIG = {
  pollInterval     = 1.5,
  axMarker         = "Tell Claude what to do instead",
  stateFile        = os.getenv("HOME") .. "/.hammerspoon/vscode_attention_state.json",
  hotkeyMods       = { "ctrl", "alt" },
  maxSlots         = 9,
  walkMaxDepth     = 30,
  slowWalksPerTick = 1,
  -- Maximum age (seconds) of a cached panelRoot before we force a fresh slow
  -- walk to refresh it. Cached subtrees occasionally become stale: the AX
  -- reference stays alive but no longer reflects the current panel content
  -- (e.g. after VS Code re-renders the webview). Without periodic refresh,
  -- such caches can keep returning "idle" forever even when there's a
  -- question or prompt to surface.
  cacheMaxAge      = 60,
}

local slotMap    = {}
local windows    = {}   -- [windowID] = { win, workspace, slot, state, promptTitle, panelRoot }
local menubar    = nil
local timer      = nil
local hotkeys    = {}
local appWatch   = nil
local sleepWatch = nil

-- ====================== persistence ======================

local function loadSlotMap()
  local f = io.open(CONFIG.stateFile, "r")
  if not f then return end
  local content = f:read("*a"); f:close()
  local ok, parsed = pcall(hs.json.decode, content)
  if ok and type(parsed) == "table" then slotMap = parsed end
end

local function saveSlotMap()
  local f = io.open(CONFIG.stateFile, "w")
  if f then f:write(hs.json.encode(slotMap, true)); f:close() end
end

local function assignSlot(workspace)
  if slotMap[workspace] then return slotMap[workspace] end
  -- Auto-migrate from the bare-name slot (pre-"@instance" naming scheme) to
  -- the new keyed slot. Lets old assignments survive the parser change.
  local bare = workspace:match("^(.+)@[^@]+$")
  if bare and slotMap[bare] then
    slotMap[workspace] = slotMap[bare]
    slotMap[bare] = nil
    saveSlotMap()
    return slotMap[workspace]
  end
  local used = {}
  for _, s in pairs(slotMap) do used[s] = true end
  for i = 1, CONFIG.maxSlots do
    if not used[i] then
      slotMap[workspace] = i
      saveSlotMap()
      return i
    end
  end
  return nil
end

-- ====================== AX setup ======================

-- Without this, VS Code reports only ~13 AX elements per window (just chrome).
local function enableA11yForCode()
  local app = hs.application.find("Code")
  if not app then return end
  local axapp = hs.axuielement.applicationElement(app)
  if axapp then axapp:setAttributeValue("AXManualAccessibility", true) end
end

-- ====================== detection ======================

-- Walks the panel subtree once, looking for BOTH the formal-prompt marker
-- and a sign that Claude's last message ended with a question.
-- Marker takes priority and early-terminates the walk.
--
-- Question detection: collect all AXStaticText fragments in DFS order, find
-- the last occurrence of the input-area placeholder ("Esc to focus or unfocus
-- Claude") as an end-of-chat sentinel, then walk backwards. The first
-- substantial fragment we encounter is Claude's trailing text — if it ends
-- with "?", flag as question; if not, the last message wasn't a question
-- (even if older messages had questions in them).
local CHAT_END_SENTINEL = "Esc to focus or unfocus Claude"
local MIN_SUBSTANTIAL = 8

local function cleanQuestion(s)
  return (s:gsub("^[%s%p]+", "")
           :gsub("^\xE2\x80[\x93\x94]%s*", "")
           :gsub("^[%s%p]+", ""))
end

-- Returns { state, title, anchor }. Possible states:
--   "waiting_marker" — formal Yes/No prompt ("Tell Claude what to do instead")
--   "waiting_askq"   — multi-choice prompt (AskUserQuestion tool, has Submit answers)
--   "question"       — end-of-conversation question (last message ends with ?)
--   "idle"           — nothing pending
-- "title" is the prompt/question text (or nil). "anchor" is an AX element the
-- caller can climb to find a stable cache root (the panel's AXWebArea).
local function scanPanel(root, maxDepth)
  if not root then return { state = "idle" } end
  local marker = nil
  local items = {}  -- list of { value, element } in DFS order
  local function walk(el, depth)
    if depth > maxDepth or marker then return end
    local v = el:attributeValue("AXValue")
    if v == CONFIG.axMarker then marker = el; return end
    if type(v) == "string" and #v >= 1 then
      table.insert(items, { value = v, element = el })
    end
    local children = el:attributeValue("AXChildren")
    if children then
      for _, c in ipairs(children) do
        walk(c, depth + 1)
        if marker then return end
      end
    end
  end
  walk(root, 0)
  if marker then
    return { state = "waiting_marker", marker = marker, anchor = marker }
  end

  -- Multi-choice AskUserQuestion prompt. "Submit answers" only appears in the
  -- active prompt UI (not history), so it's a reliable activeness signal.
  local submitIdx
  for i = #items, 1, -1 do
    if items[i].value == "Submit answers" then submitIdx = i; break end
  end
  if submitIdx then
    for i = submitIdx, 1, -1 do
      if items[i].value == "AskUserQuestion" and items[i + 1] then
        return { state = "waiting_askq", title = items[i + 1].value, anchor = items[submitIdx].element }
      end
    end
    -- Submit answers seen but couldn't locate question; still treat as waiting.
    return { state = "waiting_askq", title = nil, anchor = items[submitIdx].element }
  end

  -- End-of-conversation question via Esc-to-focus sentinel.
  local sentinelIdx
  for i = #items, 1, -1 do
    if items[i].value:find(CHAT_END_SENTINEL, 1, true) then sentinelIdx = i; break end
  end
  if not sentinelIdx then return { state = "idle" } end
  local anchor = items[sentinelIdx].element

  while sentinelIdx > 1 and items[sentinelIdx - 1].value:find(CHAT_END_SENTINEL, 1, true) do
    sentinelIdx = sentinelIdx - 1
  end

  for i = sentinelIdx - 1, math.max(1, sentinelIdx - 20), -1 do
    local t = items[i].value
    if #t >= MIN_SUBSTANTIAL then
      if t:match("%?%s*$") then
        return { state = "question", title = cleanQuestion(t), anchor = anchor }
      end
      return { state = "idle", anchor = anchor }
    end
  end
  return { state = "idle", anchor = anchor }
end

-- Climb the tree from `el` until we hit an AXWebArea (Claude Code's panel is
-- inside one), or give up after maxLevels. Using AXWebArea as the cache anchor
-- ensures the cached subtree contains the entire panel — old prompt content,
-- new messages, and the input area — so checks stay accurate as the
-- conversation grows.
local function climbToWebArea(el, maxLevels)
  for _ = 1, maxLevels or 15 do
    if not el then return nil end
    if el:attributeValue("AXRole") == "AXWebArea" then return el end
    el = el:attributeValue("AXParent")
  end
  return el
end

-- The prompt question (e.g. "Allow this bash command?") lives in the marker's
-- 3rd ancestor's subtree. We avoid climbing higher: level 5+ contains chat
-- history, where "Want me to do X?" sentences would be false positives.
-- Length filter (≤60 chars) is a second layer of defense against chat hits.
local function extractPromptTitle(marker)
  local container = marker
  for _ = 1, 3 do
    container = container and container:attributeValue("AXParent")
    if not container then return nil end
  end
  local function find(el, depth)
    if depth < 0 then return nil end
    local v = el:attributeValue("AXValue") or el:attributeValue("AXTitle")
    if type(v) == "string" and #v >= 5 and #v <= 60 and v:match("%?%s*$") then
      return v
    end
    for _, c in ipairs(el:attributeValue("AXChildren") or {}) do
      local hit = find(c, depth - 1)
      if hit then return hit end
    end
    return nil
  end
  return find(container, 4)
end

-- Promote scanPanel's structured result to the user-facing state + title.
-- Computing the title here (rather than in scanPanel) lets scanPanel sit
-- above extractPromptTitle in the file without a forward reference.
local function resolveScanResult(r)
  if r.state == "waiting_marker" then
    return "waiting", extractPromptTitle(r.marker)
  elseif r.state == "waiting_askq" then
    return "waiting", r.title
  elseif r.state == "question" then
    return "question", r.title
  else
    return "idle", nil
  end
end

-- Check using the cached panel-root subtree (fast).
-- Returns "waiting"|"question"|"idle"|"no_cache"|"cache_invalid", title.
local function fastCheck(state)
  if not state.panelRoot then return "no_cache", nil end
  local ok, role = pcall(function() return state.panelRoot:attributeValue("AXRole") end)
  if not ok or role == nil then
    state.panelRoot = nil
    return "cache_invalid", nil
  end
  local r = scanPanel(state.panelRoot, CONFIG.walkMaxDepth)
  -- If we hit "idle" AND no anchor at all, the cache no longer contains any
  -- recognizable panel landmark — it's stale. Drop and force a fresh walk.
  if r.state == "idle" and not r.anchor then
    state.panelRoot = nil
    return "cache_invalid", nil
  end
  return resolveScanResult(r)
end

-- Full walk from the window root (slow). Caches the panel's AXWebArea so
-- future polls only walk inside it. Caches even when the result is idle —
-- as long as the Claude Code panel is visible, we can pin a cache for fast
-- future detection of new prompts or questions.
local function slowCheck(state)
  local axwin = hs.axuielement.windowElement(state.win)
  if not axwin then return "idle", nil end
  local r = scanPanel(axwin, CONFIG.walkMaxDepth)
  if r.anchor then state.panelRoot = climbToWebArea(r.anchor, 15) end
  return resolveScanResult(r)
end

-- ====================== windows ======================

-- VS Code window titles can be:
--   "tab — workspace [SSH: instance]"
--   "tab — workspace [SSH: instance] — Untracked"   (git-status suffix)
--   "tab — workspace"
-- Strategy: capture everything after the first " — ", truncate at the next
-- " — " (drops trailing git status), then split off the SSH instance and
-- append it as "@instance" so the same folder opened on different remotes
-- gets distinct workspace identifiers (and distinct hotkey slots).
local function workspaceFromTitle(title)
  if not title then return nil end
  -- Standard format has a "tab — workspace [SSH: instance]" pattern, but
  -- windows with no file open (Welcome tab, etc.) have just "workspace
  -- [SSH: instance]" with no leading " — ". Fall back to the whole title.
  local rest = title:match(" \xE2\x80\x94 (.+)$") or title
  local sep = rest:find(" \xE2\x80\x94 ")
  if sep then rest = rest:sub(1, sep - 1) end
  local instance = rest:match(" %[SSH: ([^%]]+)%]$")
  rest = rest:gsub(" %[SSH:.-%]$", "")
  if instance then rest = rest .. "@" .. instance end
  return rest
end

local function refreshWindows()
  local app = hs.application.find("Code")
  if not app then windows = {}; return end
  local seen = {}
  for _, win in ipairs(app:allWindows()) do
    local id = win:id()
    if id then
      seen[id] = true
      local ws = workspaceFromTitle(win:title())
      if not windows[id] then
        windows[id] = {
          win          = win,
          workspace    = ws or ("window-" .. id),
          slot         = ws and assignSlot(ws) or nil,
          state        = "unknown",
          promptTitle  = nil,
          panelRoot    = nil,
          lastSlowWalk = 0,
        }
      else
        windows[id].win = win
        -- Upgrade workspace name if the title has settled into a parseable
        -- form (e.g. a new window started without a folder and then had one
        -- opened). Only assign a slot the first time we get a real name.
        if ws and windows[id].workspace ~= ws then
          windows[id].workspace = ws
          if not windows[id].slot then
            windows[id].slot = assignSlot(ws)
          end
        end
      end
    end
  end
  for id in pairs(windows) do
    if not seen[id] then windows[id] = nil end
  end
end

-- ====================== focus helper ======================

-- Brings a window properly to the front, including switching apps if needed.
-- `win:focus()` alone only focuses within the window's app; if that app isn't
-- frontmost (e.g. restoring focus from VS Code back to Slack), the window
-- doesn't actually become visible. Activate the app first.
local function focusWindow(win)
  if not win then return end
  pcall(function()
    local app = win:application()
    if app then app:activate() end
    win:focus()
  end)
end

-- ====================== menubar ======================

local function rebuildMenu()
  if not menubar then return end
  local anyWaiting, anyQuestion = false, false
  local list = {}
  for _, w in pairs(windows) do table.insert(list, w) end
  table.sort(list, function(a, b) return (a.slot or 99) < (b.slot or 99) end)

  local entries = {}
  for _, w in ipairs(list) do
    local dot
    if w.state == "waiting" then dot = "●"; anyWaiting = true
    elseif w.state == "question" then dot = "◐"; anyQuestion = true
    elseif w.state == "idle" then dot = "○"
    else dot = "?" end
    local hk = w.slot and ("⌃⌥" .. w.slot) or "    "
    local title = string.format("%s  %s  %s", dot, hk, w.workspace)
    if w.promptTitle then title = title .. "  —  " .. w.promptTitle end
    -- Defer the focus call so it runs after macOS dismisses the menu;
    -- otherwise the focus change races with the menu dismissal and is lost.
    local target = w
    table.insert(entries, {
      title = title,
      fn = function() hs.timer.doAfter(0, function() focusWindow(target.win) end) end,
    })
  end
  if #entries == 0 then
    table.insert(entries, { title = "(no VS Code windows)", disabled = true })
  end
  local icon = "⚪"
  if anyWaiting then icon = "🟠"
  elseif anyQuestion then icon = "🟡" end
  menubar:setTitle(icon)
  menubar:setMenu(entries)
end

-- ====================== polling ======================

-- Round-robin pointer so each uncached window gets a fair slow-walk turn.
-- Without this, the first uncached window in pairs() order would monopolize
-- the per-tick budget and others would never be checked.
local rrIndex = 0

local function applyResult(w, result, title)
  if w.state ~= result then
    print(string.format("[vscode_attention] %s: %s -> %s", w.workspace, w.state, result))
  end
  w.state, w.promptTitle = result, title
end

local function pollOnce()
  refreshWindows()
  local list = {}
  for _, w in pairs(windows) do table.insert(list, w) end

  -- Fast check every window every tick.
  for _, w in ipairs(list) do
    local result, title = fastCheck(w)
    if result == "waiting" or result == "idle" then
      applyResult(w, result, title)
    end
  end

  -- Slow walk one window per tick that's either uncached or whose cache has
  -- aged past cacheMaxAge. Round-robin order so each candidate gets a fair
  -- turn even when several are stale at once.
  if #list > 0 then
    local now = hs.timer.absoluteTime() / 1e9
    for _ = 1, #list do
      rrIndex = (rrIndex % #list) + 1
      local w = list[rrIndex]
      local stale = (now - (w.lastSlowWalk or 0)) > CONFIG.cacheMaxAge
      if (not w.panelRoot) or stale then
        local result, title = slowCheck(w)
        w.lastSlowWalk = now
        applyResult(w, result, title)
        break
      end
    end
  end

  rebuildMenu()
end

-- ====================== hotkeys ======================

local function focusBySlot(slot)
  for _, w in pairs(windows) do
    if w.slot == slot then focusWindow(w.win); return end
  end
end

-- Returns windows needing attention: all "waiting" first (by slot), then all
-- "question" (by slot). The cycle hotkey walks this list in order.
local function sortedWaiting()
  local waiting, question = {}, {}
  for _, w in pairs(windows) do
    if w.state == "waiting" then table.insert(waiting, w)
    elseif w.state == "question" then table.insert(question, w) end
  end
  local function bySlot(a, b) return (a.slot or 99) < (b.slot or 99) end
  table.sort(waiting, bySlot)
  table.sort(question, bySlot)
  for _, w in ipairs(question) do table.insert(waiting, w) end
  return waiting
end

-- previousFocus is set when the user starts a cycle (jumps to a waiting window
-- from outside it) and consumed when they exit the cycle (no waiting left).
local cycleState = { previousFocus = nil }

local function smartCycleWaiting()
  local current = hs.window.focusedWindow()
  local waiting = sortedWaiting()

  if #waiting > 0 then
    local currentId = current and current:id() or nil
    local idx
    for i, w in ipairs(waiting) do
      if w.win:id() == currentId then idx = i; break end
    end
    local target
    if idx then
      target = waiting[(idx % #waiting) + 1]
    else
      cycleState.previousFocus = current
      target = waiting[1]
    end
    print(string.format("[vscode_attention] cycle: %s -> %s (prev saved: %s)",
      current and current:title():sub(1, 30) or "nil",
      target.win:title():sub(1, 30),
      tostring(idx == nil)))
    focusWindow(target.win)
    return
  end

  -- No waiting windows. End-of-cycle restore takes precedence over cold-press.
  if cycleState.previousFocus then
    print(string.format("[vscode_attention] restore -> %s",
      cycleState.previousFocus:title():sub(1, 40)))
    focusWindow(cycleState.previousFocus)
    cycleState.previousFocus = nil
    return
  end

  -- Cold press, no waiting. If already on VS Code, do nothing. Otherwise
  -- quick-jump to the most recently focused VS Code window.
  local app = current and current:application()
  if app and app:name() == "Code" then return end
  for _, w in ipairs(hs.window.orderedWindows()) do
    local a = w:application()
    if a and a:name() == "Code" then focusWindow(w); return end
  end
end

local function bindHotkeys()
  for i = 1, CONFIG.maxSlots do
    table.insert(hotkeys, hs.hotkey.bind(CONFIG.hotkeyMods, tostring(i),
      function() focusBySlot(i) end))
  end
  table.insert(hotkeys, hs.hotkey.bind(CONFIG.hotkeyMods, "space", smartCycleWaiting))
end

-- ====================== debug helpers ======================

function M.dump()
  for _, w in pairs(windows) do
    print(string.format("slot=%s  state=%s  cached=%s  ws=%s  prompt=%s",
      tostring(w.slot), w.state, tostring(w.panelRoot ~= nil),
      w.workspace, tostring(w.promptTitle)))
  end
end

-- ====================== lifecycle ======================

function M.start()
  loadSlotMap()
  -- The second argument is an autosave name. With it, macOS remembers the
  -- item's position in the menu bar across reloads — without it, Ice (or any
  -- menubar manager) treats each reload as a brand-new item and resets it
  -- to the leftmost position (which on notch-MacBooks vanishes behind the
  -- camera cutout).
  menubar = hs.menubar.new(true, "vscode_attention")
  enableA11yForCode()
  appWatch = hs.application.watcher.new(function(name, event, _)
    if name == "Code" and
       (event == hs.application.watcher.launched
        or event == hs.application.watcher.activated) then
      hs.timer.doAfter(0.5, enableA11yForCode)
    end
  end)
  appWatch:start()

  -- After a sleep/wake or screen unlock, force a fresh refresh. SSH
  -- reconnects and Chromium renderer restarts during sleep can leave the
  -- polling in a stuck state where `windows` is empty even though VS Code
  -- is running with multiple windows. Re-applying AXManualAccessibility
  -- after wake also helps if Chromium dropped it during sleep.
  sleepWatch = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake
       or event == hs.caffeinate.watcher.screensDidUnlock then
      hs.timer.doAfter(2, function()
        enableA11yForCode()
        -- Clear caches so the post-wake walks re-pin to current AXWebAreas.
        for _, w in pairs(windows) do w.panelRoot = nil end
        pollOnce()
      end)
    end
  end)
  sleepWatch:start()

  bindHotkeys()
  timer = hs.timer.doEvery(CONFIG.pollInterval, pollOnce)
  pollOnce()
end

M.start()

return M
