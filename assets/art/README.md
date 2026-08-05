# coffee-bar — art package

One object at three scales: a 16×16 template glyph (menu bar), a 1024 layered app
icon (Apple grid), and a web/GitHub set cut from the same geometry.

**Colours** — ink `#121214` (light appearance) / `#F2F1EE` (dark), warm neutral base
`#EFEDE7`, web tile `#F2F0EB`.

Three roles. **`state` and `action` are the two accents.** `rest` is a neutral
grey, not an accent — it is what the palette uses to say "nothing is held".

| Role | Light | Dark | Job | Accent? |
|---|---|---|---|---|
| state | `#A2571E` | `#B8682A` | the liquid; held awake | yes |
| action | `#FF9500` | `#FF9F0A` | Apple `systemOrange`; buttons, links, focus | yes |
| rest | `#6B7683` | `#6B7683` | released; free to sleep | no |

**Never mix `state` and `action`.** `state` colours the liquid and the held
segments — in the icon system it is used **only** for the liquid. `action`
colours buttons, links and focus rings, and appears on the web only.

**Neither accent carries body text.** That is a design rule, not a measurement.
Only one of the four combinations actually fails 4.5:1:

| combination | ratio | verdict |
|---|---|---|
| `action` `#FF9500` on light `#F2F0EB` | 1.93 | fails |
| `action` `#FF9F0A` on dark `#101013` | 9.24 | passes |
| `state` `#A2571E` on light `#F2F0EB` | 4.71 | passes |
| `state` `#B8682A` on dark `#101013` | 4.57 | passes |

Holding both accents out of body text in both appearances keeps this one rule
instead of four exceptions. Ink **on** `action` is the safe inverse — 8.51
(light) and 9.10 (dark) — so a filled button carries body text.

In the **app**, `state` tints the selected segment of all three pickers —
Serving, Display and Battery floor — because a selected segment is a held
segment. The indicator beside the serving summary takes `state` while a hold is
active and `rest` when it is released; its symbol also changes shape, filled to
outline, so the state survives Differentiate Without Color. Those four controls
are the only places the app asks this palette for a colour.

Warnings are the **one declared exception** to "Never mix `state` and `action`"
above, and the app's panel is where it shows: the advisory lines sit beside the
`state`-tinted pickers.

Warnings pin no hex. They take SwiftUI's semantic `.orange`, so the system keeps
control of how that colour adapts to the appearance and to Increase Contrast.
That is the same pigment as `action`. The exception is narrow and deliberate:
`warning` means attention, and `.orange` is the colour macOS users already read
that way. The rule still holds where it can be enforced — the app's `ColorRole`
has no `action` case, so no caller can name the role. The web-only clause covers
the role, not this one system pigment. As caption text on a light backdrop
`.orange` falls below 4.5:1; that gap is open as issue #30.

**The decision, 2026-08-04.** The accent moved off `#76B900`. That green is
NVIDIA's brand colour and this is a personal Apache-2.0 product, so it can read
as corporate endorsement — and coffee is not green.

> **The art landed, 2026-08-05.** Of the 62 rasters under
> `assets/art/**`, `recut.sh` re-cuts 34 from the vector sources: the `default`
> and `dark` appicon renders, the iconset, all of `web/` and both repo avatars.
> `remap.py` recolours the 6 that have no vector source — the four wordmarks
> and the two composite `github/` images — by rotating the retired hue and
> keeping each pixel's saturation, value and alpha. Authoring real vector
> sources for those six is still open. The other 22 rasters carry no accent at
> all — the 15 menu-bar templates and the 7 greyscale `mono` appicon renders.
> `census.py` opens every raster. It fails on any pixel that is exactly
> `#76B900`, and on any pixel in the green hue band 70–100° **above** the
> floors `s > 0.25` and `v > 0.20`. Below those floors it does not look.

**What the guard cannot see.** The two floors exist so that near-neutral pixels
— dark ink, pale paper — are not read as green. `remap.py` tests the same
predicate, so it recoloured exactly what `census.py` can report and skipped
exactly what `census.py` cannot. Zero exact `#76B900` pixels remain anywhere. A
wider sweep — hue 55–145°, `s > 0.10`, `v > 0.10` — finds 708 pixels of
anti-aliasing residue in four files, measured 2026-08-05:

| file | residual px | canvas px |
|---|---|---|
| `wordmark/coffee-bar-wordmark-dark-2x.png` | 341 | 864,000 |
| `github/readme-header-1600x400.png` | 187 | 640,000 |
| `wordmark/coffee-bar-wordmark-light-2x.png` | 131 | 864,000 |
| `github/social-preview-1280x640.png` | 49 | 819,200 |

These are edge blends of the retired accent, not the accent. For example
`#1E2E00` is `#76B900` at a quarter of its brightness, so `v` = 0.180 and the
`v` floor excludes it; `#D3E3B3` is `#76B900` blended 75 % toward the
dark-appearance ink `#F2F1EE`, so `s` = 0.211 and the `s` floor excludes it.
Both 1x wordmarks are clean, so the residue in the two `-2x` wordmarks is a
sub-pixel hairline at 1x. Real vector sources for these six files remove it.
That work is still open, as above.

The menu-bar glyph has no colour at all — it is alpha only.

> **Filenames:** the export pipeline strips `@` from filenames, so `@2x`/`@3x`
> assets arrive as `-2x`/`-3x`.
>
> **Only for a fresh art delivery unzipped over the tree:** run
> `menubar/fix-names.sh` and `appicon/make-icns.sh` once to restore the names.
>
> Do **not** run them on a normal checkout. `make-icns.sh` renames the five
> `-2x` files to `@2x` inside the tracked `AppIcon.iconset` and writes an
> untracked `AppIcon.icns` beside it, so it dirties tracked art. A later
> `recut.sh` writes the five `-2x` names back beside the five stale `@2x`
> names, which leaves 67 PNGs under `assets/art/**` against the
> `EXPECTED_TOTAL = 62` that `census.py` asserts — the guard then fails.
>
> A normal build needs neither script. Since the app-icon commit,
> `scripts/build-app.sh` builds the bundle's `.icns` itself: it copies the
> iconset to a temporary directory and renames the copy, so the tracked files
> stay clean.

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
- `AppIcon.iconset/` + `make-icns.sh` → `AppIcon.icns` via `iconutil`. Run
  `make-icns.sh` only on a fresh delivery: it renames the tracked `-2x` files in
  place, and the census then fails after the next `recut.sh` — see **Filenames**
  above. `scripts/build-app.sh` builds the app's `.icns` from a copy of this
  iconset, so a normal build runs nothing here.

## web/
`favicon.svg` (monochrome, `prefers-color-scheme` aware), `favicon-16/32/48.png`,
`apple-touch-icon-180.png`, `icon-192/512.png`, `icon-512-maskable.png`,
`site.webmanifest`, `head-snippet.html` (paste into `<head>`).

The web rasters shipped in `site/` are cut from `site/appicon-web.svg`, which is
the same geometry as the app icon on the **web tile** `#F2F0EB` rather than the
appicon base `#EFEDE7`. `icon-512-maskable.png` insets that art by 0.72 about
the canvas centre for the platform safe zone.

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
