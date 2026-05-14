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
  maxSlots         = 5,
  walkMaxDepth     = 30,
  panelRootLevels  = 5,
  slowWalksPerTick = 1,
}

local slotMap   = {}
local windows   = {}    -- [windowID] = { win, workspace, slot, state, promptTitle, panelRoot }
local menubar   = nil
local timer     = nil
local hotkeys   = {}
local appWatch  = nil

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

-- Returns marker (or nil), question text (or nil), and an anchor AX element
-- the caller can climb to find a stable cache root (AXWebArea). The anchor
-- is the marker if found, else the sentinel element if found, else nil.
local function scanPanel(root, maxDepth)
  if not root then return nil, nil, nil end
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
  if marker then return marker, nil, marker end

  local sentinelIdx
  for i = #items, 1, -1 do
    if items[i].value:find(CHAT_END_SENTINEL, 1, true) then sentinelIdx = i; break end
  end
  if not sentinelIdx then return nil, nil, nil end
  local anchor = items[sentinelIdx].element

  -- Skip consecutive sentinel duplicates (placeholder + a11y label render twice).
  while sentinelIdx > 1 and items[sentinelIdx - 1].value:find(CHAT_END_SENTINEL, 1, true) do
    sentinelIdx = sentinelIdx - 1
  end

  for i = sentinelIdx - 1, math.max(1, sentinelIdx - 20), -1 do
    local t = items[i].value
    if #t >= MIN_SUBSTANTIAL then
      if t:match("%?%s*$") then return nil, cleanQuestion(t), anchor end
      return nil, nil, anchor
    end
  end
  return nil, nil, anchor
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

-- Check using the cached panel-root subtree (fast).
-- Returns "waiting"|"question"|"idle"|"no_cache"|"cache_invalid", title.
local function fastCheck(state)
  if not state.panelRoot then return "no_cache", nil end
  local ok, role = pcall(function() return state.panelRoot:attributeValue("AXRole") end)
  if not ok or role == nil then
    state.panelRoot = nil
    return "cache_invalid", nil
  end
  local marker, lastQuestion = scanPanel(state.panelRoot, CONFIG.walkMaxDepth)
  if marker then return "waiting", extractPromptTitle(marker) end
  if lastQuestion then return "question", lastQuestion end
  return "idle", nil
end

-- Full walk from the window root (slow). Caches the panel's AXWebArea so
-- future polls only walk inside it. Caches even when the result is idle —
-- as long as the Claude Code panel is visible (sentinel present), we can
-- pin a cache for fast future detection of new prompts or questions.
local function slowCheck(state)
  local axwin = hs.axuielement.windowElement(state.win)
  if not axwin then return "idle", nil end
  local marker, lastQuestion, anchor = scanPanel(axwin, CONFIG.walkMaxDepth)
  if anchor then state.panelRoot = climbToWebArea(anchor, 15) end
  if marker then return "waiting", extractPromptTitle(marker) end
  if lastQuestion then return "question", lastQuestion end
  return "idle", nil
end

-- ====================== windows ======================

-- VS Code window titles can be:
--   "tab — workspace [SSH: instance]"
--   "tab — workspace [SSH: instance] — Untracked"   (git-status suffix)
--   "tab — workspace"
-- Strategy: capture everything after the first " — ", then truncate at the
-- next " — " (drops trailing git status), then strip "[SSH: ...]".
local function workspaceFromTitle(title)
  if not title then return nil end
  local rest = title:match(" \xE2\x80\x94 (.+)$")
  if not rest then return nil end
  local sep = rest:find(" \xE2\x80\x94 ")
  if sep then rest = rest:sub(1, sep - 1) end
  return (rest:gsub(" %[SSH:.-%]$", ""))
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
          win         = win,
          workspace   = ws or ("window-" .. id),
          slot        = ws and assignSlot(ws) or nil,
          state       = "unknown",
          promptTitle = nil,
          panelRoot   = nil,
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

  -- Slow walk one uncached window per tick, round-robin.
  if #list > 0 then
    for _ = 1, #list do
      rrIndex = (rrIndex % #list) + 1
      local w = list[rrIndex]
      if not w.panelRoot then
        local result, title = slowCheck(w)
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
  bindHotkeys()
  timer = hs.timer.doEvery(CONFIG.pollInterval, pollOnce)
  pollOnce()
end

M.start()

return M
