#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
AOSP_ROOT=${AOSP_ROOT:-/home/rinnrei/Project/uwuAOSP}
OUT_DIR=${OUT_DIR:-$WORKSPACE/out/custom-aosp-dt-debug}
BOOT_BASE=${BOOT_BASE:-$AOSP_ROOT/out/target/product/nabu/boot.img}
VENDOR_BOOT_BASE=${VENDOR_BOOT_BASE:-$AOSP_ROOT/out/target/product/nabu/vendor_boot.img}
KERNEL=${KERNEL:-$WORKSPACE/out/nabu-4.14.336-b3k1/artifacts/Image.gz}
DTB=${DTB:-$WORKSPACE/out/nabu-4.14.336-b3k1/artifacts/dtb}
CUSTOM_DTBO=${CUSTOM_DTBO:-$WORKSPACE/out/nabu-4.14.336-b3k1/arch/arm64/boot/dts/qcom/nabu-sm8150-overlay.dtbo}
AOSP_DTBO_RAW=${AOSP_DTBO_RAW:-$AOSP_ROOT/out/target/product/nabu/obj/DTBO_OBJ/arch/arm64/boot/dtbo.img}
MKDTBOIMG=${MKDTBOIMG:-$AOSP_ROOT/kernel/xiaomi/nabu/scripts/dtc/libfdt/mkdtboimg.py}
AVBTOOL=${AVBTOOL:-$AOSP_ROOT/out/host/linux-x86/bin/avbtool}
DEBUG_PANIC_AFTER=${DEBUG_PANIC_AFTER:-}
MAGISKBOOT=${MAGISKBOOT:-$WORKSPACE/out/b1-preserve-ramdisk-package/tools/magiskboot}

for input in "$BOOT_BASE" "$VENDOR_BOOT_BASE" "$KERNEL" "$DTB" \
  "$CUSTOM_DTBO" "$AOSP_DTBO_RAW" "$MKDTBOIMG" "$AVBTOOL" "$MAGISKBOOT"; do
  [ -f "$input" ] || { echo "missing input: $input" >&2; exit 2; }
done

mkdir -p "$OUT_DIR"
OUT_DIR=$(CDPATH= cd -- "$OUT_DIR" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nabu-custom-aosp-dt.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$MAGISKBOOT" "$WORK/magiskboot"
chmod 0755 "$WORK/magiskboot"

mkdir -p "$WORK/boot" "$WORK/vendor"
(
  cd "$WORK/boot"
  "$WORK/magiskboot" unpack "$BOOT_BASE" >/dev/null
  cp "$KERNEL" kernel
  "$WORK/magiskboot" repack "$BOOT_BASE" "$OUT_DIR/boot-custom-aosp-dt-debug.img" >/dev/null
)

(
  cd "$WORK/vendor"
  "$WORK/magiskboot" unpack -h "$VENDOR_BOOT_BASE" >/dev/null
  cp "$DTB" dtb
  sed -i 's/androidboot\.init_fatal_reboot_target=recovery/androidboot.init_fatal_reboot_target=none/g' header
  sed -i 's/[[:space:]]pstore\.no_console=1\([[:space:]]\|$\)/\1/g' header
  if [ -n "$DEBUG_PANIC_AFTER" ]; then
    case "$DEBUG_PANIC_AFTER" in
      *[!0-9]*|'') echo "DEBUG_PANIC_AFTER must be seconds" >&2; exit 2 ;;
    esac
    sed -i "s#^cmdline=\(.*\)#cmdline=\1 bk.debug_panic_after=$DEBUG_PANIC_AFTER panic=0#" header
  fi
  "$WORK/magiskboot" repack "$VENDOR_BOOT_BASE" \
    "$OUT_DIR/vendor_boot-custom-aosp-dt-debug.img" >/dev/null
)

mkdir -p "$WORK/dtbo"
python3 "$MKDTBOIMG" dump "$AOSP_DTBO_RAW" --dtb "$WORK/dtbo/entry" >/dev/null
cp "$CUSTOM_DTBO" "$WORK/dtbo/entry.10"
python3 "$MKDTBOIMG" create "$WORK/dtbo/composite.img" --page_size=4096 \
  "$WORK/dtbo/entry.0" "$WORK/dtbo/entry.1" "$WORK/dtbo/entry.2" \
  "$WORK/dtbo/entry.3" "$WORK/dtbo/entry.4" "$WORK/dtbo/entry.5" \
  "$WORK/dtbo/entry.6" "$WORK/dtbo/entry.7" "$WORK/dtbo/entry.8" \
  "$WORK/dtbo/entry.9" "$WORK/dtbo/entry.10" "$WORK/dtbo/entry.11" \
  "$WORK/dtbo/entry.12"
cp "$WORK/dtbo/composite.img" "$OUT_DIR/dtbo-custom-aosp-dt-debug.img"
"$AVBTOOL" add_hash_footer --image "$OUT_DIR/dtbo-custom-aosp-dt-debug.img" \
  --partition_size 33554432 --partition_name dtbo --algorithm NONE
python3 "$MKDTBOIMG" dump "$OUT_DIR/dtbo-custom-aosp-dt-debug.img" \
  > "$OUT_DIR/dtbo-custom-aosp-dt-debug.dump"
grep -q 'dt_entry_count = 13' "$OUT_DIR/dtbo-custom-aosp-dt-debug.dump"

mkdir -p "$WORK/validate"
(
  cd "$WORK/validate"
  "$WORK/magiskboot" unpack -h "$OUT_DIR/vendor_boot-custom-aosp-dt-debug.img" >/dev/null
  grep -Eq '^cmdline=.*androidboot\.init_fatal_reboot_target=none([[:space:]]|$)' header
  ! grep -Eq '^cmdline=.*pstore\.no_console=1([[:space:]]|$)' header
  fdtdump dtb 2>/dev/null | grep -q 'console-size = <0x00200000>'
  cmp -s dtb "$DTB"
)

sha256sum "$OUT_DIR/boot-custom-aosp-dt-debug.img" \
  "$OUT_DIR/vendor_boot-custom-aosp-dt-debug.img" \
  "$OUT_DIR/dtbo-custom-aosp-dt-debug.img" > "$OUT_DIR/SHA256SUMS"
printf '%s\n' "$OUT_DIR/boot-custom-aosp-dt-debug.img" \
  "$OUT_DIR/vendor_boot-custom-aosp-dt-debug.img" \
  "$OUT_DIR/dtbo-custom-aosp-dt-debug.img"
