# Releasing

A release is a `vX.Y.Z` tag whose version equals `manifest.json` `version`. The
tag push builds the archive, attests it and publishes a GitHub Release; nothing
is built or published by hand.

Users still install with `omarchy plugin add https://github.com/pohunekd/omarchy`,
which clones the default branch. The release archive is the pinned, verifiable
artefact (for pohunek.dev and manual installs).

## Assets

- `pohunek-omarchy-X.Y.Z-noarch.tar.gz`: `git archive` of the tagged commit under
  the prefix `pohunek-omarchy-X.Y.Z/`. `.gitattributes` marks `.github/`,
  `.agents/`, `.claude/`, `changelog.d/`, `site/`, and `tests/` as
  `export-ignore`, so they are not in it. The build is reproducible: a rebuild
  of the same commit yields the same bytes.
- `pohunek-omarchy-X.Y.Z-noarch.tar.gz.sha256`: its checksum.
- Both files carry a build provenance attestation.

The release body starts with the folded `CHANGELOG.md` section between
`<!-- pohunek-changelog:start -->` and `<!-- pohunek-changelog:end -->`.

## Prepare

1. Choose the version `X.Y.Z` and set it in `manifest.json`.
2. Fold the fragments into the changelog (skip when the section for this version
   is already in `CHANGELOG.md`, as `0.3.0` is):

   ```bash
   scripts/changelog fold X.Y.Z [--date YYYY-MM-DD]
   scripts/changelog notes X.Y.Z      # the block the release body will carry
   scripts/gates
   ```

   `fold` refuses a version that already has a section, and `notes` refuses
   while fragments remain in `changelog.d/`.
3. Open a pull request with the manifest bump and the fold (label
   `no-changelog`) and merge it. The pull request runs `release.yml` as a dry
   run: it builds the archive and checksum and uploads them as workflow
   artifacts, and shows the release body, without tagging or publishing.

## Tag

From an up-to-date `main` whose `manifest.json` already has the version:

```bash
git tag -a vX.Y.Z -m "vX.Y.Z"    # annotated; the tag must point at the merged commit
git push origin vX.Y.Z
```

The workflow stops in `prepare` when the tag and `manifest.json` disagree, in
`build` when a gate fails or the archive is wrong, and in `body` when the
changelog has no section for the version or fragments are left.

A tag must point at a commit on `main`; `prepare` refuses any other.

If `publish` fails after it created the draft (for example a transient API
error during verification), a rerun stops with "a release or draft for vX.Y.Z
already exists". Delete the draft, keeping the tag, then re-run the failed jobs:

```bash
gh release delete vX.Y.Z --repo pohunekd/omarchy --yes
```

## Verify

```bash
gh release download vX.Y.Z --repo pohunekd/omarchy --dir release
cd release
sha256sum -c pohunek-omarchy-X.Y.Z-noarch.tar.gz.sha256
gh attestation verify pohunek-omarchy-X.Y.Z-noarch.tar.gz --repo pohunekd/omarchy
gh attestation verify pohunek-omarchy-X.Y.Z-noarch.tar.gz.sha256 --repo pohunekd/omarchy
```

Check that the release body holds the changelog block between the two markers.

## Workflow jobs

`prepare` (version), `build` (gates, archive, checksum, extract and validate),
`body` (release body; `scripts/release-body` previews the next release on pull requests, under a preview patch version when the manifest version already has its section), `attest` (only `id-token` and `attestations: write`, tag
pushes only), `publish` (only `contents: write`, tag pushes only: draft, verify
assets and body, publish). Every action is pinned to a commit SHA.
