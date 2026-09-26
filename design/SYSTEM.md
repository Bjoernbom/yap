# bjornbom design system

The visual system behind yap, written so the next small Mac app can use it as
is. yap is the reference implementation: `App/Sources/Brand/` for code,
`site/index.html` for the web.

The feel: made by one person who cares about craft. Calm, black and white,
precise. Pixels for personality, native UI for everything you act on.

## Colour

Black and white, plus one quiet accent. Colour means something or it isn't
there.

| Token | Hex | Job |
| --- | --- | --- |
| `notch` | `#000000` | The hardware-black surface: notch, icon tile, dark cards |
| `ink` | `#FFFFFF` | Text and marks on `notch` (`#F5F5F7` on the web) |
| `bone` | `#D9D4C7` | The accent. The app is doing its one thing (yap: listening) |
| `bone-dim` | `#67655F` | A quiet or idle mark: `bone` at 45 % on black |
| `stone` | `#787060` | `bone` on a light surface, where `bone` vanishes: focus rings, strokes |
| `blood` | `#FF453A` | Recording, and nothing else |

Rules:

- One accent per app, and `bone` is it. Don't add a second hue for variety.
- `bone` is for marks (dots, bars, strokes, a `$` prompt), never a large fill.
  The one exception is a small button on black.
- On light surfaces use `stone`; on dark surfaces use `bone`.
- Grey states come from `ink` at lower opacity, not new colours: yap's
  "working" shimmer is `ink` at 22 % to 100 %.
- Everything else is the platform: SwiftUI `.primary` and `.secondary`,
  system backgrounds, system controls.

## Type

- **Pixelify Sans** (OFL, bundled) for brand moments only: the wordmark,
  timers, big numbers. Never for a sentence.
- **SF Pro** for all functional UI; **SF Mono** for commands and paths.
- Names are lowercase: yap, bjornbom.

## Pixels

- The signature is a mark made of square dots: 4 px dots on a 6 px pitch on
  the web; on screen, dots land on whole points.
- Heights are odd so rows line up around a centre row.
- Pixel art is drawn on the target pixel grid and sampled nearest-neighbour.
  Never scale it smoothly. See `design/icon/README.md` for the icon grids.

## Icons

- A black tile with the app's pixel mark in `bone`, a dim `bone-dim` dot where
  something is quiet. No gradients, no mascot, no letters.
- Must read at 16 pt: reduce to two or three solid bars there.
- Generated from source (`design/icon/generate.py`), never drawn by hand.
- Menu bar: a template image (the pixel wordmark), so macOS tints it.

## Motion

- Things grow out of where they live (yap's notch grows out of the hardware
  notch): spring, about 200 ms. They shrink back the same way.
- Motion shows state, never decoration. Reduced motion means static.
- A soft tick on start and stop, with a setting to turn it off.

## Voice

- Short. Lowercase for brand moments (headlines, the notch, README), sentence
  case for anything you act on (settings, errors, permissions).
- Say what happened and what to do, in one line. No apologies, no exclamation
  marks.
- Humour is seasoning: one small wink per screen at most.
- About and README footer: "<app> is made by bjornbom. Open source, MIT."

## Web and README

- One static page per app, no build step, no trackers. Light and dark, 16 px
  gutters down to 320 px.
- README: icon, pixel wordmark (light and dark), tagline, one first-person
  line on why the app exists, a demo GIF, then install.
- Demo GIFs are real frames from the app, scaled 2x nearest-neighbour.
