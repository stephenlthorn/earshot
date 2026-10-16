# Contributing to Earshot

Thanks for helping. Bug reports, docs fixes and pull requests are all welcome.

## Before you start

- Search open and closed issues first. Someone may already be on it.
- For anything bigger than a small fix, open an issue first so we can agree on the approach before you write code.
- Security problems go to the private form, not an issue. See [SECURITY.md](SECURITY.md).
- Never paste real transcripts, notes, recordings or keys into an issue or a pull request. Use made-up examples ("Send Acme the revised proposal by Friday").

## Set up

You need macOS 26, Xcode 26.x and [XcodeGen](https://github.com/yonaskolb/XcodeGen). `make screenshots` also needs Google Chrome and ffmpeg, and `make claude-test`, `make e2e` and `make e2e-import` need Claude Code signed in with a Claude plan.

```sh
brew install xcodegen
git clone https://github.com/stephenlthorn/earshot.git
cd earshot
make test
```

[Building from source](docs/building-from-source.md) covers every `make` target, what each one needs and touches, signing (`SIGN_IDENTITY`), `EARSHOT_BUILD_LOCK` and the tests that need hardware or Claude.

## Where code goes

- **`Packages/EarshotKit`** holds the logic, and its tests. If a change makes a decision (what to show, when to start, what to send), it belongs here, with time passed in as a `now` closure and a `sleep` closure, so it can be tested without waiting.
- **`App/`** is a thin layer that wires EarshotKit to SwiftUI, AppKit and system permissions. Keep it thin.
- **`plugins/`** and **`.claude-plugin/`** hold the Claude Code plugins and the marketplace.
- **`Scripts/`** holds the scripts behind `make e2e`, `make e2e-import`, `make screenshots` and `make claude-test`, and their Python checkers. A checker change comes with a test in `Scripts/test_*.py`.

[Architecture](docs/architecture.md) explains the pipeline, the files each meeting writes and the rules that keep them consistent.

## Rules for code

- **Test first.** New behaviour comes with a test in EarshotKit. Tests use Swift Testing and fakes. They never call a real model, never need a permission and never touch real meetings.
- **Hardware and Claude tests are gated.** Tests that need the Mac's speech engine, audio, calendar or Keychain check `EARSHOT_DEVICE_TESTS=1`. Tests that call Claude check `EARSHOT_CLAUDE_TESTS=1`. Both stay out of the user's meetings, index and settings.
- **Swift 6 strict concurrency stays on**, with no new warnings.
- **System callbacks** (Core Audio, audio taps, notification delegates and observers) are built in `nonisolated static` functions or a queue-confined worker, and hop to the main actor with `Task { @MainActor in … }`. A block built inside a `@MainActor` context crashes when the system calls it from another thread.
- **Old meetings keep working.** Don't add pipeline stages or modes. New data goes in new files or optional fields, every new file carries `version: 1`, and an unknown enum value must decode to a fallback, never fail. The v1 fixtures in `Tests/Fixtures/v1/` must keep passing.
- **Other people's words are data.** Any third-party text that reaches a model goes through `PromptFraming`. Anything that can act on that text needs a human click.
- **Never touch the user's Claude login.** Every `claude` child gets its environment from `ClaudeEnvironment.child(claudePath:)`.
- **Small files.** Aim for under 400 lines, and never over 800.
- **No third-party dependencies** without an issue to discuss it first.

## Rules for words

Everything a user reads, in the app or in the docs, follows the same style:

- plain and short, in the active voice, speaking to "you";
- say what a thing does before how;
- headings in sentence case;
- every command in a code block;
- no em dashes: use a comma, a colon or a full stop;
- no hype words.

## Pull requests

- One change per pull request, with tests for new behaviour.
- `make test` passes, and `make app` builds.
- If you touched `Scripts/`, run:

  ```sh
  python3 -B -m unittest discover -s Scripts -p 'test_*.py'
  ```

- If you touched `plugins/` or `.claude-plugin/`, run:

  ```sh
  claude plugin validate --strict .
  claude plugin validate --strict plugins/earshot
  claude plugin validate --strict plugins/earshot-reminders
  ```

- If you changed how a window looks, run `make screenshots` and commit the new images.
- Update the docs if behaviour changed, and add a line to [CHANGELOG.md](CHANGELOG.md) under "Unreleased".
- Commit messages follow `<type>: <description>`, where type is one of `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf` or `ci`. For example:

  ```
  fix: a flag added during Fix is no longer lost
  ```

CI runs on every pull request, on GitHub's `macos-26` runner with Xcode 26.6. It runs `make test` and the checker's Python tests, builds the command-line tool, builds the app unsigned, and checks that the plugin and marketplace JSON parse. It has no `claude`, so it can't run `claude plugin validate`, and it can't run `make device-test`, `make claude-test`, `make e2e` or `make e2e-import`. Say in the pull request which of these you ran yourself.

## License

By contributing, you agree that your work is released under the [MIT license](LICENSE).

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
