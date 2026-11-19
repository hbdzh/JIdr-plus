# Multi-device input synchronizer

Run several emulators as one: input on the **leader** device is replayed on every **follower** in real time (tap, swipe, multi-finger touch, keys, text, paste and the back/home/recents/volume/power keys). Design: [docs/design/sync-plan.md](design/sync-plan.md), decision D45.

> Status: implemented across the daemon (`sync.*`), CLI (`jidr input-sync`), MCP (`sync_start`/`sync_stop`/`sync_status`), player bridges, and the SwiftUI Synchronizer panel (`⇧⌘Y`). Real-emulator latency and stress benchmarks have not been run in this environment yet (no local Android SDK system image).

## Using the Synchronizer

- **GUI:** Open **同步器… / Synchronizer…** from the menu bar (`⇧⌘Y`), the Command Palette (`⌘K`), or the Synchronizer button in any player window toolbar. Select two or more running devices, pick a leader, choose coordinate adaptation (`Stretch` or `Letterbox`) and input filters, then click **Start sync**.
- **In-player indicators:** Each participating window shows a corner glass pill (`Syncing · Leader` or `Syncing · Following`). Followers are locked by default so stray clicks don't desynchronize; clicking a locked follower offers **Take over** to promote it to leader. Followers without an open window run in a hidden background player session managed by `SyncHub`.
- **CLI & MCP:** `jidr input-sync start --leader <dev> --follower <dev>…`, `stop`, `status`, `add`, `remove`, `leader`; MCP `sync_start`, `sync_stop`, `sync_status`. Input flows while the leader has an open player window.

## Concepts

- **Session.** At most one session at a time, with one leader and at least one follower. Every member must be a running device.
- **Leader.** The device whose input is mirrored. Any member can become the leader with `sync.set_leader`; the old leader becomes a follower. The leader can also record or play back operation scripts while syncing, mirroring playback events to every follower in real time.
- **Follower.** A device that receives the leader's input. Followers are locked by default (`lock_followers`), so stray input on them does not desynchronize the group. Followers cannot record or play back scripts while participating in a sync session.
- **End of a session.** `sync.stop`, or automatically when the leader stops, crashes, hibernates or is deleted, or when fewer than two members remain. A follower that stops is simply removed.

## Options

| Option | Default | Meaning |
|---|---|---|
| `adaptation` | `stretch` | `stretch` keeps the same relative position on every screen. `letterbox` fits the leader's screen inside the follower's, keeping its aspect ratio, so a tap lands on the same pixel of the scaled-down picture. |
| `sync_keyboard` | `true` | Forward key presses and releases. |
| `sync_text` | `true` | Forward committed text and paste. |
| `sync_tool_keys` | `true` | Forward back, home, recents, volume and power. |
| `lock_followers` | `true` | Ignore direct input on followers while the session is active. |
| `jitter_ms` | `0` | Random extra delay of 0 to 20 ms per follower. |

## Commands and events

See the generated reference in [control-protocol.md](control-protocol.md): `sync.start`, `sync.stop`, `sync.status`, `sync.add_follower`, `sync.remove_follower`, `sync.set_leader`, `sync.set_options` and `sync.report`. Events: `sync.state` (the whole session, or `null` when it ended) and `sync.follower_error`.

Errors reuse the existing codes: `usage` (bad selection or options), `not_found` (no session, unknown device) and `busy` (a session is already active). A follower whose queue overflows is reported as `error` in its status instead of failing a call.

## Limits

- Different aspect ratios or orientations can make taps land differently. Rotation is not synchronized.
- Devices must be in the same app state for identical taps to do the same thing.
- Latency and stress figures are not measured yet.
