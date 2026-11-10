/**
 * The switchable Omarchy layer. Raw values are copied from basecamp/omarchy
 * `themes/<id>/colors.toml` (MIT, see site/NOTICE); `wall` picks one of its
 * background shades. `resolveTheme` derives the
 * roles the page paints with and guarantees WCAG AA for every text role, so
 * a theme whose own palette is too faint (a pastel green on a cream background)
 * keeps its hue and gets only as dark as legibility needs.
 */
import { ensureContrast } from '../lib/color';

export type Mode = 'dark' | 'light';

export interface RawTheme {
	id: string;
	label: string;
	mode: Mode;
	background: string;
	/** Tile gap colour: the theme's dark_background (dark themes) or darker_background (light themes). */
	wall: string;
	lighter_background: string;
	selection: string;
	muted: string;
	foreground: string;
	bright_foreground: string;
	dark_foreground: string;
	accent: string;
	green: string;
	yellow: string;
	red: string;
}

export const RAW_THEMES: RawTheme[] = [
	{
		id: 'tokyo-night', label: 'Tokyo Night', mode: 'dark',
		background: '#1a1b26', wall: '#13141c', lighter_background: '#24283b',
		selection: '#292e42', muted: '#414868',
		foreground: '#a9b1d6', bright_foreground: '#c0caf5', dark_foreground: '#565f89',
		accent: '#7aa2f7', green: '#9ece6a', yellow: '#e0af68', red: '#f7768e',
	},
	{
		id: 'gruvbox', label: 'Gruvbox', mode: 'dark',
		background: '#282828', wall: '#1e1e1e', lighter_background: '#3c3836',
		selection: '#504945', muted: '#665c54',
		foreground: '#d4be98', bright_foreground: '#d4be98', dark_foreground: '#7c6f64',
		accent: '#7daea3', green: '#a9b665', yellow: '#d8a657', red: '#ea6962',
	},
	{
		id: 'everforest', label: 'Everforest', mode: 'dark',
		background: '#2d353b', wall: '#21272c', lighter_background: '#343f44',
		selection: '#3d484d', muted: '#475258',
		foreground: '#d3c6aa', bright_foreground: '#d3c6aa', dark_foreground: '#4f585e',
		accent: '#7fbbb3', green: '#a7c080', yellow: '#dbbc7f', red: '#e67e80',
	},
	{
		id: 'catppuccin', label: 'Catppuccin', mode: 'dark',
		background: '#1e1e2e', wall: '#161622', lighter_background: '#313244',
		selection: '#45475a', muted: '#585b70',
		foreground: '#cdd6f4', bright_foreground: '#cdd6f4', dark_foreground: '#6c7086',
		accent: '#89b4fa', green: '#a6e3a1', yellow: '#f9e2af', red: '#f38ba8',
	},
	{
		id: 'rose-pine', label: 'Rose Pine', mode: 'light',
		background: '#faf4ed', wall: '#e1dbd5', lighter_background: '#f2e9e1',
		selection: '#dfdad9', muted: '#cecacd',
		foreground: '#575279', bright_foreground: '#575279', dark_foreground: '#9893a5',
		accent: '#56949f', green: '#286983', yellow: '#ea9d34', red: '#b4637a',
	},
	{
		id: 'flexoki-light', label: 'Flexoki Light', mode: 'light',
		background: '#FFFCF0', wall: '#e5e2d8', lighter_background: '#E6E4D9',
		selection: '#CECDC3', muted: '#B7B5AC',
		foreground: '#100F0F', bright_foreground: '#100F0F', dark_foreground: '#878580',
		accent: '#205EA6', green: '#879A39', yellow: '#D0A215', red: '#D14D41',
	},
];

export const DEFAULT_DARK = 'tokyo-night';
export const DEFAULT_LIGHT = 'flexoki-light';

/** pohunek's "needs you" amber and its darker readings on light surfaces. */
export const AMBER = '#e7c094';
export const AMBER_INK_CANDIDATES = [AMBER, '#b26b00', '#8f5400'];

/** WCAG AA: 4.5 for text, 3 for the borders and glyphs that carry meaning. */
export const AA_TEXT = 4.5;
export const AA_UI = 3;

export interface ResolvedTheme {
	id: string;
	label: string;
	mode: Mode;
	/** Tile gap colour (the "wallpaper"). */
	wall: string;
	/** Terminal tile and bar surface. */
	bg: string;
	bgRaised: string;
	selection: string;
	/** Inactive tile border. */
	borderIdle: string;
	/** Active tile border and focus ring: 3:1 against the wall and the tile. */
	borderActive: string;
	fg: string;
	fgMuted: string;
	accent: string;
	/** Text on an accent fill. */
	onAccent: string;
	ok: string;
	bad: string;
	hl: string;
	/** Amber text; the unmodified pohunek amber wherever it already reads. */
	needs: string;
}

export function resolveTheme(t: RawTheme): ResolvedTheme {
	const surfaces = [t.background, t.lighter_background, t.wall];
	const text = (candidates: string[]) => ensureContrast(candidates, surfaces, AA_TEXT, t.foreground);
	const accent = text([t.accent]);
	const onAccent = ensureContrast([t.background, t.foreground], [accent], AA_TEXT, t.foreground);
	const fg = ensureContrast([t.foreground], [...surfaces, t.selection], AA_TEXT, t.foreground);
	return {
		id: t.id,
		label: t.label,
		mode: t.mode,
		wall: t.wall,
		bg: t.background,
		bgRaised: t.lighter_background,
		selection: t.selection,
		borderIdle: t.selection,
		borderActive: ensureContrast([t.accent], [t.wall, t.background], AA_UI, t.foreground),
		fg,
		fgMuted: text([t.dark_foreground]),
		accent,
		onAccent,
		ok: text([t.green]),
		bad: text([t.red]),
		hl: text([t.yellow]),
		needs: text(AMBER_INK_CANDIDATES),
	};
}

export const THEMES: ResolvedTheme[] = RAW_THEMES.map(resolveTheme);

const ROLE_VARS: Record<string, keyof ResolvedTheme> = {
	'--wall': 'wall',
	'--bg': 'bg',
	'--bg-raised': 'bgRaised',
	'--selection': 'selection',
	'--border-idle': 'borderIdle',
	'--border-active': 'borderActive',
	'--fg': 'fg',
	'--fg-muted': 'fgMuted',
	'--accent': 'accent',
	'--on-accent': 'onAccent',
	'--ok': 'ok',
	'--bad': 'bad',
	'--hl': 'hl',
	'--needs': 'needs',
};

function block(selector: string, t: ResolvedTheme): string {
	const decls = Object.entries(ROLE_VARS).map(([v, k]) => `${v}:${t[k]}`).join(';');
	return `${selector}{${decls};color-scheme:${t.mode}}`;
}

/**
 * The page paints from the default theme for the visitor's colour scheme until
 * a `data-theme` attribute (set from localStorage) names another one, so the
 * theme works without JS too.
 */
export function themeCss(themes: ResolvedTheme[] = THEMES): string {
	const byId = (id: string) => {
		const t = themes.find((x) => x.id === id);
		if (!t) throw new Error(`unknown default theme ${id}`);
		return t;
	};
	const dark = byId(DEFAULT_DARK);
	const light = byId(DEFAULT_LIGHT);
	return [
		block(':root', dark),
		`@media (prefers-color-scheme:light){${block(':root:not([data-theme])', light)}}`,
		...themes.map((t) => block(`:root[data-theme="${t.id}"]`, t)),
	].join('\n');
}
