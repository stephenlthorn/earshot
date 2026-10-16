# Privacy and consent

Earshot records conversations with other people, so it is built to keep as much as possible on your Mac and to send as little as possible anywhere else. This guide says exactly what stays, what leaves, when, and where it goes. It ends with your part: telling people you're recording.

## The short version

- **Audio never leaves your Mac.** Transcription runs on your Mac with Apple's speech engine.
- **Screenshots never leave your Mac.** If you turn on screen reading, text is read from them on your Mac.
- **With a local model on your Mac, the AI features keep the text on your Mac too.** Notes, live to-dos, the brief, Ask and Fix all run on your own server. Do targets you turn on still send the to-dos you confirm (see below), and a server on another machine gets the text you send it. See [Local models](local-models.md).
- **Otherwise only text goes to Claude,** and only for the features you use: transcript excerpts, the meeting title and a cleaned agenda, attendee names and company domains (never full email addresses), and cleaned screen text if screen reading is on.
- **Every v0.2 feature that reads more is off until you turn it on:** the live assistant, the calendar, call detection and screen reading.
- **No analytics, no telemetry.** Earshot doesn't phone home.
- **Earshot never touches your Claude login.** It doesn't read, store or pass on your Claude credentials.

## What stays on your Mac

| What | Where | Notes |
|---|---|---|
| Audio | The meeting folder (`~/Documents/Earshot` by default) | Kept compressed (about 15 MB per track per hour) unless you set **Audio** to "Delete it once notes exist" in Settings > Storage |
| Transcripts, notes, the notes page | The meeting folder | `transcript.md`, `notes.md`, `notes.html` and their JSON versions |
| Live to-dos, the brief, flags, questions and answers | The meeting folder | `live.json`, `brief.json`, `session.json`, `qa.json` |
| Do target logs | The meeting folder | `do-<target>.log`, for example `do-webhook.log` |
| Screen text | The meeting folder, `screen.json` | Screenshots, in a `screen` folder, only with "Keep screenshots (never sent)" on (off by default) |
| What Earshot learned from your edits | `~/Library/Application Support/Earshot/lessons.json` | At most 200 examples. Settings > Storage has **Learn from my edits** and **Forget what Earshot learned…** |
| The meetings index | `~/Library/Application Support/Earshot/Index/` | A read copy for the CLI and AI apps. See [AI apps](ai-apps.md#documents-folder-access) |
| Your calendar | Read from macOS, never copied in full | Only the current event is stored, in its meeting's `session.json`, with at most 50 attendees and the agenda cut to 1,500 characters. That copy includes attendees' email addresses, which never leave your Mac |
| Settings | macOS preferences for `com.stephenthorn.earshot` | Includes your webhook and routine URLs, but no keys or tokens |
| API key, webhook token, routine token | The macOS Keychain, service `com.stephenthorn.earshot` | Never written to settings, meeting folders or logs |

`~/Documents` may be synced by iCloud Drive (if Desktop & Documents is on) and backed up by Time Machine, so your audio, transcripts and notes can be copied off your Mac that way. If you don't want that, move the meetings folder in Settings > Storage.

## What goes to Claude, and when

Earshot writes notes in one of three ways, chosen in Settings > Claude:

- **Your Claude subscription, through Claude Code** (the default). Earshot runs your own installed Claude Code, which sends the text to Anthropic under your own login. For notes and the other text features it runs Claude Code in safe mode with no tools, so your hooks, plugins, MCP servers, settings files and CLAUDE.md files don't load and don't see the text. Claude Code doesn't inherit Earshot's environment: it gets only a short list of variables such as `HOME` and `PATH`. This runs your own Claude Code with your subscription. Anthropic's terms may change; an API key is the fully supported route. `make claude-test` passed all 15 checks on a Team plan, and `make e2e-import` has passed on Max and Team plans. See [Claude setup](claude-setup.md).
- **An Anthropic API key.** Earshot sends the text to Anthropic's API (`api.anthropic.com`) under your key.
- **A local model.** Earshot sends the same text to the server at the address you set, such as Ollama at `http://localhost:11434/v1`, and to nothing else. With the server on your Mac, the text never leaves it. Plain `http://` is allowed only for this Mac and your local network; anything else must use `https://`. Earshot never sends a key to that server and never follows a redirect. See [Local models](local-models.md).

The table below says what each feature sends, whichever way you chose. Everything below is text. Each piece of other people's words goes to the model inside a labelled block with the rule that it is information from the meeting, never an instruction.

| Feature | When it sends | What it sends |
|---|---|---|
| **Record** mode | Never | Nothing |
| **Notes** (Notes and Notes + Do modes) | Once, after the call, and again if you press Retry | The transcript; the title and a cleaned agenda; attendee names and company domains; flagged moments; open items from related past meetings; to-dos already started during the call; up to 8 examples of your past edits; cleaned screen text (up to 8,000 characters) if screen reading is on |
| **Live assistant** (off by default) | At each check during the call: every 90 seconds by default, about 40 calls an hour, and only after at least 150 new characters of speech | The newest transcript text (up to 8,000 characters) plus 60 seconds before it; the title and attendee names; the to-dos found so far; flags; up to 6 examples of your past edits |
| **Brief** (needs the calendar) | Once, as a recording starts with the calendar on, unless the mode is Record or there is nothing to brief from | The event title and cleaned agenda (when there is an event), attendee names and domains, and the summary, decisions and action items of up to 5 related past meetings |
| **Ask** | When you ask a question | Your question, that meeting's transcript (up to 300,000 characters), its notes and flags |
| **Fix the notes** | When you ask for a fix | Your instruction, and the meeting's notes, flags and transcript (up to 300,000 characters) |
| **Calendar** (off by default) | Never by itself | The event is read on your Mac. Only what the table rows above list ever reaches Claude |
| **Call detection** (off by default) | Never | It watches which apps use the microphone, on your Mac. Nothing is sent |
| **Screen reading** (off by default) | Only as part of the notes | Cleaned text, never images. See [Screen reading](screen-reading.md) |

What "cleaned" means:

- **The agenda:** links become `[link]`, email addresses become their domain, and lines that mention a passcode, password, PIN, meeting or conference ID, access code or dial-in are dropped.
- **Screen text:** much the same, plus private key blocks, anything that looks like a key or token, card numbers and IBANs, and runs of 9 or more digits.
- **Attendees:** names and company domains only (Dana, acme.com). Full email addresses never go to Claude.

## What goes to your Do targets

In Notes + Do mode, and when you press Start on a live to-do, the items you confirm go to the targets you switched on. See [Do targets](do-targets.md) for each one.

| Target | What it gets | Where it goes |
|---|---|---|
| Claude Code | The notes and the confirmed items, as a prompt | Your Mac, then Anthropic through your Claude Code login. In modes other than Restricted, your Claude Code hooks, plugins and MCP servers see the prompt too |
| Webhook | The payload: the notes, the confirmed items and two file paths. Never the transcript text or audio | Your URL |
| Command | The same payload, on standard input | Your Mac. The command starts in the meeting folder and can read everything there, including the transcript and audio |
| Claude Code routine | A short text: the confirmed items, their context and the summary | Anthropic's cloud, as a run of your routine |

An item started during a call sends only that item and the reason it was suggested, never transcript text.

## What AI apps can read

The CLI, the MCP server and the plugins read your meetings on your Mac, from the index in Application Support. When you use them from Claude Code or Claude Desktop, whatever the tools return becomes part of that conversation, and that app sends it to Anthropic like anything else you show it. The `earshot-reminders` plugin adds up to five of your open items from the last seven days to each Claude Code session as it starts, resumes or is cleared. Install it only if you want that. See [AI apps](ai-apps.md).

## Network connections

Apart from Claude Code, which makes its own connections, these are the only network connections Earshot makes:

- Anthropic's API, with the API-key provider;
- your local model server, with the local model provider;
- Apple, to download the speech model the first time;
- your webhook URL, if you set one up;
- your routine's fire URL at `api.anthropic.com`, if you set one up.

## Telling people you're recording

**You are responsible for recording lawfully.** Recording laws differ from place to place, and Earshot can't know where you or the people on your call are.

- **All-party consent.** Many places, including several US states, require everyone in the conversation to agree to be recorded, not just you. Several countries have similar rules.
- **Data protection.** In the EU and the UK, a recording of a person is personal data, so data protection law (GDPR) applies to how you record, keep and share it.
- **Calls across borders.** When people join from different places, the strictest rule that applies is the safe one to follow.
- **Work calls.** Your employer or your clients may have their own rules about recording and about AI note-takers.

This is not legal advice. When in doubt, ask everyone at the start and only record if they agree.

### How Earshot helps

When a recording starts and the consent reminder is on (the default):

- **The panel shows a "Let everyone know" banner** with **Copy line**, so you can paste the line into the call chat. It stays for 2 minutes. For a recording that began from a call, it stays until you dismiss it.
- **If "Show the panel during calls" is off,** a notification reminds you instead, with **Copy consent line**.

The default line is:

> Quick heads-up: I'm recording this call so an AI assistant can transcribe it and take notes. I'll share the notes afterwards.

With screen reading on, Earshot adds:

> It also reads what's shared on screen.

You can change the line in **Line to copy**, or turn off **Remind me to tell everyone I'm recording**, in Settings > Calendar > Consent. The reminder never blocks the recording.

**Recordings Earshot starts on its own.** With "Start recording automatically" on, Earshot can start recording when it notices a call. It's off by default. If you turn it on, the banner stays until you dismiss it, and you still need to tell people.

## Deleting your data

- **One meeting:** delete its folder from the meetings folder, then press **Rebuild the index** in Settings > Storage. Until you do, the CLI, the MCP server and the plugins can still read the copy in the index.
- **What Earshot learned:** Settings > Storage > **Forget what Earshot learned…**.
- **Everything:** quit Earshot, then delete the meetings folder and `~/Library/Application Support/Earshot`. If you saved keys or tokens, open Keychain Access and remove the items for `com.stephenthorn.earshot`. To clear your settings too, run `defaults delete com.stephenthorn.earshot` in Terminal.

Text already sent to Claude is handled under your agreement with Anthropic, not by Earshot.
