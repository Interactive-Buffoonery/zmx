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

The client that creates a non-task session is its first leader. The first valid
legacy Init or typed Interactive handshake consumes this one-use creation right;
Watch and automation never consume it. Automation classification permanently
removes creation eligibility for that connection, including after legacy Init;
normal user input can still claim leadership. Creator identity is the first
terminal handshake on a fresh daemon, rather than a token carried across the fork. The
creator keeps authority until another client claims, it disconnects, or it
downgrades to Watch. Task sessions have no creation right. Attaching to an
existing session never claims or resizes. The creator's handshake grid and
subsequent resizes use the ordered leader path, preserving kernel pixels when
no pixel size is supplied. A full operation queue closes the creator connection
before accepting its handshake or consuming creation; a new connection may
claim once capacity is available.
Legacy Init stores requested dimensions and serializes the current terminal;
reattach neither resizes nor synthesizes SIGWINCH. A follower RequestedSize
stores dimensions only unless it follows that attachment's queued input or
takeover; then it is ordered after that claim. Cells must be 1–4096 in each
dimension.

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
current epoch. Explicit takeover, leader change, disconnect or leader downgrade
changes the epoch. A size-only change broadcasts the grid without changing the
epoch. Queued replies are checked again before forwarding. Already forwarded
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
The fresh-session cases cover creator cell/pixel settling, exact pre-input
CPR/OSC reply and lone-ESC bytes, creator yield, retained-grid reattach, task
non-election, and Watch-first ordering, through both legacy and typed
handshakes. The fixture records kernel PTY size and actual input receipts. This does not
prove native Mac reattachment, follower layout/leader indicator, paired-device
authorization, snapshot generations/gaps, or real TUI/VoiceOver behavior.

## Queue regression checks

`test/leadership_regressions.py` exercises malformed Watch History requests,
typed and legacy coalesced input followed by resize, queued cell/pixel sizing,
and pixel retention on subsequent input. History accepts only an empty payload
(plain) or exactly one supported format byte; malformed requests are ignored.

Reply epochs change on explicit takeover or an actual leader change.
Resize validity separately tracks uninterrupted ownership: another batch by the same leader preserves its queued
resize, while an intervening leader change, disconnect or downgrade invalidates
it. A resize following a pending claim is bound to that claim and the ownership
epoch it establishes, not the leader at receipt. Per-attachment pixel preferences
are captured in ordered operations; missing pixel preferences preserve the current kernel dimensions. Pixel updates never
bypass queued input, and a full queue rejects the new resize without terminating
the daemon or evicting accepted work.

The regression fixture independently samples TIOCGWINSZ while its PTY reader is
paused. A 128 KiB batch exceeds PTY capacity, so later resize/takeover barriers
must remain blocked until its tail drains. The harness saturates the 4096-entry
operation queue, checks same daemon/child liveness, verifies complete batch
receipts after unblocking, and checks queued revocation and unsolicited Authority
notifications. These socket checks do not replace native or device acceptance.

Legacy keyboard classification accepts a payload beginning with a C0 control
(except ESC) or DEL, plus ordinary CSI arrows, Shift-Tab and Home/End (including
modified Home/End). Standalone ESC while not the current leader remains an
explicit legacy limitation: it is ambiguous with a terminal reply prefix. No
timeout or guessing heuristic elects a leader. No-leader DA fallback also runs
with legacy followers attached. Input and size-only changes from the same leader
keep the reply epoch; explicit takeover still invalidates outstanding replies.
Watch requires acceptance within one elapsed monotonic second, independent of
output traffic; SessionEnd before acceptance is an unsupported failure.
