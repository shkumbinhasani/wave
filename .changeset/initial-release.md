---
"wave": minor
---

Initial release of Wave Terminal — a macOS terminal emulator built with SwiftUI + libghostty.

- Glassy Arc-style sidebar with vibrancy and customizable theme (colors, brightness, vibrancy)
- Directory-based tab grouping with auto-detection via OSC 7
- Pinned groups with custom icons (auto-detects favicons), custom names, persisted across launches
- Drag and drop to reorder tabs within and between groups
- Keyboard-first navigation: Cmd+1-9 to focus groups, arrow keys + Enter to select
- New tabs inherit the current session's working directory
- Custom traffic lights, resizable sidebar, rounded terminal surface
- Full libghostty integration: Metal rendering, keyboard/mouse/IME, clipboard, shell integration
- Theme editor: accent color, brightness modes, vibrancy slider
- Auto-updates via Sparkle
- Move-to-Applications prompt on first launch
- Quit confirmation on Cmd+Q
