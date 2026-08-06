#!/sbin/sh
# AnyKernel3 nabu installer.  The packer adds Image.gz, dtb and dtbo.img.
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
patch_cmdline androidboot.force_normal_boot androidboot.force_normal_boot=1
if [ -f "$ramdisk/prop.default" ]; then
  patch_prop "$ramdisk/prop.default" ro.mi.os.custfeatureresolve true;
else
  abort "Missing boot ramdisk prop.default; refusing an incomplete HyperOS fix.";
fi
write_boot;

# vendor_boot is handled as a separate image on Android 12+ devices.
block=/dev/block/bootdevice/by-name/vendor_boot;
is_slot_device=1;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;
reset_ak;
dump_boot;
write_boot;
