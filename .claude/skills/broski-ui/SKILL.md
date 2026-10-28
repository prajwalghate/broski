---
name: broski-ui
description: Change any Broski screen (Mac or iPhone) so it stays clean and consistent - the look Broski already has, the Apple conventions it follows, every state a screen needs, plain copy, and the snapshot loop that shows the change before and after. Use before touching a SwiftUI view.
---

# Broski's UI

Broski should feel like a good Mac app: quiet, fast, obvious. A screen earns every control on it.

## The look

- **One accent:** `Brand.purple` (Sources/Broski/PanelView.swift) for the primary action, the selection, and Broski's own voice. Everything else is system colors: `.primary`, `.secondary`, green for "it worked", orange for "needs you", red only for errors and destructive buttons.
- **Surfaces:** a card is `RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04))`, padding 14. Tiles and chips use radius 9–10. A selected tile gets the accent at 12% plus a 1.5 pt accent stroke.
- **Spacing:** 4, 8, 12, 16, 20, 24. Sections 14–20 apart; rows in a card 8–10.
- **Type:** titles `.title3.weight(.semibold)` (sheets) or the step title style (onboarding); body 13; secondary lines 11–12 in `.secondary`. Never more than three sizes on one screen.
- **Settings** are `Form` with `.formStyle(.grouped)`, one idea per section, the explanation in the section footer. The window has a sidebar (SettingsTab: title and SF Symbol).
- **Icons** are SF Symbols, never a company's logo (ProviderIcon shows how).

## Every screen has these states

Empty (what to do first), loading (a small `ProgressView` with what it's waiting for), working, error (what happened and what to do, in the person's words), and a narrow window. A button that can't work now is disabled with a `.help` saying why, not hidden.

## Words

Plain, short, specific, English. Say what happens, not how: "Connected to OpenAI" not "Provider handshake succeeded". Name the provider the person chose, never assume Claude. No exclamation marks, no "Oops". Errors end with what to do and where ("Check the key in Settings › Models").

## Accessibility

Every icon-only button has an `.accessibilityLabel` and a `.help`; selected tiles add `.isSelected`; text uses system sizes so it scales; contrast works in both themes; nothing depends on color alone.

## The loop

1. Before: `.build/debug/Broski --snapshot /tmp/before` (every screen, light and dark, sample data in a temporary folder).
2. Change the view. Keep logic in BroskiCore with tests (`tdd` skill); views only show state and send actions.
3. After: `--snapshot /tmp/after`, then look at both themes of every screen you touched (`sips -Z 900` makes them cheap to read). New screens get a line in `Sources/Broski/Snapshots.swift`.
4. Ask the `ui-critic` agent to review the after screenshots when the change is big.
5. Keys, scrolling and focus changes need `--chat-check` (it runs in `scripts/ci.sh`).

Sample data in `Snapshots.swift` uses invented projects only: screenshots end up on the website.
