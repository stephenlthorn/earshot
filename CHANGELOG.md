# Changelog

All notable changes to Earshot are listed here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Earshot follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-10-16

Earshot can now run fully on your Mac. Transcription was already on-device; with a local model server, the notes and every other AI feature stay there too.

### Added

- **Local models.** "Write notes with" in Settings > Claude has a third choice: a local model through Ollama, LM Studio, llama.cpp or any other OpenAI-compatible server. One model writes the notes, the live to-dos, the brief, Ask and Fix. Earshot asks for a strict JSON format and also puts it in the prompt, so servers without structured outputs (mlx_lm.server) still work. It sends one call at a time, never sends a key and never follows a redirect, and plain `http://` is allowed only for this Mac and your local network. Every problem gets its own sentence: a server that isn't running, a missing model, an address without `/v1`, a meeting longer than the model's context, or a model that's too slow. See the [local models guide](docs/local-models.md).
- **The local model status.** Settings checks the server with one request for its model list, never a model call, and shows "Connected to localhost:11434. qwen3:8b is ready." or what to fix. It checks when Settings opens, shortly after you change the address or the model, and when you click Check.
- **Settings > Claude.** "Use Claude through" is now "Write notes with". With a local model it has the server address with Ollama, LM Studio and llama.cpp buttons, a model list from the server (or type a name), the status line and a link to the guide. Settings > Live suggests 120 seconds or more between checks on a local model.
- **Onboarding and What's New.** The setup checklist has **Use a local model**, and with one chosen its row shows the server's status with **Check** and **Set up**. "New in Earshot 0.3" appears once after you update, with what 0.2 added below it for anyone coming from 0.1.
- **`earshot doctor`** checks the local model first when it is chosen, and `earshot process` writes notes with it.
- **`make local-test`** runs the real-model checks against your own server: the notes, live, brief, Ask and Fix checks, `earshot process`, and (with `EARSHOT_LOCAL_ANTHROPIC_URL`) the MCP server and plugins with Claude Code on the local model.
- **`make e2e-import`** can write the notes with a local model: set `EARSHOT_E2E_LOCAL_URL` and `EARSHOT_E2E_LOCAL_MODEL`, and the app is launched with `--local <url> <model>`.

### Changed

- The live panel says "Couldn't reach the local model" or "Paused: the local model isn't set up" with a local model, and the menu offers "Set up notes" for every notes setup problem, not just a missing Claude Code or API key.
- An answer in the wrong shape, a refusal or a cut-off answer now says "the model" rather than Claude, since it can come from a local model.

## [0.2.1] - 2026-10-15

Fixes from the final review of 0.2.0.

### Fixed

- Webhook and routine sends no longer follow redirects, so your token can't be passed on to another host.
- Rebuilding the meetings index while the save folder's drive isn't connected no longer drops every meeting.
- Extra sends after a Fix get a new payload id whenever the items change, so a receiver never skips new items.
- A screen sample that was being taken when you turned screen reading off is dropped.
- Two meetings started at the same moment always get their own folders.
- Earshot passes your own `CLAUDE_CONFIG_DIR` on to Claude Code, so a custom Claude Code folder isn't mistaken for "not signed in".
- Links into Settings open the right tab. Onboarding shows when a permission was denied before, with a link to System Settings, and offers "Choose claude…" and an install link when Claude Code isn't found.
- The Sharing hotkey's registration problem is shown in Settings > Live, and the Webhook and Command sections show why they can't run.
- Small status text uses colours that pass contrast checks in light and dark mode, and icon buttons have labels for VoiceOver.
- The Ask window scrolls to the newest answer and can be resized.
- The brief card collapses for External meetings even when the calendar profile arrives after the recording starts.
- A mode preselected for a calendar event goes back to your default once the event is over, unless you changed it.
- `make claude-test`'s time limit now stops every process the tests started.

## [0.2.0] - 2026-10-15

Earshot brings the AI into the meeting. The live assistant, the calendar, noticing calls, screen reading and routines are off until you turn them on, and a meeting recorded with 0.1 opens unchanged.

### Added

- **Claude through your subscription.** Every AI feature can run on a Claude plan alone, through Claude Code 2.1.259 or later. Earshot runs your own, unmodified `claude` and never reads or stores your Claude login. An Anthropic API key is still a full alternative. Settings shows your Claude status ("Signed in to Claude (Max) through Claude Code") and what to do when something is wrong. On a Max plan, `make e2e-import` has passed: the real app imported a spoken meeting and wrote its notes through `claude -p`, twice. The full `make claude-test` suite hasn't run yet; it runs the checks against your own Claude Code.
- **Live assistant.** Live transcription during the call, and to-dos that appear in a small floating panel about every 90 seconds, using a cheaper model. One click on Start sends an item to a Do target while the call is still going. The live items are kept in `live.json`, which survives a crash and follows the meeting when its folder is renamed.
- **The live panel.** A floating panel with a timer, Flag, Sharing and Stop, the brief, the live to-dos and a status line. It tries to hide from screen sharing, and the Sharing button (⌃⌥⌘H) collapses it to a small pill that shows only the recording dot and the timer.
- **Calendar context and the brief.** Earshot reads the current calendar event (title, attendees, agenda) and past meetings with the same people, then shows a short brief as the call starts. The event sets the meeting title, the profile (External, Internal or None), the mode and the notes style.
- **Better notes.** Notes name people only when the transcript makes it clear who spoke, list what is still open from last time, and cover every flagged moment.
- **Learning from your edits.** You can edit an item's task, owner and due date in the confirm window. Your changes, and your Fix instructions, become examples that later notes follow. "Learn from my edits" in Settings > Storage is on by default, and "Forget what Earshot learned" clears what was kept.
- **Noticing calls.** Earshot can notice when a call app or a browser turns on the microphone and offer to record. It can also start recording on its own for dedicated call apps, or for a browser call when the calendar event has a video link, and stop when the call ends.
- **Flags.** Mark a moment with ⌃⌥⌘F, the panel's Flag button, or by saying "flag that". The notes cover each flagged moment.
- **Ask and Fix.** Ask questions about a past meeting, with answers that quote the time. Tell Earshot what to fix in the notes and see what changed before you save. Each saved Fix keeps the notes it replaced, so the first Fix keeps the original as `notes-r0.json`.
- **Screen reading.** Optional, and off by default. Earshot reads the text in the call app's windows on your Mac, so "this number here" makes sense in the notes. Screenshots never leave the Mac.
- **The notes page.** Each meeting gets a self-contained `notes.html` with a timeline, decisions and who owes what, in light and dark.
- **Meetings for every AI.** An MCP server (`earshot mcp`) with five read-only tools, so Claude Code, Claude Desktop or any MCP client can search meetings, read notes and list who owes what.
- **The `earshot` command-line tool**, bundled in the app as a universal binary (Apple silicon and Intel) signed with the hardened runtime: `list`, `show`, `search`, `items`, `reminders`, `process`, `doctor`, `mcp`, `version` and `help`.
- **Two Claude Code plugins** in this repo's marketplace: `earshot` (the MCP server and a `meetings` skill) and the opt-in `earshot-reminders` (open action items at the start of a session).
- **The library index** in `~/Library/Application Support/Earshot/Index/`, so other apps can read your meetings without access to `~/Documents`.
- **Claude Code routine target.** Confirmed items can start a Claude Code routine in the cloud, with "Open run" on the item.
- **Restricted Claude Code mode** for the Claude Code Do target: it can read and edit files in its work folder, and nothing else.
- **A consent line to copy** ("Quick heads-up: I'm recording this call…") in the panel when a recording starts.
- **Settings in seven tabs:** General, Claude, Live, Calendar, Do, AI apps and Storage.
- **AI apps tab** in Settings, with "Add to Claude Code", "Copy for Claude Desktop", a Command line section with "Copy the install line", and "Copy plugin lines" for the two plugins.
- **Onboarding with Claude.** First launch sets up the microphone, call audio and Claude (your subscription or an API key), then offers four optional rows that stay off until you turn them on: Calendar, Live assistant, Notice calls and Screen reading. The "New in v0.2" sheet shows the same four rows.
- **"New in v0.2" sheet** for people upgrading from 0.1.
- An Icon Composer app icon, a README with screenshots and a live panel GIF drawn from the app's real views, guides in `docs/`, CI, a release workflow that attaches `Earshot.zip` and its SHA-256, issue forms and community files.
- **New `make` targets:** `verify-app` (signatures, the universal helper, the hardened runtime and the icon), `e2e-import` (the built app on an imported file with your own Claude Code), `screenshots` (the README images) and `claude-test` (real calls through your signed-in Claude Code, in temporary folders only).

### Changed

- New installs use Claude through your subscription by default. If you upgrade from 0.1 with an API key saved, Earshot keeps using the key.
- New installs use restricted mode for the Claude Code Do target. If you upgrade with Auto or "Everything, no prompts" selected, Earshot offers once to switch.
- Notes now run Claude Code with a fixed set of flags: no tools, no MCP servers, no customizations, no permission prompts and no saved session, from an empty folder.
- Earshot finds `claude` in more places: `~/.npm-global/bin`, `~/.bun/bin`, `~/.volta/bin`, then your login shell's `PATH`.
- External meetings, and meetings started automatically, always show the confirm window, even with "Ask before sending" off.
- Clicking a meeting opens `notes.html` first, then `notes.md`, then the folder.
- Changes to `session.json` are made under a file lock, so a flag or a Fix can't be overwritten by a stale copy.
- After a crash or quit, recovery marks only the stage that was stopped as failed, so Retry appears for that stage.
- When Ask sends new items and a target fails, Retry sends them only to the targets that failed.
- The README is shorter, and the details moved to guides in `docs/`.

### Security

- Every `claude` that Earshot starts gets an environment built from an allowlist. API keys, tokens and provider switches in your environment (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_USE_*`) never reach it.
- Earshot never asks for, reads or stores your Claude login, including `claude setup-token` tokens.
- Other people's words are data. Transcript, agenda, attendee names, screen text and past lessons always reach a model inside labelled tags, with the rule that they are what people said, never instructions. The same framing applies to Do payloads, routine text, MCP results and the reminders hook.
- Anything that can act on meeting text needs a human click: Start, or Send in the confirm window. One-click Start only goes to Claude Code in restricted mode or to a webhook. Other Claude Code modes show the exact prompt and need a second click. Routines need a setting turned on first.
- MCP tools are read-only and return attendee names and company domains, never full email addresses.
- `earshot reminders` strips backticks, code fences, URLs and shell characters, and labels its output as quoted meeting notes.
- `earshot process --send` only allows webhooks, routines and restricted Claude Code, and reads tokens from the environment, never the Keychain.
- The routine target sends only the approved items, with meeting context in a section marked "Reference only". It deletes a token the server rejects, and never retries a request that may have arrived.
- Agenda text loses links, passcodes, PINs, meeting IDs and dial-in lines before it reaches a model. Screen text is also redacted for keys, tokens and long digit runs, and nothing is read while secure text entry is on or a password manager is in front.
- `notes.html` escapes all text, has no scripts and loads nothing remote.
- A live item is marked as sending on disk before it leaves the Mac, and is never re-sent on its own after a crash.

## [0.1.0] - 2026-10-15

The first release.

### Added

- A menu bar app for macOS 26 that records your microphone and your Mac's audio as two tracks, from any call app.
- Three modes: Record, Notes, and Notes + Do.
- On-device transcription with Apple's speech engine, with echo removal when the call leaks into your mic.
- Notes written by Claude, through an Anthropic API key or Claude Code, in three styles.
- Do targets for the confirmed action items: Claude Code, a webhook and a shell command, with a versioned JSON payload.
- Import of an existing audio file.
- Recovery after a crash or quit, Retry for failed steps, and audio compression to M4A.

[Unreleased]: https://github.com/stephenlthorn/earshot/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/stephenlthorn/earshot/releases/tag/v0.3.0
