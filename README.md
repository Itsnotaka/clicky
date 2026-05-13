# Clicky

Clicky is a macOS menu bar app that lives next to your cursor. It listens with push-to-talk, streams voice through Codex realtime, lets Codex inspect fresh screen captures, and can point at UI elements with an orange cursor overlay.

This repo is the open-source app code for hacking on Clicky locally.

## Architecture

Clicky is an `LSUIElement` app. It has no dock icon and no main window. The menu bar status item opens a native `NSMenu`; the cursor overlay is a transparent `NSPanel`.

Push-to-talk is the primary flow:

1. Hold `ctrl+option`.
2. The app records microphone audio.
3. PCM16 mono audio streams into `thread/realtime/appendAudio`.
4. Codex realtime replies with streamed audio output.
5. Codex can call `clicky.get_current_screen` for fresh screenshots.
6. Codex can call `clicky.point_at` to move the cursor overlay to a screen element.

Codex is the only AI backend. The app does not use Apple Speech dictation, AssemblyAI, Claude, ElevenLabs, native macOS speech playback, or a chat/speech proxy.

## Requirements

- macOS 14.2+ for ScreenCaptureKit.
- Xcode 15+.
- [Codex CLI](https://github.com/openai/codex) signed in with ChatGPT.

## Development

```bash
open leanring-buddy.xcodeproj
xcrun swiftc -parse $(rg --files -g '*.swift' leanring-buddy)
git diff --check
```

Run the app from Xcode with the `leanring-buddy` scheme. Do not run `xcodebuild`; it can invalidate local TCC permissions.

## Permissions

Clicky requests these macOS permissions:

- Microphone - push-to-talk voice capture.
- Accessibility - global keyboard shortcut and target-app actions.
- Screen Recording - screenshot capture.
- Screen Content - ScreenCaptureKit access.

## Project Map

| Path | Purpose |
|------|---------|
| `leanring-buddy/` | Main macOS app target. Read `leanring-buddy/AGENTS.md` before editing Swift. |
| `leanring-buddy.xcodeproj/` | Xcode project. Keep the `leanring-buddy` scheme name. |
| `leanring-buddyTests/` | Generated test target. Do not add or run tests unless asked. |
| `leanring-buddyUITests/` | Generated UI test target. Do not add or run tests unless asked. |
| `scripts/` | Build/release helper scripts. |
| `worker/` | Legacy Worker package. Not used for AI, transcription, or voice. |
| `AGENTS.md` | Repo-wide rules for agents and humans. |

## App Source Map

| File | Purpose |
|------|---------|
| `leanring-buddy/leanring_buddyApp.swift` | App entry point and lifecycle wiring. |
| `leanring-buddy/CompanionManager.swift` | Main voice-mode state machine. |
| `leanring-buddy/MenuBarPanelManager.swift` | Native menu bar status item and menu. |
| `leanring-buddy/RealtimeVoiceManager.swift` | Native Codex realtime voice session, microphone streaming, audio playback, and dynamic tools. |
| `leanring-buddy/BuddyPushToTalkShortcut.swift` | Shared push-to-talk shortcut matching. |
| `leanring-buddy/CodexAppServerClient.swift` | Codex app-server process and JSON-RPC bridge. |
| `leanring-buddy/CompanionScreenCaptureUtility.swift` | Screenshot and focused-window context. |
| `leanring-buddy/OverlayWindow.swift` | Transparent orange cursor overlay panel. |
| `leanring-buddy/CompanionResponseOverlay.swift` | SwiftUI overlay content. |
| `leanring-buddy/GlobalPushToTalkShortcutMonitor.swift` | Global `ctrl+option` shortcut monitor. |

## Contributing

Keep changes small and direct. Read `AGENTS.md` and the nearest nested `AGENTS.md` before editing. Do not commit unless explicitly asked.

## License

MIT. See `LICENSE`.
