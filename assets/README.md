# Brand assets

The mark is **Zeus's thunderbolt** — a winged bolt. The wordmark is **memXT**.

| Asset | Use it when |
|--|--|
| [`logo.svg`](./logo.svg) | **Default.** Transparent background, horizontal lockup. The wordmark adapts to light/dark via `prefers-color-scheme`. |
| [`logo-dark.svg`](./logo-dark.svg) | You need a self-contained dark card — slide decks, social previews, light-only surfaces. |
| [`logo-mark.svg`](./logo-mark.svg) | Icon only. Favicons, avatars, square crops. |
| [`logo-3d.html`](./logo-3d.html) | A three.js build of the logo — extruded, lit, drag to orbit. Open it in a browser (loads three.js from CDN). |
| [`demo.gif`](./demo.gif) | The terminal demo. Regenerate with `vhs docs/launch/demo.tape`. |

## Colors

| Token | Hex |
|--|--|
| Bolt (gradient) | `#FCD34D` → `#F59E0B` |
| Wings | `#F59E0B` |
| Accent (`XT`) | `#22D3EE` |
| Ink (light bg) | `#0F172A` |
| Ink (dark bg) | `#F8FAFC` |
| Badge | `#0B0B14` |

## Typography

**SF Pro, weight 800.** The wordmark is stored as **vector outlines**, not live text — so it renders
identically on every OS and in the 3D build. Don't retype it in a font; reuse the paths.

Regenerate the SVGs (and re-extract outlines) with the script in the commit that introduced them.
