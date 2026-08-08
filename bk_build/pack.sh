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
RECOVERY_DIR=$SCRIPT_DIR/recovery

[ -f "$ARTIFACTS/Image.gz" ] || { echo "run build.sh first: Image.gz missing" >&2; exit 2; }
[ -f "$ARTIFACTS/dtb" ] || { echo "run build.sh first: dtb missing" >&2; exit 2; }
[ -f "$ARTIFACTS/dtbo.img" ] || { echo "run build.sh first: dtbo.img missing" >&2; exit 2; }
[ -f "$TEMPLATE" ] || { echo "AnyKernel template missing: $TEMPLATE" >&2; exit 2; }
[ -f "$ANYKERNEL_TOOLS/ak3-core.sh" ] || { echo "AnyKernel3 core missing: $ANYKERNEL_TOOLS/ak3-core.sh" >&2; exit 2; }
[ -f "$ANYKERNEL_TOOLS/bk-reburnout.sh" ] || { echo "Re.burnout-mode policy missing: $ANYKERNEL_TOOLS/bk-reburnout.sh" >&2; exit 2; }
[ -f "$ANYKERNEL_TOOLS/bk-zram-writeback.sh" ] || { echo "zram writeback policy missing: $ANYKERNEL_TOOLS/bk-zram-writeback.sh" >&2; exit 2; }
[ -x "$ARTIFACTS/bk-zram-setup" ] || { echo "zram setup helper missing: $ARTIFACTS/bk-zram-setup" >&2; exit 2; }
[ -f "$RECOVERY_DIR/ramdisk-recovery.cpio.gz" ] || {
  echo "embedded PBRP ramdisk missing: $RECOVERY_DIR/ramdisk-recovery.cpio.gz" >&2; exit 2;
}
[ "$(sha256sum "$RECOVERY_DIR/ramdisk-recovery.cpio.gz" | awk '{print $1}')" = \
  "248feef8879116c86df1729ecf9595b4be50834dd5bd66fe5732953cafaa4602" ] || {
  echo "embedded PBRP ramdisk checksum mismatch" >&2; exit 2;
}
[ -f "$ANYKERNEL_META_INF/com/google/android/update-binary" ] || {
  echo "AnyKernel3 update-binary missing under $ANYKERNEL_META_INF" >&2; exit 2;
}
[ -f "$ANYKERNEL_META_INF/com/google/android/updater-script" ] || {
  echo "AnyKernel3 updater-script missing under $ANYKERNEL_META_INF" >&2; exit 2;
}
command -v zip >/dev/null 2>&1 || { echo "zip is required" >&2; exit 2; }
command -v unzip >/dev/null 2>&1 || { echo "unzip is required" >&2; exit 2; }

KERNEL_RELEASE=${KERNEL_RELEASE:-}
if [ -z "$KERNEL_RELEASE" ]; then
  [ -r "$OUT_DIR/include/config/kernel.release" ] || {
    echo "kernel release metadata is missing" >&2; exit 2;
  }
  IFS= read -r KERNEL_RELEASE < "$OUT_DIR/include/config/kernel.release"
fi
KERNEL_SUFFIX=${KERNEL_RELEASE##*-}
[ "$KERNEL_SUFFIX" != "$KERNEL_RELEASE" ] || {
  echo "kernel release has no package suffix: $KERNEL_RELEASE" >&2; exit 2;
}
case "$KERNEL_SUFFIX" in
  ''|*[!A-Za-z0-9._-]*)
    echo "invalid package suffix: $KERNEL_SUFFIX" >&2; exit 2 ;;
esac

stamp=$(date -u +%H%M%S)
PACKAGE="$PACKAGE_ROOT/bk-Kernel_nabu-A16-Hyper-$KERNEL_SUFFIX-$stamp"
ZIP_PATH="$PACKAGE.zip"
[ ! -e "$PACKAGE" ] && [ ! -e "$ZIP_PATH" ] || { echo "package already exists: $PACKAGE" >&2; exit 1; }
mkdir -p "$PACKAGE"
cp "$ARTIFACTS/Image.gz" "$PACKAGE/Image.gz"
cp "$ARTIFACTS/dtb" "$PACKAGE/dtb"
cp "$ARTIFACTS/dtbo.img" "$PACKAGE/dtbo.img"
cp "$TEMPLATE" "$PACKAGE/anykernel.sh"
chmod 0755 "$PACKAGE/anykernel.sh"
mkdir -p "$PACKAGE/tools" "$PACKAGE/recovery"
for tool in ak3-core.sh busybox magiskboot bk-reburnout.sh \
  bk-zram-writeback.sh; do
  cp "$ANYKERNEL_TOOLS/$tool" "$PACKAGE/tools/$tool"
done
cp "$ARTIFACTS/bk-zram-setup" "$PACKAGE/tools/bk-zram-setup"
chmod 0755 "$PACKAGE/tools/bk-zram-setup"
cp -a "$ANYKERNEL_META_INF" "$PACKAGE/META-INF"
cp "$RECOVERY_DIR/ramdisk-recovery.cpio.gz" \
  "$PACKAGE/recovery/ramdisk-recovery.cpio.gz"
(cd "$PACKAGE" && zip -qr9 "$ZIP_PATH" .)
unzip -t "$ZIP_PATH" >/dev/null
for entry in Image.gz dtb dtbo.img anykernel.sh tools/ak3-core.sh \
  tools/bk-reburnout.sh tools/bk-zram-writeback.sh tools/bk-zram-setup \
  recovery/ramdisk-recovery.cpio.gz \
  META-INF/com/google/android/update-binary \
  META-INF/com/google/android/updater-script; do
  unzip -Z1 "$ZIP_PATH" | grep -Fx "$entry" >/dev/null || {
    echo "package entry missing: $entry" >&2; exit 1;
  }
done
actual_files=$(unzip -Z1 "$ZIP_PATH" | grep -v '/$' | LC_ALL=C sort)
expected_files=$(printf '%s\n' \
  Image.gz anykernel.sh dtb dtbo.img \
  META-INF/com/google/android/update-binary \
  META-INF/com/google/android/updater-script \
  recovery/ramdisk-recovery.cpio.gz \
  tools/ak3-core.sh tools/bk-reburnout.sh tools/bk-zram-setup \
  tools/bk-zram-writeback.sh tools/busybox tools/magiskboot | LC_ALL=C sort)
[ "$actual_files" = "$expected_files" ] || {
  echo "package contains unexpected or missing files" >&2
  printf '%s\n' "$actual_files" >&2
  exit 1
}
unzip -p "$ZIP_PATH" anykernel.sh | grep -Fx 'device.name1=nabu' >/dev/null || {
  echo "AnyKernel target is not nabu" >&2; exit 1;
}
expected_kernel_string="kernel.string=RinnRei's bk-Kernel / CoolApk @零音Rei"
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -Fx "$expected_kernel_string" >/dev/null || {
    echo "AnyKernel kernel.string is incorrect" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -Fx '  patch_prop "$ramdisk/prop.default" ro.mi.os.custfeatureresolve true;' >/dev/null || {
    echo "HyperOS cust feature service property fix is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -Fx 'reburnout_target=/data/adb/service.d/bk-reburnout.sh;' >/dev/null || {
    echo "Re.burnout-mode installer is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" tools/bk-reburnout.sh | \
  grep -Fx 'REB_MODE_NAME=Re.burnout-mode' >/dev/null || {
    echo "Re.burnout-mode name is incorrect" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -Fx 'zram_script_target=/data/adb/post-fs-data.d/bk-zram-writeback.sh;' >/dev/null || {
    echo "zram post-fs-data installer is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" tools/bk-zram-writeback.sh | \
  grep -Fx 'HELPER=/data/adb/bk-kernel/bk-zram-setup' >/dev/null || {
    echo "zram helper path is incorrect" >&2; exit 1;
  }
zram_elf_magic=$(unzip -p "$ZIP_PATH" tools/bk-zram-setup | \
  dd bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$zram_elf_magic" = "7f454c46" ] || {
  echo "zram setup helper is not ELF" >&2; exit 1;
}
[ "$(unzip -p "$ZIP_PATH" recovery/ramdisk-recovery.cpio.gz | sha256sum | awk '{print $1}')" = \
  "248feef8879116c86df1729ecf9595b4be50834dd5bd66fe5732953cafaa4602" ] || {
  echo "packaged PBRP ramdisk checksum mismatch" >&2; exit 1;
}
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -F 'pbrp_sha256=15ae763c1f5b93ae48bcd007ff1f66871873aaee5b3a32852acbbf75b897fc54;' >/dev/null || {
    echo "PBRP installer checksum is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" tools/bk-reburnout.sh | \
  grep -F 'reb_write /proc/sys/vm/swappiness 180' >/dev/null || {
    echo "swappiness 180 policy is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" tools/bk-reburnout.sh | \
  grep -Fx 'REB_WB_FLUSH_SAMPLES=12' >/dev/null || {
    echo "one-minute zram writeback policy is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" tools/bk-reburnout.sh | \
  grep -Fx 'REB_WB_DAILY_PAGES=65536' >/dev/null || {
    echo "daily zram writeback budget is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" tools/bk-reburnout.sh | \
  grep -F 'reb_write /dev/cpuset/foreground/cpus 0-7' >/dev/null || {
    echo "foreground cpuset policy is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" tools/bk-reburnout.sh | \
  grep -F 'reb_write /dev/cpuset/top-app/cpus 0-7' >/dev/null || {
    echo "top-app cpuset policy is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" tools/bk-reburnout.sh | \
  grep -F 'reb_top_thread_is_heavy()' >/dev/null || {
    echo "top-app heavy-thread policy is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" tools/bk-reburnout.sh | \
  grep -F 'reb_sample_top_cpu()' >/dev/null || {
    echo "top-app CPU sampling is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" tools/bk-reburnout.sh | \
  grep -F 'taskset -p f0 "$REB_PROCESS_PID"' >/dev/null || {
    echo "launcher heavy-thread policy is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" tools/bk-reburnout.sh | \
  grep -F 'SurfaceSyncGrou|AnimThread*|FsGestureSecond)' >/dev/null || {
    echo "launcher heavy-thread list is missing" >&2; exit 1;
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
  grep -Fx 'patch_cmdline androidboot.force_normal_boot ""' >/dev/null || {
    echo "force_normal_boot removal is missing" >&2; exit 1;
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
