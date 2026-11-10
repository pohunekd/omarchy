/** WCAG 2.x colour maths shared by the theme resolver and its contrast test. */

export type Rgb = readonly [number, number, number];

export function parseHex(hex: string): Rgb {
	const m = /^#([0-9a-f]{6})$/i.exec(hex);
	if (!m) throw new Error(`not a #rrggbb colour: ${hex}`);
	const n = parseInt(m[1], 16);
	return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

export function toHex([r, g, b]: Rgb): string {
	return '#' + [r, g, b].map((c) => Math.round(c).toString(16).padStart(2, '0')).join('');
}

function channel(c: number): number {
	const s = c / 255;
	return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
}

export function luminance(hex: string): number {
	const [r, g, b] = parseHex(hex);
	return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

export function contrast(a: string, b: string): number {
	const la = luminance(a);
	const lb = luminance(b);
	return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/** Blends `t` of `to` into `from` per channel in gamma-encoded sRGB. */
export function mix(from: string, to: string, t: number): string {
	const a = parseHex(from);
	const b = parseHex(to);
	return toHex([0, 1, 2].map((i) => a[i] + (b[i] - a[i]) * t) as unknown as Rgb);
}

/**
 * Returns the first candidate that reaches `min` against every surface. When
 * none does, the last candidate is pulled toward `anchor` in 2% steps until it
 * does, so a hue is kept as long as the ratio allows.
 */
export function ensureContrast(candidates: string[], surfaces: string[], min: number, anchor: string): string {
	const ok = (c: string) => surfaces.every((s) => contrast(c, s) >= min);
	for (const c of candidates) if (ok(c)) return c;
	const base = candidates[candidates.length - 1];
	for (let t = 0.02; t <= 1.0001; t += 0.02) {
		const c = mix(base, anchor, Math.min(t, 1));
		if (ok(c)) return c;
	}
	return anchor;
}
