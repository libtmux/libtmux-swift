# Workspace fixtures

Example workspace files taken verbatim from tmuxp, which publishes them
under the MIT licence: <https://github.com/tmux-python/tmuxp>.

Each is kept as its `.yaml` and `.json` pair. tmuxp ships both spellings of
the same workspace, which is what lets one test assert the two readers agree
rather than merely that each parses.

Chosen for the shapes they carry, not for coverage of tmuxp's own features:

- `2-pane-vertical`, `3-pane` — the ordinary case.
- `blank-panes` — a blank pane in all three of its spellings: a null pane, a
  null `shell_command`, and a list holding a null.
- `skip-send`, `sleep` — commands written as `{cmd:, enter:}`.

Not every tmuxp example is a valid pair: several `.json` files there are
hand-kept copies that have drifted from their `.yaml`, differing in the
source rather than in how they read.
