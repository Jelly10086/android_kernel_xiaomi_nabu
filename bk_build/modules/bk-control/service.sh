#!/system/bin/sh

MODDIR=${0%/*}
export BK_CONTROL_DIR=$MODDIR

install_log_exporter()
{
	BK_EXPORT_APK=$MODDIR/bin/bkk-log-exporter.apk
	[ -f "$BK_EXPORT_APK" ] || return 0
	BK_EXPORT_VERSION=$(dumpsys package org.bkkernel.logexport 2>/dev/null | \
		awk -F= '/versionCode=/{ sub(/ .*/, "", $2); print $2; exit }')
	[ "$BK_EXPORT_VERSION" = 1 ] || \
		pm install -r --user 0 "$BK_EXPORT_APK" >/dev/null 2>&1
}

rm -f /data/adb/service.d/bk-reburnout.sh
install_log_exporter
BK_KEYBOARD_PID_FILE=/data/adb/bk-kernel/bk-keyboard-monitor.pid
BK_KEYBOARD_PID=$(cat "$BK_KEYBOARD_PID_FILE" 2>/dev/null)
case "$BK_KEYBOARD_PID" in
	''|*[!0-9]*) ;;
	*) kill "$BK_KEYBOARD_PID" 2>/dev/null || true ;;
esac
"$MODDIR/bin/bk-keyboard-monitor" &
printf '%s\n' "$!" > "$BK_KEYBOARD_PID_FILE"
"$MODDIR/bkctl" apply || (
	BK_RETRY=0
	while [ "$BK_RETRY" -lt 30 ]; do
		sleep 1
		"$MODDIR/bkctl" apply && exit 0
		BK_RETRY=$((BK_RETRY + 1))
	done
) &
"$MODDIR/scripts/bk-reburnout.sh"
