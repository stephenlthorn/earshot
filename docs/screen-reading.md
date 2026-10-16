# Screen reading

Screen reading lets Earshot read the text that people share on screen during a call. When someone says "this number here" or "as you can see on this slide", the notes can say which number and which slide.

It is optional and **off by default**. Everything it captures is read on your Mac. Screenshots never leave your Mac, and only cleaned-up text goes to Claude, as part of the notes.

## What it does

While you record, in any mode, Earshot looks at the call app's windows every 15 seconds. When the picture has changed, it reads the text in it with Apple's on-device text recognition (Vision). It removes anything that looks like a secret, keeps the text with a timestamp, and throws the picture away unless you chose to keep screenshots.

After the call, the notes stage picks the screen moments that matter most and gives that text to Claude along with the transcript. The notes page also marks screen moments on its timeline.

## Turn it on

1. Open **Settings > Live**.
2. Under Screen, turn on **Read my screen during calls**. You can also turn on **Screen reading** during onboarding.
3. macOS asks you to allow Earshot under **Screen & System Audio Recording**. Allow it in System Settings > Privacy & Security > Screen & System Audio Recording.
4. Quit Earshot and open it again. macOS usually applies a Screen Recording grant only after the app restarts.

If the permission is off, Settings shows "Screen Recording is off" with **Allow…** and **Open System Settings** buttons, and Earshot captures nothing. **Check** reads the permission again.

### What macOS shows you

- **A purple indicator.** While Earshot captures a window, macOS shows its screen recording indicator in the menu bar. That is expected.
- **A monthly check.** Since macOS 15, macOS asks you from time to time, about once a month, whether an app may keep recording the screen. Choose **Allow For One Month** to keep screen reading working. If you decline, Earshot stops capturing until you allow it again.
- **After each update.** Earshot builds are not notarized yet, so macOS treats each update as a new app. You have to grant Screen Recording again after every update until builds are notarized.

## What is captured

| Situation | What Earshot captures |
|---|---|
| A call app was detected (Zoom, Teams, FaceTime, Webex, Slack, Discord, Skype, Tuple, Loom) | Only that app's windows, on the display that shows them most |
| A call in a browser (Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera) | Only the frontmost browser window |
| **Read the whole display, not just the call app** is on | The main display, without Earshot's own windows. This is an explicit choice and off by default. It still needs a call app to be known |
| No call app is known | Nothing |

Some details:

- Earshot captures through a ScreenCaptureKit filter that includes only those windows. Other apps, your desktop and Earshot's own windows are not in the picture. The pointer is not captured.
- Pictures are scaled to at most 1440 pixels wide before the text is read.
- Capture runs only while a recording is running. It stops when you press Stop.
- To know which app is the call, screen reading uses the call app that call detection found. Without one, it looks at each sample for a call app that is using the microphone right then. See [Calendar and call detection](calendar-and-calls.md).

## What is skipped

Earshot skips a frame entirely, without reading it, when:

- **secure text entry is on**, for example while you type a password in any app;
- **a password manager is the frontmost app**: 1Password, Bitwarden, Dashlane, Keeper, Apple Passwords or Keychain Access.

It also keeps only frames that are worth keeping:

- **Changed frames only.** A frame is kept only when it differs from the last kept frame by more than 12% (Earshot compares a small 16 by 16 fingerprint of each picture).
- **Real text only.** Frames with fewer than 20 characters of text (not counting spaces), after redaction, are dropped.
- **No near-duplicates.** Text that is at least 80% the same as the last kept frame is dropped.
- **A cap.** A meeting keeps at most 120 screen moments.

## Redaction

Before any screen text is stored, Earshot cleans it on your Mac. It removes:

- web, mail and phone links, which become `[link]`;
- email addresses, which become `[address at example.com]`;
- whole lines that mention a passcode, password, PIN, meeting ID or dial-in, including names like `DB_PASSWORD=`;
- private key blocks;
- anything that looks like an API key or access token, which becomes `[redacted]`;
- card numbers, IBANs and runs of 9 or more digits, such as account or phone numbers, which become `[number]`.

Redaction is pattern matching, so it can miss things. If you need to share sensitive material on screen, turn off **Read my screen during calls** first: a recording that is already running stops reading at once and keeps recording. Or don't share it while Earshot is recording.

## Where it is stored

| What | Where | Leaves your Mac? |
|---|---|---|
| The screen text and its timestamps | `screen.json` in the meeting folder | Only as part of the notes request (below) |
| Screenshots | Not kept. With **Keep screenshots (never sent)** on (off by default), they are saved as `screen/001.png`, `screen/002.png` and so on in the meeting folder | Never |

`screen.json` looks like this:

```json
{
  "version": 1,
  "moments": [
    { "offset": 1312.0, "text": "Q4 pilot pricing\nTeam of 8: $1,200/month\nKickoff: Tuesday" }
  ]
}
```

`offset` is seconds from the start of the recording, on the same clock as the transcript. With screenshots kept, each moment also has an `image` field with its file name under `screen/`.

## What Claude sees

Of Earshot's own Claude calls, only the notes stage uses screen text. Live to-dos, the brief and Ask don't.

The notes request includes up to 8,000 characters of screen text, inside a block labelled as information from the meeting and never an instruction. The text is redacted again before it goes, in case `screen.json` was edited. Earshot picks moments in this order:

1. moments within 60 seconds of a flag you set;
2. moments within 30 seconds of a transcript line that points at the screen ("this slide", "this number", "on screen", "you can see", "as shown", "this chart");
3. moments spread evenly across the call.

## Tell people

When screen reading is on, Earshot's consent line adds a sentence, unless your line already has it: "It also reads what's shared on screen." See [Privacy and consent](privacy-and-consent.md).

## Turn it off

Turn off **Read my screen during calls** in **Settings > Live**. A recording that is already running stops reading at once, saves what it already read and keeps recording. A screenshot being read at that moment is thrown away, with its text. Switching it back on takes effect at the next recording. To remove what was already captured, delete `screen.json` (and `screen/`, if you kept screenshots) from the meeting folder.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Notes never mention what was on screen | Check that **Settings > Live** doesn't say "Screen Recording is off". Quit and reopen Earshot after granting it. Make sure the call app was detected or is using the microphone: screen reading captures nothing when no call app is known. Record-only meetings get no notes, so the text is only in `screen.json`. |
| Screen reading stopped working after a few weeks | macOS asked for its monthly check and it was declined or missed. Allow Earshot again in System Settings > Privacy & Security > Screen & System Audio Recording. |
| Screen reading stopped after an update | Grant the permission again. Unnotarized builds lose their grants on each update. |
| The text came from the wrong window | During a browser call, Earshot reads the frontmost browser window. Keep the call's window in front while something is shared. |

More fixes are in [Troubleshooting](troubleshooting.md).
