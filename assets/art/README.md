# coffee-bar — art package

One object at three scales: a 16×16 template glyph (menu bar), a 1024 layered app
icon (Apple grid), and a web/GitHub set cut from the same geometry.

**Colours** — ink `#121214` (light appearance) / `#F2F1EE` (dark), warm neutral base
`#EFEDE7`, web tile `#F2F0EB`, single accent `#76B900` used **only** for the liquid.
The menu-bar glyph has no colour at all — it is alpha only.

> **Filenames:** the export pipeline strips `@` from filenames, so `@2x`/`@3x` assets
> arrive as `-2x`/`-3x`. Run `menubar/fix-names.sh` and `appicon/make-icns.sh` once
> after unzipping to restore them.

## menubar/  — NSImage template images
`svg/`, `pdf/` (vector, 16pt — the format AppKit prefers), `png/` (16/32/48).

States: `idle`, `serving` (agent working), `attention` (agent blocked), `hot`
(machine running warm). Level variants `level-20/60/90` show battery percentage;
the liquid never drops below a 1.8px slug so low battery cannot read as "off".

The `Template` suffix is load-bearing — AppKit tints and inverts these automatically:

```swift
let img = NSImage(named: "coffee-bar-servingTemplate")!
img.isTemplate = true
statusItem.button?.image = img
```

Never tint these yourself, never ship a coloured menu-bar variant.

## appicon/  — 1024 app icon
- `layers/` — 9 SVGs: `{default,dark,mono}-{1-base,2-vessel,3-liquid}`. Square, flat,
  no mask, no shadow, no rounded corners; base layers are fully opaque, artwork
  layers carry alpha. This is what Icon Composer wants.
- `AppIcon.icon/` — Icon Composer bundle (`icon.json` + `Assets/`). Open it once in
  Icon Composer to confirm layer order and re-save before shipping.
- `svg/`, `pdf/` — flattened 1024 vector, one per appearance.
- `png/{default,dark,mono}/` — 16…1024 rasters.
- `AppIcon.iconset/` + `make-icns.sh` → `AppIcon.icns` via `iconutil`.

## web/
`favicon.svg` (monochrome, `prefers-color-scheme` aware), `favicon-16/32/48.png`,
`apple-touch-icon-180.png`, `icon-192/512.png`, `icon-512-maskable.png`,
`site.webmanifest`, `head-snippet.html` (paste into `<head>`).

## wordmark/
`coffee-bar-wordmark-{light,dark}.png` (+`-2x`). Always lowercase, always
hyphenated — it is a command name. Clear space either side = one glyph width.

## github/
- `social-preview-1280x640.png` — Settings → Social preview.
- `repo-avatar-512/1024.png` — org or project avatar.
- `readme-header-1600x400.png` — top of README:
  `<img src="assets/art/github/readme-header-1600x400.png" width="800" alt="coffee-bar">`

## Don't
Skeuomorphic beans, saucers or latte art; sparkles, neural nets or other AI motifs;
gradients; a second accent colour; any colour in the menu-bar glyph.
