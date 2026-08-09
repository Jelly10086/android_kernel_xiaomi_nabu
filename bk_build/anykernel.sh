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
  if { [ -f "$split_img/cmdline.txt" ] && \
       grep -Eq '(^|[[:space:]])twrpfastboot=1([[:space:]]|$)' "$split_img/cmdline.txt"; } || \
     { [ -f "$split_img/header" ] && \
       grep -Eq '^cmdline=.*(^|[[:space:]])twrpfastboot=1([[:space:]]|$)' "$split_img/header"; }; then
    abort "PBRP fastboot boot image detected." \
          "Restore the matching system boot image, then flash this package without rebooting recovery.";
  fi

  pbrp_source="$home/recovery/ramdisk-recovery.cpio.gz";
  pbrp_cpio="$home/ramdisk-recovery.cpio";
  pbrp_sha256=15ae763c1f5b93ae48bcd007ff1f66871873aaee5b3a32852acbbf75b897fc54;
  [ -f "$pbrp_source" ] || abort "Missing embedded PBRP recovery ramdisk.";
  "$bin/magiskboot" decompress "$pbrp_source" "$pbrp_cpio" || \
    abort "Cannot decompress embedded PBRP recovery ramdisk.";
  [ "$(sha256sum "$pbrp_cpio" | awk '{ print $1 }')" = "$pbrp_sha256" ] || \
    abort "Embedded PBRP recovery ramdisk checksum mismatch.";
  [ "$ramdisk" = "$home/ramdisk" ] || abort "Unexpected AnyKernel ramdisk path.";
  rm -rf "$ramdisk";
  mkdir -p "$ramdisk" || abort "Cannot create PBRP ramdisk directory.";
  cd "$ramdisk";
  EXTRACT_UNSAFE_SYMLINKS=1 cpio -d -F "$pbrp_cpio" -i || \
    abort "Cannot extract embedded PBRP recovery ramdisk.";
  cd "$home";
  [ -f "$ramdisk/init" ] && [ -f "$ramdisk/prop.default" ] && \
    [ -f "$ramdisk/twres/ui.xml" ] || abort "Embedded PBRP ramdisk is incomplete.";

  # Keep recovery selection under the bootloader's force_normal_boot property.
  patch_cmdline androidboot.force_normal_boot ""
  if [ -f "$ramdisk/prop.default" ]; then
    patch_prop "$ramdisk/prop.default" ro.mi.os.custfeatureresolve true;
  else
    abort "Missing boot ramdisk prop.default; refusing an incomplete HyperOS fix.";
  fi
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
  write_boot;
fi
