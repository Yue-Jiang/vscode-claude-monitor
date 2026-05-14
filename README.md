# VS Code Claude Code Attention Monitor

A Hammerspoon script that surfaces Claude Code permission prompts (and end-of-conversation questions) across all your VS Code windows as a menubar indicator, with global hotkeys to jump between them. Built for the case where you're running multiple VS Code windows (often SSH'd into remote machines) with Claude Code in each, and want to know — without checking every window — when one needs your input.

## What it does

Two tiers of attention:

- **Waiting (`●` orange)** — a formal Claude Code permission prompt is open in the window ("Allow this bash command?", etc.).
- **Question (`◐` yellow)** — Claude's most recent message in the chat ends with a `?`. Not a hard interrupt, but probably worth a look.

The menubar icon reflects the highest-priority state across all windows: `🟠` if any window is waiting, `🟡` if any has a pending question (and none are waiting), `⚪` otherwise.

Click the icon for a dropdown listing every VS Code window with status, hotkey, workspace, and the actual prompt/question:

```
●  ⌃⌥2  api-server     —  Allow this bash command?
◐  ⌃⌥3  web-client     —  Ready to deploy or want me to add tests first?
○  ⌃⌥1  data-pipeline
```

Global hotkeys (configurable):

- `⌃⌥1` … `⌃⌥5` — focus a specific window by its stable workspace slot.
- `⌃⌥space` — smart cycle:
  - Jump to the next waiting window. After cycling through all waiting, continue through question windows.
  - If you've answered everything and started from another app, drop you back to it.
  - If nothing is waiting and you're outside VS Code, quick-jump to the most recently active VS Code window.

## Requirements

- macOS
- [Hammerspoon](https://www.hammerspoon.org)
- VS Code with the Claude Code extension

## Install

1. Install Hammerspoon:
   ```sh
   brew install --cask hammerspoon
   ```

2. Launch it and grant **Accessibility** permission when prompted (System Settings → Privacy & Security → Accessibility → toggle Hammerspoon on). Without this, AX tree reads and global hotkeys both fail silently.

3. Drop the script into your Hammerspoon config:
   ```sh
   cp vscode_attention.lua ~/.hammerspoon/
   ```

4. Add a `require` line to `~/.hammerspoon/init.lua` (create the file if it doesn't exist):
   ```lua
   require("hs.ipc")            -- optional; enables the `hs` CLI for debugging
   require("vscode_attention")
   ```

5. Click the Hammerspoon menubar icon → **Reload Config**.

You should see the new `⚪` icon appear, and clicking it shows your VS Code windows.

## How it works

VS Code is an Electron (Chromium) app. Each window is a separate renderer process that only populates its full accessibility tree when an "assistive client" is detected. Without that, AX traversal returns only ~13 elements per window (just window chrome) — invisible to any external tool.

The script sets `AXManualAccessibility = true` on the VS Code application, which makes Chromium expose its tree without requiring VoiceOver or similar.

Detection then walks each window's panel subtree and does two things in one pass:

1. **Waiting** — looks for the static text `"Tell Claude what to do instead"`, the unique label on the 4th option of every Claude Code permission prompt.
2. **Question** — collects all text fragments in DFS order, finds the input-area sentinel `"Esc to focus or unfocus Claude"` (the chat's end marker), then walks backwards to inspect the most recent message. If it ends with `?`, the window is flagged as question. This intentionally only looks at the **last** message — old questions that have been answered don't trigger a false positive.

Once a window has been scanned once, its panel's `AXWebArea` is cached so subsequent polls only walk inside that subtree. A round-robin scheduler ensures each uncached window gets a turn even if the first one keeps consuming budget.

## Configuration

Settings live in the `CONFIG` table at the top of `vscode_attention.lua`:

| Setting | Default | Description |
| --- | --- | --- |
| `pollInterval` | `1.5` | How often (seconds) to recheck state |
| `axMarker` | `"Tell Claude what to do instead"` | Text used to detect a formal prompt |
| `hotkeyMods` | `{"ctrl", "alt"}` | Modifiers for slot hotkeys (and `space`) |
| `maxSlots` | `5` | Number of hotkey slots |
| `walkMaxDepth` | `30` | Max AX tree depth to walk |
| `slowWalksPerTick` | `1` | How many uncached windows to fully scan per tick |

Other constants near the top (`CHAT_END_SENTINEL`, `MIN_SUBSTANTIAL`) drive question detection; change if Claude Code's UI text shifts.

Slot assignments (workspace name → number `1`–`5`) are persisted in `~/.hammerspoon/vscode_attention_state.json`. Edit the file directly to reassign slots, then `hs.reload()`.

## Hotkey cheatsheet

| Keys | Action |
| --- | --- |
| `⌃⌥1`–`⌃⌥5` | Focus the VS Code window assigned to that slot |
| `⌃⌥space` | Smart cycle: waiting windows first, then question windows, then restore previous app — or quick-jump to last VS Code if none |

## Troubleshooting

**Some windows stuck on `?` in the dropdown.** Their Chromium renderers haven't exposed their AX tree yet. This usually clears on its own; if not, fully quit and relaunch VS Code (`Cmd+Q`, then reopen) — the `AXManualAccessibility` flag gets reapplied on relaunch via Hammerspoon's app watcher.

**Detection works for one window but not others.** Same root cause — each VS Code window is a separate renderer process, and Chromium's per-process a11y mode is sticky. Restart VS Code to wake all of them up at once.

**Menubar `🟠`/`🟡` doesn't fire even though something is pending.** Open the Hammerspoon console (menubar hammer icon → Console…) and run:
```lua
require("vscode_attention").dump()
```
Each window's state should appear. If they're all `unknown`, it's an Accessibility permission issue — confirm Hammerspoon is granted in System Settings.

**Workspace name parses weirdly after a git change.** VS Code occasionally appends ` — Untracked` (or similar status suffix) to window titles. The parser strips this automatically; if you see a weird workspace name in the menubar, give it a poll cycle or two.

**Menubar icon jumps back to the leftmost position after every reload.** This happens with menubar managers like Ice or Bartender if the menubar item doesn't have an autosave name. The script passes one to `hs.menubar.new`, so position should persist — if it doesn't, try dragging the icon to your preferred slot once and then reloading.

**A question is flagged but the conversation didn't actually end with one.** Possible if Claude's last visible text fragment happens to end in `?` (e.g., a quoted question in a longer response). The heuristic is approximate — false positives in question state are intentional design ground; if they're frequent, raise `MIN_SUBSTANTIAL` in the source so trailing short fragments are ignored.

## Files

- `vscode_attention.lua` — the entire module
- `~/.hammerspoon/init.lua` — your existing Hammerspoon entry point (you add one `require` line)
- `~/.hammerspoon/vscode_attention_state.json` — auto-generated workspace → slot mapping (not in this repo)

## License

MIT
