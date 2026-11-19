---
name: miko
description: "Run, watch and drive Android emulators with Miko (CLI `miko`, the Miko desktop app, MCP server `miko mcp`). Use when the user mentions Miko or a Miko device, or asks for an Android phone or tablet emulator to run something on, an emulator screenshot, logcat, rotation, snapshots, or starting and stopping a device. For testing an app's flows on a device, also load miko-app-testing."
---

# Miko

Miko (جذر) runs Android emulators, optionally rooted. A daemon owns every device. The desktop app, the `miko` CLI and the MCP server (`miko mcp`) are thin clients over the same protocol, so a device started from one shows up in all of them. Today Miko ships for macOS on Apple Silicon (arm64 images). Docs: https://github.com/hbdzh/miko-simulator (`docs/cli.md`, `docs/mcp.md`, `docs/control-protocol.md`).

If `miko` isn't on the `PATH`, use the CLI bundled in the installed app at `miko simulator.app/Contents/Helpers/miko`, or see https://github.com/hbdzh/miko-simulator for build and release information.

**Prefer the CLI.** It covers every command, needs no setup and works in scripts. `miko call <method> '<json>'` reaches any protocol command that has no subcommand. A Miko device is not an Android Studio AVD: `emulator -list-avds` doesn't list it. A `.miko` file is a script for `miko shell` (one `miko` command per line, without the `miko`); `miko shell file.miko` runs it and stops at the first failing line. Interactively, prefer one-shot `miko` commands over the shell.

## Find or create a device

```bash
miko device list                 # NAME, STATUS, IMAGE, ROOT, SERIAL (the adb serial while running)
miko --json device list          # the same as JSON
miko profile list                # phone-6.1-fhd, phone-6.7-qhd, small-phone-5, tablet-11, agent-lean
miko image list --installed      # images already downloaded (works offline)
```

Reuse a stopped device whose form factor fits the app. Otherwise create one from an installed image, so nothing has to download:

```bash
miko -q device create Phone --image 35 --profile phone-6.1-fhd --agent-owned
miko -q device start Phone --timeout 300    # waits for boot, prints the line with the adb serial
```

- `--image` takes `35`, `35:google_apis`, `35:google_apis_playstore` or a full `system-images;…` package.
- `--agent-owned` marks the device as yours, so you (or the MCP server) may delete it later (D5).
- Installing a new image downloads 1–2 GB and needs the user to accept Google's SDK license. Ask before `miko image install`, and never pass `--accept-licenses` for them.

## Let the user watch

The daemon runs devices headless. To see the screen, the user opens the Miko app and then the device's player window (on macOS: `open -a Miko`). Tell them that's where to look.

## Look, act and read logs

```bash
miko --json call media.screenshot '{"device":"Phone"}'        # result.path is the PNG; read it to see the screen
miko call sensor.rotate '{"device":"Phone","angle":90}'       # 0, 90, 180 or 270
miko call key.press '{"device":"Phone","key":"back"}'         # back, home, recents, enter, power, volume_up…
miko call app.launch '{"device":"Phone","package":"com.example.app"}'
miko logcat Phone -n 200 --filter ActivityManager:I
miko logcat Phone --clear
```

`media.screenshot` takes an optional `"path"`; without it the PNG goes to the user's Pictures/miko folder. Taps, swipes, text and the UI tree go through `adb -s <serial> shell input …` or the MCP tools; see miko-app-testing.

Other protocol commands work the same way through `miko call`: `network.set`, `gps.set`, `battery.set`, `clipboard.set`, `media.record` / `media.record_stop` and more. `miko audio inject <device> <file.wav>` plays a WAV as the device's microphone (`miko audio stop <device>` ends it). `miko commands` lists them all. A call with a missing param fails with `missing field <name>`, which tells you what to add.

`miko network loss` and `miko network dns` simulate network conditions and persist them across boots. `miko identity` reads identifiers and can change Android ID with root; doing so restarts the Android framework. `miko sync start <device> <folder>` mirrors a host folder one way to the device (or both ways with `--bidirectional`, resolving any conflicts with `miko sync resolve <id> <path> --keep local|remote|both`); stop it with `miko sync stop <id>`. Only sync folders and destinations the user has authorized. `miko input-sync start --leader <dev> --follower <dev>` mirrors player input from a leader device to followers (`miko input-sync status`, `miko input-sync stop`, `miko input-sync add|remove|leader <dev>`); input flows while the leader has an open player window. `miko gamepad` forwards a host controller. `miko flash` installs supported Magisk modules, copies ordinary ZIPs, and refuses recovery and partition images.

## Snapshots, stop and clean up

```bash
miko snapshot save Phone before-login
miko snapshot load Phone before-login
miko snapshot list Phone
miko device stop Phone                       # saves the quick-boot state
miko device delete Phone --yes               # only a device you created
```

## MCP instead of the CLI

If the Miko MCP server is connected (Claude Code: `claude mcp add miko -- miko mcp`), its tools do the same: `command_run` runs any protocol command (`device.create`, `device.start`…), and `screenshot`, `tap`, `swipe`, `type_text`, `press_key`, `ui_dump` and `logcat_tail` drive a device directly. `screenshot` returns the image itself, so you don't need to read a file. Devices created through `command_run device.create` are agent-owned automatically.

## Exit codes (with `--json`)

0 ok · 1 unexpected · 2 usage (bad params, missing `--yes`) · 3 not found or not running (start it) · 4 busy (another job holds the device) · 5 boot timeout · 6 SDK, download or license · 7 root failed · 8 stale daemon (rerun with `--restart-stale`) · 9 resource exhausted (the machine's RAM budget is full; see miko-agent-devices).

## Don't

- Don't delete, reset or wipe a device you didn't create in this session (`device delete`, `device reset`, `app.uninstall`, `snapshot delete`) without asking. Devices you created are yours to clean up; say what you removed.
- Don't stop a device the user is using or watching. Leave the user's devices as you found them.
- Don't change the root mode of the user's devices: `miko root set` cold-boots them.
- Don't create Miko devices with Android Studio's tools or in its AVD folder. Miko keeps its own SDK and devices and only reads Android Studio's.
