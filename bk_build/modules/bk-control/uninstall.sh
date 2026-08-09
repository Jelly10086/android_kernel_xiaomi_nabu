#!/system/bin/sh

PID_FILE=/data/adb/bk-kernel/Re.burnout-mode.pid
PID=$(cat "$PID_FILE" 2>/dev/null)
case "$PID" in
	''|*[!0-9]*) ;;
	*) kill "$PID" 2>/dev/null || true ;;
esac
PID_FILE=/data/adb/bk-kernel/bk-keyboard-monitor.pid
PID=$(cat "$PID_FILE" 2>/dev/null)
case "$PID" in
	''|*[!0-9]*) ;;
	*) kill "$PID" 2>/dev/null || true ;;
esac
rm -f /data/adb/service.d/bk-reburnout.sh
rm -f /data/adb/post-fs-data.d/bk-zram-writeback.sh
pm uninstall --user 0 org.bkkernel.logexport >/dev/null 2>&1 || true
