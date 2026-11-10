import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'bun:test';
import { contrast } from '../src/lib/color';
import {
	AA_TEXT, AA_UI, AMBER, DEFAULT_DARK, DEFAULT_LIGHT, RAW_THEMES, THEMES, themeCss,
} from '../src/config/themes';

// The pohunek parchment layer is constant across themes (pohunek.dev tokens.css, light values).
const css = readFileSync(new URL('../src/styles/tokens.css', import.meta.url), 'utf8');
const token = (name: string): string => {
	const m = new RegExp(`--${name}:\\s*(#[0-9a-fA-F]{6})`).exec(css);
	if (!m) throw new Error(`token --${name} not found in tokens.css`);
	return m[1];
};
const PAPER = {
	paper: token('paper'), raised: token('paper-raised'), sunk: token('paper-sunk'),
	ink: token('ink'), inkMuted: token('ink-muted'), leather: token('leather'),
	leatherStrong: token('leather-strong'), amberInk: token('amber-ink'),
};
const CRT = {
	bg: token('crt-bezel'), screen: token('crt-screen'), ink: token('crt-ink'), muted: token('crt-muted'),
	phosphor: token('phosphor'), amber: token('amber'),
};

describe('every shipped theme meets WCAG AA', () => {
	for (const t of THEMES) {
		describe(t.id, () => {
			const surfaces = { bg: t.bg, raised: t.bgRaised, wall: t.wall };
			for (const [sname, s] of Object.entries(surfaces)) {
				for (const role of ['fg', 'fgMuted', 'accent', 'ok', 'bad', 'hl', 'needs'] as const) {
					test(`${role} text on ${sname} >= ${AA_TEXT}`, () => {
						expect(contrast(t[role], s)).toBeGreaterThanOrEqual(AA_TEXT);
					});
				}
			}
			test('title text on the idle title bar', () => {
				expect(contrast(t.fg, t.selection)).toBeGreaterThanOrEqual(AA_TEXT);
			});
			test('text on an accent fill', () => {
				expect(contrast(t.onAccent, t.accent)).toBeGreaterThanOrEqual(AA_TEXT);
			});
			test('active border and focus ring are visible against the wall and the tile', () => {
				expect(contrast(t.borderActive, t.wall)).toBeGreaterThanOrEqual(AA_UI);
				expect(contrast(t.borderActive, t.bg)).toBeGreaterThanOrEqual(AA_UI);
			});
		});
	}
});

describe('the constant pohunek layers meet WCAG AA', () => {
	test('ink on parchment', () => {
		for (const bg of [PAPER.paper, PAPER.raised, PAPER.sunk]) {
			expect(contrast(PAPER.ink, bg)).toBeGreaterThanOrEqual(AA_TEXT);
			expect(contrast(PAPER.inkMuted, bg)).toBeGreaterThanOrEqual(AA_TEXT);
			expect(contrast(PAPER.leather, bg)).toBeGreaterThanOrEqual(AA_TEXT);
			expect(contrast(PAPER.leatherStrong, bg)).toBeGreaterThanOrEqual(AA_TEXT);
			expect(contrast(PAPER.amberInk, bg)).toBeGreaterThanOrEqual(AA_TEXT);
		}
	});
	test('phosphor, amber and chalk on the CRT void', () => {
		for (const c of [CRT.ink, CRT.muted, CRT.phosphor, CRT.amber]) {
			expect(contrast(c, CRT.bg)).toBeGreaterThanOrEqual(AA_TEXT);
			expect(contrast(c, CRT.screen)).toBeGreaterThanOrEqual(AA_TEXT);
		}
	});
});

describe('theme table', () => {
	test('ids are unique and both defaults exist with the matching mode', () => {
		const ids = RAW_THEMES.map((t) => t.id);
		expect(new Set(ids).size).toBe(ids.length);
		expect(RAW_THEMES.find((t) => t.id === DEFAULT_DARK)?.mode).toBe('dark');
		expect(RAW_THEMES.find((t) => t.id === DEFAULT_LIGHT)?.mode).toBe('light');
	});
	test('light and dark are both represented', () => {
		expect(RAW_THEMES.some((t) => t.mode === 'light')).toBe(true);
		expect(RAW_THEMES.some((t) => t.mode === 'dark')).toBe(true);
	});
	test('the generated css defines every theme and the colour-scheme fallback', () => {
		const css = themeCss();
		for (const t of THEMES) expect(css).toContain(`:root[data-theme="${t.id}"]`);
		expect(css).toContain('prefers-color-scheme:light');
	});
});
