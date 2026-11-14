#!/usr/bin/env bash
# shellcheck shell=bash
# The VD_* globals are set here and read by the tools that source this file.
# shellcheck disable=SC2034
# Verified downloads of pohunek releases, sourced by tools/install-pohunek and
# tools/onboard. Only https GitHub release URLs of zajca/pohunek and
# pohunekd/plugin-assistant are fetched. Every archive is checked against its
# published SHA-256 and, when `gh` is signed in, its GitHub build attestation.
#
# The functions return status codes and set VD_* globals; they never exit.
# The caller owns the work directory and its cleanup.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "verified-download.bash is sourced by the tools, not run." >&2
  exit 2
fi

VD_CORE_REPO="zajca/pohunek"
VD_ASSISTANT_REPO="pohunekd/plugin-assistant"
VD_ASSISTANT_ID="pohunek.context.assistant"
# The plugin-assistant archive is attested by the core repository's reusable
# release workflow; the certificate names that workflow at the release tag.
VD_ASSISTANT_SIGNER="https://github.com/zajca/pohunek/.github/workflows/plugin-release.yml"
VD_VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$'
VD_FIXTURES=""
# The `gh` the attestation and release-notes reads run: `gh` on PATH, or in
# test mode only the stub POHUNEK_ONBOARD_TEST_GH names.
VD_GH="gh"

# Test hook: POHUNEK_ONBOARD_TEST_FIXTURES names a local directory that stands
# in for GitHub (tests/onboard_test.py). Downloads then copy
# <dir>/<host>/<path> of each URL. The `gh` on PATH is never called then; a
# stub executable inside that directory, named by POHUNEK_ONBOARD_TEST_GH,
# takes its place, or none.
vd_init() {
  local tool fixtures=${POHUNEK_ONBOARD_TEST_FIXTURES:-} stub=${POHUNEK_ONBOARD_TEST_GH:-}
  for tool in curl sha256sum jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required." >&2; return 1; }
  done
  if [[ -n $fixtures ]]; then
    if [[ $fixtures != /* || ! -d $fixtures || -L $fixtures ]]; then
      echo "POHUNEK_ONBOARD_TEST_FIXTURES must name an existing local directory." >&2
      return 1
    fi
    VD_FIXTURES=$fixtures
    VD_GH=""
    echo "TEST MODE: release downloads come from $VD_FIXTURES, not GitHub."
    if [[ -n $stub ]]; then
      if [[ $stub != "$VD_FIXTURES"/* || $stub == *..* || ! -f $stub || -L $stub || ! -x $stub ]]; then
        echo "POHUNEK_ONBOARD_TEST_GH must name an executable file inside the fixture directory." >&2
        return 1
      fi
      VD_GH=$stub
      echo "TEST MODE: gh is the stub $VD_GH."
    fi
  elif [[ -n $stub ]]; then
    echo "POHUNEK_ONBOARD_TEST_GH works only together with POHUNEK_ONBOARD_TEST_FIXTURES." >&2
    return 1
  fi
  return 0
}

# The only URLs these tools download.
vd_allowed_url() {
  local repos='(zajca/pohunek|pohunekd/plugin-assistant)'
  [[ $1 =~ ^https://github\.com/${repos}/releases/download/v[0-9A-Za-z.-]+/[A-Za-z0-9._+-]+$ ||
     $1 =~ ^https://api\.github\.com/repos/${repos}/releases/(latest|tags/v[0-9A-Za-z.-]+)$ ]]
}

# vd_get URL OUT [MAX_SECONDS]: 0 on success, 22 when the file does not exist
# (HTTP 404 or a missing fixture), another curl status otherwise.
vd_get() {
  local url=$1 out=$2 max=${3:-600}
  vd_allowed_url "$url" || { echo "Refusing to download $url" >&2; return 2; }
  if [[ -n $VD_FIXTURES ]]; then
    local source="$VD_FIXTURES/${url#https://}"
    [[ -f $source && ! -L $source ]] || return 22
    cp -- "$source" "$out"
    return
  fi
  # Long downloads show a progress bar on a terminal; the rest stay quiet.
  local progress=(-sS)
  if (( max > 60 )) && [[ -t 2 ]]; then progress=(--progress-bar); fi
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fL "${progress[@]}" --max-time "$max" -o "$out" -- "$url"
}

vd_sha256() {
  local sum
  sum=$(sha256sum -- "$1") || return 1
  printf '%s\n' "${sum%% *}"
}

# Whether `gh` can check attestations and read release notes.
vd_gh_ready() {
  [[ -n $VD_GH ]] && command -v "$VD_GH" >/dev/null 2>&1 && "$VD_GH" auth status >/dev/null 2>&1
}

# vd_attest FILE REPO [extra gh args...]: prints the outcome; 1 when the
# attestation does not verify. Without a signed-in `gh` it is skipped.
vd_attest() {
  local file=$1 repo=$2
  shift 2
  if vd_gh_ready; then
    "$VD_GH" attestation verify "$file" --repo "$repo" "$@" >/dev/null || return 1
    echo "GitHub build attestation: verified."
  else
    echo "GitHub build attestation: skipped (gh is not signed in)."
  fi
}

# Sets VD_CORE_TAG and VD_CORE_VERSION to the latest core release.
vd_latest_core() {
  local work=$1 tag
  vd_get "https://api.github.com/repos/$VD_CORE_REPO/releases/latest" "$work/latest.json" 30 || return 1
  tag=$(jq -r '.tag_name // empty' "$work/latest.json") || return 1
  VD_CORE_VERSION=${tag#v}
  [[ $tag == v* && $VD_CORE_VERSION =~ $VD_VERSION_RE ]] || { echo "Unexpected release tag: $tag" >&2; return 1; }
  VD_CORE_TAG=$tag
}

# vd_fetch_core WORK: downloads the Linux x86_64 daemon archive of
# VD_CORE_TAG into WORK and verifies it. Sets VD_CORE_ARCHIVE (a path).
vd_fetch_core() {
  local work=$1 name base expected actual
  name="pohunek-daemon-${VD_CORE_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
  base="https://github.com/$VD_CORE_REPO/releases/download/$VD_CORE_TAG"
  echo "Release $VD_CORE_TAG: $name"
  vd_get "$base/$name" "$work/$name" 600 || { echo "Could not download $name." >&2; return 1; }
  vd_get "$base/$name.sha256" "$work/$name.sha256" 30 || { echo "Could not download $name.sha256." >&2; return 1; }
  expected=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$work/$name.sha256")
  actual=$(vd_sha256 "$work/$name") || return 1
  if [[ ! $expected =~ ^[0-9a-f]{64}$ || $expected != "$actual" ]]; then
    echo "Checksum mismatch for $name." >&2
    return 1
  fi
  echo "SHA-256: verified ($actual)."
  vd_attest "$work/$name" "$VD_CORE_REPO" || { echo "Attestation check failed for $name." >&2; return 1; }
  VD_CORE_ARCHIVE="$work/$name"
}

# The assistant package digest the core release notes of v<V> publish, from
# the line `Assistant package pohunek.context.assistant <V> sha256: <hex>`.
vd_notes_digest() {
  local work=$1 version=$2 body lines
  body="$work/core-notes.txt"
  if vd_gh_ready; then
    "$VD_GH" release view "v$version" --repo "$VD_CORE_REPO" --json body --jq .body >"$body" || return 1
  else
    vd_get "https://api.github.com/repos/$VD_CORE_REPO/releases/tags/v$version" "$work/core-release.json" 30 || return 1
    jq -r '.body // ""' "$work/core-release.json" >"$body" || return 1
  fi
  lines=$(tr -d '\r' <"$body" | awk -v want="Assistant package $VD_ASSISTANT_ID $version sha256:" '
    index($0, want) == 1 { rest = substr($0, length(want) + 1); sub(/^ +/, "", rest); print rest }')
  # Exactly one line, holding exactly one digest.
  [[ $lines =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$lines"
}

# vd_fetch_assistant WORK VERSION: downloads the assistant package of
# plugin-assistant v<VERSION> and verifies it three ways: its SHA256SUMS, the
# digest in the core release notes of v<VERSION>, and the attestation.
# Sets VD_ASSISTANT_ARCHIVE and VD_ASSISTANT_DIGEST (64 hex characters).
# Returns 3 when that release or its archive does not exist.
vd_fetch_assistant() {
  local work=$1 version=$2 name base sums listed actual notes rc
  [[ $version =~ $VD_VERSION_RE ]] || { echo "Unexpected version: $version" >&2; return 1; }
  name="$VD_ASSISTANT_ID-$version.tar.zst"
  base="https://github.com/$VD_ASSISTANT_REPO/releases/download/v$version"
  sums="$work/assistant-SHA256SUMS"
  rc=0; vd_get "$base/SHA256SUMS" "$sums" 30 || rc=$?
  if (( rc == 22 )); then
    echo "pohunekd/plugin-assistant has no release v$version with a SHA256SUMS file." >&2
    return 3
  elif (( rc != 0 )); then
    echo "Could not download SHA256SUMS of plugin-assistant v$version." >&2
    return 1
  fi
  rc=0; vd_get "$base/$name" "$work/$name" 300 || rc=$?
  if (( rc == 22 )); then
    echo "pohunekd/plugin-assistant v$version has no $name." >&2
    return 3
  elif (( rc != 0 )); then
    echo "Could not download $name." >&2
    return 1
  fi
  listed=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$sums")
  actual=$(vd_sha256 "$work/$name") || return 1
  if [[ ! $listed =~ ^[0-9a-f]{64}$ || $listed != "$actual" ]]; then
    echo "Checksum mismatch: $name does not match its SHA256SUMS entry." >&2
    return 1
  fi
  if ! notes=$(vd_notes_digest "$work" "$version"); then
    echo "The core release notes of v$version do not carry exactly one line" >&2
    echo "'Assistant package $VD_ASSISTANT_ID $version sha256: <digest>'." >&2
    return 1
  fi
  if [[ $notes != "$actual" ]]; then
    echo "Checksum mismatch: $name differs from the digest in the core release notes." >&2
    return 1
  fi
  echo "SHA-256: verified against SHA256SUMS and the core release notes ($actual)."
  if ! vd_attest "$work/$name" "$VD_ASSISTANT_REPO" \
      --cert-identity "$VD_ASSISTANT_SIGNER@refs/tags/v$version" \
      --source-ref "refs/tags/v$version"; then
    echo "Attestation check failed for $name." >&2
    return 1
  fi
  VD_ASSISTANT_ARCHIVE="$work/$name"
  VD_ASSISTANT_DIGEST=$actual
}
