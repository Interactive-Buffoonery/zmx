---
name: merge-risk
description: Assess how risky a zmx change is to merge and where human attention would help most. Use after verification and before opening a pull request, or when asked for merge risk on a branch or PR. Read-only and advisory.
---

# Merge risk

Assess the exposure left in a change, for reviewers. This is not merge approval
or a gate. Do not edit, build, run tests, start reviewers, post comments, or
merge.

## Evidence

Reuse results from this revision, then read the diff and its callers. Missing,
older, or inconclusive evidence is unknown, never passing.

- Use Zig 0.16.0, as required by `build.zig.zon`. A different Zig on PATH does
  not prove this build.
- `zig fmt --check build.zig build.zig.zon src` checks formatting.
  `zig build test` runs unit tests, including frozen IPC wire layouts.
  Neither proves a real attach, PTY, or awesoMux journey.
- Attach regression coverage is a follow-up after PR #29 merges. When present,
  `zig build && zig build test-replay && python3 test/attach_scrollback.py zig-out/bin/zmx`
  checks real-daemon replay into a fresh Ghostty terminal. Until then, report
  this proof as unavailable. It does not prove every terminal emulator or TUI.
- A Linux check does not prove macOS process discovery or PTY behavior, and a
  macOS check does not prove Linux. Name the platform actually exercised.

## Where risk lives

| The diff touches | Failure | Proof beyond formatting and unit tests | What a revert leaves |
| --- | --- | --- | --- |
| `src/loop.zig` daemon creation, `ensureSession`, shutdown; `src/socket.zig` | A live session is replaced, orphaned, or ended; a socket points to the wrong session | Real create, detach, reattach, child exit, stale socket, and unresponsive daemon cases in an isolated socket directory; confirm the original child survives | Ended processes and lost scrollback cannot be restored; live daemons and sockets remain |
| `handleInit`, `src/util.zig` terminal serialization, Ghostty dependency | Reattach loses scrollback, cursor or terminal modes, or corrupts later output | Attach regression when available; real terminal checks with primary and alternate screens, changed width, and continued output | Connected terminals can retain bad state; replacing the binary does not replace the daemon's in-memory terminal |
| Leadership, `handleResize`, input routing in `src/loop.zig` | A viewer steals input or size authority; a detached leader leaves the session stuck | Two clients with different sizes; leader disconnect and takeover; non-input reports; verify PTY dimensions and foreground SIGWINCH | Running daemons keep their leader and size state until corrected; a revert does not undo input already sent |
| `src/daemonize.zig`, `src/cross.zig`, `src/posix.zig`, `src/signal.zig` | Wrong child command, environment, signal, exit status, or terminal cleanup | Real PTY on each affected OS: exec failure, detach, trailing command exit, signals, and parent terminal flags after exit | Child processes keep their environment and process groups; ended work stays ended; terminal settings may need repair |
| `src/ipc.zig`, `src/status.zig`, cwd queries, socket paths and permissions | New clients cannot talk to old daemons; status is wrong or exposes session data | Existing wire-layout tests plus old/new client-daemon pairs; verify status ownership, token handling, cwd, and access with isolated sessions | Old daemons, status files, and sockets remain; reverting code cannot retract exposed data or change an already running protocol |
| `build.zig`, `build.zig.zon`, release inputs, awesoMux integration | A supported target stops building, or awesoMux ships an incompatible backend | Build affected targets; exercise the exact zmx revision through awesoMux's pinned submodule and its terminal lifecycle checks | awesoMux keeps its own submodule pin and shipped binary; a zmx revert alone does not update either |
| `.github/`, PR template and validator, contributor and agent guidance | Checks reject valid PRs, accept incomplete descriptions, or run untrusted code with write access | Validator tests and positive/negative bodies; workflow lint; hosted checks on this PR; inspect trusted-base checkout and token permissions | Runs, labels, and comments already created remain; revert restores rules only for later runs |

Use only resources owned by this task for runtime proof. Never kill unrelated
sessions to make a check pass. A harness that cannot run counts as not proved.

## Judge

Check alignment with the request, then the row, its reach, and its proof.

- **Fork maintenance:** This fork merges `neurosnap/zmx` upstream. Keep changes
  narrow, preserve upstream structure, and keep awesoMux-only behavior separate
  where practical. Note likely merge conflicts or changed upstream contracts.
- **Timing:** A source revert affects later builds. It does not replace running
  daemons or a released binary. Coordinate a downstream pin update and release
  when awesoMux has shipped the affected revision. Do not restart user sessions
  without permission.
- **Detection:** Name the failing check, local log, terminal symptom, or user
  report that would reveal the failure. Do not assume production telemetry.

Use low, medium, high, or unknown. High: a failure ends running work, loses
terminal state, widens access, or breaks live-daemon compatibility, and the
row's proof did not run at this revision. Never low with an open security
finding or missing proof for an affected runtime row. Docs-only changes need
`git diff --check` and are low unless they change a protocol or journey contract.
For CI-only changes, low needs local checks and the hosted checks that can run
before merge; name trusted-base workflows that first take effect after merge.

## Report

Return one line for `Merge risk:` under Notes: the level, the main reason, and
how to recover. Use simple English or ASD-STE100 (Simplified Technical English).

> Merge risk: high. Changes session cleanup, so a bug could end running work.
> Recovery: a revert stops further loss but cannot restore ended sessions.

When asked for the full assessment, add the revision, one line per row touched,
and the next action that would most reduce risk.
