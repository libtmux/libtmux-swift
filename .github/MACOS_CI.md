# macOS CI

What a test needs so it passes on macOS as well as Linux.

## Waiting

- **Wait for the event, not the clock.** Subscribe, act, then wait for the
  notification, `wait-for` channel, hook, or pane output the action causes.
  Keep a timeout only as a hang guard. The macOS runner is slower to start
  processes, so a deadline tuned on Linux fails there.
- **Read after the change, not after the command.** tmux renames windows,
  starts pane processes and draws output after the command returns. Name
  windows yourself unless the name is what the test checks.
- **Wait for the shell before typing.** Keys typed before the shell is ready
  are echoed back, and a text wait can match a command that never ran.
- **Read control-mode output all the time.** tmux stops reading panes when its
  only attached client is a control client nobody reads.

## Paths and sockets

- **Compare physical paths.** tmux reports `/private/tmp/...` for `/tmp/...`.
  Resolve the expected path before comparing.
- **Keep socket paths short.** A socket path must fit in 104 bytes, and the
  macOS temporary directory is long. Put sockets under a short directory.
- **Poll for a socket; don't watch for it.** Watchers built on FSEvents
  (libuv, .NET, Julia) do not report a socket being created.

## Shells and processes

- **`/bin/sh` is bash 3.2.** Pin the pane's shell, avoid bash 4 syntax, and
  expect `pane_current_command` to say `bash`.
- **No `/proc`, no `/bin/false`.** Use `ps` or tmux formats, and `false` from
  `PATH`.
- **Reap before signalling a process group.** `killpg` fails with EPERM when
  every member has exited but has not been reaped.
- **Stay well under 511 terminals.** Past that, tmux reports
  `fork failed: Device not configured`. Kill every server a test starts.
- **Keep typed input under 1 KB.** Longer input is dropped. Send long text
  through a file or a paste buffer.
- **Read a pane until its process exits.** On macOS a process cannot finish
  exiting while its terminal output is unread.

## Building tmux

Configure with `--enable-utf8proc --enable-jemalloc`. Recent tmux refuses to
configure on macOS without a choice for both.

## Reproducing on Linux

- Slow runner: pin the test to one CPU beside busy loops, or put a `tmux`
  wrapper that sleeps first on `PATH`.
- Physical paths: point the test's temporary directory at a symlink.
- `/bin/sh` as bash: `set -g default-shell /bin/sh` and
  `set -g default-command "/bin/bash -i"`.
- Long socket paths: set `TMPDIR` to a deep directory.

## In this repository

- `Scripts/stress_tests.py` repeats the real-tmux suites and counts failures
  per test; `macos-stress.yml` runs it weekly and on demand.
- `Scripts/run_with_hang_guard.py` wraps a test run and samples the process
  tree and every test tmux server before the job's own timeout.
- `waitForExit` in `TmuxFixture` and `runProgram` in the Examples tests wait
  for a child process without parking a thread.
- `Scripts/check_time_limits.py` keeps every suite limit a backstop.
