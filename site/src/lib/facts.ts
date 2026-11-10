/** Facts the page quotes, read at build time: the repository root plus the published release. */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

/** Builds and tests run from site/, one level below the repository root. */
const root = resolve(process.cwd(), '..');

export interface Facts {
	version: string;
	released: string | null;
}

/** Environment variable that names the published release; `scripts/latest-release.ts` produces it. */
export const RELEASE_ENV = 'SITE_RELEASE_VERSION';

/** `X.Y.Z` from a release tag `vX.Y.Z`; anything else is rejected. */
export function versionOfTag(tag: unknown): string {
	const m = typeof tag === 'string' ? /^v(\d+\.\d+\.\d+)$/.exec(tag) : null;
	if (!m) throw new Error(`release tag is not vX.Y.Z: ${JSON.stringify(tag)}`);
	return m[1];
}

/** The `## X.Y.Z - YYYY-MM-DD` heading of one version in a CHANGELOG.md. */
export function releaseDate(changelog: string, version: string): string | null {
	const m = new RegExp(`^## ${version.replaceAll('.', '\\.')} - (\\d{4}-\\d{2}-\\d{2})\\s*$`, 'm').exec(changelog);
	return m ? m[1] : null;
}

/** The page advertises the published release only, never the manifest version of unreleased work. */
export function readFacts(published: string | undefined = process.env[RELEASE_ENV]): Facts {
	if (!published) {
		throw new Error(`${RELEASE_ENV} is not set: build with ${RELEASE_ENV}=$(bun scripts/latest-release.ts)`);
	}
	const version = versionOfTag(`v${published}`);
	return { version, released: releaseDate(readFileSync(resolve(root, 'CHANGELOG.md'), 'utf8'), version) };
}
