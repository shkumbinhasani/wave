# Wave Terminal

A fast, opinionated macOS terminal built with SwiftUI, AppKit, and [libghostty](https://github.com/ghostty-org/ghostty) — the GPU-accelerated engine behind Ghostty.

It's been my daily driver since I started building it, and a few colleagues run it full-time too. It's still a young project, but it's stable enough that I don't reach for anything else.

![Wave Terminal](assets/screenshot.png)

## What makes it different

- **Sidebar, not a tab bar.** Tabs live in a glassy left sidebar and are **automatically grouped by working directory** — anchored to the enclosing git repo root, so `cd`-ing into a subfolder stays under the project. Subfolders nest into a tidy tree.
- **Profiles.** Arc-style profiles, each with its own tab set, theme, icon, and optional SSH host. Switch profiles per window; two windows can sit on different profiles at once.
- **Coding-agent aware.** Wave knows when Claude Code, Codex, OpenCode, or Gemini is running in a tab — it shows the agent's logo, colors the tab by status, and sends a desktop notification when a background agent finishes or needs input. (Details below.)
- **Git at a glance.** Dirty-file badges per group and a built-in read-only diff viewer for uncommitted changes.
- **Multi-window with drag tear-out.** Drag a tab out of the sidebar to pop it into its own window; the shell keeps running.

## Install

### Homebrew (recommended)

```bash
brew install shkumbinhasani/tap/wave
```

### Direct download

Download `wave-macos-arm64.zip` from [Releases](https://github.com/shkumbinhasani/wave/releases/latest), unzip, then **right-click → Open** (not double-click) on first launch. If macOS says the app is "damaged and can't be opened", clear the quarantine attribute:

```bash
xattr -cr /path/to/wave.app
```

Wave will offer to move itself to `/Applications` on first launch. Apple Silicon only (arm64).

### Updates

Wave updates itself automatically via Sparkle. You can also check manually: **Wave → Check for Updates…**

## Features

### Sidebar & grouping
- Terminals grouped automatically by working directory, anchored to the git repo root.
- **Pinned groups** persist across launches, show even when empty (click to spawn a tab), and can carry a custom SF Symbol, an image, or an auto-detected project favicon/logo.
- Subfolder tabs nest under a dotted tree within their group.
- Reorder tabs by drag, within and between groups.
- Pinned or auto-hiding (drawer) sidebar; hover the left edge to reveal it when hidden. Resizable 180–400px.

### Profiles
- Multiple profiles, each with its own tabs, theme, icon, and optional SSH host.
- Active profile is per-window; switch with the profile bar at the bottom of the sidebar or trackpad-swipe the pager.
- **SSH profiles** open new tabs directly into `ssh <host>`; passwords are stored in the macOS Keychain, never on disk in plaintext.

### Theming
- Per-profile theme: accent color, tint, blur/vibrancy, and light/dark mode (which also syncs the terminal's color scheme).
- Real `NSVisualEffectView` vibrancy behind an accent tint. Right-click the sidebar → **Edit Theme…**.

### Git integration
- Per-group dirty badge showing the count of changed files.
- Built-in **uncommitted diff viewer**: changed-file list + rendered unified diff, opened from a group's badge, its context menu, or **Cmd+Shift+D**. View-only (no staging/commit).
- Live updates via filesystem watching. Toggle in Settings (on by default).

### Coding-agent integration
Wave detects coding agents running inside a tab and surfaces their state without you having to watch the terminal:

- **Supported agents:** Claude Code, Codex, OpenCode, Gemini.
- **Tab glyph** per agent (Claude and OpenCode ship brand logos; others use tinted symbols).
- **Status color:** running (blue), needs input (orange), done (green), error (red).
- **Desktop notifications** when an agent **finishes** or **needs input** in a tab you're not currently looking at — titled `Agent · folder`. Click a notification to jump straight to that tab. The Dock icon badges the number of tabs needing attention.

How it hooks in, on first launch (all idempotent, all opt-out by uninstalling the agent):
- **Claude Code** — a `claude` shim on the terminal's `PATH` re-execs the real binary with `--settings` pointing at a Wave-managed hooks file. Your global `~/.claude/settings.json` is left untouched.
- **Codex / Gemini** — hooks merged non-destructively into `~/.codex/hooks.json` / `~/.gemini/settings.json` (only if that agent is installed).
- **OpenCode** — a small plugin registered in `~/.config/opencode` (only if present).

Identity is detected primarily from the terminal title, with the hooks driving lifecycle status and routing notifications to the exact tab. Everything Wave writes lives under `~/.wave` and each agent's own config dir — remove `~/.wave` to undo it.

### Terminal
- **libghostty rendering** — GPU-accelerated via Metal, with full keyboard, mouse, and IME (marked-text / input-method) support.
- **In-terminal search** — floating overlay with live match count (Cmd+F).
- **Shell integration** — OSC 7 directory tracking, title updates, working-directory inheritance for new tabs.
- **File drag-and-drop** inserts shell-escaped paths.
- **Copy / Paste / Select All** via Ctrl-click / right-click menu.
- Background tabs pause rendering to save CPU.
- Confirmation prompts before closing a tab, window, or quitting while a process is still running.

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| Cmd+T | New tab (inherits current directory) |
| Cmd+W | Close tab |
| Cmd+F | Find in terminal |
| Cmd+G / Cmd+Shift+G | Find next / previous |
| Cmd+S | Toggle sidebar |
| Cmd+Shift+D | Toggle git diff for the current repo |
| Cmd+1 … Cmd+9 | Focus sidebar group 1–9 |
| ↑ / ↓ | Navigate tabs within the focused group |
| Return | Select focused tab / open a terminal in an empty group |
| Escape | Close search → close diff → cancel group focus |
| Ctrl+→ / Ctrl+← | Next / previous profile |
| Cmd+Q | Quit (with confirmation if processes are running) |

Tabs are moved to a new window by dragging them out of the sidebar, or via **Move to New Window** in a tab's context menu.

## Build from source

Requires an Apple Silicon Mac.

```bash
# 1. Install dependencies
brew install zig xcodegen

# 2. Clone and build GhosttyKit
git clone --depth 1 https://github.com/ghostty-org/ghostty.git /tmp/ghostty
cd /tmp/ghostty
zig build -Demit-xcframework -Dxcframework-target=native --release=fast

# 3. Copy the framework into the repo
cd /path/to/wave
mkdir -p Frameworks
cp -R /tmp/ghostty/macos/GhosttyKit.xcframework Frameworks/

# 4. Generate the Xcode project and build
xcodegen generate
xcodebuild -project wave.xcodeproj -scheme wave -configuration Release build
```

The Xcode project is generated by XcodeGen from `project.yml` (it's gitignored), so run `xcodegen generate` after pulling changes or adding files.

## License

MIT
