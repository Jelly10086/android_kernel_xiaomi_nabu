#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -n "${KERNEL_DIR:-}" ]; then
  KERNEL_DIR=$(CDPATH= cd -- "$KERNEL_DIR" && pwd)
else
  KERNEL_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
fi
OUT_DIR=${OUT_DIR:-$KERNEL_DIR/out/nabu-a16}
ARTIFACTS=${ARTIFACTS:-$OUT_DIR/artifacts}
PACKAGE_ROOT=${PACKAGE_ROOT:-$OUT_DIR/packages}
TEMPLATE=$SCRIPT_DIR/anykernel.sh
ANYKERNEL_DIR=$SCRIPT_DIR/anykernel
ANYKERNEL_TOOLS=$ANYKERNEL_DIR/tools
ANYKERNEL_META_INF=$ANYKERNEL_DIR/META-INF

[ -f "$ARTIFACTS/Image.gz" ] || { echo "run build.sh first: Image.gz missing" >&2; exit 2; }
[ -f "$ARTIFACTS/dtb" ] || { echo "run build.sh first: dtb missing" >&2; exit 2; }
[ -f "$ARTIFACTS/dtbo.img" ] || { echo "run build.sh first: dtbo.img missing" >&2; exit 2; }
[ -f "$TEMPLATE" ] || { echo "AnyKernel template missing: $TEMPLATE" >&2; exit 2; }
[ -f "$ANYKERNEL_TOOLS/ak3-core.sh" ] || { echo "AnyKernel3 core missing: $ANYKERNEL_TOOLS/ak3-core.sh" >&2; exit 2; }
[ -f "$ANYKERNEL_META_INF/com/google/android/update-binary" ] || {
  echo "AnyKernel3 update-binary missing under $ANYKERNEL_META_INF" >&2; exit 2;
}
[ -f "$ANYKERNEL_META_INF/com/google/android/updater-script" ] || {
  echo "AnyKernel3 updater-script missing under $ANYKERNEL_META_INF" >&2; exit 2;
}
command -v zip >/dev/null 2>&1 || { echo "zip is required" >&2; exit 2; }
command -v unzip >/dev/null 2>&1 || { echo "unzip is required" >&2; exit 2; }

stamp=$(date -u +%Y%m%d-%H%M%S)
PACKAGE="$PACKAGE_ROOT/bk-Kernel_nabu-A16-Hyper-$stamp"
ZIP_PATH="$PACKAGE.zip"
[ ! -e "$PACKAGE" ] && [ ! -e "$ZIP_PATH" ] || { echo "package already exists: $PACKAGE" >&2; exit 1; }
mkdir -p "$PACKAGE"
cp "$ARTIFACTS/Image.gz" "$PACKAGE/Image.gz"
cp "$ARTIFACTS/dtb" "$PACKAGE/dtb"
cp "$ARTIFACTS/dtbo.img" "$PACKAGE/dtbo.img"
cp "$TEMPLATE" "$PACKAGE/anykernel.sh"
chmod 0755 "$PACKAGE/anykernel.sh"
cp -a "$ANYKERNEL_TOOLS" "$PACKAGE/tools"
cp -a "$ANYKERNEL_META_INF" "$PACKAGE/META-INF"
[ -f "$ARTIFACTS/build-info.txt" ] && cp "$ARTIFACTS/build-info.txt" "$PACKAGE/build-info.txt" || true
[ -f "$ARTIFACTS/SHA256SUMS" ] && cp "$ARTIFACTS/SHA256SUMS" "$PACKAGE/SHA256SUMS" || true

cat > "$PACKAGE/README.txt" <<EOF
Target: Xiaomi nabu
Kernel image: Image.gz
Device trees: sm8150, sm8150p, sm8150p-v2, sm8150-v2 (concatenated as dtb)
Overlay image: dtbo.img
Boot/vendor_boot: handled separately by anykernel.sh.
Required base: boot image matching the installed system; PBRP fastboot boot images are rejected.
EOF
(cd "$PACKAGE" && zip -qr9 "$ZIP_PATH" .)
unzip -t "$ZIP_PATH" >/dev/null
for entry in Image.gz dtb dtbo.img anykernel.sh tools/ak3-core.sh \
  META-INF/com/google/android/update-binary \
  META-INF/com/google/android/updater-script; do
  unzip -Z1 "$ZIP_PATH" | grep -Fx "$entry" >/dev/null || {
    echo "package entry missing: $entry" >&2; exit 1;
  }
done
unzip -p "$ZIP_PATH" anykernel.sh | grep -Fx 'device.name1=nabu' >/dev/null || {
  echo "AnyKernel target is not nabu" >&2; exit 1;
}
expected_kernel_string="kernel.string=bk's kernel"
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -Fx "$expected_kernel_string" >/dev/null || {
    echo "AnyKernel kernel.string is incorrect" >&2; exit 1;
  }
LEGACY_KERNEL_NAME=$(printf '\115\141\150\151\162\157')
if unzip -p "$ZIP_PATH" anykernel.sh | grep -F "$LEGACY_KERNEL_NAME" >/dev/null; then
  echo "legacy kernel string remains in AnyKernel" >&2
  exit 1
fi
unzip -p "$ZIP_PATH" anykernel.sh | grep -Fx 'block=boot;' >/dev/null || {
  echo "boot handling is missing" >&2; exit 1;
}
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -Fx 'patch_cmdline androidboot.force_normal_boot=1' >/dev/null || {
    echo "normal-boot command-line patch is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -F 'PBRP fastboot boot image detected.' >/dev/null || {
    echo "PBRP boot-image guard is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -Fx 'block=/dev/block/bootdevice/by-name/vendor_boot;' >/dev/null || {
    echo "vendor_boot handling is missing" >&2; exit 1;
  }
[ "$(unzip -p "$ZIP_PATH" anykernel.sh | grep -c '^dump_boot;$')" -eq 2 ] || {
  echo "boot/vendor_boot dump steps are incomplete" >&2; exit 1;
}
[ "$(unzip -p "$ZIP_PATH" anykernel.sh | grep -c '^write_boot;$')" -eq 2 ] || {
  echo "boot/vendor_boot write steps are incomplete" >&2; exit 1;
}
(cd "$PACKAGE_ROOT" && sha256sum "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256")
echo "$ZIP_PATH"
