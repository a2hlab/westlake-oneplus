#!/bin/bash
# Build the 5.10.194 sdm845 kernel (ohos_port linux-sdm845 + patches/kernel) with the OpenHarmony clang, then put
# its modules into the board's module directory, from where the OH build packs them into system.img.
set -euo pipefail
. "$(dirname "$0")/config.sh"
[ -x "$OH_CLANG_BIN/clang" ] || die "OpenHarmony clang not found at $OH_CLANG_BIN (run 02-prebuilts.sh)"
export PATH="$OH_CLANG_BIN:$PATH"
mkdir -p "$KERNEL_OUT"
# LOCALVERSION= (set but empty) keeps the release at 5.10.194-sdm845 even though the patched tree is "dirty".
K=(make -C "$KERNEL_SRC" O="$KERNEL_OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang HOSTCC=clang LOCALVERSION=
   KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=oneplus6)

step "config: sdm845_ohos_defconfig + patches/kernel/oneplus6.config${STAGING:+ + staged configs ($STAGING)}"
"${K[@]}" sdm845_ohos_defconfig
cat "$REPO_DIR/patches/kernel/oneplus6.config" >> "$KERNEL_OUT/.config"
for t in $STAGING; do
  [ -d "$REPO_DIR/patches/staging/$t" ] || die "no staged topic '$t' in patches/staging"
  for c in "$REPO_DIR/patches/staging/$t/kernel/"*.config; do if [ -f "$c" ]; then cat "$c" >> "$KERNEL_OUT/.config"; fi; done
done
"${K[@]}" olddefconfig
grep -q '^CONFIG_FONT_TER16x32=y' "$KERNEL_OUT/.config" || die "config fragment not applied"

step "Image.gz dtbs modules"
"${K[@]}" -j"$(nproc)" Image.gz dtbs modules
rel=$(cat "$KERNEL_OUT/include/config/kernel.release")
[ "$rel" = "$KERNEL_RELEASE" ] || die "kernel release is $rel, expected $KERNEL_RELEASE"
ls -l "$KERNEL_OUT/arch/arm64/boot/Image.gz" "$KERNEL_OUT/arch/arm64/boot/dts/qcom/sdm845-oneplus-enchilada.dtb"

step "modules -> device/board/oneplus/fajita/modules/$rel"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"${K[@]}" INSTALL_MOD_PATH="$tmp" modules_install >/dev/null
src="$tmp/lib/modules/$rel"; dst="$OH_ROOT/device/board/oneplus/fajita/modules/$rel"
[ -d "$dst" ] || die "$dst missing (is device/board/oneplus synced?)"
# The board installs exactly the files listed in modules_path_194.gni; all of them must exist in this build.
python3 - "$OH_ROOT/device/board/oneplus/fajita/modules/modules_path_194.gni" "$src" "$rel" <<'EOF'
import os, re, sys
listed = re.findall(r'"%s/([^"]+)"' % re.escape(sys.argv[3]), open(sys.argv[1]).read())
missing = [f for f in listed if not os.path.exists(os.path.join(sys.argv[2], f))]
print(f'{len(listed)} files listed by the board, {len(missing)} missing from this kernel build')
for f in missing[:20]: print('  missing', f)
sys.exit(1 if missing else 0)
EOF
rm -rf "$dst/kernel"
cp -a "$src/kernel" "$dst/kernel"
for f in "$src"/modules.*; do cp -a "$f" "$dst/"; done
echo "$rel $(date -u +%FT%TZ)" > "$KERNEL_OUT/.modules-installed"
echo "installed $(find "$dst/kernel" -name '*.ko' | wc -l) modules"
