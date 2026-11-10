/**
 * Copies the screenshots, the demo and the logo from the repository root into
 * src/generated (gitignored) so the page and the README share one source.
 */
import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const out = fileURLToPath(new URL('../src/generated/', import.meta.url));

const files: Array<[string, string]> = [
	['docs/demo.gif', 'demo.gif'],
	['docs/bar.png', 'bar.png'],
	['docs/list.png', 'list.png'],
	['docs/state.png', 'state.png'],
	['docs/actions.png', 'actions.png'],
	['docs/new.png', 'new.png'],
	['docs/help.png', 'help.png'],
	['docs/hosts.png', 'hosts.png'],
	['assets/pohunek-app.png', 'pohunek-app.png'],
];

mkdirSync(out, { recursive: true });
for (const [from, to] of files) {
	const src = root + from;
	if (!existsSync(src)) throw new Error(`missing source asset: ${from}`);
	copyFileSync(src, out + to);
}
console.log(`synced ${files.length} assets into src/generated`);
