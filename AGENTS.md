# Clicky Agent Notes

## Project

Clicky is a macOS `LSUIElement` companion app. It has a menu bar status item, a native SwiftUI dashboard, and floating overlay windows. The dashboard is the main control center for setup, permissions, model settings, cursor behavior, computer-use context, and logs.

## Build And Validation

- Open and run from Xcode with the `leanring-buddy` scheme.
- Do not run `xcodebuild`; it can invalidate TCC permissions.
- For static validation, use `xcrun swiftc -parse $(rg --files -g '*.swift' leanring-buddy)`.
- Do not add or run regression tests unless explicitly asked.
- Known non-blocking warnings: Swift 6 concurrency warnings and the deprecated `onChange` warning in `OverlayWindow.swift`.

## Code Style

- Prefer clear, descriptive names over short names.
- Keep UI in SwiftUI unless AppKit is required for system integration such as `NSStatusItem`, `NSMenu`, `NSPanel`, `NSWindow`, event taps, or permission APIs.
- Keep UI state updates on `@MainActor`.
- Use async/await for asynchronous work.
- All buttons and interactive SwiftUI controls should have pointer cursor behavior.
- Do not add compatibility shims, stale aliases, dead exports, or migration scaffolding; this is an unreleased app.
- Do not use emoji glyphs in code, logs, scripts, or UI copy.

## Architecture Reminders

- Menu bar click opens a compact native `NSMenu`.
- Dashboard is a floating native SwiftUI `NSPanel` and should remain the central setup/configuration surface.
- Voice input uses Apple Speech and push-to-talk with `ctrl + option`.
- Codex communication goes through local `codex app-server` with subscription passthrough.
- Screen and focused-window context stay in the main app process so permissions remain tied to the app identity.
