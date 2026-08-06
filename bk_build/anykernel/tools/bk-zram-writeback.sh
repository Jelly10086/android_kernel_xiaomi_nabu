#!/system/bin/sh
# Attach Android's per-boot zram backing file before swapon_all initializes it.

PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin
export PATH
umask 077

ZRAM=/sys/block/zram0
HELPER=/data/adb/bk-kernel/bk-zram-setup
LOG=/data/adb/bk-kernel/zram-writeback.log

mkdir -p /data/adb/bk-kernel /data/per_boot || exit 0
printf '%s start\n' "$(date '+%F %T')" > "$LOG"

[ -x "$HELPER" ] || { echo 'helper missing' >> "$LOG"; exit 0; }
[ -r "$ZRAM/disksize" ] || { echo 'zram0 missing' >> "$LOG"; exit 0; }
[ "$(cat "$ZRAM/backing_dev" 2>/dev/null)" = none ] || {
	echo 'zram backing already configured' >> "$LOG"
	exit 0
}
# Leave at least 2 GiB free on userdata.  Failure disables writeback without
# changing the normal in-memory zram setup.
AVAILABLE_KB=$(df -k /data 2>/dev/null | awk 'END { print $4 + 0 }')
[ "$AVAILABLE_KB" -ge 3145728 ] || {
	echo "insufficient free space: ${AVAILABLE_KB}K" >> "$LOG"
	exit 0
}

"$HELPER"
RESULT=$?
printf 'result=%s backing=%s limit=%s enabled=%s\n' \
	"$RESULT" \
	"$(cat "$ZRAM/backing_dev" 2>/dev/null)" \
	"$(cat "$ZRAM/writeback_limit" 2>/dev/null)" \
	"$(cat "$ZRAM/writeback_limit_enable" 2>/dev/null)" >> "$LOG"
exit 0
