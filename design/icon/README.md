# App icon

The yap icon is the notch's pixel waveform: lime dots on black, mirrored
around a middle bar, with a dim "quiet" dot at each end, the way a silent bar
looks in the notch. At 16 pt it becomes three solid lime bars.

Everything here is generated. Don't edit the PNGs by hand.

```bash
python3 design/icon/generate.py            # App/Resources/Assets.xcassets
python3 design/icon/generate.py --sheet    # also concepts.png
python3 design/icon/generate.py --final path/to/yap.app   # final-*.png
python3 design/icon/generate.py --measure  # re-measure kernel.json
```

Needs Pillow, Xcode (`actool`) and `swift`. `--sheet` and `--final` render
through IconServices (`render-icon.swift`), so the renders include the
macOS 26 mask, scaling and rim light, exactly as Finder and System Settings
show them.

## Concepts

`concepts.png` shows four concepts at 1024, 128, 32 and 16, plus 32 pt and
16 pt @2x zoomed, on light and dark.

| Concept | Verdict |
| --- | --- |
| **y + cursor**: pixel "y" and a lime text cursor | Good idea ("talk. it types."), but at 16 pt it reads as "yl". The big white letter fights the lime. |
| **pixel waveform** (shipped) | The signature element from the notch, so the icon means "the thing in my notch". Recognisable at every size, calm, not cute. |
| **notch on lime**: black notch hanging off a lime tile | Loud and recognisable in the Dock, but the notch plus dots reads as a face (too cute). It also spends lime as a surface, while the brand keeps lime for "listening". |
| **0.4 wordmark**: the old icon, pixel-snapped | Most literal link to 0.4, but three glyphs don't fit 16 pt. In the Accessibility list it's a grey smudge. |

## Why the waveform

- **16 pt legibility.** Three lime bars on black survive at 16 pt. Letters
  don't.
- **Recognisable.** A lime-on-black mark stands out in the Dock and in the
  Accessibility list, where most icons are colourful and glossy. It's also
  the same thing you see in the notch while you talk.
- **On brand.** Black, pixels, one accent, and lime used only for its job:
  the waveform means listening.
- **Not too cute.** No face, no mascot, no joke. It reads like a tool.

The menu bar keeps the pixel "yap" wordmark (`MenuBarIcon.swift`). It is a
template image and doesn't clash: the word in the menu bar, the waveform
everywhere else.

## Sharp at small sizes

macOS 26 doesn't draw an AppIcon image 1:1. It scales every full-bleed square
into the rounded body and masks it:

| Image | Shown as | Body |
| --- | --- | --- |
| 16 px | 16 pt @1x | 14 px at offset 1 |
| 32 px | 16 pt @2x (Accessibility list, Finder lists) | 28 px at offset 2 |
| 64 px | 32 pt @2x | 52 px at offset 6 |
| 128 px | 64 pt @2x, 128 pt @1x | 104 px at offset 12 |
| 1024 px | 512 pt @2x | 824 px at offset 100 |

So 8 image pixels become 7 screen pixels at 16 pt, and pixel art drawn on the
image grid comes out soft. `--measure` renders combs of lime columns through
IconServices and stores the resampling kernel in `kernel.json` (near-bilinear,
in gamma space). The kernel shows that at 16 pt @2x only edges at body pixels
6–8, 13–15 and 20–22 stay sharp, and the same pattern repeats every 7 px.
Dots with 1 px gaps can't be sharp there, whatever the image holds.

So:

- **16 pt @2x** gets its own 28 px grid: three 2 px bars with every edge on a
  sharp line. It is point-sampled, and the render matches the target to within
  0.3 % on average. The only soft pixels are the tips of the middle bar.
- **16 pt @1x** gets a 14 px grid on the same idea. At 1x only the middle bar
  can be fully sharp.
- **32 pt @2x and up** use the 26-cell master (2 px per cell at 52, 4 at
  104). For the 64 and 128 px images the generator solves for the image that
  comes closest to the target after resampling (bounded least squares against
  the measured kernel), which roughly halves the soft pixels.
- **256 px and up** are point-sampled. A half-pixel edge doesn't show there.

Verified renders from a built `yap.app`: `final-16.png`, `final-16@2x.png`,
`final-32.png`, `final-32@2x.png`, `final-128.png`, `final-512.png` (and the
other `@2x` files).

## Follow-up: Icon Composer

The icon ships as a classic `AppIcon` asset catalog, which macOS 26 wraps in
its rounded shape and rim light. The native format is an Icon Composer
`.icon` (layers, Liquid Glass, dark and tinted variants). It needs the Icon
Composer app to author well, so it isn't done yet. When it is: the dots as
one layer, the black as the background, and a hand-tuned 16 pt. Check that
the Icon Composer renderer keeps the 16 pt bars on the sharp lines above.
