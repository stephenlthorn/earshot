# Building from source

This guide is for you if you want to build Earshot yourself, run its tests or change the code. If you only want to use the app, download it from the [latest release](https://github.com/stephenlthorn/earshot/releases/latest) and follow [Getting started](getting-started.md) instead.

## What you need

- A Mac running macOS 26 (Tahoe), Apple silicon or Intel.
- Xcode 26.x. Earshot is developed with Xcode 26.5, and CI builds it with Xcode 26.6. The package needs Swift tools 6.2 or later, which every Xcode 26 brings.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), which turns `project.yml` into the Xcode project. The project file is generated and never committed.
- `python3`, for the test checkers. Xcode includes one.

Some targets need more:

| For | You also need |
|---|---|
| `make screenshots` | Google Chrome and ffmpeg |
| `make claude-test`, `make e2e-import` and `make e2e` | Claude Code 2.1.259 or later, signed in with a Claude plan |
| `make e2e` | The microphone and call audio permissions for Earshot |

Earshot has no third-party Swift dependencies, so there is nothing else to download.

Install XcodeGen, and ffmpeg if you will render screenshots, with Homebrew:

```sh
brew install xcodegen ffmpeg
```

If you have more than one Xcode, check which one is active:

```sh
xcodebuild -version
```

Switch with `xcode-select` if you need to:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Get the code

```sh
git clone https://github.com/stephenlthorn/earshot.git
cd earshot
```

## How the code is laid out

| Folder | What it holds |
|---|---|
| `Packages/EarshotKit` | A Swift package with all the logic: capture, transcription, the pipeline, the Claude client, Do targets, the library index, the `earshot` command-line tool and the MCP server. Almost every test lives here. |
| `App/` | The menu bar app: a thin SwiftUI and AppKit layer that wires EarshotKit to windows, the panel and system permissions. |
| `plugins/` and `.claude-plugin/` | The two Claude Code plugins and the marketplace file that lists them. |
| `Scripts/` | The end-to-end, Claude and screenshot scripts that `make` runs, and their Python checkers. |
| `docs/` | These guides, and `docs/images` for the README pictures. |

See [Architecture](architecture.md) for how the pieces fit together.

## The make targets

Every job has a `make` target. Run them from the repo root.

| Target | What it does | What it needs |
|---|---|---|
| `make test` | EarshotKit unit tests, then the tests of the scripts' checkers | Xcode and Python 3 only: no microphone, no permissions, no Claude |
| `make device-test` | The unit tests plus the tests that use the Mac itself | macOS 26 speech assets, audio output |
| `make app` | Builds and signs `Earshot.app`, then runs `verify-app` | Xcode and XcodeGen |
| `make verify-app` | Checks a built app's signatures, helper, version and icon | A built app |
| `make run` | `make app`, then opens the app | Xcode and XcodeGen |
| `make release` | `make app`, then zips it to `build/Earshot.zip` and checks the zip | Xcode and XcodeGen |
| `make e2e` | `make app`, then records a scripted meeting played through your speakers | Microphone and call audio permissions, Claude Code signed in |
| `make e2e-import` | `make app`, then the app processes an audio file end to end | Claude Code signed in |
| `make screenshots` | `make app`, then renders the README pictures | Google Chrome, ffmpeg |
| `make claude-test` | Real Claude calls through your own Claude Code | Claude Code signed in with a Claude plan |
| `make local-test` | The same checks against your own local model server | A local server, `EARSHOT_LOCAL_URL` and `EARSHOT_LOCAL_MODEL` |

### Two variables

- **`SIGN_IDENTITY`** is the code signing identity for `make app`, and so for `make run`, `make release`, `make e2e` and `make e2e-import`. The default, `-`, signs ad hoc. See [Keep your permissions between builds](#keep-your-permissions-between-builds).
- **`EARSHOT_BUILD_LOCK`** is a path to a lock file. When it is set, `make screenshots`, `make claude-test` and `make local-test` run their builds (and the screenshot render) under `/usr/bin/lockf`, so two heavy jobs on one Mac wait for each other instead of running at once. Use it when a script or another session may build at the same time:

  ```sh
  EARSHOT_BUILD_LOCK=/tmp/earshot-build.lock make claude-test
  ```

### What the tests touch

| Target | Writes to | Never touches |
|---|---|---|
| `make test` | Temporary folders and throwaway `UserDefaults` suites | A model, a permission, your meetings, your Settings, your library index, your Keychain |
| `make device-test` | The same, plus one throwaway login Keychain item it deletes again | Your meetings, Settings, index and existing Keychain items |
| `make claude-test` | A temporary folder, with its own meetings folder and index for each check | Your meetings, your index (it checks before and after), your lessons and your Earshot settings |
| `make e2e-import` | A temporary folder, with its own meetings folder, library index and lessons | Your meetings, your index and your saved Settings |
| `make e2e` | A temporary folder in `/tmp`, with its own meetings folder, library index and lessons | Your meetings, your index and your saved Settings |
| `make screenshots` | `docs/images/screens/` and `docs/images/live-panel.gif` | Your Settings, meetings, index and Keychain |

### Unit tests

```sh
make test
```

This runs `swift test` in `Packages/EarshotKit`. The tests use Swift Testing and fakes for everything outside the process: the Claude client, the calendar, the audio process list, the screen capturer, the text recognizer and the clock. They never call a model and never need a permission, so run them on every change. CI runs the same command.

You can also run them directly:

```sh
cd Packages/EarshotKit && swift test
```

The tests include copies of real meeting folders written by Earshot 0.1, in `Tests/Fixtures/v1/`. They prove that a meeting recorded with an older version still opens, lists, searches and renders in this one. If you change a file format, these tests tell you whether you broke an old meeting.

The checker that `make e2e-import` uses has its own Python tests, on made-up run folders. CI runs them too:

```sh
python3 -B -m unittest discover -s Scripts -p 'test_*.py'
```

### Build the app

```sh
make app
```

`make app` does these steps:

1. Runs `xcodegen generate` to create `Earshot.xcodeproj` from `project.yml`. A `postGenCommand` in `project.yml` then marks `App/AppIcon.icon` as an Icon Composer file, and the step fails if that didn't work.
2. Builds a universal app (Apple silicon and Intel) without signing.
3. Builds the universal `earshot` command-line tool with SwiftPM, in `build/helper` so it doesn't disturb the `swift test` cache, and copies it into `Earshot.app/Contents/Helpers/`.
4. Signs the tool with the hardened runtime, then signs the app with the hardened runtime and `App/Earshot.entitlements`.
5. Runs `make verify-app` on the result.

The app ends up at `build/Build/Products/Release/Earshot.app`. Xcode's own ad-hoc signing drops the hardened runtime flag, which is why the build is unsigned and `make` signs it afterwards.

To build and open it in one step:

```sh
make run
```

### Check a built app

```sh
make verify-app
```

This checks both signatures (the bundled `earshot` tool and the app), that the tool holds both architectures, that both carry the hardened runtime, and that the app icon is in the app. It ends with a line like `Earshot 0.2.0 build 2: helper and icon OK`. To check another copy, such as an unzipped download, pass its path:

```sh
make verify-app APP_PATH="$HOME/Downloads/Earshot.app"
```

### Build a release zip

```sh
make release
```

This runs `make app`, zips the app to `build/Earshot.zip`, unzips the zip into a scratch folder and runs `verify-app` on that copy, so the zip itself is proven to carry the signed tool. The release workflow on GitHub runs the same target.

### Keep your permissions between builds

By default `make app` signs ad hoc (`SIGN_IDENTITY=-`). macOS treats each ad-hoc build as a new app, so it asks for the microphone, call audio, calendar and screen permissions again after every rebuild.

If you have an Apple Development certificate (a free Apple account in Xcode gives you one), sign with it and your permission grants survive rebuilds:

```sh
make app SIGN_IDENTITY="Apple Development"
```

The same variable works with every target that runs `make app`. To see which identities your Mac has:

```sh
security find-identity -v -p codesigning
```

### The command-line tool on its own

The `earshot` tool is an executable target in EarshotKit. You can build and run it without the app:

```sh
cd Packages/EarshotKit
swift build -c release --product earshot
.build/release/earshot help
```

Or run a command straight from source:

```sh
cd Packages/EarshotKit
swift run earshot list --since 7d
```

It reads the same meetings and library index as the app. See [AI apps](ai-apps.md) for every command.

### Device tests

```sh
make device-test
```

These tests use the Mac itself, so they are switched off in `make test` and in CI. `make device-test` sets `EARSHOT_DEVICE_TESTS=1` and runs the whole suite. The extra tests cover:

- on-device transcription of a file, and live transcription of a speech file fed as a stream, with a finalize in the middle;
- audio compression to M4A;
- the login Keychain, with a throwaway item;
- text recognition on a rendered image (never a real screen capture);
- the calendar permission status, read without asking;
- the Core Audio process list while `afplay` plays a sound.

They need the macOS 26 speech assets for your language. If they are missing, the first run downloads them, which can take a few minutes. Detecting the microphone device of a call app is not in this set, because it would trigger a microphone prompt in the test runner. That is checked by hand.

### Claude tests

```sh
make claude-test
```

These make real calls through your own Claude Code, the same way the app does. `make claude-test` runs `Scripts/claude-test.sh`, which:

1. Stops at once with one `FAIL (preflight)` line if Claude Code isn't signed in with a Claude plan.
2. Builds EarshotKit, its tests and the `earshot` tool (under `EARSHOT_BUILD_LOCK` if you set it).
3. Runs the gated Swift checks with `EARSHOT_CLAUDE_TESTS=1`, then the shell checks.
4. Prints one `PASS` or `FAIL` line per check with the evidence, and a summary. On a failure it keeps its logs and folders and prints where they are.

Before any of that, `make claude-test` runs the unit tests of `Scripts/claude_test_check.py`, the checker that reads each `claude -p` run in (l) and (m). The `claude -p` runs load every MCP tool up front (`ENABLE_TOOL_SEARCH=false`). The checker also ignores `ToolSearch` and `Skill`, the tools Claude Code uses to reach other tools, so a run that calls them first still counts as using only Earshot's tools.

You need Claude Code 2.1.259 or later, signed in with a Claude plan. Check with:

```sh
claude --version
claude auth status
```

`auth status` should report `"authMethod": "claude.ai"`. The calls count against your plan's usage limits, like any other use of Claude Code. Each `claude -p` run in the shell checks is capped at $1 with `--max-budget-usd`.

On a Max plan, `make e2e-import` has passed: the real app imported a spoken meeting and wrote its notes through `claude -p`, twice. The full `make claude-test` suite hasn't run yet. `make claude-test` runs these checks against your own Claude Code.

What they check:

1. **The client** (a, b). The exact argument list Earshot uses, run from an empty folder with the prompt on standard input. Then a call with `ANTHROPIC_API_KEY=bogus` set in the parent environment, to prove the key never reaches Claude Code and your subscription is still used.
2. **Notes from a fixed transcript** (c, d, e). One transcript names Ashley, the proposal and Friday, and the notes must say so. One has two external attendees, and nothing may be pinned on a person the transcript didn't identify. One uses different wording live and in the notes, and the items must still link.
3. **Live to-dos** (f) from a scripted meeting fed in stages.
4. **The brief, Ask and Fix** (g, h, i).
5. **The Claude Code Do target in restricted mode** (j), in a temporary folder. The file it was asked to write must exist, a write outside the folder must be denied, and the result must say "Partly done".
6. **`earshot process`** (k) on a meeting spoken by `say` into a file, end to end, with its own index and lessons. It reads an empty settings domain (`EARSHOT_SETTINGS_DOMAIN`), so it runs on Earshot's default settings: Claude Code and the default notes model, even if you chose an API key or another model in Settings.
7. **The MCP server** (l), through `claude -p --mcp-config … --strict-mcp-config`. Claude must call `search_meetings` and answer correctly, and must quote, not act on, a planted instruction ("rm -rf") in a fixture transcript.
8. **Both plugins** (m), loaded with `--plugin-dir`: the five tools must be visible and the reminders must reach the model.
9. **Isolation.** Your real library index must be unchanged at the end.

The Claude Code routine target is covered by stubbed HTTP tests in `make test`. No `make` target fires a real routine.

### Local model tests

```sh
EARSHOT_LOCAL_URL=http://localhost:11434/v1 EARSHOT_LOCAL_MODEL=qwen3:8b make local-test
```

These run the same checks as `make claude-test`, with your own local model server instead of Claude. `make local-test` runs the tests of its helper scripts first, then `Scripts/local-test.sh`, which:

1. Stops at once with one `FAIL (preflight)` line if the server doesn't list `EARSHOT_LOCAL_MODEL`, and says what it does list.
2. Builds EarshotKit, its tests and the `earshot` tool (under `EARSHOT_BUILD_LOCK` if you set it).
3. Runs the gated Swift suite `LocalLiveTests` with `EARSHOT_LOCAL_TESTS=1`: one structured call (a), then the notes, live, brief, Ask and Fix checks (c) to (i), with 10 minutes for each call.
4. Runs `earshot process` (k) on a meeting spoken by `say`, with a settings domain of its own that holds only the local provider, address and model.
5. Runs the MCP server and plugin checks (l) and (m) only when `EARSHOT_LOCAL_ANTHROPIC_URL` names the server's Anthropic Messages API and Claude Code is installed. Claude Code then runs on your local model, not your Claude plan. Otherwise it prints a `SKIP` line.
6. Checks that your library index is unchanged, and prints one `PASS`, `FAIL` or `SKIP` line per check with a summary.

Slow models make this take a long time. Raise the server's context length first (see [Local models](local-models.md)).

`make e2e-import` can use a local model too. Set both `EARSHOT_E2E_LOCAL_URL` and `EARSHOT_E2E_LOCAL_MODEL`, and the app writes the notes with that model (it passes `--local <url> <model>` to the app):

```sh
EARSHOT_E2E_LOCAL_URL=http://localhost:11434/v1 EARSHOT_E2E_LOCAL_MODEL=qwen3:8b make e2e-import
```

### End to end with real audio

```sh
make e2e
```

This builds the app, launches it with `--e2e`, plays a scripted two-voice meeting through your speakers with the macOS `say` voices, records it for 40 seconds and runs the whole pipeline with your own Claude Code. A command target saves the Do payload in the meeting folder. `Scripts/e2e_check.py` then checks the transcript, the action items, the payload and the compressed audio, and prints `PASS` or `FAIL` with the reason.

Because it records for real, grant Earshot the microphone and call audio permissions first, and sign in to Claude Code. It runs on its own test settings and never saves them over yours. The meeting goes to a temporary folder in `/tmp`, with its own library index and lessons, so your index is never touched.

### End to end on an imported file

```sh
make e2e-import
```

This builds the app and runs the Python tests for its checker first. It then makes a two-voice meeting with `say`, launches the app with `--e2e-import <file> <folder> <data folder>`, and the app imports the file, transcribes it, writes notes with your own Claude Code and builds the Do payload, all in a temporary folder. The run writes its library index entry to its own index in the data folder, never to yours. `Scripts/e2e_import_check.py` then checks `notes.json`, `notes.html`, that index entry and the payload.

It needs no microphone and asks for no permission. Its main job is to prove that the GUI app, launched from Finder's environment, finds and runs your own `claude` with your own login. Sign in to Claude Code first.

It cleans up after itself on every exit, including Ctrl-C: it stops the app it started and, on a Mac where Earshot never ran, removes the default Settings the app saved. The temporary folder, with the meetings and the run's index, is kept so you can look at it.

### Screenshots and the README pictures

```sh
make screenshots
```

This builds the app and launches it with `--render-screenshots`. The app renders its real SwiftUI views offscreen with a made-up sample meeting, in light and dark, and the script writes them to `docs/images/screens/` as `<name>-light.png` and `<name>-dark.png`. It also renders the notes page through headless Google Chrome and the 12 frames of `docs/images/live-panel.gif`, which ffmpeg joins. Nothing is screen-recorded, so no screen permission is needed and no private data appears. The script checks that your Settings file was not changed during the render.

Two things to know:

- While it renders (about 20 seconds), keys you type in other apps are dropped.
- The menu screenshot needs this Mac's microphone status for Earshot not to be "denied". The renderer stops if it is.

If Chrome is not in `/Applications`, point to it with `CHROME=/path/to/chrome`. Run the target after any change to how a window looks, and commit the new images with the change.

The app icon is an Icon Composer file, `App/AppIcon.icon`, made of a hand-written `icon.json` and SVG layers. Xcode builds it into the app. The README copy, `docs/images/icon-256.png`, is rendered from the same file with Xcode's `ictool`:

```sh
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" App/AppIcon.icon --export-image --output-file docs/images/icon-256.png \
  --platform macOS --rendition Default --width 256 --height 256 --scale 1
```

## Working on the plugins

The plugins are plain files, so there is nothing to build. Try your changes in a single Claude Code session, without installing anything:

```sh
claude --plugin-dir plugins/earshot
```

Before you open a pull request, validate the marketplace and both plugins:

```sh
claude plugin validate --strict .
claude plugin validate --strict plugins/earshot
claude plugin validate --strict plugins/earshot-reminders
```

CI has no `claude`, so it only checks that the JSON files parse, that each plugin the marketplace lists exists with a matching name, and that the launch scripts are executable. Run the validate commands yourself.

The `earshot` plugin's MCP launcher looks for the app in `/Applications`, then `~/Applications`. Install your build there to test the plugin against it, or set `EARSHOT_HELPER` to another `earshot` binary.

## Run the same checks as CI

CI runs on GitHub's `macos-26` runner with Xcode 26.6. To run its steps locally:

```sh
make test
python3 -B -m unittest discover -s Scripts -p 'test_*.py'
(cd Packages/EarshotKit && swift build -c release --product earshot && .build/release/earshot version)
xcodegen generate --quiet
xcodebuild -project Earshot.xcodeproj -scheme Earshot -configuration Release \
  -derivedDataPath build -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

CI never runs `make device-test`, `make claude-test`, `make e2e` or `make e2e-import`, because they need a real Mac, permissions or a Claude login.

## Troubleshooting the build

- **`xcodegen: command not found`.** Install it with `brew install xcodegen`.
- **`xcodegen generate` fails right after it writes the project.** The `postGenCommand` uses the macOS `sed`. If a GNU `sed` comes first in your `PATH`, run it as `PATH="/usr/bin:$PATH" make app`.
- **"No such module" or Swift version errors.** Your active Xcode is older than 26. Check `xcodebuild -version` and switch with `xcode-select`.
- **The app asks for every permission again after a rebuild.** That is ad-hoc signing. Use `SIGN_IDENTITY="Apple Development"`.
- **`make screenshots` says Chrome or ffmpeg is not found.** Install Google Chrome, or set `CHROME=/path/to/chrome`, and run `brew install ffmpeg`.
- **`make claude-test` says Claude Code is not signed in with a Claude plan.** Run `claude` in Terminal, log in, and check `claude auth status`. If `authMethod` is something other than `claude.ai` (a Console API key, an API key helper, a token or another provider), log in with your plan:

  ```sh
  claude auth login --claudeai
  ```
