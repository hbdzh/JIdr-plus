---
name: miko-agent-devices
description: "Get an Android emulator of your own with Miko instead of using the user's: lease a throwaway clone of a base (`miko pool get`), use its serial, renew and release it, or create a persistent lean device. Covers the host RAM budget, `resource_exhausted` (exit 9) and hibernating idle devices. Use when you need a device for testing, CI or parallel agents, when several agents or devices share one machine, or when a start fails because the machine is full. Load miko for the basics."
---

# Devices of your own

Many devices can share one machine (D42), but RAM is the limit: a default phone costs about 7.6 GB of host memory, a lean one about 4 GB. Use a device that is yours, never one the user is working on. Don't attach to `emulator-5554` or any serial you didn't get from the commands below, and don't stop, hibernate or delete the user's devices.

## Throwaway: lease a clone of a base

A base is a snapshotted device that clones resume from in seconds. See which exist:

```bash
miko base ls                         # BASE, IMAGE, PROFILE, ROOT, LEASED
```

If there's none, ask the user before making one: it stops the device it is made from. They can make it themselves, or let you:

```bash
miko -q device create agent-base --image 35 --profile agent-lean --agent-owned
miko -q device start agent-base --timeout 300
miko base create agent-base android-35    # snapshot miko-base; stops agent-base, retains its settings
```

Then lease a clone, use the serial it prints, and give it back:

```bash
miko --json pool get android-35 --ttl 1h     # result.serial, result.lease.id, result.device.name
adb -s emulator-5556 shell getprop sys.boot_completed
miko pool renew 4b0c1d2e-0000-4000-8000-000000000000 --ttl 1h     # long task: extend the lease
miko pool release android-35-a1b2c3           # by device name or lease id; the clone is deleted
miko pool ls                                  # your leases and when they expire
```

- The serial in `result.serial` is the only device you may touch. Pass it to adb (`adb -s <serial>`), Flutter (`flutter run -d <serial>`) or Gradle (`ANDROID_SERIAL=<serial>`).
- A lease ends at its TTL (default `2h` from the CLI), counted from delivery. TTL leases keep their IDs and deadlines across daemon restarts. The daemon then stops and deletes the clone, so renew it before a long run. If renewal reports `busy`, the clone is already being released. Always release when you're done.
- Nothing you do in a clone reaches the base or other clones. Each clone starts from the base's saved state.
- Miko disables animations in each clone before handing it over; creating a base leaves the source's animation settings untouched.

## Persistent: a lean device

When the device must keep its state between sessions (an account you logged into, a long-lived test setup), create your own with the lean profile (720×1280, 2 GB, no audio or cameras):

```bash
miko -q device create agent-phone --image 35 --profile agent-lean --agent-owned
miko -q device start agent-phone --timeout 300
miko device hibernate agent-phone           # saves everything and frees its RAM; start resumes in seconds
miko device start agent-phone
```

Hibernate your device when you pause for a while instead of leaving it running. `miko device stop` also saves quick-boot state, but resuming a hibernated device is faster.

## The machine is full

`miko device start` exits **9** (`resource_exhausted`) when starting would go past the RAM budget (75% of host RAM by default). `miko pool get` first waits up to `--timeout` seconds (120 by default), then exits 9.

```bash
miko budget                          # what each running device is expected to use and uses now
miko --json device start agent-phone # on exit 9: error.data.devices, error.data.hibernate_candidates
```

What to do, in order:
1. Release clones you leased and no longer need, and hibernate or stop your own idle devices (`hibernate_candidates` lists the longest-idle running devices; only touch the ones you created).
2. Use the `agent-lean` profile instead of a default one.
3. Wait and retry (`miko pool get … --timeout 600`).
4. Only if the user agrees: `miko device start <name> --force`. It can make the whole machine swap.

## With MCP or `miko call`

With the MCP server (`miko mcp`), `pool_get {base}` and `pool_release {lease | device}` do the same as the CLI. Without `ttl_s`, the lease lasts as long as your MCP session; if the session ends without a release, the daemon deletes the clone 2 minutes later. Other commands go through `command_run`: `base.list`, `pool.renew`, `device.hibernate`, `host.budget`.

Every command above is also a protocol command for scripts:

```bash
miko call host.budget
miko call pool.list
miko call device.hibernate '{"device":"agent-phone"}'
```

## Don't

- Don't use, stop, hibernate or delete a device you didn't create or lease. Ask instead.
- Don't make a base from the user's device without asking: `base create` stops it.
- Magisk bases require an existing shell `su` grant and copy the source's app data and root settings into each clone. On Play Store images the user must choose a permanent grant; never grant it on their behalf.
- Don't leave leases or running devices behind. Release and stop what you started, and say what you removed.
- Don't use `--force` past the budget on your own.
