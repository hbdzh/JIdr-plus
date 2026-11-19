# `miko` command line

`miko` drives everything the Miko app can do, from a terminal or a CI script. It talks to the Miko daemon, which it starts automatically when needed (D4). Run `miko --help` or `miko <command> --help` for every flag; `miko completions zsh|bash|fish` prints shell completions.

## Quick start

```bash
miko image list                                   # images for this Mac
miko image install 35 --accept-licenses           # API 35 google_apis
miko device create Phone --image 35               # rooted with adb by default (D7)
miko device start Phone                           # waits until booted
miko install Phone app.apk
miko logcat Phone -n 100
miko device stop Phone
```

In CI, add `--json` and check the exit code:

```bash
miko --json device start Phone --timeout 300 || exit $?
```

## Commands

| Command | What it does |
|---|---|
| `device create <name> --image <img> [--profile id] [--ram MB] [--cpus N] [--width px] [--height px] [--density dpi] [--data-mb MB] [--root none\|adb\|magisk] [--agent-owned]` | Create a device. `<img>` is `35`, `35:google_apis`, `35:google_apis_playstore`, `35:google_apis:arm64-v8a` or a full `system-images;…` package. |
| `device start <names…> \| --all [--cold-boot] [--no-wait] [--timeout s] [--force]` | Start and wait for boot. `--timeout` cancels the boot and exits 5. `--no-wait` returns the boot job id. Past the host RAM budget it exits 9 unless `--force`. |
| `device stop <names…> \| --all` | Stop, saving quick-boot state (D29). Flushes the guest's storage (`sync`) first, so settings changed just before the stop survive the next start. |
| `device hibernate <names…> \| --all` | Save each running device's whole state under the snapshot `miko-hibernate`, check it holds memory, then stop it without the quick-boot save (D42). It uses no RAM; `device start` resumes it in seconds. `device stop` leaves it hibernated; `device reset` discards the state. Auto-hibernate after idle minutes: `settings set --auto-hibernate-minutes N` (off by default) or per device `device edit <name> --auto-hibernate N` (`0` = never, `--auto-hibernate-default` follows the setting). Idle means no Miko command for the device and no player attached. |
| `device list`, `device details <name>`, `device connect-info <name>` | Status, settings and disk usage; the gRPC endpoint/token and adb serial of a running device. |
| `device clone <name> <new> [--keep-snapshot snap]`, `device edit <name> [--rename n] [--ram …] [--agent-owned bool] [--auto-hibernate N \| --auto-hibernate-default]` | Copy or change a stopped device. With `--keep-snapshot` the copy is a copy-on-write clone (APFS / reflink; a full copy after a disk check elsewhere) that keeps that snapshot and resumes it on its first start, in seconds (D42); without it the copy cold-boots. |
| `device reset <name> --yes`, `device delete <names…> \| --all --yes` | Destructive: wipe data, or delete. Without `--yes` they ask on a terminal and refuse otherwise. |
| `install <name> <apk> [--no-replace] [--grant] [--downgrade]` | Install an APK. A signature mismatch fails with `details.signature_mismatch = true`. |
| `push <name> <local> [remote]`, `pull <name> <remote> <local>` | Copy files (push defaults to `/sdcard/Download/`). |
| `logcat <name> [-n N] [--filter spec…] [-f] [--clear]` | Dump, follow (`-f`) or clear the log. |
| `flash <name> <zip>` | Install Magisk/Zygisk modules on Full-root devices, or copy other supported ZIPs to Download. Recovery, Riru and partition-image archives are refused. |
| `sync start <device> <folder> [remote] [--bidirectional]`, `sync list [device]`, `sync resolve <id> <path> --keep local\|remote\|both`, `sync stop <id>` | One-way or bidirectional folder synchronization. One-way copies host changes and deletions to the device while preserving device-only files; `--bidirectional` syncs changes and deletions both ways and preserves conflicts for `sync resolve`. Start returns before the first copy finishes. |
| `input-sync start --leader <dev> --follower <dev>… [--adaptation stretch\|letterbox] [--no-keyboard] [--no-text] [--no-tool-keys] [--unlock-followers] [--jitter-ms N]`, `input-sync stop`, `input-sync status`, `input-sync add\|remove\|leader <dev>` | Mirror player input from a leader device onto running followers (D45, [sync.md](sync.md)). The CLI manages the session; input flows while the leader has an open player window. |
| `gamepad list`, `gamepad connect <device> [--controller id]`, `gamepad disconnect <device>` | Forward a Mac game controller to a running emulator; connect returns a job ID. |
| `identity <device> [--android-id ID]` | Read Android ID and IMEI, or set a 16-digit hexadecimal Android ID with root. Setting restarts Android's framework. IMEI is read-only. |
| `image list [--installed]`, `image install <img> [--accept-licenses]` | System images. |
| `profile list` | Built-in hardware profiles (D24). `agent-lean` (720×1280, 2 GB, 2 cores, no audio or cameras) costs ~4 GB of host RAM instead of ~7.6 GB. |
| `budget` | Host RAM, the device budget (`settings set --budget-percent`, 75% by default) and what each running device is expected to use and uses now (D42). |
| `network loss <device> [percent]`, `network dns <device> [normal\|slow\|fail] [--delay-ms N]` | Control outgoing packet loss and DNS simulation. Requires root and netem; stored settings are restored on boot. See [on-device helper](on-device-helper.md). |
| `root helper <device>` | Start the on-device helper if needed and report its version, protocol, uid and SELinux context. |
| `sdk status`, `sdk licenses <pkgs…>`, `sdk install <pkgs…> [--accept-licenses]` | The SDK Miko uses (its private one by default, or a configured writable custom install root; Android Studio's is only read, D3). |
| `root set <name> none\|adb\|magisk`, `root verify <name>`, `root status <name>`, `root auto-grant <name> on\|off` | Root modes (provided by the root engine). `auto-grant` grants every app root without a prompt on a Full-root device (D22, off by default; `root.auto_grant`). |
| `root writable-system <name> on\|off` | A writable `/system` on an `adb`-root device (`-writable-system` + `adb remount`); `off` goes back to the read-only stock image. Cold boots a running device (D29); refused with exit code 2 on `none`/`magisk` devices, Play Store images and images older than API 31. See docs/root.md. |
| `snapshot list\|save\|load\|delete <name> [snapshot]` | Snapshots tagged with their root mode (provided by the widgets provider). |
| `base create <device> <name>`, `base ls`, `base rm <name> --yes` | Bases (D42): `create` saves a running device (including Magisk root) as a read-only base with snapshot `miko-base` and stops the device. Its animation settings are preserved; pool clones disable animations before delivery. Magisk requires a valid per-device patched ramdisk and a working shell `su` grant. A base can't be started; `rm` refuses while clones of it are leased. |
| `pool get <base> [--ttl 2h] [--timeout s]`, `pool release <lease\|device>`, `pool renew <lease> [--ttl 2h]`, `pool ls` | Throwaway clones of a base for agents and CI (D42): `get` resumes a copy-on-write clone and prints its serial. The lease lasts `--ttl` (default 2 h) from delivery, then the daemon stops and deletes the clone. TTL leases retain their IDs and deadlines across daemon restarts. A full RAM budget makes `get` wait up to `--timeout` (120 s), then exit 9. The daemon stays up while leases exist (D4). |
| `cert install <name> <file>`, `cert list <name>`, `cert verify <name>`, `cert remove <name> <cert>\|--all` | CA certificates in a Full-root device's system store (root engine, `root.cacert.*`); install and remove restart the device. See docs/root.md. |
| `proxy set <name> [host:]port`, `proxy clear <name>`, `proxy show <name>` | The device's global HTTP proxy (widgets provider, `network.proxy.*`). The host defaults to `10.0.2.2`, this Mac. |
| `audio inject <name> <file> [--loop] [--rate Hz [--channels 1\|2]] [--no-wait]`, `audio stop <name>` | Play a WAV as the device's microphone (widgets provider, `audio.*`); `--rate` reads the file as headerless 16-bit PCM. See [Microphone](#microphone). |
| `jobs list [--all]`, `jobs wait <job>`, `jobs cancel <job>` | Long-running operations. |
| `commands` | Every protocol command (what the GUI and MCP see). |
| `call <method> [params-json]` | Call any protocol command directly, e.g. `miko call device.start '{"device":"Phone","cold_boot":true}'`. Follows jobs. |
| `daemon [run]`, `daemon stop`, `daemon status` | Run the daemon in the foreground, stop it (devices keep running), or show it. |
| `shell [script]` | Interactive shell, or run a script of commands; see [Shell](#shell). |
| `completions <shell>` | Shell completions. |

Global flags: `--json`, `-q/--quiet` (no progress), `--restart-stale` (or `MIKO_RESTART_STALE=1`).

## Shell

`miko shell` is an interactive shell, Miko's take on Genymotion Shell. Each line is a `miko` command without the `miko` (a leading `miko` is ignored, so pasted lines work). It uses the CLI's own command definitions over one daemon connection, so every command, flag, output and exit code is the same as in the one-shot CLI, and it adds nothing to the protocol.

```text
$ miko shell
miko> use Phone
Using Phone.
miko (Phone)> device start --timeout 300
miko (Phone)> proxy set 8080
miko (Phone)> snapshot save before-login
miko (Phone)> call sensor.rotate '{"angle":90}'
miko (Phone)> --json device details
miko (Phone)> exit
```

| Builtin | What it does |
|---|---|
| `use <device>` | Make it the current device, shown in the prompt; `use` alone clears it. |
| `source <file>` | Run a script (below) inside the shell. |
| `help [command]` | The builtins and commands, or a command's `--help`. |
| `exit [code]`, `quit`, Ctrl-D | Leave the shell. |

**The current device** is filled in for commands that take a device first (`device start`, `proxy set`, `snapshot save`, `install`, `logcat`, `root`, `cert` …) when the line doesn't name one: if the first argument is an existing device's name or id it is used as it is, otherwise the current device is put in front of the arguments (`proxy set 8080` runs `proxy set Phone 8080`). Lines with `--all` are left alone. `call <method> [params]` gets `"device"` added to its params when the method takes one and the params don't name it.

**Words** split like a POSIX shell without expansion: `'…'` is literal, `"…"` honours `\"` and `\\`, `\` escapes one character, and `#` at the start of a word begins a comment. There are no variables, pipes or `$(…)`; use your own shell for those.

**Completion and history.** Tab completes builtins, subcommands, flags, value choices (`root set Phone <Tab>`), device names, protocol methods from `commands.list` after `call`, and file paths. History is kept in `shell_history` in Miko's data directory (`~/Library/Application Support/miko`, or `$MIKO_HOME/data`). Ctrl-C stops the running command (a job it started keeps running in the daemon, as when Ctrl-C ends a one-shot `miko`; `jobs cancel` stops it) and the shell carries on.

**Scripts.** `miko shell setup.miko`, piped input (`miko shell < setup.miko`, or `-` for stdin) and `source` run the lines in order, skipping blank lines and `#` comments, so `#!/usr/bin/env -S miko shell` works as a first line. The first failing line stops the script: stderr says `setup.miko:5: stopped here (exit code 3)` and `miko shell` exits with that command's [exit code](#exit-codes). `exit <code>` ends a script early. `--json` and `-q` given before `shell` apply to every line; with `--json`, each command prints its own envelope line.

```bash
# setup.miko
device create Phone --image 35 --profile phone-6.1-fhd
use Phone
device start --timeout 300
proxy set 8080
snapshot save clean
```

## HTTP proxy

Point a running device at Burp, mitmproxy or any HTTP proxy on your Mac:

```bash
miko proxy set Phone 8080             # 10.0.2.2:8080, the Mac's port 8080
miko proxy set Phone 192.168.1.5:3128 # a proxy elsewhere on the network
miko proxy show Phone
miko proxy clear Phone
```

Inside the emulator `10.0.2.2` is the Mac's `127.0.0.1`, so Burp's default listener (`127.0.0.1:8080`) works as it is; `127.0.0.1` on the device is the device itself. The proxy is Android's global `http_proxy` setting: apps that use the system proxy (most HTTP stacks, WebView, Chrome) send their traffic through it, on Wi-Fi and mobile data. It takes effect at once and stays across restarts and snapshots until you clear it. To read HTTPS, apps must also trust the proxy's CA as a system certificate: `miko cert install` on a Full-root device (see [CA certificates](#ca-certificates)).

## CA certificates

To read HTTPS from apps, trust the proxy's CA as a system certificate on a Full-root (Magisk) device:

```bash
miko root set Phone magisk                   # once
miko cert install Phone ~/Downloads/cacert.der   # Burp's CA (PEM or DER); restarts the device
miko cert list Phone
miko cert remove Phone a4ac454c.0            # or --all
```

`install` restarts the device and fails with exit code 7 (root failed) unless the certificate ends up in the store apps read. How it works on each Android version is in docs/root.md.

## Microphone

Play an audio file into a running device's microphone, for voice input, speech recognition or call tests:

```bash
miko audio inject Phone ~/Desktop/hello.wav           # waits until it has played
miko audio inject Phone ~/Desktop/hello.wav --loop --no-wait
miko audio stop Phone
miko audio inject Phone capture.pcm --rate 16000      # headerless 16-bit little-endian PCM, mono
```

Miko streams the file over the emulator's gRPC `injectAudio`. WAV files can be 8- or 16-bit PCM (sent as they are), or 24/32-bit PCM or 32/64-bit float (converted to 16-bit), mono or stereo, at 8–48 kHz. Other files, other rates and more channels exit 2; convert them first, e.g. `afconvert -f WAVE -d LEI16@44100 in.m4a out.wav`. The audio plays as the device reads its microphone: start the app's recording before or after, and if nothing records, playback waits (the progress stops) until something does or you stop it. `--loop` repeats until `audio stop`; `jobs cancel` also ends it. One file plays at a time per device; a second `audio inject` exits 4. The Mac's own microphone isn't routed to the device (yet).

## Licenses (D8)

Images and the emulator are downloaded from Google on your machine, after you accept their license. On a terminal, `miko image install` shows each license and asks. Headless, `--accept-licenses` prints each license id and the SHA-256 of its text, then records your consent. Read the texts first with `miko sdk licenses <package>`. When a license text changes, Miko asks again.

## JSON output (`--json`)

Every command prints exactly one JSON line (`logcat -f` prints one per log line):

```json
{"miko_json": 2, "ok": true, "result": …}
{"miko_json": 2, "ok": false, "error": {"code": "not_found", "exit_code": 3, "message": "no device named \"x\"", "data": null}}
```

`miko_json` is the envelope version; it changes only on breaking changes (see the changelog below). `result` is the protocol result of the underlying command (docs/control-protocol.md). Commands that act on several devices (`device start|stop|delete`) return an array.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | Unexpected error |
| 2 | Usage: bad arguments or params, unknown command, missing `--yes` |
| 3 | Not found (device, image, job…), or the device isn't running |
| 4 | Busy: another operation holds the device (`error.data.holder` is the job) |
| 5 | Boot timeout |
| 6 | SDK, emulator, download or license problem |
| 7 | Root failed |
| 8 | Daemon stale: a daemon of another version is running (use `--restart-stale`) |
| 9 | Resource exhausted: starting would go past the host RAM budget (`error.data.devices` lists what uses it; see `miko budget`) |

## Environment

| Variable | Effect |
|---|---|
| `MIKO_HOME` | Put all Miko data under this directory (tests, portable setups) |
| `MIKO_LOG` | Daemon log filter, e.g. `debug` |
| `MIKO_DAEMON_BIN` | The `miko` binary used to auto-start the daemon |
| `MIKO_SDK_REPO` | SDK repository mirror (default Google's) |
| `MIKO_RESTART_STALE` | Same as `--restart-stale` |

## Changelog

| `miko_json` | Change |
|---|---|
| 2 | Renamed the envelope version field to `miko_json`. |
| 1 | Initial format used the previous envelope field. |
