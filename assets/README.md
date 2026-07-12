# Brand assets

The mark is **Zeus's thunderbolt** — a winged bolt. The wordmark is **memXT**.

| Asset | Use it when |
|--|--|
| [`logo.svg`](./logo.svg) | **Default.** Transparent background, horizontal lockup. The wordmark adapts to light/dark via `prefers-color-scheme`. |
| [`logo-dark.svg`](./logo-dark.svg) | You need a self-contained dark card — slide decks, social previews, light-only surfaces. |
| [`logo-mark.svg`](./logo-mark.svg) | Icon only. Favicons, avatars, square crops. |
| [`logo-3d.html`](./logo-3d.html) | A three.js build of the logo — extruded, lit, drag to orbit. Live at **[yupcha.github.io/memxt/assets/logo-3d.html](https://yupcha.github.io/memxt/assets/logo-3d.html)**. Append `?p=0.25` to freeze a pose (0–1 around the loop) — that's how the GIF frames are captured. |
| [`logo-3d.gif`](./logo-3d.gif) | The 3D logo as a seamless loop, for the README (GitHub can't run WebGL). Regenerate: capture `?p=i/N` frames headlessly, then `ffmpeg … palettegen/paletteuse=dither=none` + `gifsicle -O3 --lossy`. Skip the dither — it's noise, and it doubles the file size. |
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
