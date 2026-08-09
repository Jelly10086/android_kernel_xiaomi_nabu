#!/system/bin/sh

MODDIR=${0%/*}
export BK_CONTROL_DIR=$MODDIR

install_log_exporter()
{
	BK_EXPORT_APK=$MODDIR/bin/bkk-log-exporter.apk
	[ -f "$BK_EXPORT_APK" ] || return 0
	BK_EXPORT_STAGE=/data/local/tmp/bkk-log-exporter.apk
	BK_EXPORT_MARKER=/data/adb/bk-kernel/log-exporter.sha256
	BK_EXPORT_HASH=$(sha256sum "$BK_EXPORT_APK" 2>/dev/null | awk '{ print $1 }')
	BK_EXPORT_TRY=0
	while [ "$BK_EXPORT_TRY" -lt 60 ]; do
		BK_EXPORT_VERSION=$(dumpsys package org.bkkernel.logexport 2>/dev/null | \
			awk -F= '/versionCode=/{ sub(/[[:space:]].*/, "", $2); print $2; exit }')
		BK_INSTALLED_HASH=$(cat "$BK_EXPORT_MARKER" 2>/dev/null)
		if [ "$BK_EXPORT_VERSION" = 2 ] && \
		   [ -n "$BK_EXPORT_HASH" ] && [ "$BK_INSTALLED_HASH" = "$BK_EXPORT_HASH" ]; then
			return 0
		fi
		cp -f "$BK_EXPORT_APK" "$BK_EXPORT_STAGE" 2>/dev/null || true
		chown 2000:2000 "$BK_EXPORT_STAGE" 2>/dev/null || true
		chmod 0644 "$BK_EXPORT_STAGE" 2>/dev/null || true
		restorecon "$BK_EXPORT_STAGE" >/dev/null 2>&1 || true
		if pm install -r --user 0 "$BK_EXPORT_STAGE" >/dev/null 2>&1; then
			printf '%s\n' "$BK_EXPORT_HASH" > "$BK_EXPORT_MARKER"
			rm -f "$BK_EXPORT_STAGE"
			return 0
		fi
		BK_EXPORT_TRY=$((BK_EXPORT_TRY + 1))
		sleep 2
	done
	rm -f "$BK_EXPORT_STAGE"
}

rm -f /data/adb/service.d/bk-reburnout.sh
install_log_exporter &
BK_KEYBOARD_PID_FILE=/data/adb/bk-kernel/bk-keyboard-monitor.pid
BK_KEYBOARD_PID=$(cat "$BK_KEYBOARD_PID_FILE" 2>/dev/null)
case "$BK_KEYBOARD_PID" in
	''|*[!0-9]*) ;;
	*) kill "$BK_KEYBOARD_PID" 2>/dev/null || true ;;
esac
"$MODDIR/bin/bk-keyboard-monitor" &
printf '%s\n' "$!" > "$BK_KEYBOARD_PID_FILE"
"$MODDIR/scripts/bk-wake-guard.sh"
"$MODDIR/bkctl" apply || (
	BK_RETRY=0
	while [ "$BK_RETRY" -lt 30 ]; do
		sleep 1
		"$MODDIR/bkctl" apply && exit 0
		BK_RETRY=$((BK_RETRY + 1))
	done
) &
"$MODDIR/scripts/bk-reburnout.sh"
