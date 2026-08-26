#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
AOSP_ROOT=${AOSP_ROOT:-/home/rinnrei/Project/uwuAOSP}
OUT_DIR=${OUT_DIR:-$WORKSPACE/out/aosp-pstore-reader}
BOOT_BASE=${BOOT_BASE:-$AOSP_ROOT/out/target/product/nabu/boot.img}
VENDOR_BOOT_BASE=${VENDOR_BOOT_BASE:-$AOSP_ROOT/out/target/product/nabu/vendor_boot.img}
MAGISKBOOT=${MAGISKBOOT:-$WORKSPACE/out/b1-preserve-ramdisk-package/tools/magiskboot}

for input in "$BOOT_BASE" "$VENDOR_BOOT_BASE" "$MAGISKBOOT"; do
  [ -f "$input" ] || { echo "missing input: $input" >&2; exit 2; }
done

mkdir -p "$OUT_DIR"
OUT_DIR=$(CDPATH= cd -- "$OUT_DIR" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nabu-pstore-reader.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$MAGISKBOOT" "$WORK/magiskboot"
chmod 0755 "$WORK/magiskboot"
cp "$BOOT_BASE" "$OUT_DIR/boot-aosp-pstore-reader.img"

(
  cd "$WORK"
  ./magiskboot unpack -h "$VENDOR_BOOT_BASE" >/dev/null
  sed -i 's/androidboot\.init_fatal_reboot_target=recovery/androidboot.init_fatal_reboot_target=none/g' header
  grep -Eq '^cmdline=.*(^|[[:space:]])pstore\.no_console=1([[:space:]]|$)' header || \
    sed -i 's/^cmdline=\(.*\)$/cmdline=\1 pstore.no_console=1/' header
  ./magiskboot repack "$VENDOR_BOOT_BASE" \
    "$OUT_DIR/vendor_boot-aosp-pstore-reader.img" >/dev/null
)

mkdir -p "$WORK/validate"
(
  cd "$WORK/validate"
  "$MAGISKBOOT" unpack -h "$OUT_DIR/vendor_boot-aosp-pstore-reader.img" >/dev/null
  grep -Eq '^cmdline=.*androidboot\.init_fatal_reboot_target=none([[:space:]]|$)' header
  grep -Eq '^cmdline=.*pstore\.no_console=1([[:space:]]|$)' header
) || {
  echo "pstore reader vendor_boot validation failed" >&2
  exit 1
}

sha256sum "$OUT_DIR/boot-aosp-pstore-reader.img" \
  "$OUT_DIR/vendor_boot-aosp-pstore-reader.img" > "$OUT_DIR/SHA256SUMS"
printf '%s\n' "$OUT_DIR/boot-aosp-pstore-reader.img" \
  "$OUT_DIR/vendor_boot-aosp-pstore-reader.img"
