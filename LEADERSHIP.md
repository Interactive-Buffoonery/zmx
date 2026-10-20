# Typed terminal attachments

This fork adds a local socket contract for awesoMux #827, stacked on
`480fc5e` (existing-only attach). It preserves all old tags, the 8-byte header,
and the 4-byte legacy Init/Resize payload. Payload integers below are little
endian; lengths are exact unless a trailing byte batch is stated.

Two shapes were considered: extending legacy Init/Input, or adding typed
messages. Extensions are ambiguous to old daemons and cannot distinguish user
input from terminal replies. Additive messages provide positive acceptance and
keep old layouts unchanged.

| Tag | Payload |
| --- | --- |
| 26 AttachRole | version u8 (=1), role u8 (1 Watch, 2 Interactive), rows u16, columns u16 |
| 27 AttachAccepted | attachment ID u64, role revision u64 |
| 28 Authority | request: empty; response: leader attachment ID u64 (0 means none), authority epoch u64, rows u16, columns u16 |
| 29 UserBatch | attachment ID u64, revision u64, rows u16, columns u16, nonempty bytes |
| 30 TerminalReply | attachment ID u64, revision u64, authority epoch u64, nonempty bytes |
| 31 TakeOver | attachment ID u64, revision u64, rows u16, columns u16 |
| 32 RequestedSize | attachment ID u64, revision u64, rows u16, columns u16 |
| 33 Downgrade | attachment ID u64, revision u64 |

Clients must receive AttachAccepted before using the typed contract. An old
daemon ignores tag 26: unsupported/timeout is terminal, with no Init, legacy
input or session-creation fallback. `zmx watch NAME` implements this rule and
connects only to an existing socket. It does not read stdin or forward terminal
replies; Ctrl-C exits. Authority updates go to stderr. This diagnostic terminal
client is not the paired-device relay or its safe remote renderer.

Watch is permanent for that connection. Its dispatch allowlist permits only
Authority, Info, History, CwdQuery, LabelGet and Detach. This blocks repeated
Init/AttachRole, Input, Send, Run, Write, injected Output, resizing, terminal
replies, takeover, environment/label mutation, Kill and DetachAll. Downgrade
turns an interactive connection into permanent Watch, increments its revision,
drops its unforwarded operations, and clears its leadership while retaining
the grid. Closing a connection has the same authority/queue cleanup. Reconnect
gets a new ID, with no restored claim.

Attach never claims or resizes. Initial PTY creation retains the creator's grid.
Legacy Init stores requested dimensions and serializes the current terminal;
reattach neither resizes nor synthesizes SIGWINCH. A follower RequestedSize
stores dimensions only. Cells must be 1–4096 in each dimension.

All PTY writes use one bounded daemon operation queue (256 KiB of payload,
4096 operations). Queue capacity and payload ownership are reserved before
acceptance. A user batch or explicit takeover applies its validated size and
sets leadership immediately before its first byte (or at its empty takeover
barrier). A partially written batch holds the front of the queue; later input,
resize and takeover operations cannot overtake it. Ordinary takeover preserves
other eligible queued user input. There is no automatic retry/replay and no
per-batch acknowledgment; callers must not retry ambiguous sends. A full queue
rejects the new operation without claiming leadership.

Replies are accepted only from the current interactive leader and only for the
current epoch. Every claim, leader disconnect or leader downgrade changes the
epoch; queued replies are checked again before forwarding. Already forwarded
bytes cannot be withdrawn. Automation Send does not claim or resize. Watch
attachments affect neither synthetic focus reports nor fallback DA responses.
A typed leader suppresses the daemon's fallback DA response.

Legacy `attach` remains compatible with old daemons and uses `isUserInput` to
classify its arbitrary stdin stream. That heuristic cannot prove provenance
when replies and keystrokes are coalesced. The relevant upstream kitty status
reply fix from `54b212d` is included without unrelated dependency/pin changes.
Legacy followers suppress recognized replies at the daemon, but complete Mac
renderer reply suppression and authority presentation require a typed native
input seam. This work does not claim that native/relay acceptance.

Run `python3 test/leadership.py ./zig-out/bin/zmx` under the host's heavy gate.
The maintained real-socket harness covers watch mutation bypasses, positive
handshake/no legacy fallback, attach/resize non-election, explicit takeover,
leader disconnect, retained-grid reattach, per-batch size, concurrent batch
contiguity, stale replies, queued reply invalidation, and queued-input downgrade.
The fixture records kernel PTY size and actual input receipts. This does not
prove native Mac reattachment, follower layout/leader indicator, paired-device
authorization, snapshot generations/gaps, or real TUI/VoiceOver behavior.
