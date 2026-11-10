/**
 * Prints the version (X.Y.Z) of the latest published release of this
 * repository. Uses the gh CLI, which authenticates with GH_TOKEN in CI and
 * with the local login elsewhere. Exits non-zero when there is no release.
 */
import { spawnSync } from 'node:child_process';
import { versionOfTag } from '../src/lib/facts';

const result = spawnSync('gh', ['api', 'repos/pohunekd/omarchy/releases/latest', '--jq', '.tag_name'], { encoding: 'utf8' });
if (result.error) throw result.error;
if (result.status !== 0) {
	console.error(result.stderr.trim() || `gh api exited ${result.status}`);
	process.exit(1);
}
console.log(versionOfTag(result.stdout.trim()));
