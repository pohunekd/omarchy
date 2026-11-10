# DESIGN.md: Engraved tiling

The visual system of omarchy.pohunek.dev. It fuses two systems without skinning
one as the other: **Omarchy owns structure and theme**, **pohunek owns material
and voice**. `src/styles/tokens.css`, `src/styles/site.css` and
`src/config/themes.ts` are the implementation; when this file and the code
disagree, the code wins and this file is updated.

## Concept

The page is a Hyprland workspace. Every section is a tile.

| Owned by Omarchy | Owned by pohunek |
|---|---|
| Geometry: rounding 0, 2px border, 5px gaps between tiles, 10px outer gap, a top bar | Material: parchment sheets, engravings, CRT terminal voids |
| Colour that follows the user: tile borders, title bars, the bar, terminal tiles, focus ring (six themes from `colors.toml`) | Constant colour: paper, ink, leather, phosphor, amber |
| JetBrains Mono for the bar, window titles, terminals and labels | Domine for display headlines and Karla for body inside parchment tiles |
| Workspaces, keycaps (`<kbd>`), window titles | Section signs, corner brackets, figure captions, "needs you" amber |

Where they meet, each tile is a window (Omarchy) holding a sheet or a terminal
(pohunek). Split tiles stack a terminal void over a parchment label plate.

## Layers

1. **Constant pohunek layer** (`tokens.css`): the light values of
   pohunek.dev's tokens. Parchment tiles are cream in every theme, like a sheet
   pinned on the desktop.
2. **Switchable Omarchy layer** (generated from `themes.ts`): `--wall` (tile
   gaps), `--bg`, `--bg-raised`, `--fg`, `--fg-muted`, `--accent`, `--ok`,
   `--bad`, `--hl`, `--needs`. A theme's own palette is used as is when it
   reaches WCAG AA; otherwise the colour keeps its hue and is darkened (or
   lightened) just enough. `tests/themes.test.ts` checks every role against
   every surface it can sit on, for every shipped theme.

Themes: tokyo-night (default dark), gruvbox, everforest, catppuccin,
rose-pine (light) and flexoki-light (default light). The bar picker is a
radio group (arrow keys), persists to `localStorage` and defaults to
`prefers-color-scheme`; without JS the same default applies through CSS.

## Bridge rule

The "needs you" signal is always pohunek amber, working is the theme green and a
problem is the theme red, exactly like the cursor of the pohunek bar icon. On a
light surface amber text falls back to a darker amber that reaches AA.

## Tiles

- 2px border, `--border-idle` when idle and `--accent` when focused (hover or
  keyboard focus; with JS the focus stays on the last tile the pointer entered,
  like focus-follows-mouse).
- A title bar in the border colour carries the window title, for example
  `pohunek - list`, and turns accent-filled on focus.
- Parchment tiles carry four engraving corner brackets; terminal tiles do not.
- No blur, shadows or gradients.

## Layout

- Desktop (64rem and up): 12-column grid, 5px gaps, 10px outer gap. The hero is
  a master/stack: the master tile on the left, the demo and bar-state tiles in
  the stack. The tour is a 3x2 grid, keys are three tiles.
- Tablet: two columns for the tour and keys.
- Mobile: one column of tiles with 10px gaps, a vertical workspace.

## Motion

Tiles slide in on scroll (transform and opacity only, 180ms), the focus border
follows the pointer, the install command is typed once when its line is wide
enough to stay on one row, and the amber cursor blinks. Everything is off under
`prefers-reduced-motion` (the demo GIF is replaced by its first frame). All
content is in the HTML; JS only adds the picker, the workspace indicator, the
clock, copy buttons and the effects above.

## Content rules

Copy comes from `README.md`, `docs/`, `CHANGELOG.md` and `manifest.json`; the
version shown is read from `manifest.json` at build time. Screenshots are the
repository's own (`docs/`, synthetic sessions from `tools/demo-pohunek`),
copied into `src/generated/` by `scripts/sync-assets.ts`. No third-party
request is made at runtime; `scripts/check-dist.ts` fails the build otherwise.

## Trademark

"for Omarchy" is used nominatively. No Omarchy or Basecamp logo or wordmark
font, no copy of omarchy.org's layout, no claim of being official. The footer
reads: "Not affiliated with Omarchy or Basecamp. Omarchy is a project by
Basecamp/DHH."
