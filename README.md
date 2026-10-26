# worktape

worktape records your work for devlogs and screencasts.

It records your terminal and each window you open from it. Each recording becomes a video.

## Install

worktape needs macOS 15 or later.

```sh
brew install carldaws/tap/worktape
```

Homebrew also installs asciinema, agg and ffmpeg. macOS asks for screen recording permission on the first recording.

To build it yourself:

```sh
brew install asciinema agg ffmpeg
swift build -c release
cp .build/release/worktape ~/.local/bin/
```

## Use

```sh
cd my-project
worktape init     # creates .worktapes/
worktape record   # starts a recorded shell
worktape stop     # stops it
```

`exit` also stops a recording. `ctrl+\` pauses and resumes it.

worktape records each window you open from the recorded shell. A recording ends when its window closes or you pause. Resuming starts a new recording for each open window.

When you stop, worktape renders the terminal recording as a video. It plays at normal speed, cuts pauses to half a second and fits in 4K. `ctrl+c` skips this step.

Each session gets its own folder, named after the time it started. Window videos start with the time each one started:

```
.worktapes/
  2026-10-21-233457/
    2026-10-21-233457.cast         terminal recording
    2026-10-21-233457.mp4          terminal video
    2026-10-21-233459-editor.mov   window video, named after the window
```

Describe a session to name it after the day instead. worktape won't use the same description twice in a day:

```sh
worktape record "fixing the jump"
```

```
.worktapes/
  2026-10-21-fixing-the-jump/
    2026-10-21-fixing-the-jump.cast
    2026-10-21-fixing-the-jump.mp4
    2026-10-21-233459-editor.mov
```

`.worktapes/` ignores itself in git. You can render the `.cast` again with [agg](https://docs.asciinema.org/manual/agg/).

Terminal videos use JetBrains Mono when it is installed. Install it with `brew install --cask font-jetbrains-mono`.

## Shell hook

Add this line to `~/.zshrc`:

```sh
eval "$(worktape hook zsh)"
```

The hook adds:

- a red `●` to your prompt while recording
- a yellow `‖` to your prompt while paused
- a yellow `○` to your prompt in a project that isn't recording
- a reminder when you enter a project that isn't recording

## Limits

- Window videos include all sound on the Mac.
- worktape only records windows from programs you start in the recorded shell. It misses apps you start with `open`.
- A window video keeps its starting size. worktape scales a resized window to fit.
- worktape can't see pauses if your asciinema config sets its own notifications.

## Tests

```sh
swift test
Tests/Integration/run.sh
```

The integration tests record real sessions. They need asciinema, agg, ffmpeg and screen recording permission.
