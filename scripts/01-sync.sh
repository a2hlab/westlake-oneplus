#!/bin/bash
# Create the source tree: OpenHarmony at the release tag + the OnePlus port repos at the tested commits.
# Download is ~100 GB; the tree after the build uses ~200 GB (ccache can grow to 100 GB over rebuilds; keep ~300 GB free).
set -euo pipefail
. "$(dirname "$0")/config.sh"
export PATH="$HOST_DIR/bin:$PATH"
command -v repo >/dev/null || die "repo launcher not found (run scripts/00-host-setup.sh)"

# gitcode.com (the main OpenHarmony mirror) answers HTTP 418 to git's user agent. repo forces
# GIT_HTTP_USER_AGENT, so send a browser User-Agent as an extra header for gitcode only.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://gitcode.com/.extraHeader
export GIT_CONFIG_VALUE_0="User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130 Safari/537.36"

mkdir -p "$OH_ROOT"; cd "$OH_ROOT"
if [ ! -d .repo ]; then
  step "repo init $OH_TAG"
  repo init -u "$OH_MANIFEST_URL" -b "refs/tags/$OH_TAG" --no-repo-verify --depth=1
fi
mkdir -p .repo/local_manifests
cp "$REPO_DIR/manifests/ohport.xml" .repo/local_manifests/ohport.xml

step "repo sync"
ok=0
for i in 1 2 3; do
  if repo sync -c -j"$SYNC_JOBS" --no-tags; then ok=1; break; fi
  echo "sync attempt $i failed; retrying"
done
[ $ok = 1 ] || die "repo sync failed 3 times"

step "git lfs pull"
repo forall -c 'git lfs pull'

# The full pin list is for the tested release; SKIP_PIN_CHECK=1 for other OH tags (e.g. a 7.0 trial).
[ "${SKIP_PIN_CHECK:-0}" = 1 ] || "$SCRIPTS_DIR/verify-pins.sh"
