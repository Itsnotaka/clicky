# Hi, this is Clicky.
It's an AI teacher that lives as a buddy next to your cursor. It can see your screen, talk to you, and even point at stuff. Kinda like having a real teacher next to you.

Download it [here](https://www.clicky.so/) for free.

![Clicky — an ai buddy that lives on your mac](clicky-demo.gif)

This is the open-source version of Clicky for those that want to hack on it, build their own features, or just see how it works under the hood.

## Get started with Codex

The fastest way to get this running is with [OpenAI Codex](https://github.com/openai/codex).

Once you get Codex running, paste this:

```
Hi Codex.

Clone the Clicky repository into my current directory.

Then read the AGENTS.md. I want to get Clicky running locally on my Mac.

Help me set up everything — install Codex with pnpm and get it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ and [pnpm](https://pnpm.io/installation)
- A ChatGPT plan supported by Codex (for subscription passthrough)

### 1. Install Codex with pnpm

Clicky talks to a local `codex app-server` process for chat, which means you do not need an API key in the app.

```bash
pnpm add -g @openai/codex
codex --version
```

Then sign in once:

```bash
codex login
```

If you prefer not to rely on your shell `PATH`, you can put the full Codex binary path in `leanring-buddy/Info.plist` under `CodexCLIPath`. On most Macs installed via pnpm that path is `~/Library/pnpm/codex`.

### 2. Point the app at your Codex install

Open `leanring-buddy/Info.plist` and set:

- `CodexCLIPath` if Clicky cannot find the pnpm-installed `codex` binary automatically

### 3. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, type into the prompt box or hold `ctrl + option` to talk, and if needed use the Codex sign-in button in the panel to finish ChatGPT auth from inside the app.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (`ctrl + option`)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

If you want the full technical breakdown, read `AGENTS.md`. But here's the short version:

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk uses Apple Speech locally, typed prompts go through the same screen-aware flow, and Clicky sends the transcript + screenshot to a local `codex app-server` process authenticated with your ChatGPT subscription. Responses are spoken with native macOS speech. Codex can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI + Codex auth/model/text controls
  CodexAppServerClient.swift # Local Codex app-server bridge
  OverlayWindow.swift       # Blue cursor overlay
  AppleSpeechTranscriptionProvider.swift # Local speech transcription
  BuddyDictation*.swift     # Push-to-talk pipeline
AGENTS.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Codex, it already knows the codebase — just tell it what you want to build and point it at `AGENTS.md`.
