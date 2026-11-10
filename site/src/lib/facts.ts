/** Facts the page quotes from the repository root, read at build time. */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

/** Builds and tests run from site/, one level below the repository root. */
const root = resolve(process.cwd(), '..');

export interface Facts {
	version: string;
	released: string | null;
}

/** First `## X.Y.Z - YYYY-MM-DD` heading of a CHANGELOG.md. */
export function latestRelease(changelog: string): { version: string; date: string } | null {
	const m = /^## (\d+\.\d+\.\d+) - (\d{4}-\d{2}-\d{2})\s*$/m.exec(changelog);
	return m ? { version: m[1], date: m[2] } : null;
}

export function readFacts(): Facts {
	const manifest = JSON.parse(readFileSync(resolve(root, 'manifest.json'), 'utf8')) as { version?: unknown };
	if (typeof manifest.version !== 'string') throw new Error('manifest.json has no version');
	const release = latestRelease(readFileSync(resolve(root, 'CHANGELOG.md'), 'utf8'));
	return { version: manifest.version, released: release?.version === manifest.version ? release.date : null };
}
