# Player operation recordings (v1)

Status: implementation in progress (player-window MVP). CLI/MCP playback is a
later phase and is deliberately not part of this contract.

This is the MuMu-style "operation recording" feature: the player records the
user's normalised input commands with timings, stores the timeline as JSON, and
replays it locally in the player bridge. Scripts are data, not code.

## Scope (v1)

- Entry point: the player window only.
- Recorded events: touch, mapped touch, key down/up, text, paste, tool keys.
- Not recorded: rotation, screen recording/screenshot/file operations, copy/cut,
  select-all, app inspect/uninstall.
- Playback options: count, duration, infinite loop, loop interval, speed
  (0.25x–4x).
- Closing the player window stops recording and playback (the bridge process
  exits).
- Scripts live in `<Jidr data>/scripts/`; they are portable JSON files.
- No daemon, CLI, MCP or protocol changes in v1.

## Script format

```json
{
  "format": "jidr.operation-recording",
  "version": 1,
  "id": "uuid",
  "name": "每日签到",
  "created_at": "2026-11-12T01:00:00.000Z",
  "device": "Phone 6.1 FHD+",
  "display": { "width": 576, "height": 1280 },
  "playback": {
    "mode": "count",
    "count": 1,
    "duration_ms": 0,
    "interval_ms": 0,
    "speed": 1.0
  },
  "events": [
    { "t": 0, "type": "touch", "x": 0.5, "y": 0.4, "down": true },
    { "t": 80, "type": "touch", "x": 0.5, "y": 0.4, "down": false },
    { "t": 300, "type": "key", "key": "ENTER", "down": true },
    { "t": 340, "type": "key", "key": "ENTER", "down": false },
    { "t": 600, "type": "text", "text": "hello" },
    { "t": 900, "type": "tool_key", "key": "back" }
  ]
}
```

Rules:

- `t` is milliseconds from the start, monotonically non-decreasing.
- Touch coordinates are normalised shown-screen coordinates (0…1), exactly like
  the bridge's `touch` command.
- `mapped_touch` ids are 3…9.
- Names are 1…80 characters; a script has 1…200,000 events and is at most 24 h
  long.
- `playback` is the last-used default; the UI may override it per run.
- Display size is used only for a compatibility warning; normalized coordinates
  still map to the current screen.

## Core crate API (`crates/jidr-automation`)

Pure Rust, no UI/daemon dependencies. Public API used by the bridge:

- `Script`, `Event` (tagged `type`), `TimedEvent`, `DisplayInfo`,
  `PlaybackOptions`, `PlaybackMode`, `ScriptSummary`
- `validate(&Script) -> JidrResult<()>`
- `Recorder`: `new(now)`, `record(event, now)`, `pause(now)`, `resume(now)`,
  `is_paused()`, `event_count()`, `finish(name, device, display, playback, now)`
  (finish appends release events for still-held touch/key state and validates).
- `ScriptStore::new(data_dir)`: `list()`, `load(id)`, `save(&script)`,
  `delete(id)`, `rename(id, name)`, `import(path)`, `export(id, path)`.
- Errors use `jidr_core::JidrError` (`usage`/`not found` semantics).

## Player bridge protocol additions

The player bridge is the Rust process spawned by the Swift player. stdin is
NDJSON commands; stderr carries JSON notifications. The player bridge remains
UI-agnostic so a future Windows/HarmonyOS UI can reuse it.

### Commands (stdin)

```text
{"type":"script_record_start"}
{"type":"script_record_pause"}
{"type":"script_record_resume"}
{"type":"script_record_stop","name":"..."}
{"type":"script_record_cancel"}
{"type":"script_list"}
{"type":"script_delete","id":"..."}
{"type":"script_rename","id":"...","name":"..."}
{"type":"script_import","path":"/abs/path.json"}
{"type":"script_export","id":"...","path":"/abs/path.json"}
{"type":"script_play_start","id":"...","options":{...PlaybackOptions...}}
{"type":"script_play_pause"}
{"type":"script_play_resume"}
{"type":"script_play_stop"}
```

Rules:

- Recording and playback are mutually exclusive; a conflicting command emits
  `script.busy`.
- While playback is active, ordinary input commands from the UI are ignored
  (the UI disables input); script commands still work.
- Rotation is rejected in v1: it is never recorded and a script containing one
  is invalid.
- On stop/cancel/pause/finish, held key/touch inputs are released.

### Notifications (stderr, `JIDR_SCRIPT:` + JSON)

```text
{"op":"record","state":"recording"|"paused"|"saved"|"stopped"|"failed","name":..., "message":..., "script":{summary}}
{"op":"list","scripts":[{summary...}]}
{"op":"play","state":"playing"|"paused"|"finished"|"stopped"|"failed","loop":1,"count":3,"name":...,"message":...}
{"op":"error","code":"script.busy","message":"..."}
```

`message` is the English fallback (the Swift UI may translate common codes).
Summaries contain `id,name,duration_ms,event_count,created_at,display`.

### Playback engine

The playback state lives in the bridge main loop (same controller as user
input, so release/hold handling is shared). A ~5 ms tick advances due events;
the loop remains responsive to frames and to pause/resume/stop commands. Event
times are divided by `speed`; loop intervals are real time. The engine emits
`play` notifications on start/loop/pause/resume/stop/finish.

## Swift UI

- Player side rail gains "操作录制"; it opens a non-modal script window so the
  player remains usable while recording.
- Script window: list, record/pause/resume/stop, playback settings, play/pause/
  stop, rename, delete, import/export, resolution warning.
- Player HUD while recording/playing: elapsed time, loop count, pause/stop.
- Closing the player window stops everything naturally (bridge exits).
- All strings bilingual via the existing player localisation helper.
