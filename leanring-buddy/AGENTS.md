# leanring-buddy

Main macOS app target. Follow the root `AGENTS.md` first.

## Commands

- Static validation: `xcrun swiftc -parse $(rg --files -g '*.swift' leanring-buddy)`.
- Do not run `xcodebuild`; use Xcode with the `leanring-buddy` scheme.
- Do not add or run tests unless the user explicitly asks.

## Voice

- Codex realtime is the supported voice backend.
- Do not add Apple Speech dictation or `NSSpeechSynthesizer` playback to the push-to-talk path.
- Do not add Claude, direct OpenAI REST transcription, or proxy speech services without explicit request.
- Keep `clicky.get_current_screen` and `clicky.point_at` as app-owned realtime tools for fresh screen context and pointing.

## UI Rules

- Use SwiftUI for normal views.
- Use AppKit for menu bar, panels, windows, event taps, permissions, and ScreenCaptureKit integration.
- Keep `NSMenu` native.
- Keep overlay windows transparent and non-activating.
- Keep UI state mutations on `@MainActor`.
- Add pointer cursor behavior to interactive SwiftUI controls.
