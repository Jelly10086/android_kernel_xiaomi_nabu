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
dump_boot;
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

# The stock HyperOS boot header leaves this property empty.  The bootloader
# supplies it for a normal boot and omits it for recovery.  Remove values left
# by older packages so recovery remains reachable.
patch_cmdline androidboot.force_normal_boot ""
if [ -f "$ramdisk/prop.default" ]; then
  patch_prop "$ramdisk/prop.default" ro.mi.os.custfeatureresolve true;
else
  abort "Missing boot ramdisk prop.default; refusing an incomplete HyperOS fix.";
fi

reburnout_source="$home/tools/bk-reburnout.sh";
reburnout_target=/data/adb/service.d/bk-reburnout.sh;
zram_script_source="$home/tools/bk-zram-writeback.sh";
zram_script_target=/data/adb/post-fs-data.d/bk-zram-writeback.sh;
zram_helper_source="$home/tools/bk-zram-setup";
zram_helper_target=/data/adb/bk-kernel/bk-zram-setup;
[ -f "$reburnout_source" ] || abort "Missing Re.burnout-mode runtime policy.";
[ -f "$zram_script_source" ] || abort "Missing zram writeback policy.";
[ -f "$zram_helper_source" ] || abort "Missing zram setup helper.";
[ -d /data/adb ] && [ -w /data/adb ] || \
  abort "Decrypted /data with KernelSU is required for Re.burnout-mode.";
mkdir -p /data/adb/service.d /data/adb/post-fs-data.d /data/adb/bk-kernel || \
  abort "Cannot create KernelSU boot-script directories.";
cp "$reburnout_source" "$reburnout_target" || \
  abort "Cannot install Re.burnout-mode runtime policy.";
cp "$zram_script_source" "$zram_script_target" || \
  abort "Cannot install zram writeback policy.";
cp "$zram_helper_source" "$zram_helper_target" || \
  abort "Cannot install zram setup helper.";
set_perm 0 0 0755 "$reburnout_target";
set_perm 0 0 0755 "$zram_script_target";
set_perm 0 0 0755 "$zram_helper_target";
write_boot;

# vendor_boot is handled as a separate image on Android 12+ devices.
block=/dev/block/bootdevice/by-name/vendor_boot;
is_slot_device=1;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;
reset_ak;
dump_boot;
write_boot;
