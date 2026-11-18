#!/bin/bash
# Apply, in order: the OnePlus port's own OH patches (the same set its init_patch.sh applies), this repo's OH
# patches, the kernel patches, and the build.sh Node version. Safe to re-run: applied patches are skipped.
set -euo pipefail
. "$(dirname "$0")/config.sh"
cd "$OH_ROOT"

apply_one() {  # apply_one PROJECT_DIR PATCH
  local dir=$1 p=$2
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || die "$dir is not a git project (sync incomplete?)"
  if git -C "$dir" apply --check -R --whitespace=nowarn "$p" >/dev/null 2>&1; then
    echo "  already applied: ${p#$REPO_DIR/} -> $dir"
  elif git -C "$dir" apply --check --whitespace=nowarn "$p" >/dev/null 2>&1; then
    git -C "$dir" apply --whitespace=nowarn "$p"
    echo "  applied:         ${p#$REPO_DIR/} -> $dir"
  else
    git -C "$dir" apply --check --whitespace=nowarn "$p" || true
    die "$p does not apply to $dir"
  fi
}

step "port patches (device/board/oneplus/fajita/patch)"
# The port's patches are written for OH 6.1; patches/port-7.0 holds the ones rebased onto 7.0 (same file names).
for p in device/board/oneplus/fajita/patch/*.patch; do
  # file name: NNNN=path@to@project=oh.patch  (as parsed by the port's init_patch.sh)
  b=$(basename "$p"); d=${b#*=}; d=${d%=*}; d=${d//@//}
  if [ -f "$REPO_DIR/patches/port-7.0/$b" ]; then apply_one "$d" "$REPO_DIR/patches/port-7.0/$b"
  else apply_one "$d" "$OH_ROOT/$p"; fi
done

step "westlake-oneplus OH patches"
while IFS= read -r p; do
  rel=${p#$REPO_DIR/patches/oh/}; apply_one "$(dirname "$rel")" "$p"
done < <(find "$REPO_DIR/patches/oh" -name '*.patch' | sort)

step "kernel patches -> ${KERNEL_SRC#$OH_ROOT/}"
for p in "$REPO_DIR"/patches/kernel/*.patch; do apply_one "$KERNEL_SRC" "$p"; done

# build.sh is a copy of build/build_scripts/build.sh made by repo sync (re-copied on every sync).
step "build.sh: expect Node 18"
sed -i 's/^EXPECTED_NODE_VERSION="14.21.1"$/EXPECTED_NODE_VERSION="18.20.1"/' build.sh
grep -n '^EXPECTED_NODE_VERSION=' build.sh
