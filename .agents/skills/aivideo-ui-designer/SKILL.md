---
name: aivideo-ui-designer
description: Specialized macOS SwiftUI design skill for AIVideo based on Apple HIG and UI/UX Pro Max intelligence. Use when designing, styling, or refactoring macOS views, inspector panels, timeline controls, buttons, or typography in AIVideo.
---

# AIVideo UI/UX Design System (macOS SwiftUI)

## Design Identity: The Calm Editor ("Bàn Biên Tập Bình Tĩnh")
- Focused on video, story, and evidence without visual distraction.
- Three fundamental questions answered on every screen:
  1. What am I looking at?
  2. What decision is required?
  3. What is the next primary action?

## Color Tokens & Appearance
- **System Appearance**: Supports both Light and Dark mode natively.
- **Accent Pair**:
  - Light mode: Deep Teal `#0F766E` with White `#FFFFFF` foreground.
  - Dark mode: Mint Teal `#5EEAD4` with Dark Forest Green `#062C28` foreground.
- **Surfaces**: macOS native semantic colors (`NSColor.windowBackgroundColor`, `NSColor.controlBackgroundColor`).
- **Typography**: System SF Pro font; `.monospacedDigit()` for all timecodes, durations, and numeric metrics.

## Spacing & Touch Targets
- Spacing scale: 4, 8, 12, 16, 24, 32 pt.
- Minimum interactive target: 44×44 pt.
- Bo góc (Corner Radius): 8–12 pt for custom cards and panels; system-managed controls keep system radii.

## How to Query UI/UX Pro Max
When designing or styling new components, invoke the local UI/UX Pro Max engine:
```bash
python3 ~/.gemini/config/plugins/ui-ux-pro-max/skills/ui-ux-pro-max/scripts/search.py "<component-type or query>" --stack swiftui
```
