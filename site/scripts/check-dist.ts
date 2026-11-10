/** Post-build gate: the built site makes no external requests and keeps its content without JS. */
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SOCIAL_IMAGE } from '../src/config/site';
import { socialProblems } from '../src/lib/social';
import { cssExternal, externalRequests, hasLang, imagesWithoutAlt, scriptNetworkUse } from '../src/lib/dist-check';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));
if (!existsSync(dist)) throw new Error('dist/ is missing: run astro build first');

function walk(dir: string): string[] {
	return readdirSync(dir).flatMap((n) => {
		const p = join(dir, n);
		return statSync(p).isDirectory() ? walk(p) : [p];
	});
}

const ORIGIN = 'https://omarchy.pohunek.dev';
const problems: string[] = [];
const files = walk(dist);
for (const f of files) {
	const rel = f.slice(dist.length);
	if (f.endsWith('.html')) {
		const html = readFileSync(f, 'utf8');
		for (const r of externalRequests(html)) problems.push(`${rel}: external request ${r}`);
		for (const i of imagesWithoutAlt(html)) problems.push(`${rel}: image without alt ${i}`);
		if (!hasLang(html)) problems.push(`${rel}: <html> has no lang`);
		for (const p of socialProblems(html, ORIGIN)) problems.push(`${rel}: ${p}`);
	} else if (f.endsWith('.css')) {
		for (const r of cssExternal(readFileSync(f, 'utf8'))) problems.push(`${rel}: ${r}`);
	} else if (f.endsWith('.js')) {
		for (const r of scriptNetworkUse(readFileSync(f, 'utf8'))) problems.push(`${rel}: script uses ${r}`);
	}
}

// The link preview image the meta tags point at.
const socialFile = join(dist, SOCIAL_IMAGE.path);
if (!existsSync(socialFile)) {
	problems.push(`${SOCIAL_IMAGE.path}: missing from dist`);
} else {
	const png = readFileSync(socialFile);
	const isPng = png.subarray(1, 4).toString('latin1') === 'PNG';
	const [w, h] = isPng ? [png.readUInt32BE(16), png.readUInt32BE(20)] : [0, 0];
	if (!isPng) problems.push(`${SOCIAL_IMAGE.path}: not a PNG`);
	else if (w !== SOCIAL_IMAGE.width || h !== SOCIAL_IMAGE.height) problems.push(`${SOCIAL_IMAGE.path}: ${w}x${h}, expected ${SOCIAL_IMAGE.width}x${SOCIAL_IMAGE.height}`);
	if (png.length > SOCIAL_IMAGE.maxBytes) problems.push(`${SOCIAL_IMAGE.path}: ${png.length} bytes exceeds ${SOCIAL_IMAGE.maxBytes}`);
}

// Content that must be readable without running any script.
const index = readFileSync(join(dist, 'index.html'), 'utf8');
for (const needle of [
	'omarchy plugin add https://github.com/pohunekd/omarchy --enable',
	'Not affiliated with Omarchy or Basecamp. Omarchy is a project by Basecamp/DHH.',
	'gh attestation verify',
]) {
	if (!index.includes(needle)) problems.push(`index.html: missing static content "${needle}"`);
}

if (problems.length) {
	console.error(problems.join('\n'));
	process.exit(1);
}
console.log(`dist ok: ${files.length} files, no external requests, every image has alt`);
