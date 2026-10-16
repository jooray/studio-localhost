---
name: Localhost Recording Studio
description: A matte black catalogue sleeve where every song is a numbered entry whose face is a polar plot of its own waveform.
colors:
  ground: "#0A0A0B"
  ink: "#F2F2F0"
  ink-soft: "#BEBEBB"
  ink-mute: "#8E8E8B"
  rule: "#BDBDBA"
  rule-faint: "#3B3B3B"
  grid: "#6B6B6B"
  signal-red: "#C8553D"
  code-grey: "#7D7D7F"
  code-blue: "#3F6E8C"
  code-gold: "#D8A461"
  code-red: "#C8553D"
  code-white: "#F2F2F0"
typography:
  display:
    fontFamily: "Geist, sans-serif"
    fontSize: "64px"
    fontWeight: 300
    lineHeight: 1
    letterSpacing: "-0.02em"
  status:
    fontFamily: "GeistMono, monospace"
    fontSize: "26.5px"
    fontWeight: 300
    lineHeight: 1
    letterSpacing: "-0.3px"
  index:
    fontFamily: "GeistMono, monospace"
    fontSize: "30px"
    fontWeight: 300
    lineHeight: 1
    letterSpacing: "normal"
  label:
    fontFamily: "GeistMono, monospace"
    fontSize: "24.5px"
    fontWeight: 300
    lineHeight: 1
    letterSpacing: "normal"
  body:
    fontFamily: "Geist, sans-serif"
    fontSize: "22.5px"
    fontWeight: 300
    lineHeight: 1.156
    letterSpacing: "-0.15px"
  value:
    fontFamily: "GeistMono, monospace"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.3
    letterSpacing: "0.04em"
  etched:
    fontFamily: "GeistMono, monospace"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.2
    letterSpacing: "0.16em"
  etched-action:
    fontFamily: "GeistMono, monospace"
    fontSize: "15px"
    fontWeight: 500
    lineHeight: 1.2
    letterSpacing: "0.16em"
rounded:
  none: "0px"
spacing:
  hairline: "1px"
  gutter-phone: "25px"
  text-inset-phone: "55px"
  gutter-wide: "32px"
  target-min: "48px"
  action-band: "56px"
  index-entry: "60px"
  page-header: "64px"
  header-band: "124px"
  index-column: "232px"
  index-column-wide: "300px"
components:
  cell:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink}"
    rounded: "{rounded.none}"
    height: "{spacing.target-min}"
  cell-selected:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink}"
    rounded: "{rounded.none}"
  cell-active:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.signal-red}"
    rounded: "{rounded.none}"
  record-cell:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink}"
    typography: "{typography.etched-action}"
    rounded: "{rounded.none}"
    padding: "0 8px 0 18px"
    height: "{spacing.action-band}"
  record-cell-disabled:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink-mute}"
    typography: "{typography.etched-action}"
  status-line:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink}"
    typography: "{typography.status}"
    height: "48px"
  index-bar-cell:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink}"
    typography: "{typography.index}"
    rounded: "{rounded.none}"
    height: "52px"
  index-entry:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink}"
    typography: "{typography.value}"
    padding: "0 24px"
    height: "{spacing.index-entry}"
  code-strip:
    height: "41px"
  code-strip-mini:
    width: "64px"
    height: "7px"
  settings-sheet:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink}"
    rounded: "{rounded.none}"
    padding: "0 25px 8px"
    width: "720px"
  choice-cell:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink-mute}"
    typography: "{typography.etched}"
    width: "82px"
    height: "{spacing.target-min}"
  choice-cell-selected:
    textColor: "{colors.ink}"
  setup-primary:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink}"
    typography: "{typography.etched-action}"
    padding: "0 0 0 18px"
    height: "56px"
---

# Design System: Localhost Recording Studio

Recorded from the shipped build, version 0.4.3 (commit ba82712), on the Catalogue Sleeve direction (seed 3fa1913f). Source of truth: `lib/ui/theme.dart` (`Sleeve`, `SleeveType`), `lib/ui/widgets/sleeve.dart`, `lib/ui/widgets/polar_plot.dart`, `lib/ui/frame.dart`, `lib/ui/screens/*`, `lib/state/take.dart`.

## Overview

**Creative North Star: "The Catalogue Sleeve"**

The studio is a record catalogue printed on a matte black sleeve. Each song is a numbered entry (LRS-001 and on). Its face is a polar pulse plot of its own waveform, and it carries a five-block colour code derived from its seed. The interface is set like a post-punk catalogue back cover: white hairline rules divide the page into bands, engraved mono capitals name things, and a plain light grotesk carries the words people write. There are no cards, no chrome and no Material furniture. Every control is a hairline-framed cell, or a cell with its frame switched off.

The page is calm and flat, and the eye goes to two things. One is the plot, which shows the take as a white burst inside a radial hairline grid. The other is a single red mark: the entry being recorded now, or the armed end of the Record cell. Everything else stays white on black at three ink strengths. Density changes with window size, but the world doesn't. The phone follows the approved comp exactly, measured in comp pixels and scaled by one unit `u`. Wide windows set the same parts side by side, with the catalogue index as a left column.

**Key Characteristics:**
- Matte black ground, ink in three strengths, hairline rules at 1 px, square corners everywhere except the round plot.
- Two faces only: Geist (light, for the words people write and display numerals) and Geist Mono (light to medium, for everything engraved, numbered or measured).
- One red, reserved for what is live now.
- Each song's colour code strip is the only place that uses colour as decoration, and it is data.
- Motion is one grammar. Things step in with an exponential ease-out and nothing bounces. Reduce-motion makes everything static.

## Colors

A monochrome sleeve with one signal red and a five-colour code that belongs to the songs, not to the interface.

### Primary
- **Signal Red** (signal-red): marks the one active entry: the running entry's number, frame and REC tag in the index column, index bar, catalogue row and song display numeral. It also fills the 30 px end block of an armed primary action (Record, setup Install/Continue) and the small square fault mark in an error line. On the active cell, the 2 px focus frame is red as well. Text selection uses it at 40% alpha (`#66C8553D`) with a solid red handle.

### Neutral
- **Matte Ground** (ground): every surface. Pages, sheets, dialogs, snackbars and tooltips all sit on the same black. The theme defines a raised tone one step lighter (`#111112`), but no shipped surface paints it.
- **Sleeve Ink** (ink): primary text, the plot burst, the progress arc, the hub dot, selected-cell frames, the focus frame, and determinate progress fills.
- **Soft Ink** (ink-soft): secondary engraved text: settings summaries, header glyphs, notes, and catalogue style lines.
- **Muted Ink** (ink-mute): field keys, disabled text, hints, queued and stopped entries, and the plot's outer ring (5.9:1 on ground).
- **Rule White** (rule): the hairline frames and band rules.
- **Faint Rule** (rule-faint): dividers inside lists and sheets, the progress track, and empty index slots (`···`).
- **Plot Grid** (grid): the plot's inner rings and spokes, and the extend screen's grid.

### Tertiary: the colour code
- **Code Grey, Code Blue, Code Gold, Code Red, Code White** (code-grey, code-blue, code-gold, code-red, code-white): the five-block strip for each song, weighted by its seed. Blocks sit edge to edge with no gaps and no borders. These colours appear only inside a code strip. Code Red shares Signal Red's value, and inside the strip it means nothing more than its block.

### Named Rules
**The One Red Rule.** Outside the code strip, red means "live now": the entry being recorded, the armed end of the primary action, or a fault mark. It is never a decoration, a hover state or a category colour. Failed and stopped entries go to muted ink.

**The Code Is Data Rule.** The colour code is derived from the song's seed and drawn only as a strip. Never take a code colour for chrome, text or state.

## Typography

**Display Font:** Geist (bundled weights 300, 400, 500)
**Body Font:** Geist, light
**Label/Mono Font:** Geist Mono (bundled weights 300, 400, 500)

**Character:** The mono is the engraving. It carries capitals, numbers, durations and data in light-to-regular weights, tracked wide when small. Geist light is the handwriting. It carries only what the user wrote: style text, lyrics, titles.

Sizes are comp pixels at a 576 px wide comp and are multiplied by the scale unit `u` (see Layout). Etched and value styles clamp to an **11 px floor** after scaling (`SleeveType.floor`). The other roles stay above 11 px at the smallest `u` the build allows.

### Hierarchy
- **Display** (Geist 300, 64 px, line-height 1, tracking −0.02em): the catalogue number at the head of the song page. The only display use.
- **Status** (Geist Mono 300, 26.5 px, line-height 1, tracking −0.3 px): the engraved status line, e.g. `RECORDING · LRS-015 · 2:14 / 4:00`. Word spaces render at 42% of a mono cell, so the line reads engraved rather than typed.
- **Index** (Geist Mono 300, 30 px, line-height 1): short catalogue numerals in the index bar (`012 013 014 015`).
- **Label** (Geist Mono 300, 24.5 px, line-height 1): the field names STYLE and LYRICS, in capitals at body size.
- **Body** (Geist 300, 22.5 px, line-height 26 px, tracking −0.15 px): style and lyrics, including the section tags `[VERSE]`. Smaller variants are derived from it: queue titles (15u + 2 px), catalogue style lines (15 px), and setup titles (18 px at weight 400).
- **Value** (Geist Mono 400, 15 px by default, line-height 1.3, tracking 0.04em): catalogue numbers in lists, data values, seeds, paths and log lines. Lists use 12 to 16 px.
- **Etched** (Geist Mono 400, 13 px by default, line-height 1.2, tracking 0.16em, always uppercase): every small engraved label: page titles, field keys, cell text, durations, REC/QUEUED tags and snackbars. It is used at 11 to 13 px.
- **Etched action** (Geist Mono 500, 15 px, tracking 0.16em, uppercase): the primary-action label (`RECORD LRS-016`, `QUEUE LRS-016`, setup Install/Continue). This is the only weight-500 use.

### Named Rules
**The Eleven Floor Rule.** Nothing set in this world drops below 11 logical px, at any scale.

**The Two Hands Rule.** The mono engraves (labels, numbers, measurements, actions) and Geist light writes (the user's words). Never set user-written text in mono or a label in Geist.

## Layout

**Comp unit.** The phone layout comes straight from the approved comp (576 px wide). Every measurement is in comp px multiplied by `u = width / 576`, clamped to 0.55–1.25 on the studio and 0.62–1.0 on secondary pages. Below 600 px the comp has authority: plot box 396u at (90u, 35u) inside a 465u band, a 25u gutter, text inset 55u, the status line pinned between two indented rules in a 48u band, the style block in 115u, then a rule and lyrics. At the bottom sit the 41u code strip, the index bar (max(52u, 48)) and the Record row (max(54u, 48)) joined underneath it. The bottom stack hides while the keyboard is open.

**Wide windows put the parts side by side** (approved by the user).
- **600 px and up:** the catalogue index becomes a left column (232 px, or 300 px from 840 px) behind a vertical hairline. The page sits beside it.
- **Two columns** when the content width is at least 760 px. The plot (flex 11) sits on the left. Style, lyrics and queue (flex 10) sit on the right. Underneath, one band of max(56u, 48) holds the status line and the Record row split on the same 11:10 line, followed by the code strip. Here `u = min(contentW/1240, h/860)`, clamped to 0.62–1.0, with a 32u gutter.
- **One column** below that: a header band, the plot (340u), the status band, style, lyrics, queue, strip and Record, with `u = contentW/640` clamped to 0.6–1.0.

**Shared rule positions.** On every wide studio layout, the first cross-column rule sits 124 px down (the header band). The index column header matches it, so the rules run straight across the vertical hairline. Secondary pages use a 64 px page header (back glyph, etched title, actions, rule) on both sides. Index entries are 60 px tall with 24 px side padding. Settings content caps at 820 px. Setup and the record sheet cap at 720 px.

**The Shared Rule Rule.** A horizontal rule that crosses the index column and the page must sit at the same height on both sides: 124 px on the studio, 64 px on secondary pages.

**The Comp Authority Rule.** Below 600 px, a layout question goes to the comp, expressed in comp px times `u`, and is never invented afresh.

## Elevation & Depth

The sleeve is completely flat. Every theme elevation is 0 and no shadow exists anywhere. Depth comes from hairlines and bands. A modal sheet sits on the same ground with a single top hairline. The barrier behind it is black at 70% (`#B3000000`). Dialogs, snackbars and tooltips are ground-coloured boxes with a 1 px rule frame. Interaction shows up as fill, never as lift: hover adds 5% white (`#0DFFFFFF`), press adds 10% (`#1AFFFFFF`), and keyboard focus draws a 2 px ink frame (red on the active cell).

**The Printed Sleeve Rule.** Nothing floats. If something needs separating, give it a rule or a band, never a shadow, a glow or a lighter card.

## Shapes

Every rectangle has square corners (radius 0), including the scrollbar thumb (2 px wide, unrounded). Frames are 1 px hairlines. A run of adjacent cells shares its rules: the index bar draws only the dividers it needs, and the Record row joins the bottom rule of the index bar. The circle belongs to the plot, which is native to this world: concentric rings, spokes and a spindle hole. The catalogue glyph and the app icon repeat it. Glyphs are drawn in-house on a 24-unit grid with one 1.25 px stroke and square caps. Play and pause are the only filled glyphs. Fault marks are solid red squares (10u in lines, 8 px in snackbars).

## Components

### Cell (the one control shape)
A hairline-framed rectangle that holds text or a glyph. Frame states: rest uses Rule White, selected uses Sleeve Ink, active uses Signal Red. The frame can also be turned off, or drawn on chosen sides only. The minimum target is 48 px. Hover and press use the fills described under Elevation. Focus is a 2 px frame. A tap gives a selection-click haptic. Glyph buttons are frameless cells, max(48, glyph + 20) px square.

### Record cell (primary action)
An etched-action label (`RECORD LRS-016`, `RECORD LRS-016 +2` for variants, `QUEUE …` while busy) set 18u in from the left. **Armed** (there is something to record and nothing is running): a 30 px Signal Red block fills the right end. **Busy:** the block disappears and the label reads QUEUE. **Empty form:** the label drops to muted ink and the block disappears. Beside it, a cell shows the settings summary (`32 STEPS · 4:00`, etched 11 px, soft ink) and opens the settings sheet. On phones an ALL cell (catalogue glyph + ALL) closes the row. The setup screen reuses the same armed cell at 56 px.

### Status line
One engraved line between hairline rules, in the status style. Its words come from the take state: `RECORDING · LRS-015 · 2:14 / 4:00`, `PLAYING`/`PAUSED`, `QUEUED · LRS-016`, `FAILED`/`STOPPED · LRS-014` (shown with a red fault square and a Retry action), and `NO RECORDINGS YET`. A play or pause glyph sits at the right end. When the engine stops, the whole line becomes an error line (`ENGINE STOPPED` + a Setup cell). On phones the text is inset 30u and the band stays pinned while lyrics scroll.

### Polar plot (signature)
The face of each song. On the full plot: 16 evenly spaced rings and 24 spokes (every 15°) in Plot Grid, with the outer ring in Muted Ink. The waveform is a solid ink burst around a hole of 0.30r. RMS gives the body, peaks push needles outward, and hard hits bite the inner edge into the hole. 360° is the whole song, running clockwise from the top. A 2.2 px ink spindle dot marks the centre. Progress is an ink arc on the outer ring, max(2, 0.85% of size) px wide with butt caps. Before audio exists, seeded needles appear clockwise as tokens arrive. While recording, the burst breathes ±1.2% on a 3.2 s cycle and a faint scan line runs inward from the head of the arc. An extend section shows as a thick ink arc with two radial bounds. The plot is tappable and draggable for seeking. The mini plot (76 px catalogue rows) has 6 rings, 12 spokes and 0.75 px lines.

### Code strip
Five flush blocks from the code palette, weighted by the song's seed. Sizes: 41u under the phone comp, 34u on wide screens, and a 64 × 7 px swatch (56 × 7 in catalogue rows) beside a number. When the current seed changes, the strip fades in and grows from the left.

### Index bar (phone) and index column (wide)
**Bar:** the last four short numerals in index style, inside cells that share their rules. The current entry is framed in ink, and the running entry is framed and set in red. Empty slots show `···` in Faint Rule and queued entries use muted ink. New numerals fade in and slide from 25% to the right. **Column:** a header with the catalogue glyph, etched INDEX, a menu glyph, and (in the 124 px studio band) an etched line `4 ENTRIES · NEXT LRS-016`. Then a rule and 60 px entries: the full number (value 15 px), a 64 × 7 code swatch, and a right-aligned duration, REC, QUEUED or STOPPED tag (etched 12). The running entry is red-framed. The selected entry is ink-framed.

### Catalogue row
A frameless cell (red frame only while running) holding a mini plot, the number with its code swatch, a soft-ink style line, an etched status, and a play glyph.

### Settings sheet (record sheet)
A modal bottom sheet, capped at 720 px wide and 86% of the window height. It is scaled with `u` clamped to 0.7–1.0 and has 25u gutters. The header reads etched RECORDING (muted) with a close glyph, then a rule. The rows scroll. Each row has an etched muted key in a 120u column, values on the right, and a Faint Rule beneath. Choices are cells 74u + 8 wide and 48 px tall: unselected ones are frameless in muted ink, and the selected one gets an ink frame and ink text. Seed and length use value 16 px. A footer holds a Studio settings link and a framed DONE cell.

### Setup
A single column capped at 720 px. At the top: the app icon at 52 px and the etched app name. Below that, key/value rows (etched 11 px keys in a 96u or 130 px column, value 15 px), Geist titles at 18 px/400, and soft-ink notes at 14 px. Progress is a Faint Rule track with a 3 px ink fill. Indeterminate progress is a 1 px linear indicator. The primary action is the armed cell, with a muted line underneath until the licence is accepted. A 220 px log uses value 11 px.

### Inputs
A field has no box and no underline. The surrounding hairlines are its frame. The text style comes from its role (body for style and lyrics, value for seeds and URLs), hints use muted ink, and the cursor is a 1.5 px ink bar.

### Feedback
Error lines and snackbars are etched uppercase on ground, inside a hairline frame, with a red fault square on errors. Snackbars float and stay 3 s (6 s for errors). Tooltips are etched 11 px mono in a ruled box after a 600 ms wait.

### Motion
There is one grammar: **step** (260 ms) on the exponential ease-out `cubic-bezier(0.16, 1, 0.3, 1)`. Pages fade and rise 2.5% (reversing with ease-in). Index numerals and the code strip step in by the same rule. The progress arc glides between reports over 900 ms on the same ease. The recording breath runs 3.2 s per cycle. When the platform asks for reduced motion, page transitions return the child unchanged, switchers and the arc go to zero duration, and the breath stops at rest.

## Do's and Don'ts

### Do:
- **Do** build every control from the hairline cell (1 px, radius 0, 48 px minimum target) and change only its frame colour for state: rule at rest, ink when selected, red when live.
- **Do** measure phone layouts in comp px times `u` and defer to the comp below 600 px.
- **Do** keep the 124 px studio header band and the 64 px page header so rules line up across the index column.
- **Do** set user-written words in Geist 300 and everything engraved in Geist Mono with 0.16em tracking, uppercase, never below 11 px.
- **Do** step things in at 260 ms on `cubic-bezier(0.16, 1, 0.3, 1)` and honour reduce-motion by rendering the final state.
- **Do** draw new glyphs on the 24-unit grid with a 1.25 px square-capped stroke.

### Don't:
- **Don't** use red for anything except the live entry, the armed primary block and fault marks. Failed or stopped states use muted ink.
- **Don't** use code-strip colours outside a code strip.
- **Don't** round a rectangle, add a shadow or glow, or lift a surface to a lighter card. The plot's circle is the only curve.
- **Don't** use gradients.
- **Don't** add stock Material components (filled buttons, chips, outlined text fields, FABs, ripples). The theme turns splash and highlight off.
