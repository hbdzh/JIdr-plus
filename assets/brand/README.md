# Miko brand assets

The symbol is a root (جذر) that grows into a phone outline. The legacy symbol and web assets are generated from `source/appLogoOnPaper.jpg` by `build.sh`. The app bundle and MCP icons use the approved default artwork in `../icon/Icon/`; `build.sh` regenerates them from that file.

```bash
brew install potrace librsvg imagemagick   # once
assets/brand/build.sh
```

## Colours

| Token | Hex | Use |
|---|---|---|
| Brand blue (top) | `#2A88FA` | icon gradient start |
| Brand blue (bottom) | `#1267E0` | icon gradient end; favicon symbol |
| Lilac | `#B9A6F7` | Arabic wordmark جذر on dark |
| Ink | `#101010` | social card background |

These were sampled from the approved board (`source/brand-board.jpg`). When the design system's `tokens.json` lands in `docs/design/`, it is the source of truth; update the colours in `build.sh` to match and re-run.

## Files

| File | What | Used by |
|---|---|---|
| `symbol.svg` | the symbol, `fill="currentColor"` | everything; tint it |
| `symbol-bold.svg` | thicker strokes for ≤32 px | small icons, favicon, menu bar |
| `app-icon.svg` / `app-icon-1024.png` | legacy icon artwork | docs and legacy web assets |
| `app-icon-small.svg` | legacy 16/32 px artwork | favicon |
| `avatar.svg` / `avatar-1024.png` | circular avatar | GitHub org/repo, social profiles |
| `social-card.svg` / `.png` | 1200×630 preview card | Open Graph / Twitter card |
| `web/` | `favicon.svg`, `favicon.ico`, `favicon-32.png`, `apple-touch-icon.png`, `og-image.png`, `avatar-512.png`, `symbol.svg` | standalone web assets |
| `../../apps/miko-swiftui/Resources/Miko.icns` | app bundle icon (16–1024, @1x/@2x) | Phase 12a bundle (`CFBundleIconFile`) |

## Rules

- Never recolour the app icon gradient outside the tokens above. Tint `symbol.svg` with text or accent tokens in-app.
- Keep clear space around the symbol of at least ¼ of its width.
- No Google, Android or Genymotion marks next to the symbol.
- Ownership: this folder is shared and read-only for the work streams. Only `build.sh` changes it.

The native app icon is generated at `apps/miko-swiftui/Resources/Miko.icns`. Retired Slint/menu-bar raster duplicates are no longer generated.

The four approved artwork variants are retained under `../icon/Icon/`. The macOS bundle and MCP extension use the default variant; the iOS dark and clear variants are not automatically selected by the macOS `.icns` format.
