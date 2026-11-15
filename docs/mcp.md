# Jidr for AI agents (MCP)

`jidr mcp` serves the [Model Context Protocol](https://modelcontextprotocol.io) on stdio. Agents get every Jidr command plus fast tools for driving a device: look, tap, type, read the UI. It starts the Jidr daemon if it isn't running.

## Add Jidr to Codex

In Jidr settings, choose **Configure Codex**. The command path defaults to the packaged Jidr helper; change it if needed. The button runs `codex mcp add`, preserving other Codex settings. Restart Codex or start a new conversation after configuration.

Alternatively, run:

```bash
codex mcp add jidr -- /Applications/Jidr.app/Contents/Helpers/jidr mcp
codex mcp list
```

Adjust the path to where Jidr is installed. For manual configuration, add this to `~/.codex/config.toml`:

```toml
[mcp_servers.jidr]
command = "/Applications/Jidr.app/Contents/Helpers/jidr"
args = ["mcp"]
```

The settings button requires the Codex CLI. Other MCP clients can still use `jidr mcp` with their own configuration. `jidr uninstall` removes the Codex entry and cleans up entries from older Jidr integrations (D31).

## Add Jidr to WorkBuddy

Choose **Configure WorkBuddy** in Jidr settings to add the Jidr server to the user-level `~/.workbuddy/mcp.json`, preserving existing entries. Alternatively, use **Copy WorkBuddy MCP configuration** and merge the JSON into WorkBuddy's MCP configuration. Check the server's connection status in WorkBuddy after saving. The user-level configuration applies across projects; see the [WorkBuddy MCP guide](https://www.codebuddy.ai/docs/zh/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/MCP-Guide).

`jidr uninstall` also removes the Jidr entry from this user-level file.

JIdr Plus has not yet been published to the MCP Registry.

The current source version is 0.5.0. Build the matching local MCP bundle with
`cargo xtask release --rehearsal`; the presence of a version in `server.json`
does not mean its release asset or Registry entry has been published. The
registry checksum remains a placeholder until a real artifact is published.

## Tools

| Tool | Hints | What it does |
|---|---|---|
| `command_list {prefix?}` | read-only | Every Jidr command with its params schema and flags |
| `command_run {command, params, timeout_s?}` | may be destructive | Runs any command; long-running ones (boot, image install) are waited for, up to `timeout_s` (900 s), then returned as a job |
| `pool_get {base, ttl_s?, timeout_s?}` | interacts | A throwaway device of your own: a copy-on-write clone of a base, resumed from its snapshot in seconds. Returns `{lease, device, serial, connect}`. Without `ttl_s` the lease lasts as long as this MCP session, plus 2 minutes |
| `pool_release {lease \| device}` | destructive (your clone only) | Gives the clone back: it is stopped and deleted |
| `jobs_list {all?}`, `jobs_cancel {job}` | read-only / idempotent | Long-running operations |
| `screenshot {device}` | read-only | PNG of the screen fitted in 1024×1024, plus the screen size and scale |
| `tap {device, x, y, coords?}` | interacts | Tap; coordinates are in the screenshot image unless `coords: "device"` |
| `swipe {device, x1, y1, x2, y2, duration_ms?, coords?}` | interacts | Swipe or drag (scroll, open the app drawer) |
| `type_text {device, text, enter?}` | interacts | Type printable ASCII into the focused field |
| `press_key {device, key}` | interacts | `GoHome`, `GoBack`, `AppSwitch`, `Enter`, `Power`, volume, arrows… |
| `ui_dump {device}` | read-only | uiautomator XML: text, ids and bounds to find what to tap |
| `logcat_tail {device, lines?, filter?}` | read-only | Recent log lines (the last N lines that match the filter) |
| `ca_cert_install {device, path}` | may restart the device | Trust a CA certificate (PEM or DER, on this Mac) as a system cert on a running Full-root device, then verify; `root.cacert.list` / `.verify` / `.remove` go through `command_run` |
| `command_run root.writable_system {device, enabled}` | restarts a running device | A writable `/system` on an `adb`-root device, or back to read-only (docs/root.md); refused with `usage` on other root modes, Play Store images and images older than API 31 |
| `proxy_set {device, host?, port}`, `proxy_clear {device}` | idempotent | The device's global HTTP proxy, for Burp or mitmproxy on the Mac (`host` defaults to `10.0.2.2`, the Mac as the emulator sees it) |

TTL leases start when the clone is delivered and keep their IDs and deadlines across daemon restarts. A connection lease whose daemon restarts enters the same two-minute grace period; an existing grace deadline is not extended by another restart. Renewal returns `busy` if the clone is already being released.

Creating a base preserves the source device's animation settings. Pool clones have animations disabled after boot, before they are delivered to an agent.

Everything else goes through `command_run`, e.g. playing a WAV on this Mac as the device's microphone for a voice flow: `command_run {command: "audio.inject", params: {device, path, loop?}, timeout_s: 5}` returns the job while it plays, and `command_run {command: "audio.stop", params: {device}}` ends it.

Packet loss is available through `command_run` with `network.shaping.get` and `network.shaping.set {device, loss_pct}`. It requires Shell or Full Root and netem support; 0 clears it and a cold boot resets it. See [on-device helper](on-device-helper.md) for interface and qdisc limitations.

Every tool carries `readOnlyHint`, `destructiveHint`, `idempotentHint` and `openWorldHint` annotations. Jidr errors come back as tool results with `isError: true` and structured `{code, message, data}` (codes as in docs/control-protocol.md), so an agent can recover, e.g. start a stopped device after `not_found`.

## Devices for agents (D42)

Use a device of your own, never the user's (for example not `emulator-5554`):

- **Throwaway:** `pool_get {base}` (bases: `command_run base.list`; a person makes one with `jidr base create <device> <name>`). Use the returned `serial` with adb, Flutter or Gradle, and call `pool_release` when done. If the session ends without it, the daemon deletes the clone 2 minutes later. For long tasks pass `ttl_s` and extend it with `command_run pool.renew`.
- Magisk-rooted bases are supported when the source already has a working shell `su` grant. Clones inherit the base snapshot's data and root settings; only use a base prepared for the agent's access. See [Root modes](root.md#magisk-pool-bases).
- **Persistent:** `command_run device.create {name, image, profile: "agent-lean"}` (about 4 GB of host RAM instead of ~7.6 GB) and `device.start`; hibernate it with `device.hibernate` when idle.
- **Full machine:** `pool_get` waits up to `timeout_s` (120 s) for room in the host RAM budget, then fails with `resource_exhausted`. `device.start` fails with it at once; its `data.devices` says what uses the RAM and `data.hibernate_candidates` which running devices are idle longest. Hibernate or release your own devices, or wait; don't hibernate the user's.

## Safety policy (D5)

By default an agent can read, interact, start and stop. Commands flagged destructive (`device.delete`, `device.reset`, …) are refused unless:

- the device is **agent-owned**: devices an agent creates through `command_run device.create` are agent-owned automatically, and a person can mark one with `jidr device edit <name> --agent-owned true`; or
- the server runs as `jidr mcp --allow-destructive`.

Refusals carry `data.policy = "D5"`. Connection-level protocol methods (`hello`, `events.subscribe`, `logcat.follow`, `daemon.shutdown`) aren't callable through MCP.

## Measured latency (not gated)

From the five scripted agent tasks (`cargo nextest run -p jidr-mcp --features emulator`, M1 Pro, API 31 arm64): screenshot ~0.4–1.1 s, tap ~0.2–0.4 s, type_text ~0.7–1.2 s, press_key ~0.01–0.1 s, swipe 1–4 s, logcat_tail ~0.2–0.5 s, ui_dump 4–6 s median (uiautomator itself is slow), cold boot via `command_run device.start` 25–32 s.
