# Contributing

This is an awesoMux-maintained fork that merges upstream zmx. Keep PRs small
and focused, preserve upstream structure, and separate fork-only behavior where
practical. Size labels are informational and do not block a merge.

Use Zig 0.16.0 from `build.zig.zon`. Before a code PR, run:

```sh
zig fmt --check build.zig build.zig.zon src
zig build test
```

Run affected real-session checks too. CI currently covers Linux unit tests;
it does not prove macOS or awesoMux behavior. After PR #29 merges, add
`zig build && zig build test-replay && python3 test/attach_scrollback.py zig-out/bin/zmx`
to CI for the attach regression.

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
