#!/system/bin/sh

MODDIR=${0%/*}
export BK_CONTROL_DIR=$MODDIR

rm -f /data/adb/post-fs-data.d/bk-zram-writeback.sh
"$MODDIR/scripts/bk-zram-writeback.sh"
