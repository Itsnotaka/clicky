# leanring-buddy

Main macOS app target. Follow the root `AGENTS.md` first.

## Commands

- Static validation: `xcrun swiftc -parse $(rg --files -g '*.swift' leanring-buddy)`.
- Do not run `xcodebuild`; use Xcode with the `leanring-buddy` scheme.
- Do not add or run tests unless the user explicitly asks.

## Transcription

- Apple Speech is the supported speech-to-text backend.
- Do not use Codex realtime conversation APIs for dictation.
- Do not add direct OpenAI REST transcription without explicit request.

## UI Rules

- Use SwiftUI for normal views.
- Use AppKit for menu bar, panels, windows, event taps, permissions, and ScreenCaptureKit integration.
- Keep `NSMenu` native.
- Keep overlay windows transparent and non-activating.
- Keep UI state mutations on `@MainActor`.
- Add pointer cursor behavior to interactive SwiftUI controls.
