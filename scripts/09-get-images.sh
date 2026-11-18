#!/bin/bash
# Install without building: download the prebuilt images of a release of this repository, check them against
# the release's SHA256SUMS and unpack them into $PREBUILT_DIR. Then install and boot them as usual, with
#   IMAGES_DIR=$PREBUILT_DIR BOOT_IMG=$PREBUILT_DIR/boot-oneplus6.img scripts/10-install.sh   (and 11-boot-oh.sh)
# Needs curl, zstd and sha256sum. RELEASE_TAG picks a release (default: the latest one). Safe to re-run:
# files that are already there and match the checksums are not downloaded again.
set -euo pipefail
. "$(dirname "$0")/config.sh"

: "${RELEASE_TAG:=latest}"
: "${PREBUILT_DIR:=$WORK_DIR/prebuilt}"
REPO_URL=https://github.com/a2hlab/westlake-oneplus
if [ "$RELEASE_TAG" = latest ]; then base=$REPO_URL/releases/latest/download
else base=$REPO_URL/releases/download/$RELEASE_TAG; fi
: "${RELEASE_URL:=$base}"   # override for a mirror or a local copy (file:///...)
for t in curl zstd sha256sum; do command -v "$t" >/dev/null || die "$t is missing (apt install curl zstd coreutils)"; done

mkdir -p "$PREBUILT_DIR"; cd "$PREBUILT_DIR"
ok()  { awk -v f="$1" '$2 == f' SHA256SUMS | grep -q . && awk -v f="$1" '$2 == f' SHA256SUMS | sha256sum -c --status - 2>/dev/null; }
get() {  # get FILE: download unless already present and correct; fail on a checksum mismatch
  if ok "$1"; then echo "  $1: already here"; return; fi
  curl -fL --retry 3 -o "$1" "$RELEASE_URL/$1"
  ok "$1" || die "$1: checksum mismatch"
  echo "  $1: OK"
}

step "release $RELEASE_TAG ($RELEASE_URL) -> $PREBUILT_DIR"
curl -fsSL --retry 3 -o SHA256SUMS "$RELEASE_URL/SHA256SUMS"
get boot-oneplus6.img
for f in vendor system; do
  if ok "$f.img"; then echo "  $f.img: already here"; continue; fi
  get "$f.img.zst"
  zstd -d -f --long=27 -q "$f.img.zst" -o "$f.img"
  ok "$f.img" || die "$f.img: checksum mismatch after unpacking"
  echo "  $f.img: OK"
  rm -f "$f.img.zst"
done

echo
echo "Images ready. With the phone in Android (slot A, root adb):"
echo "  export IMAGES_DIR=$PREBUILT_DIR BOOT_IMG=$PREBUILT_DIR/boot-oneplus6.img"
echo "  scripts/10-install.sh && scripts/11-boot-oh.sh && scripts/check-oh.sh"
