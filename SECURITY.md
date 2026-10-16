# Security policy

Earshot records your meetings, runs your own Claude Code, and can hand action items to other programs. Security bugs here can expose private conversations, so please report them privately.

## Supported versions

Only the latest release gets security fixes.

| Version | Supported |
|---|---|
| 0.2.x | Yes |
| 0.1.x | No: please update |

## How to report

Please don't open a public issue for a security problem.

1. Go to [Report a vulnerability](https://github.com/stephenlthorn/earshot/security/advisories/new). This is GitHub's private reporting form, and only the maintainer can see what you send.
2. Say what you found and what an attacker could do with it.
3. Give the steps to reproduce it, with made-up meeting content. Never send a real recording, transcript or key.
4. Include your Earshot version, your macOS version, your Claude Code version (`claude --version`) and which Claude provider you use (subscription or API key).

I'll reply as soon as I can. We'll agree on a fix and a disclosure date with you, and credit you in the release notes unless you'd rather we didn't.

## What Earshot can reach

So you can judge what counts as a bug, here is what Earshot touches:

- your microphone and your Mac's audio output, and optionally your calendar and the text in a call app's windows;
- meeting folders, by default in `~/Documents/Earshot`, and its own files in `~/Library/Application Support/Earshot`;
- secrets in the Keychain: your Anthropic API key, your webhook token and your routine token;
- your own `claude` command, which it runs for notes and, if you set it up, as a Do target;
- the Do targets you switch on: Claude Code, a webhook, a shell command, a Claude Code routine.

Earshot is not sandboxed, because it runs other programs with your permissions. It uses the hardened runtime.

## In scope

### Credentials

Earshot must never read, store or pass on your Claude login. That includes the Keychain item and files Claude Code keeps, and `claude setup-token` tokens. Its own secrets must stay in the Keychain. Report it if you find any of these:

- your Claude login, or a token, read or copied by Earshot;
- the API key, webhook token or routine token written to settings, a meeting folder, a log, a payload or the index;
- an API key, token or provider switch from your environment reaching a `claude` child (every child should get only the allowlisted environment);
- a token sent to a host other than the one it belongs to.

### Prompt injection from meeting content

Anyone on a call can say anything, and that text ends up in prompts. Agendas, attendee names and shared screens are the same. Earshot treats all of it as data: it reaches a model inside labelled tags, and nothing acts on it without a human click. Report it if meeting content can:

- start a Do target, a routine, a command or any other action without you pressing Start or Send;
- get past the one-click rules, for example making an item start in a non-restricted Claude Code mode with one click;
- make the MCP server, the CLI or the reminders hook output text that a client would treat as an instruction instead of quoted content;
- get raw transcript text into a Do payload or routine text where the docs say it isn't sent;
- inject a script or a remote resource into `notes.html`.

### Other things we want to hear about

- another app, website or person triggering a recording, a Do target or the MCP server without your consent;
- an MCP tool that can change anything, or that returns full email addresses the caller didn't pass in;
- screen reading capturing windows other than the call app's (unless you chose "Whole screen"), or capturing while secure text entry is on;
- text sent to Claude that the docs say stays on the Mac, such as audio, screenshots or full email addresses.

## Out of scope

- **Risks you opted into.** The Claude Code Do target in Auto or "Everything, no prompts" mode, and the Command target, run with your permissions by design. The docs explain the risk. A model doing something unwise there after you pressed Send is not a vulnerability in Earshot, unless meeting text got there without your click.
- **Screen sharing.** The live panel *tries* to hide from screen sharing. Some call apps may still show it. Use the Sharing button (⌃⌥⌘H) to collapse it. Report a call app where hiding fails as a normal bug.
- **Unnotarized builds.** Builds are not notarized yet, so macOS shows a warning on first launch. That is known.
- **Claude Code, Claude Desktop and Anthropic's services.** Report problems in those to Anthropic.
- **An attacker who already controls your Mac account.** Anyone who can run code as you can read your meetings anyway.
