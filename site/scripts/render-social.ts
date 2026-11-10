/**
 * Renders the committed artwork from its HTML sources in social/ with headless
 * Chromium and writes optimized PNGs:
 *   social/social.html  -> public/social.png   (1200x630 link preview)
 *   social/preview.html -> ../preview.png      (marketplace hero, repository root)
 * Run: CHROME_BIN=/path/to/chrome bun scripts/render-social.ts
 * The screenshots inside the artwork come from tools/demo-pohunek (docs/).
 */
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { themeCss } from '../src/config/themes';

interface Target { source: string; out: string; width: number; height: number; maxBytes: number }

const site = fileURLToPath(new URL('../', import.meta.url));
const targets: Target[] = [
	{ source: 'social/social.html', out: 'public/social.png', width: 1200, height: 630, maxBytes: 300 * 1024 },
	{ source: 'social/preview.html', out: '../preview.png', width: 1600, height: 808, maxBytes: 1024 * 1024 },
];

const chrome = process.env.CHROME_BIN;
if (!chrome) throw new Error('CHROME_BIN is not set: point it at a Chrome or Chromium binary');

const tokens = readFileSync(join(site, 'src/styles/tokens.css'), 'utf8');
const profile = mkdtempSync(join(tmpdir(), 'render-social-'));
try {
	for (const t of targets) {
		const html = readFileSync(join(site, t.source), 'utf8')
			.replace('{{THEME_CSS}}', themeCss())
			.replace('{{TOKENS_CSS}}', tokens);
		const rendered = join(site, t.source.replace(/([^/]+)\.html$/, '.out-$1.html'));
		const raw = join(profile, 'raw.png');
		writeFileSync(rendered, html);
		execFileSync(chrome, [
			'--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
			'--allow-file-access-from-files', '--no-first-run', `--user-data-dir=${join(profile, 'data')}`,
			`--window-size=${t.width},${t.height}`, '--virtual-time-budget=8000', `--screenshot=${raw}`,
			`file://${rendered}`,
		], { stdio: ['ignore', 'ignore', 'inherit'] });
		rmSync(rendered);
		const meta = await sharp(raw).metadata();
		if (meta.width !== t.width || meta.height !== t.height) throw new Error(`${t.source}: rendered ${meta.width}x${meta.height}, expected ${t.width}x${t.height}`);
		await sharp(raw).png({ palette: true, quality: 90, effort: 10, colours: 128, dither: 0.5 }).toFile(join(site, t.out));
		const size = statSync(join(site, t.out)).size;
		if (size > t.maxBytes) throw new Error(`${t.out}: ${size} bytes exceeds ${t.maxBytes}`);
		console.log(`${t.out}: ${t.width}x${t.height}, ${size} bytes`);
	}
} finally {
	rmSync(profile, { recursive: true, force: true });
}
