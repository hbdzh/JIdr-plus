# On-device helper and packet loss

JIdr builds a small Apache-2.0 Rust helper for the Android guest. It starts on
demand under Shell Root or Magisk, exposes fixed typed operations over an
abstract Unix socket, and is reached through an adb forward on host loopback.
The guest checks peer credentials and accepts only root and the adb shell;
the host checks the executable's SHA-256 and protocol before use. The helper
does not offer an arbitrary command interface. The source and approach are
adapted from upstream Jidr's [helper implementation](https://github.com/jidr-dev/jidr/commit/6f3f9a0364d6db770b4d41ceeb1c58e2fbc90d73).

`network.shaping.set` controls egress packet loss using the guest's `tc`
and `netem` on interfaces with an IPv4 default route. It needs a running,
rooted device and kernel support for netem. A cold boot clears the setting;
a snapshot can retain it. Changing interfaces or routes may require applying
the setting again. A partial failure across interfaces can leave some changed;
read the status and clear or retry. Setting loss replaces the selected
interfaces' root qdisc; clearing removes a root netem qdisc. It is therefore
not suitable for preserving a separately configured custom qdisc.

Development builds need `cargo xtask helper --arch aarch64` for arm64 guests
or `--arch x86_64` for x86_64 guests. A release packages the arm64 helper in
the app and MCP bundle; the release scanner permits it only at the intended
paths and only when it matches the just-built helper. The helper is not an
Android SDK binary or system image.
