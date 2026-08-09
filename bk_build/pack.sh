#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -n "${KERNEL_DIR:-}" ]; then
  KERNEL_DIR=$(CDPATH= cd -- "$KERNEL_DIR" && pwd)
else
  KERNEL_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
fi
OUT_DIR=${OUT_DIR:-/home/rinnrei/Project/uwuAP-temp/out/nabu-4.14.336-b2w1}
ARTIFACTS=${ARTIFACTS:-$OUT_DIR/artifacts}
PACKAGE_ROOT=${PACKAGE_ROOT:-$OUT_DIR/packages}
TEMPLATE=$SCRIPT_DIR/anykernel.sh
ANYKERNEL_DIR=$SCRIPT_DIR/anykernel
ANYKERNEL_TOOLS=$ANYKERNEL_DIR/tools
ANYKERNEL_META_INF=$ANYKERNEL_DIR/META-INF
RECOVERY_DIR=$SCRIPT_DIR/recovery
MODULE_DIR=$SCRIPT_DIR/modules/bk-control

[ -f "$ARTIFACTS/Image.gz" ] || { echo "run build.sh first: Image.gz missing" >&2; exit 2; }
[ -f "$ARTIFACTS/dtb" ] || { echo "run build.sh first: dtb missing" >&2; exit 2; }
[ -f "$ARTIFACTS/dtbo.img" ] || { echo "run build.sh first: dtbo.img missing" >&2; exit 2; }
[ -f "$TEMPLATE" ] || { echo "AnyKernel template missing: $TEMPLATE" >&2; exit 2; }
[ -f "$ANYKERNEL_TOOLS/ak3-core.sh" ] || { echo "AnyKernel3 core missing: $ANYKERNEL_TOOLS/ak3-core.sh" >&2; exit 2; }
[ -f "$ANYKERNEL_TOOLS/bk-reburnout.sh" ] || { echo "Re.burnout-mode policy missing: $ANYKERNEL_TOOLS/bk-reburnout.sh" >&2; exit 2; }
[ -f "$ANYKERNEL_TOOLS/bk-zram-writeback.sh" ] || { echo "zram writeback policy missing: $ANYKERNEL_TOOLS/bk-zram-writeback.sh" >&2; exit 2; }
[ -x "$ARTIFACTS/bk-zram-setup" ] || { echo "zram setup helper missing: $ARTIFACTS/bk-zram-setup" >&2; exit 2; }
[ -x "$ARTIFACTS/bk-keyboard-monitor" ] || { echo "keyboard monitor missing: $ARTIFACTS/bk-keyboard-monitor" >&2; exit 2; }
[ -f "$MODULE_DIR/module.prop" ] || { echo "bk-control module missing: $MODULE_DIR" >&2; exit 2; }
[ -f "$MODULE_DIR/webroot/index.html" ] || { echo "bk-control WebUI missing" >&2; exit 2; }
[ -f "$MODULE_DIR/webroot/bkControl.js" ] || { echo "bk-control WebUI bundle missing" >&2; exit 2; }
[ -f "$MODULE_DIR/webroot/bridge.js" ] || { echo "bk-control WebUI bridge missing" >&2; exit 2; }
[ -f "$MODULE_DIR/webroot/style.css" ] || { echo "bk-control WebUI style missing" >&2; exit 2; }
[ -f "$MODULE_DIR/bin/bkk-log-exporter.apk" ] || { echo "bk-control log exporter missing" >&2; exit 2; }
for webui_resource in \
  composeResources/org.bkkernel.control.generated.resources/drawable/home.svg \
  composeResources/org.bkkernel.control.generated.resources/drawable/policy.svg \
  composeResources/org.bkkernel.control.generated.resources/drawable/save_log.svg \
  composeResources/org.bkkernel.control.generated.resources/font/bk_cjk.ttf; do
  [ -f "$MODULE_DIR/webroot/$webui_resource" ] || {
    echo "bk-control WebUI resource missing: $webui_resource" >&2; exit 2;
  }
done
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
[ "$(grep -c '^export BOOTMODE;$' "$ANYKERNEL_META_INF/com/google/android/update-binary")" -eq 1 ] || {
  echo "AnyKernel3 bootmode export is missing" >&2; exit 2;
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
PACKAGE="$PACKAGE_ROOT/bk-Kernel_nabu-A17-Hyper-$KERNEL_SUFFIX-$stamp"
ZIP_PATH="$PACKAGE.zip"
[ ! -e "$PACKAGE" ] && [ ! -e "$ZIP_PATH" ] || { echo "package already exists: $PACKAGE" >&2; exit 1; }
mkdir -p "$PACKAGE"
cp "$ARTIFACTS/Image.gz" "$PACKAGE/Image.gz"
cp "$ARTIFACTS/dtb" "$PACKAGE/dtb"
cp "$ARTIFACTS/dtbo.img" "$PACKAGE/dtbo.img"
cp "$TEMPLATE" "$PACKAGE/anykernel.sh"
chmod 0755 "$PACKAGE/anykernel.sh"
mkdir -p "$PACKAGE/tools" "$PACKAGE/recovery" "$PACKAGE/module"
for tool in ak3-core.sh busybox magiskboot; do
  cp "$ANYKERNEL_TOOLS/$tool" "$PACKAGE/tools/$tool"
done
cp -a "$MODULE_DIR/." "$PACKAGE/module/"
mkdir -p "$PACKAGE/module/scripts" "$PACKAGE/module/bin"
cp "$ANYKERNEL_TOOLS/bk-reburnout.sh" "$PACKAGE/module/scripts/bk-reburnout.sh"
cp "$ANYKERNEL_TOOLS/bk-zram-writeback.sh" "$PACKAGE/module/scripts/bk-zram-writeback.sh"
cp "$ARTIFACTS/bk-zram-setup" "$PACKAGE/module/bin/bk-zram-setup"
cp "$ARTIFACTS/bk-keyboard-monitor" "$PACKAGE/module/bin/bk-keyboard-monitor"
chmod 0755 "$PACKAGE/module/bkctl" "$PACKAGE/module/service.sh" \
  "$PACKAGE/module/post-fs-data.sh" "$PACKAGE/module/action.sh" \
  "$PACKAGE/module/uninstall.sh" "$PACKAGE/module/scripts/bk-reburnout.sh" \
  "$PACKAGE/module/scripts/bk-zram-writeback.sh" \
  "$PACKAGE/module/bin/bk-zram-setup" \
  "$PACKAGE/module/bin/bk-keyboard-monitor"
cp -a "$ANYKERNEL_META_INF" "$PACKAGE/META-INF"
cp "$RECOVERY_DIR/ramdisk-recovery.cpio.gz" \
  "$PACKAGE/recovery/ramdisk-recovery.cpio.gz"
(cd "$PACKAGE" && zip -qr9 "$ZIP_PATH" .)
unzip -t "$ZIP_PATH" >/dev/null
for entry in Image.gz dtb dtbo.img anykernel.sh tools/ak3-core.sh \
  module/module.prop module/bkctl module/service.sh module/post-fs-data.sh \
  module/webroot/index.html module/webroot/bkControl.js \
  module/webroot/bridge.js module/webroot/style.css \
  module/scripts/bk-reburnout.sh \
  module/scripts/bk-zram-writeback.sh module/bin/bk-zram-setup \
  module/bin/bk-keyboard-monitor \
  module/bin/bkk-log-exporter.apk \
  recovery/ramdisk-recovery.cpio.gz \
  META-INF/com/google/android/update-binary \
  META-INF/com/google/android/updater-script; do
  unzip -Z1 "$ZIP_PATH" | grep -Fx "$entry" >/dev/null || {
    echo "package entry missing: $entry" >&2; exit 1;
  }
done
actual_files=$(unzip -Z1 "$ZIP_PATH" | grep -v '/$' | LC_ALL=C sort)
expected_base=$(printf '%s\n' \
  Image.gz anykernel.sh dtb dtbo.img \
  META-INF/com/google/android/update-binary \
  META-INF/com/google/android/updater-script \
  recovery/ramdisk-recovery.cpio.gz \
  tools/ak3-core.sh tools/busybox tools/magiskboot)
expected_module=$(cd "$PACKAGE" && find module -type f -print)
expected_files=$(printf '%s\n%s\n' "$expected_base" "$expected_module" | LC_ALL=C sort)
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
  grep -F 'patch_prop "$ramdisk/prop.default" ro.mi.os.custfeatureresolve true;' >/dev/null || {
    echo "HyperOS cust feature service property fix is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -Fx 'module_target=/data/adb/modules/bk-control;' >/dev/null || {
    echo "bk-control module installer is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -Fx '  set_perm_recursive 0 0 0755 0644 "$module_target";' >/dev/null || {
    echo "bk-control module permission setup is incorrect" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -Fx 'REB_MODE_NAME=Re.burnout-mode' >/dev/null || {
    echo "Re.burnout-mode name is incorrect" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" module/scripts/bk-zram-writeback.sh | \
  grep -F 'HELPER=${BK_CONTROL_DIR:-/data/adb/modules/bk-control}/bin/bk-zram-setup' >/dev/null || {
    echo "zram helper path is incorrect" >&2; exit 1;
  }
zram_elf_magic=$(unzip -p "$ZIP_PATH" module/bin/bk-zram-setup | \
  dd bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$zram_elf_magic" = "7f454c46" ] || {
  echo "zram setup helper is not ELF" >&2; exit 1;
}
keyboard_elf_magic=$(unzip -p "$ZIP_PATH" module/bin/bk-keyboard-monitor | \
  dd bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$keyboard_elf_magic" = "7f454c46" ] || {
  echo "keyboard monitor is not ELF" >&2; exit 1;
}
[ "$(unzip -p "$ZIP_PATH" recovery/ramdisk-recovery.cpio.gz | sha256sum | awk '{print $1}')" = \
  "248feef8879116c86df1729ecf9595b4be50834dd5bd66fe5732953cafaa4602" ] || {
  echo "packaged PBRP ramdisk checksum mismatch" >&2; exit 1;
}
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -F 'pbrp_sha256=15ae763c1f5b93ae48bcd007ff1f66871873aaee5b3a32852acbbf75b897fc54;' >/dev/null || {
    echo "PBRP installer checksum is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -F 'reb_config_get swappiness 180' >/dev/null || {
    echo "swappiness 180 policy is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -Fx 'REB_WB_FLUSH_SAMPLES=12' >/dev/null || {
    echo "one-minute zram writeback policy is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -Fx 'REB_WB_DAILY_PAGES=65536' >/dev/null || {
    echo "daily zram writeback budget is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -F 'reb_write /dev/cpuset/foreground/cpus 0-2,4-7' >/dev/null || {
    echo "foreground cpuset policy is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -Fx 'REB_TASK_GUARD=6200' >/dev/null || {
    echo "runtime task guard is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -F 'am kill-all >/dev/null 2>&1 || true' >/dev/null || {
    echo "runtime cached-process guard is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -F 'reb_update_perf_taskset()' >/dev/null || {
    echo "offline performance-CPU fallback is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -F 'reb_write /dev/cpuset/top-app/cpus 0-7' >/dev/null || {
    echo "top-app cpuset policy is missing" >&2; exit 1;
  }
if unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -F '> /dev/cpuset/' >/dev/null; then
  echo "runtime policy must not move framework-managed cpuset membership" >&2
  exit 1
fi
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -F 'reb_top_thread_is_heavy()' >/dev/null || {
    echo "top-app heavy-thread policy is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -F 'reb_sample_top_cpu()' >/dev/null || {
    echo "top-app CPU sampling is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
  grep -F 'taskset -p f7 "$REB_PROCESS_PID"' >/dev/null || {
  echo "launcher base affinity policy is missing" >&2; exit 1;
}
unzip -p "$ZIP_PATH" module/bkctl | grep -F 'collect-log)' >/dev/null || {
  echo "bk-control log collector is missing" >&2; exit 1;
}
unzip -p "$ZIP_PATH" module/bkctl | grep -F 'open-log)' >/dev/null || {
  echo "bk-control log exporter bridge is missing" >&2; exit 1;
}
unzip -p "$ZIP_PATH" module/service.sh | grep -F 'org.bkkernel.logexport' >/dev/null || {
  echo "bk-control log exporter installer is missing" >&2; exit 1;
}
unzip -p "$ZIP_PATH" module/bkctl | grep -F 'theme-seed)' >/dev/null || {
  echo "bk-control dynamic color source is missing" >&2; exit 1;
}
unzip -p "$ZIP_PATH" module/webroot/index.html | \
  grep -F '/internal/colors.css' >/dev/null || {
  echo "bk-control dynamic color bridge is missing" >&2; exit 1;
}
unzip -p "$ZIP_PATH" module/scripts/bk-reburnout.sh | \
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
  grep -F 'patch_cmdline androidboot.force_normal_boot ""' >/dev/null || {
    echo "force_normal_boot removal is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -F 'PBRP fastboot boot image detected.' >/dev/null || {
  echo "PBRP boot-image guard is missing" >&2; exit 1;
}
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -Fx '  ui_print "Bootmode install: updating bkk-control only; boot is unchanged.";' >/dev/null || {
  echo "bootmode boot-image guard is missing" >&2; exit 1;
}
unzip -p "$ZIP_PATH" anykernel.sh | \
  grep -F 'block=/dev/block/bootdevice/by-name/vendor_boot;' >/dev/null || {
    echo "vendor_boot handling is missing" >&2; exit 1;
  }
[ "$(unzip -p "$ZIP_PATH" anykernel.sh | grep -c '^[[:space:]]*dump_boot;$')" -eq 2 ] || {
  echo "boot/vendor_boot dump steps are incomplete" >&2; exit 1;
}
[ "$(unzip -p "$ZIP_PATH" anykernel.sh | grep -c '^[[:space:]]*write_boot;$')" -eq 2 ] || {
  echo "boot/vendor_boot write steps are incomplete" >&2; exit 1;
}
(cd "$PACKAGE_ROOT" && sha256sum "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256")
echo "$ZIP_PATH"
