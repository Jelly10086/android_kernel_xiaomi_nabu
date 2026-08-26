#!/sbin/sh
# AnyKernel3 nabu installer; the packer adds Image.gz, dtb and dtbo.img.
properties() { "
kernel.string=RinnRei's bk-Kernel / CoolApk @零音Rei
device.name1=nabu
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
"; }

block=boot;
is_slot_device=1;
ramdisk_compression=auto;
. tools/ak3-core.sh;
if [ "$BOOTMODE" != true ]; then
  dump_boot;
fi
if [ "$BOOTMODE" = true ]; then
  ui_print "Bootmode install: updating bkk-control only; boot is unchanged.";
else
  ui_print "Preserving the installed boot ramdisk.";
  # Keep recoverable Oops/WARN paths even if an older vendor_boot carried
  # debugging panic overrides in its command line.
  patch_cmdline oops=panic ""
  patch_cmdline panic_on_warn=1 ""
fi

module_source="$home/module";
module_target=/data/adb/modules/bk-control;
module_stage=/data/adb/modules/bk-control.new;
[ -f "$module_source/module.prop" ] || abort "Missing bk-control module metadata.";
[ -f "$module_source/service.sh" ] || abort "Missing bk-control service.";
[ -f "$module_source/post-fs-data.sh" ] || abort "Missing bk-control post-fs-data service.";
[ -f "$module_source/webroot/index.html" ] || abort "Missing bk-control WebUI.";
[ -f "$module_source/scripts/bk-reburnout.sh" ] || abort "Missing Re.burnout-mode runtime policy.";
[ -f "$module_source/scripts/bk-zram-writeback.sh" ] || abort "Missing zram writeback policy.";
[ -f "$module_source/scripts/bk-wake-guard.sh" ] || abort "Missing wake guard.";
[ -f "$module_source/bin/bk-zram-setup" ] || abort "Missing zram setup helper.";
[ -f "$module_source/bin/bk-keyboard-monitor" ] || abort "Missing keyboard monitor.";
[ -f "$module_source/bin/bkk-log-exporter.apk" ] || abort "Missing log exporter.";
if [ -d /data/adb ] && [ -w /data/adb ]; then
  mkdir -p /data/adb/modules /data/adb/bk-kernel || \
    abort "Cannot create KernelSU module directories.";
  rm -rf "$module_stage";
  mkdir -p "$module_stage" || abort "Cannot stage bk-control module.";
  cp -R "$module_source/." "$module_stage/" || abort "Cannot copy bk-control module.";
  rm -rf "$module_target";
  mv "$module_stage" "$module_target" || abort "Cannot activate bk-control module.";
  rm -f "$module_target/remove" "$module_target/disable" "$module_target/update";
  set_perm_recursive 0 0 0755 0644 "$module_target";
  set_perm 0 0 0755 "$module_target/bkctl";
  set_perm 0 0 0755 "$module_target/service.sh";
  set_perm 0 0 0755 "$module_target/post-fs-data.sh";
  set_perm 0 0 0755 "$module_target/action.sh";
  set_perm 0 0 0755 "$module_target/uninstall.sh";
  set_perm 0 0 0755 "$module_target/scripts/bk-reburnout.sh";
  set_perm 0 0 0755 "$module_target/scripts/bk-zram-writeback.sh";
  set_perm 0 0 0755 "$module_target/scripts/bk-wake-guard.sh";
  set_perm 0 0 0755 "$module_target/bin/bk-zram-setup";
  set_perm 0 0 0755 "$module_target/bin/bk-keyboard-monitor";
  rm -f /data/adb/service.d/bk-reburnout.sh;
  rm -f /data/adb/post-fs-data.d/bk-zram-writeback.sh;
  rm -f /data/adb/bk-kernel/bk-zram-setup;
else
  ui_print "Decrypted /data is unavailable; bk-control was not installed.";
fi
if [ "$BOOTMODE" != true ]; then
  write_boot;

  # vendor_boot is handled as a separate image on Android 12+ devices.
  block=/dev/block/bootdevice/by-name/vendor_boot;
  is_slot_device=1;
  ramdisk_compression=auto;
  patch_vbmeta_flag=auto;
  reset_ak;
  dump_boot;
  patch_cmdline oops=panic ""
  patch_cmdline panic_on_warn=1 ""
  write_boot;
fi
