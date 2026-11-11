# Contributing

This is an awesoMux-maintained fork that merges upstream zmx. Keep PRs small
and focused, preserve upstream structure, and separate fork-only behavior where
practical. Size labels are informational and do not block a merge.

Use Zig 0.17.0 from `build.zig.zon`. Before a code PR, run:

```sh
zig fmt --check build.zig build.zig.zon src
zig build test
```

Run affected real-session checks too. CI covers Linux formatting, unit tests,
terminal replay tests, PR automation tests, and the real-daemon attach regression.
It does not prove macOS or awesoMux behavior. For attach changes, also run:

```sh
zig build && zig build test-replay && python3 test/attach_scrollback.py zig-out/bin/zmx
```

Use the exact [PR template](.github/pull_request_template.md) sections, remove
placeholders, and use simple English or ASD-STE100. List models after `Models:`
in Notes, or write `None`. Include screenshots for visible changes, or write
`Not applicable`. Docs-only PRs may omit UI / UX.

Agents should use [merge-risk](.agents/skills/merge-risk/SKILL.md) after current
verification and add its one-line result under Notes. It is advisory and adds
no merge permission. Human contributors may use it too.

PR hygiene and size workflows use trusted code from the default branch. They
first take effect after their initial merge. Existing PRs need the new sections
at their next description edit or push. No repository protection rules are
changed by these workflows.

## prerequisites

- [Zig](https://ziglang.org/) `0.17.0`
- [bats-core](https://github.com/bats-core/bats-core) (integration tests)
- [Go](https://go.dev/) `1.23+` (docs site)

You can also use `nix develop` (`flake.nix`) or the `Dockerfile` (`docker build -t zig-zmx .`).

## build & test

```bash
zig build                        # build ./zig-out/bin/zmx
zig build check                  # fast compile check
zig build examples               # build examples/ against the zmx module
zig build test                   # run unit tests
bats --jobs 1 test/*.bats        # run integration tests
zig fmt --check .                # check formatting
```

## local debugging

Isolate development sessions from your running `zmx` sessions using `ZMX_DIR`:

```bash
ZMX_DIR=/tmp/zmx-dev ./zig-out/bin/zmx attach dev
```

Logs are written to `{log_dir}/zmx.log` and `{log_dir}/{session_name}.log` (run `zmx version` to see resolved socket and log paths).

## docs

Documentation lives in `docs/posts/` and is built with [`pdocs`](https://github.com/picosh/pdocs):

```bash
cd docs && make ssg
```

## a smol contract

- Write programs that solve a well defined problem.
- Write programs that behave the way most users expect them to behave.
- Write programs that a single person can maintain.
- Write programs that compose with other smol tools.
- Write programs that can be finished.

## guidelines

- Ensure `zig fmt --check .`, `zig build test`, and `bats --jobs 1 test/*.bats` pass.
- Preserve the frozen AMX header, tags, and payload layouts in `src/ipc.zig`.
  Add new operations with unused tags; do not reuse upstream tag numbers.
- Add user-facing changes under `## Staged` in `CHANGELOG.md` and update `docs/posts/` when needed.
