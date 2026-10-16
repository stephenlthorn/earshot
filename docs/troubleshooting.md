# Troubleshooting

Find what you see in the tables below, then try the fix next to it.

Two things help with almost any problem:

- **Run `earshot doctor`** in Terminal. It checks Claude, the speech model (and may download it), the meetings folder, the index, the MCP server, the Claude Code plugin and where the app is running from. Each line starts with `ok`, `warn` or `fail` and says what to fix. Add `--json` for the same checks as JSON. To install the `earshot` command, see [AI apps](ai-apps.md#install-it).
- **Look at the meeting's warning.** Each meeting in the menu shows its latest warning or error, and failed steps have a **Retry** button.

```sh
earshot doctor
```

## Installing and updating

| What you see | Fix |
|---|---|
| macOS says Earshot can't be opened, or that Apple couldn't check it for malicious software | Builds are not notarized yet. Try to open Earshot once, then open System Settings > Privacy & Security, scroll to the message about Earshot, click **Open Anyway** and confirm |
| Permissions stopped working after an update | Until builds are notarized, macOS treats each update as a new app. Grant Microphone, Screen & System Audio Recording, Calendars and Notifications again. If Earshot is listed and switched on but still doesn't work, switch it off and on, or remove it with the minus button and let Earshot ask again |
| "Move Earshot to Applications first" (in Settings > AI apps, or from `earshot doctor`) | macOS is running Earshot from a temporary location because it was opened from Downloads (this is called translocation). Quit Earshot, drag `Earshot.app` into your Applications folder in Finder, and open it from there |
| No Earshot icon in the Dock | That's normal. Earshot lives in the menu bar: look for the waveform icon |

## Recording

| What you see | Fix |
|---|---|
| The other side of the call is missing, or "The call audio was silent" | Earshot records the call through the Screen & System Audio Recording permission, and macOS gives no error when it's denied: it just records silence. Allow Earshot in System Settings > Privacy & Security > Screen & System Audio Recording. Then press **Test** on the Call audio row of the setup checklist (Settings > General > **Setup checklist…**). The test plays a short sound, so make sure your Mac isn't muted |
| The call track has music or other sounds in it | The call track records everything your Mac plays. Pause music and videos before the call |
| Record is greyed out, or "Grant microphone access" | Click **Grant microphone access** in the menu. It opens System Settings > Privacy & Security > Microphone, where you allow Earshot |
| "Less than 500 MB of disk space is free, so Earshot can't record." | Free some space on the drive that holds the meetings folder, or move the folder in Settings > Storage. Below 2 GB, Earshot still records but warns you |
| "Recording stopped: less than 500 MB of disk space was left." | Earshot stops a recording when the drive runs that low (checked every 30 seconds). Free space or move the folder in Settings > Storage |
| Your own voice is in the transcript twice | Your speakers leak the call into your mic. Earshot removes most of these repeats. Use headphones, or turn on **Echo cancellation on my mic** in Settings > General (meant for speakers, not headphones) |
| "Earshot couldn't register ⌃⌥⌘F" in Settings > Live | Another app already uses that shortcut. Quit that app or change its shortcut, then turn **Flag a moment with ⌃⌥⌘F** off and on again, or reopen Earshot. You can still flag with the panel's Flag button or by saying "flag that" with the live assistant on. If another app holds ⌃⌥⌘H, Earshot shows no message: use the **Sharing** button in the panel's header instead |
| Earshot didn't notice a call | Check that **Notice when a call app uses the microphone** is on in Settings > Calendar. The app must be on Earshot's list of call apps or browsers, and it must use a real microphone (virtual and aggregate audio devices don't count). Earshot asks about the same app at most once every 10 minutes, and never while it is already recording. See [Noticing calls](calendar-and-calls.md#noticing-calls) |
| A call notice never appeared | Notifications may be off. Allow them in System Settings > Notifications > Earshot. Without notifications, the menu bar icon shows a badge and the choice waits in the menu |
| A recording didn't stop when the call ended | Earshot only stops recordings that began from a call: started automatically, or with **Record** on its call question. It waits until the app has used no input for 45 seconds and the call looks over. If it can't tell, it asks, and stops by itself after 5 minutes unless you answered **Keep recording**. With **Stop when the call ends** off, it asks and waits for you. Recordings you started from the menu are never stopped automatically |

## Claude

Earshot shows Claude's status in Settings > Claude. When you start a recording in Notes or Notes + Do mode, Earshot also warns if it can't find Claude Code, if no API key is set, or if the local model has no address or model. **A Claude problem never stops a recording:** the recording starts anyway, and the notes step fails into Retry. See [Claude setup](claude-setup.md) for the full setup.

| What you see | Fix |
|---|---|
| "Claude Code not found", or "Claude Code wasn't found. Install it, or set its path in Settings, Claude." | Install Claude Code, then run `claude` once in Terminal and sign in. Earshot looks in `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.bun/bin` and `~/.volta/bin`, then asks your login shell. If yours is somewhere else, run `whence -p claude` in Terminal and pick that file with **Choose claude…** in Settings > Claude. The path is set there, in the Claude tab |
| "Claude Code can't start: …" | Earshot found a `claude` file but couldn't run it. Run `claude --version` in Terminal to see why, or pick another file with **Choose claude…** |
| "Claude Code is not signed in: run `claude` in Terminal and log in" | Run `claude` in Terminal and sign in with your Claude account. If it says "Login expired", run `/login` inside Claude Code. Then press **Check** in Settings > Claude, and **Retry** on any failed meeting |
| "Claude Code <version> is too old; update it", or "Claude Code is too old; update it." | Earshot needs Claude Code 2.1.259 or later. Run `claude update`, or update it the way you installed it. Then press **Check** in Settings > Claude |
| "No Claude API key is set" or "Anthropic rejected the API key" | You chose the API key provider. Paste a working key from console.anthropic.com in Settings > Claude, or press **Use my Claude subscription instead**. `earshot doctor` reads the key only from `ANTHROPIC_API_KEY`, not from the Keychain |
| "Claude Code is set to use an API key, not your subscription" (or "an API key helper", "a token", "another provider") | Your Claude Code itself is set up to use something other than your Claude login. Run `claude auth status` in Terminal to see what it uses. Sign in with your Claude account with `/login` in Claude Code, or switch Earshot to the API key provider in Settings > Claude |
| "Your Claude usage limit is reached. Press Retry later." | Your plan's usage window is used up. Press **Retry** on the meeting once it resets. On a Pro plan, use Sonnet for notes and leave the live assistant off. An API key avoids plan limits, at API prices |
| "Paused: Claude usage limit" or "Paused: Claude Code is not signed in" in the panel | The live assistant stopped for the rest of this meeting. Recording carries on, and the notes run after the call as usual. Fix the cause before the next call |
| "Paused: the live model isn't available, pick another in Settings, Live" in the panel | Your plan or key can't use the model typed in **Live model** in Settings > Live, or it is misspelled. Pick another model from the menu next to the field. The live assistant stopped for the rest of this meeting |
| "Paused: Claude Code is too old, update it", "Paused: check the API key in Settings, Claude" or "Paused: Claude Code wasn't found, check Settings, Claude" in the panel | A setup problem that won't fix itself during the call, so the live assistant stopped for the rest of this meeting. Fix it in Settings > Claude before the next call |
| "Paused: Claude isn't set up" in the panel | Earshot couldn't find Claude Code when the recording started, so the live assistant didn't run. Fix the status in Settings > Claude |
| "Your plan can't use <model>; pick another in Settings." | Choose a different model for that role in Settings > Claude > Models: **Notes and Fix**, **Live to-dos** or **Brief and Ask** |
| The notes step failed, with a **Retry** button | The recording and transcript are safe. Fix the cause shown on the meeting, then press **Retry**. After two failures in a row, Earshot waits for you to press Retry instead of trying again by itself |
| "Couldn't reach Claude; trying at the next check" in the panel | A live call failed. Earshot tries again at the next check, every 90 seconds by default (**Check every** in Settings > Live). If it keeps happening, check the status in Settings > Claude |
| "The model's answer came back in the wrong shape", or "The notes came back in the wrong shape" | The model didn't follow the answer format. Press **Retry**. With a local model, a bigger model follows it more often |

### Local models

With a local model, Settings > Claude shows the server's status instead, and the same line is the **Local model** check in `earshot doctor`. The [local models guide](local-models.md#troubleshooting) has the full list.

| What you see | Fix |
|---|---|
| "Can't reach the local model server at …" or "Can't reach … Start Ollama, LM Studio or your server." | Start the server, check the address and port in Settings > Claude, then press **Check** |
| "… has no chat endpoint. Check that the address ends in /v1." | Add `/v1` to the address, or click the button for your server under **Server address** |
| "The local server has no model named …" or "… has no model named …" | Pick a model the server lists, or download it first, for example `ollama pull qwen3:8b` |
| "The meeting is longer than the local model's context window." | Raise the server's context length (`OLLAMA_CONTEXT_LENGTH=32768 ollama serve` for Ollama), then press **Retry** |
| "The local model didn't answer within … minutes. Try a smaller model." | The model is too slow for this Mac. Try a smaller model, then press **Retry** |
| "Couldn't reach the local model; trying at the next check" in the panel | A live pass failed or took too long. Set **Check every** in Settings > Live to 120 seconds or more |
| "Paused: the local model isn't set up, check Settings, Claude" in the panel | No server address or no model was set when the recording started. Set both in Settings > Claude before the next call |

## During a call

| What you see | Fix |
|---|---|
| The panel showed up in your screen share | Earshot **tries** to hide the panel from screen sharing ("Try to hide the panel when I share my screen" in Settings > Live), but some call apps capture it anyway. Before you share, press the **Sharing** button in the panel's header or ⌃⌥⌘H: the panel shrinks to a small pill that shows only the recording dot and the timer. Sharing one window instead of the whole screen also keeps the panel out. You can also turn off "Show the panel during calls" |
| No live to-dos appear | Check that **Find to-dos during the call** is on in Settings > Live and the mode is Notes or Notes + Do. Earshot waits for at least 150 new characters of speech before each check, so a quiet stretch shows nothing. The status line in the panel says what it's doing |
| No Start button on live to-dos | Start appears only with the live assistant on, in Notes + Do mode, on to-dos with the AI badge, and only when the target under "Start sends to" works. If no target works, you see "Set up a Do target" instead. A routine also needs "Allow Start during calls for routines". See [Do targets](do-targets.md#starting-items-during-a-call) |
| No brief when the call started | A brief needs **Use my calendar** and **Show a short brief when a meeting starts** on, and either an agenda on the current event or a related past meeting (same people, or the same title when nobody else is invited). It isn't written in Record mode, and the panel must be showing for you to see it. If writing it fails, or you stop before it's ready, Earshot skips it quietly |
| "Calendar access is off" in Settings > Calendar | Click **Open System Settings**, then allow Earshot full access in Privacy & Security > Calendars |
| Notes never mention what was shared on screen | See [Screen reading](screen-reading.md#troubleshooting) |

## Do targets

| What you see | Fix |
|---|---|
| Claude Code finished as failed or partial, with denied paths | In Restricted mode Claude Code can only work with files inside the work folder. The detail and `do-claude-code.log` list what was refused. Move the work into the work folder, or choose a different mode if you understand the risk. See [permission modes](do-targets.md#permission-modes) |
| "Interrupted while sending to …" | Earshot quit or crashed while a target was working. It never re-runs Claude Code, a command or a routine on its own. Check what was done, then press **Retry** if you want to send again |
| The webhook fails with a 4xx | Your receiver refused the request, so Earshot doesn't retry. (408 and 429 are the exceptions: Earshot tries those up to three more times.) `do-webhook.log` has the status and the first 300 bytes of the response |
| Your command fails with "command not found" | The command runs in a zsh login shell that reads `~/.zprofile`, not `~/.zshrc`. Set `PATH` in `~/.zprofile` |
| Routine: "The routine token is wrong or was regenerated" (401) | Earshot deleted the stored token. On claude.ai/code/routines, open the routine's API trigger, regenerate the token, and paste it into Settings > Do |
| Routine: "Hourly limit reached; try again in …" (429) | A routine can be fired 30 times an hour, and an account 100 times. Wait for the time shown ("later" when the server gave none), then press **Retry** |
| Routine: a timeout or network error that says "It may have started a run" | Earshot can't tell whether the run started, so it doesn't retry. Check the routine's runs on claude.ai/code before pressing **Retry** |

More routine errors are in [Do targets](do-targets.md#errors).

## AI apps

| What you see | Fix |
|---|---|
| "Allow <app> to access your Documents folder, or move the Earshot folder in Settings." | macOS blocked Claude Code or Claude Desktop from reading `~/Documents`. Open System Settings > Privacy & Security > Files and Folders and turn on **Documents Folder** for the app named (such as Terminal, iTerm, Visual Studio Code or Claude), then reopen it. Or move the meetings folder out of Documents in Settings > Storage. See [Documents folder access](ai-apps.md#documents-folder-access) |
| The Earshot tools don't appear in Claude Code | Run `claude mcp get earshot` to check the server, or `/plugin` if you use the plugin. The plugin needs Earshot in `/Applications` or `~/Applications`. With `claude mcp add`, the path you added must still exist, so if you moved the app, add it again. Use the plugin or `claude mcp add`, not both |
| "Earshot.app was not found in /Applications or ~/Applications" | The plugin looks for the app in `/Applications` and `~/Applications` only, never on your `PATH`. Move Earshot there, open it once, then restart Claude Code |
| A meeting you deleted still shows in Claude Code or `earshot list` | The CLI and AI apps read the index, which keeps a copy. Press **Rebuild the index** in Settings > Storage |
| Claude Desktop doesn't show the Earshot tools | Check that `claude_desktop_config.json` is valid JSON and that the path is `/Applications/Earshot.app/Contents/Helpers/earshot` with the argument `mcp`. Quit Claude Desktop completely and reopen it. The log is `~/Library/Logs/Claude/mcp-server-earshot.log` |
| `earshot: command not found` | In Settings > AI apps, click **Copy the install line** and paste it in Terminal. It links `earshot` into `~/.local/bin`, so make sure that folder is on your `PATH`. See [AI apps](ai-apps.md#install-it) |

## Still stuck?

Open an issue on GitHub with what you did, what you expected and what happened, plus the output of `earshot doctor`. Please don't paste transcripts, notes, API keys or tokens: they can contain private data. Security problems go to the private reporting form described in [SECURITY.md](../SECURITY.md).
