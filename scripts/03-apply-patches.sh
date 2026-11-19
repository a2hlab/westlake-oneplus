#!/bin/bash
# Apply, in order: the OnePlus port's own OH patches (the same set its init_patch.sh applies), this repo's OH
# patches, the kernel patches, and the build.sh Node version. Safe to re-run: applied patches are skipped.
# CHECK_ONLY=1 only reports which patches are applied and applies nothing.
set -euo pipefail
. "$(dirname "$0")/config.sh"
cd "$OH_ROOT"

# The patches in order, one "PROJECT_DIR<tab>PATCH" line each.
list_patches() {
  local p b d
  # The port's patches are written for OH 6.1; patches/port-7.0 holds the ones rebased onto 7.0 (same file names).
  for p in device/board/oneplus/fajita/patch/*.patch; do
    # file name: NNNN=path@to@project=oh.patch  (as parsed by the port's init_patch.sh)
    b=$(basename "$p"); d=${b#*=}; d=${d%=*}; d=${d//@//}
    if [ -f "$REPO_DIR/patches/port-7.0/$b" ]; then p=$REPO_DIR/patches/port-7.0/$b; else p=$OH_ROOT/$p; fi
    printf '%s\t%s\n' "$d" "$p"
  done
  find "$REPO_DIR/patches/oh" -name '*.patch' | sort | while IFS= read -r p; do
    d=${p#$REPO_DIR/patches/oh/}; printf '%s\t%s\n' "$(dirname "$d")" "$p"
  done
  for p in "$REPO_DIR"/patches/kernel/*.patch; do printf '%s\t%s\n' "$KERNEL_SRC" "$p"; done
}

# applied_count DIR PATCH...: how many of the PATCHes, from the first on, DIR has. A project's patches are checked as
# a series, taken back out last first from a copy of the files they touch: a later patch can change the lines around
# an earlier one, and then the earlier one alone no longer reverse-applies.
applied_count() {
  local dir=$1; shift
  local k i f tmp ok
  for ((k = $#; k > 0; k--)); do
    tmp=$(mktemp -d /tmp/apply-patches.XXXXXX)
    for f in $(sed -n 's#^+++ b/##p' "${@:1:k}" | sort -u); do
      if [ -e "$dir/$f" ]; then mkdir -p "$tmp/$(dirname "$f")"; cp -p "$dir/$f" "$tmp/$f"; fi
    done
    ok=1
    for ((i = k; i >= 1; i--)); do
      (cd "$tmp" && git apply -R --whitespace=nowarn "${!i}" >/dev/null 2>&1) || { ok=0; break; }
    done
    rm -rf "$tmp"
    [ $ok = 1 ] && break
  done
  echo "$k"
}

step "patches, each project's in order: the port's (device/board/oneplus/fajita/patch), this repo's, the kernel's"
mapfile -t entries < <(list_patches)
mapfile -t dirs < <(printf '%s\n' "${entries[@]}" | cut -f1 | awk '!seen[$0]++')
for d in "${dirs[@]}"; do
  [ -d "$d/.git" ] || [ -f "$d/.git" ] || die "$d is not a git project (sync incomplete?)"
  mapfile -t ps < <(printf '%s\n' "${entries[@]}" | awk -F'\t' -v d="$d" '$1 == d { print $2 }')
  for ((i = 0; i < ${#ps[@]}; i++)); do ps[i]=$(realpath "${ps[i]}"); done
  k=$(applied_count "$d" "${ps[@]}")
  for ((i = 0; i < ${#ps[@]}; i++)); do
    p=${ps[i]}; name=${p#$REPO_DIR/}; name=${name#$OH_ROOT/}
    if ((i < k)); then
      echo "  already applied: $name -> ${d#$OH_ROOT/}"
    elif git -C "$d" apply --check --whitespace=nowarn "$p" >/dev/null 2>&1; then
      if [ "${CHECK_ONLY:-0}" = 1 ]; then echo "  would apply:     $name -> ${d#$OH_ROOT/}"; continue; fi
      git -C "$d" apply --whitespace=nowarn "$p"
      echo "  applied:         $name -> ${d#$OH_ROOT/}"
    else
      git -C "$d" apply --check --whitespace=nowarn "$p" || true
      die "$p does not apply to $d"
    fi
  done
done
[ "${CHECK_ONLY:-0}" = 1 ] && exit 0

# build.sh is a copy of build/build_scripts/build.sh made by repo sync (re-copied on every sync).
step "build.sh: expect Node 18"
sed -i 's/^EXPECTED_NODE_VERSION="14.21.1"$/EXPECTED_NODE_VERSION="18.20.1"/' build.sh
grep -n '^EXPECTED_NODE_VERSION=' build.sh
