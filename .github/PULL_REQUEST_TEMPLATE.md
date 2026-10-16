## What this changes

<!-- One or two sentences about what changes for someone using Earshot. Link the issue: Fixes #123 -->

## How I tested it

- [ ] `make test` passes
- [ ] `make app` builds
- [ ] I tried it in the app (say which mode and call app)
- [ ] `make device-test` passes (if I touched capture, transcription, the Keychain or screen reading)
- [ ] `make claude-test` passes (if I touched how Claude is called, prompts, the MCP server or the plugins)
- [ ] `claude plugin validate --strict` passes for the marketplace and both plugins (if I touched `plugins/` or `.claude-plugin/`)

## Checklist

- [ ] No API keys, tokens, real transcripts, notes or recordings in the diff
- [ ] New logic lives in EarshotKit and has tests
- [ ] Meetings written by older versions still open (the v1 fixtures pass)
- [ ] Third-party text that reaches a model goes through `PromptFraming`
- [ ] User-facing text is plain and short, with no em dashes
- [ ] Docs updated if behaviour changed, and screenshots re-rendered if a window changed
- [ ] A line in CHANGELOG.md under "Unreleased"
