# Development Rules

## Commands

- Open and run from Xcode with the `leanring-buddy` scheme.
- Static Swift validation after Swift changes: `xcrun swiftc -parse $(rg --files -g '*.swift' leanring-buddy)`.
- Documentation-only validation: `git diff --check`.
- Do not run `xcodebuild`; it can invalidate TCC permissions.

Known upstream warnings about Swift 6 concurrency, deprecated `NSSpeechSynthesizer`, and deprecated SwiftUI `onChange` are not the current target. Do not fix them unless asked.

## Code Quality

- Keep changes minimal and canonical. This is unreleased software; no compatibility shims, aliases, migrations, or dead exports.
- Prefer direct control flow and clear names over abstractions.
- Use SwiftUI for UI unless AppKit is required for system integration: `NSStatusItem`, `NSMenu`, `NSPanel`, `NSWindow`, event taps, permissions.
- Keep UI state updates on `@MainActor`.
- Use async/await for async work.
- Do not suppress type or concurrency problems with forced casts, `AnyView`, `as any`, `try?`, or comments.
- Add pointer cursor behavior to interactive SwiftUI controls.
- No emoji glyphs in code, logs, scripts, or UI copy.

## Git

- Never commit unless the user asks.
- Never use destructive git commands unless the user explicitly asks.
- Do not revert or overwrite unrelated work from another agent or the user.
