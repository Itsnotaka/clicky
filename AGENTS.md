# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice and typed controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it locally with Apple Speech, and sends the transcript + a screenshot of the user's screen to a local `codex app-server` process. Codex responds with text (streamed over app-server stdio) and voice (native macOS speech). A blue cursor overlay can fly to and point at UI elements Codex references on any connected monitor.

Chat uses local Codex subscription passthrough, so no API key ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Local `codex app-server` authenticated with the user's ChatGPT subscription. Clicky launches the process, queries auth/model state over JSON-RPC stdio, and streams multimodal turns through ephemeral threads.
- **Background Actions**: Codex can return structured background action plans. Clicky currently executes reusable primitives such as opening a public URL in an already-running browser window without intentionally foregrounding it.
- **Permission Guidance**: Permission rows can open the relevant Privacy & Security pane and show an in-app helper overlay. Browser Automation uses Apple Events permission probing so Clicky can ask for per-browser control access before running background browser actions.
- **Speech-to-Text**: Apple Speech.
- **Text-to-Speech**: Native macOS speech
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Codex embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout

### Key Architecture Decisions

**Menu Bar Menu + Panel Pattern**: Clicky uses `NSStatusItem` for the menu bar icon. Clicking the icon opens a native `NSMenu` with the agent-running toggle and app actions, while Settings opens the custom borderless `NSPanel` floating control screen. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Local Speech**: Push-to-talk uses Apple Speech and responses use `NSSpeechSynthesizer`, so the local setup does not require speech API keys.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → speech → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File                                     | Lines | Purpose                                                                                                                                                                                                                                                                                                                                            |
| ---------------------------------------- | ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `leanring_buddyApp.swift`                | ~89   | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar.                                                                                                                           |
| `CompanionManager.swift`                 | ~1121 | Central state machine. Owns the agent-running lifecycle, dictation, shortcut monitoring, screen capture, background action routing, browser Automation permission state, Codex auth/model state, speech output, and overlay management. Tracks voice state (idle/listening/processing/responding), model selection, and cursor visibility. Coordinates the full push-to-talk or typed prompt → background action or screenshot → Codex → speech → pointing pipeline. |
| `CompanionBackgroundAgent.swift`         | ~167  | Structured background action plan models and reusable executors. Currently supports opening public URLs in already-running browser windows after checking/requesting per-browser Automation permission.                                                                                                                                       |
| `CompanionBrowserAutomationPermission.swift` | ~201 | Supported browser targets and Apple Events Automation permission probing for background browser actions.                                                                                                                                                                                                                                     |
| `CompanionPermissionAssistant.swift`     | ~536  | Local System Settings permission guide inspired by `zats/permiso`. Opens Privacy & Security panes and shows a floating helper overlay with drag-to-add guidance or Automation instructions.                                                                                                                                                    |
| `MenuBarPanelManager.swift`              | ~370  | NSStatusItem native menu + custom NSPanel lifecycle. Creates the menu bar icon, hosts the SwiftUI agent toggle inside the native dropdown, opens Settings as the floating companion screen, and installs click-outside-to-dismiss monitoring for that screen.                                                                                       |
| `CompanionPanelView.swift`               | ~694  | SwiftUI content for the floating Settings panel. Native macOS-style grouped rows for Codex status, typed prompts, model selection, cursor visibility, permissions, browser Automation setup, onboarding, and footer actions.                                                                                                                       |
| `OverlayWindow.swift`                    | ~839  | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions.                                                                                                                            |
| `CompanionResponseOverlay.swift`         | ~217  | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay.                                                                                                                                                                                                                                                |
| `CompanionScreenCaptureUtility.swift`    | ~132  | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display.                                                                                                                                                                                                                                    |
| `BuddyDictationManager.swift`            | ~866  | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback.                                                                           |
| `BuddyTranscriptionProvider.swift`       | ~55   | Protocol surface and provider factory for voice transcription backends. Uses Apple Speech for the no-key local setup.                                                                                                                                                                                                                              |
| `AppleSpeechTranscriptionProvider.swift` | ~147  | Local fallback transcription provider backed by Apple's Speech framework.                                                                                                                                                                                                                                                                          |
| `BuddyAudioConversionSupport.swift`      | ~108  | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers.                                                                                                                                                                                                                        |
| `GlobalPushToTalkShortcutMonitor.swift`  | ~132  | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions.                                                                                                                                                                                                                                      |
| `CodexAppServerClient.swift`             | ~835  | Local Codex app-server bridge. Launches `codex app-server`, initializes JSON-RPC over stdio, checks ChatGPT auth state, starts browser login, lists models, and streams multimodal or structured text turns.                                                                                                                                      |
| `DesignSystem.swift`                     | ~673  | Design system tokens — adaptive surfaces, Display P3–tagged accent (`#FF4700` sRGB basis), corner radii, button styles. UI references `DS.Colors`, `DS.CornerRadius`, etc.                                                                                                                                                                         |
| `WindowPositionManager.swift`            | ~262  | Window placement logic, Screen Recording permission flow, and accessibility permission helpers.                                                                                                                                                                                                                                                    |
| `AppBundleConfiguration.swift`           | ~28   | Runtime configuration reader for keys stored in the app bundle Info.plist.                                                                                                                                                                                                                                                                         |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
