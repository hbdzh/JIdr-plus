# Jidr design

Direction **Workbench**: one IDE-like window, dark-first, soft cards, devices open in independent native windows. Read `system/README.md` first: it holds the voice, colour, status, type, motion, icon and RTL rules.

| What | Where |
|---|---|
| Tokens (W3C DTCG, dark and light) | `tokens.json` |
| Design-system rules | `system/README.md` |
| Component specs (50) | `system/components/<Name>/README.md` |
| Component CSS (the app's reduced-motion overrides come from it) | `system/components/bundle.css` |
| Workbench component CSS (retained as design reference) | `jidr.css` |
| Product brief | `PRODUCT.md` |
| Brand (icon, symbol, web set) | `../../assets/brand/` |
| SwiftUI visual refresh (2026-11): tokens, design kit and implementation notes | [`visual-refresh.md`](visual-refresh.md) |

Chosen concepts: launcher **1A** (sidebar device list and device detail), device window **4A** (docked widget panel), landing page **8A** (headline over the app).

## Implementation rules (D41)

- **One source:** `tokens.json`. Never hand-copy hex values.
  - `apps/jidr-swiftui/generate-tokens.sh` generates the raw Swift token layer and semantic Workbench layer. CI checks generation is idempotent.
  - The Swift semantic layer maps shared tokens to native controls and AppKit window chrome.
- **Fonts:** Geist, Geist Mono and Noto Kufi Arabic (all OFL-1.1). Bundle them in the app (`apps/jidr-swiftui/Resources/fonts/`, with licences) with the required OFL notices.
- **Icons:** native SF Symbols, mapped from the shared Lucide meanings by the Swift generator. Shared SVGs in `assets/lucide` retain their ISC license.
- **Brand vs tokens:** the app icon gradient (`#2A88FA → #1267E0`, `assets/brand/`) is the approved icon and stays as is. Inside the UI, use tokens only: accent `jidr-color-accent-*` for actions, root violet `jidr-color-root` for root only. The Arabic wordmark جذر uses `jidr-color-root`.
- Prefer native macOS controls and window/panel presentation; keep token-driven custom surfaces consistent.
