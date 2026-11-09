# macOS packaging

`cargo xtask release` (in `xtask/src/release.rs`) builds `Jidr.app`, `Jidr-<version>-arm64.dmg` and the MCP bundle `jidr-mcp-<version>-darwin-arm64.mcpb` from this folder and `../mcp`.

| File | What |
|---|---|
| `Info.plist.in` | bundle metadata; `@VERSION@` becomes the workspace version |
| `sign.sh` | Developer ID signing (hardened runtime, inside-out) and DMG notarization + staple; `cargo xtask release` calls it when `JIDR_SIGNING_IDENTITY` is set |
| `verify.sh` | Gatekeeper, hardened runtime and the stapled ticket; the release workflow runs it on signed builds. Fails on ad-hoc builds, as expected |
| `../mcp/manifest.json` | MCPB manifest (`@VERSION@`); the bundle holds it, the signed `jidr` as `server/jidr`, the icon and the licences. `jidr-mcp`'s tests check its tool list |
| `../../server.json` | MCP Registry metadata template; its release URL and checksum must be verified before any future publication |

Bundle layout:

```
Jidr.app/Contents/
  Info.plist  PkgInfo
  MacOS/Jidr            GUI (apps/jidr-gui, GPL-3.0)
  Helpers/jidr          CLI, daemon and MCP server (apps/jidr, Apache-2.0)
  Resources/Jidr.icns   from apps/jidr-gui/assets/macos (D39)
  Resources/licenses/   LICENSE-APACHE, LICENSE-GPL, NOTICE
```

The CLI lives in `Helpers/` because `MacOS/jidr` and `MacOS/Jidr` are the same path on the default case-insensitive APFS.

```bash
cargo xtask release --dry-run --scan    # local build, DMG, mount check, forbidden-content scan
```

## Releases and signing (D32)

Run the **Check release packaging** workflow manually on the branch to build and scan unsigned test artifacts without creating a release. The workflow stores the DMG, MCP bundle and checksums as a short-lived Actions artifact; these files are not notarized and are not a public release.

The inherited release-please workflow is configured for `main`; this repository currently uses `jidr-plus-initial`, so that automation does not run on the current branch. The manually dispatched release workflow builds and uploads assets to an existing release tag in this repository. It does not publish an MCP Registry entry or website. `server.json` contains a placeholder checksum and must not be published directly. The release workflow generates `mcp-registry.json` using the actual MCP bundle checksum and uploads it as an asset for review; registry publication is a separate manual step.

Repository secrets for signing (without them the DMG is ad-hoc signed and the run warns; users then open the app from System Settings › Privacy & Security › Open Anyway):

| Secret | Value |
|---|---|
| `MAC_DEVELOPER_ID_P12_BASE64` | the Developer ID Application certificate and its private key, exported from Keychain Access as a `.p12`, base64-encoded |
| `MAC_DEVELOPER_ID_P12_PASSWORD` | the password chosen when exporting the `.p12` |
| `MAC_NOTARY_KEY_P8_BASE64` | an App Store Connect API key (`.p8`, from App Store Connect › Users and Access › Integrations), base64-encoded |
| `MAC_NOTARY_KEY_ID` | that key's ID |
| `MAC_NOTARY_ISSUER_ID` | that key's issuer ID |
| `RELEASE_PLEASE_TOKEN` | optional: a fine-grained token with contents and pull-requests write, so the release PR runs CI |

Set them without printing anything, for example `base64 -i developer-id.p12 | gh secret set MAC_DEVELOPER_ID_P12_BASE64`, and check the file exists first: if `base64` fails, `gh` stores an empty secret.

To sign and notarize locally: `JIDR_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_KEY_PATH=path/to/AuthKey.p8 NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… cargo xtask release --scan`.

The scan fails the build if the bundle or the DMG contains Google SDK binaries, system images or Magisk. Jidr downloads those on the user's machine, never ships them.
