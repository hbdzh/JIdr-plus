# Bundled runtime provenance — local candidate

Status: local verification in progress; **not approved for public redistribution**.

## Inputs

- Android Emulator `37.3.10`, build `16970787`, Google official archive `emulator-darwin_aarch64-16970787.zip`, SHA-1 `3ec739595d44092e835f006d806dd380bc8d6dd7`.
- Android SDK Platform-Tools `37.0.3`, Google official archive `platform-tools_r37.0.3-darwin.zip`, SHA-1 `d48920e2650321710b4d15d3acd9e277d59cd55b`.
- The official archives were downloaded and their archive checksums verified. Every file present in the candidate was compared to the matching archive entry: 200 emulator files match; the sole replaced file is `qemu/darwin-aarch64/qemu-system-aarch64-headless`. Its SHA-256 is `1731317391dcb943fc4dc867133045b75755b30e7ad49a9ca1b83ddbf88f7dbd`. Two `.miko-*` records are locally generated. All 12 platform-tools files match; its `.miko-package.json` is locally generated. Unused Qt and Android skin overlay APKs are absent from the candidate.
- The replacement was built locally from AOSP `platform/external/qemu` commit `5e51202879523d4df1bca8ca6944129ff05df02b`; six files are modified. The local diff SHA-256 is `342484fad499de73a48ad1604b5a14036a9c3a6025af2e5d990a292f7be04f2f`. The patch, observed project revisions, build-generated notices and pinned file hashes are retained in `packaging/runtime-source/`. A temporary source snapshot and dependency source candidates were also collected.
- The candidate copies upstream Emulator `LICENSE`, `NOTICE.txt`, `NOTICE.csv`, Platform-Tools `NOTICE.txt` and the locally generated core notices and licence texts with the binary files.

## Licence and source review

- The emulator notice identifies GPL-2.0-only QEMU, GPL-2.0-or-later FFmpeg and LGPL components among others. Its package root also includes an Apache-2.0 notice. Google SDK terms distinguish open-source components from other SDK components; the package cannot be treated as having one blanket licence.
- A source candidate was gathered for the modified QEMU tree and several identified dependencies. This is **not established to be the complete corresponding source** for every distributed binary. The QEMU patch and dependency source/revision mapping, build instructions, build-time dependencies, and source-offer/access method require verification.
- `libselinux` is labeled `CC-PDDC OR UNKNOWN` by the generated inventory; its source NOTICE states it is public-domain software with a warranty exclusion. Other component-level obligations still need review.
- The AOSP checkout's manifest export failed because the optional system-images project is absent. Existing project HEADs were recorded, but a clean rebuild and a fully pinned manifest are not yet verified. The locally built core is not currently reproducible by the repository's CI.
- Until the above review is completed, the conditional clean-room rule prohibits publicly redistributing the bundled candidate. This record is technical evidence, not a legal conclusion.

## Reproduction and verification performed

- `scripts/prepare-bundled-runtime.py` successfully reconstructed the 215-file pinned runtime from independently downloaded official archives, the saved metadata and the locally built core. The release command now rejects a missing, modified, additional or incomplete input before building.
- An ad-hoc local DMG built from the reconstructed runtime passed mounted-image validation, retained the original and generated core notices, and selected its embedded SDK from an isolated home. An isolated Android 36 device was created, started, stopped and deleted using the bundled runtime and a pre-existing read-only image.
- The final candidate, verified input archives and core, and the incomplete source-review kit are retained locally under `target/miko-runtime-review/`; this ignored directory is not a public source distribution or a long-term source offer.
- The published v0.10.0 tag and DMG predate this work and do not contain the runtime. The normal release command remains blocked pending review; CI has not yet been configured to acquire or build the pinned core.
