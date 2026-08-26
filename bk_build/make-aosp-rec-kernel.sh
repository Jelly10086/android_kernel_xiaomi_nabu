#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
AOSP_ROOT=${AOSP_ROOT:-/home/rinnrei/Project/uwuAOSP}
OUT_DIR=${OUT_DIR:-$WORKSPACE/out/aosp-rec-debug}
BOOT_BASE=${BOOT_BASE:-$AOSP_ROOT/out/target/product/nabu/boot.img}
VENDOR_BOOT_BASE=${VENDOR_BOOT_BASE:-$AOSP_ROOT/out/target/product/nabu/vendor_boot-debug.img}
KERNEL=${KERNEL:-$WORKSPACE/out/nabu-4.14.336-b3k1/artifacts/Image.gz}
DTB=${DTB:-$WORKSPACE/out/nabu-4.14.336-b3k1/artifacts/dtb}
CUSTOM_DTBO=${CUSTOM_DTBO:-$WORKSPACE/out/nabu-4.14.336-b3k1/arch/arm64/boot/dts/qcom/nabu-sm8150-overlay.dtbo}
AOSP_DTBO_RAW=${AOSP_DTBO_RAW:-$AOSP_ROOT/out/target/product/nabu/obj/DTBO_OBJ/arch/arm64/boot/dtbo.img}
DEBUG_PANIC_AFTER=${DEBUG_PANIC_AFTER:-}
MKDTBOIMG=${MKDTBOIMG:-$AOSP_ROOT/kernel/xiaomi/nabu/scripts/dtc/libfdt/mkdtboimg.py}
AVBTOOL=${AVBTOOL:-$AOSP_ROOT/out/host/linux-x86/bin/avbtool}
MAGISKBOOT=${MAGISKBOOT:-$WORKSPACE/out/b1-preserve-ramdisk-package/tools/magiskboot}

for input in "$BOOT_BASE" "$VENDOR_BOOT_BASE" "$KERNEL" "$DTB" \
  "$CUSTOM_DTBO" "$AOSP_DTBO_RAW" "$MKDTBOIMG" "$AVBTOOL" "$MAGISKBOOT"; do
  [ -f "$input" ] || { echo "missing input: $input" >&2; exit 2; }
done
[ -x "$MAGISKBOOT" ] || { echo "magiskboot is not executable: $MAGISKBOOT" >&2; exit 2; }

mkdir -p "$OUT_DIR"
OUT_DIR=$(CDPATH= cd -- "$OUT_DIR" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nabu-aosp-rec.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

mkdir -p "$WORK/boot" "$WORK/vendor"
cp "$MAGISKBOOT" "$WORK/boot/magiskboot"
cp "$MAGISKBOOT" "$WORK/vendor/magiskboot"
chmod 0755 "$WORK/boot/magiskboot" "$WORK/vendor/magiskboot"

(
  cd "$WORK/boot"
  ./magiskboot unpack "$BOOT_BASE" >/dev/null
  cp "$KERNEL" kernel
  ./magiskboot repack "$BOOT_BASE" "$OUT_DIR/boot-aosp-rec-debug.img" >/dev/null
)

(
  cd "$WORK/vendor"
  ./magiskboot unpack -h "$VENDOR_BOOT_BASE" >/dev/null
  # The 4.14.336 kernel is built with the matching concatenated nabu DTBs.
  # Keeping the newer AOSP DTB here makes the kernel reach neither init nor adb.
  cp "$DTB" dtb
  ./magiskboot cpio ramdisk.cpio 'extract system/etc/init/hw/init.rc recovery-init.rc' >/dev/null
  sed -i 's#^[[:space:]]*write /proc/sys/kernel/panic_on_oops 1[[:space:]]*$#    write /proc/sys/kernel/panic_on_oops 0#' recovery-init.rc
  ./magiskboot cpio ramdisk.cpio \
    'add 0644 system/etc/init/hw/init.rc recovery-init.rc' >/dev/null
  # Keep init from jumping straight to bootloader/recovery on a service fault;
  # the debug boot must remain reachable long enough to collect logs over adb.
  grep -Eq '^cmdline=.*(^|[[:space:]])androidboot\.init_fatal_reboot_target=recovery([[:space:]]|$)' header || {
    echo "expected init fatal reboot target is missing from vendor_boot cmdline" >&2
    exit 1
  }
  sed -i 's/androidboot\.init_fatal_reboot_target=recovery/androidboot.init_fatal_reboot_target=none/g' header
  # This is the failing-kernel image. It must keep PSTORE_FLAGS_CONSOLE so
  # ramoops records the complete printk stream for the next boot to read.
  sed -i 's/[[:space:]]pstore\.no_console=1\([[:space:]]\|$\)/\1/g' header
  if [ -n "$DEBUG_PANIC_AFTER" ]; then
    case "$DEBUG_PANIC_AFTER" in
      *[!0-9]*|'') echo "DEBUG_PANIC_AFTER must be seconds" >&2; exit 2 ;;
    esac
    sed -i "s#^cmdline=\(.*\)#cmdline=\1 bk.debug_panic_after=$DEBUG_PANIC_AFTER panic=0#" header
  fi
  ./magiskboot repack "$VENDOR_BOOT_BASE" "$OUT_DIR/vendor_boot-aosp-rec-debug.img" >/dev/null
)

validation_index=0
for image in "$OUT_DIR/boot-aosp-rec-debug.img" "$OUT_DIR/vendor_boot-aosp-rec-debug.img"; do
  validation_index=$((validation_index + 1))
  mkdir -p "$WORK/validate-$validation_index"
  (
    cd "$WORK/validate-$validation_index"
    "$MAGISKBOOT" unpack -h "$image" >/dev/null 2>&1
  ) || {
    echo "repacked image failed validation: $image" >&2
    exit 1
  }
done

# Keep the AOSP 13-entry table and replace only nabu's entry (index 10).
# The bootloader expects this table shape and a full-size AVB footer, even on
# unlocked builds.
mkdir -p "$WORK/dtbo"
python3 "$MKDTBOIMG" dump "$AOSP_DTBO_RAW" --dtb "$WORK/dtbo/entry" >/dev/null
cp "$CUSTOM_DTBO" "$WORK/dtbo/entry.10"
python3 "$MKDTBOIMG" create "$WORK/dtbo/composite.img" --page_size=4096 \
  "$WORK/dtbo/entry.0" "$WORK/dtbo/entry.1" "$WORK/dtbo/entry.2" \
  "$WORK/dtbo/entry.3" "$WORK/dtbo/entry.4" "$WORK/dtbo/entry.5" \
  "$WORK/dtbo/entry.6" "$WORK/dtbo/entry.7" "$WORK/dtbo/entry.8" \
  "$WORK/dtbo/entry.9" "$WORK/dtbo/entry.10" "$WORK/dtbo/entry.11" \
  "$WORK/dtbo/entry.12"
cp "$WORK/dtbo/composite.img" "$OUT_DIR/dtbo-aosp-rec-debug.img"
"$AVBTOOL" add_hash_footer --image "$OUT_DIR/dtbo-aosp-rec-debug.img" \
  --partition_size 33554432 --partition_name dtbo --algorithm NONE
python3 "$MKDTBOIMG" dump "$OUT_DIR/dtbo-aosp-rec-debug.img" \
  > "$OUT_DIR/dtbo-aosp-rec-debug.dump"
grep -q 'dt_entry_count = 13' "$OUT_DIR/dtbo-aosp-rec-debug.dump" || {
  echo "composite dtbo image validation failed" >&2
  exit 1
}

grep -q '^    write /proc/sys/kernel/panic_on_oops 0$' "$WORK/vendor/recovery-init.rc" || {
  echo "recovery panic_on_oops override is missing" >&2
  exit 1
}
grep -Eq '^cmdline=.*androidboot\.init_fatal_reboot_target=none([[:space:]]|$)' "$WORK/vendor/header" || {
  echo "init fatal reboot target override is missing" >&2
  exit 1
}
[ -s "$DTB" ] || {
  echo "custom DTB is empty" >&2
  exit 1
}
printf '%s\n' "androidboot.init_fatal_reboot_target=none" > "$OUT_DIR/cmdline-extra.txt"
sha256sum "$OUT_DIR/boot-aosp-rec-debug.img" \
  "$OUT_DIR/vendor_boot-aosp-rec-debug.img" \
  "$OUT_DIR/dtbo-aosp-rec-debug.img" > "$OUT_DIR/SHA256SUMS"
printf '%s\n' "$OUT_DIR/boot-aosp-rec-debug.img" \
  "$OUT_DIR/vendor_boot-aosp-rec-debug.img" "$OUT_DIR/dtbo-aosp-rec-debug.img"
