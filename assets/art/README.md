# coffee-bar — art package

One object at three scales: a 16×16 template glyph (menu bar), a 1024 layered app
icon (Apple grid), and a web/GitHub set cut from the same geometry.

**Colours** — ink `#121214` (light appearance) / `#F2F1EE` (dark), warm neutral base
`#EFEDE7`, web tile `#F2F0EB`. Two accents, with two jobs:

| Role | Light | Dark | Job |
|---|---|---|---|
| state | `#A2571E` | `#B8682A` | the liquid; held awake |
| action | `#FF9500` | `#FF9F0A` | Apple `systemOrange`; buttons, links, focus |
| rest | `#6B7683` | `#6B7683` | released; free to sleep |

**Never mix the two.** `state` colours the liquid and the held segments — in the
icon system it is used **only** for the liquid. `action` colours buttons, links
and focus rings, and appears on the web only. Neither carries text: both fail
4.5:1 on either background. Ink on `action` reaches 8.51 (light) and 9.10
(dark), so a filled button carries body text.

The accent moved off `#76B900` on 2026-08-04. That green is NVIDIA's brand
colour and this is a personal Apache-2.0 product, so it can read as corporate
endorsement — and coffee is not green.

> **The recolour is not finished.** `site/**` carries the new accents. The app
> icon sources under `assets/art/appicon/**`, the web set under
> `assets/art/web/**`, and the GitHub art under `assets/art/github/**` all still
> carry `#76B900`. Re-cutting them, and rebuilding `AppIcon.icns`, is a tracked
> follow-up and is out of scope for the site redesign (design §8). Until it
> lands, the installed app icon stays green while the site is roast.

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
gradients; a third accent colour; any colour in the menu-bar glyph.
