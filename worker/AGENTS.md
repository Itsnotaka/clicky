# worker

Legacy Cloudflare Worker package. Clicky no longer uses this path for AI, transcription, speech, or chat.

## Rules

- Do not add AI backends here.
- Do not proxy Codex, OpenAI, chat, speech-to-text, or text-to-speech through the Worker.
- Do not add secrets for AI providers.
- Prefer deleting or archiving Worker code over expanding it, unless the user explicitly asks for a non-AI Worker feature.

## Commands

- Install: `npm install` from `worker/`.
- Local dev: `npm run dev` from `worker/`.
- Deploy: `npm run deploy` from `worker/`.

Only run Worker commands when editing Worker files.
