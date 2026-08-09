#!/system/bin/sh

PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin
export PATH
umask 077

STATE_DIR=/data/adb/bk-kernel
PID_FILE=$STATE_DIR/bk-wake-guard.pid
ACTIVE_FILE=$STATE_DIR/bk-wake-guard.active
LOG_FILE=$STATE_DIR/bk-wake-guard.log
SNAPSHOT_DIR=$STATE_DIR/wake-guard-last

guard_log()
{
	printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

screen_on()
{
	BK_BACKLIGHT_FOUND=0
	for BK_BACKLIGHT in /sys/class/backlight/*/actual_brightness \
		/sys/class/backlight/*/brightness \
		/sys/class/leds/lcd-backlight/brightness; do
		[ -r "$BK_BACKLIGHT" ] || continue
		BK_BACKLIGHT_FOUND=1
		BK_BRIGHTNESS=$(cat "$BK_BACKLIGHT" 2>/dev/null)
		case "$BK_BRIGHTNESS" in ''|*[!0-9]*) continue ;; esac
		[ "$BK_BRIGHTNESS" -gt 0 ] && return 0
	done
	[ "$BK_BACKLIGHT_FOUND" -eq 0 ]
}

wait_for_screen()
{
	BK_WAIT=$1
	while [ "$BK_WAIT" -gt 0 ]; do
		sleep 1
		screen_on && return 0
		BK_WAIT=$((BK_WAIT - 1))
	done
	return 1
}

dump_command()
{
	BK_DUMP_FILE=$1
	shift
	"$@" > "$BK_DUMP_FILE" 2>&1 &
	BK_DUMP_PID=$!
	(
		sleep 6
		kill "$BK_DUMP_PID" 2>/dev/null || true
	) &
	BK_TIMER_PID=$!
	wait "$BK_DUMP_PID" 2>/dev/null || true
	kill "$BK_TIMER_PID" 2>/dev/null || true
}

capture_wake_state()
{
	BK_REASON=$1
	rm -rf "$SNAPSHOT_DIR"
	mkdir -p "$SNAPSHOT_DIR" || return 0
	{
		date
		uname -a
		printf 'reason=%s\n' "$BK_REASON"
		printf 'boot_completed=%s\n' "$(getprop sys.boot_completed 2>/dev/null)"
		printf 'systemui=%s\n' "$(pidof com.android.systemui 2>/dev/null)"
		printf 'system_server=%s\n' "$(pidof system_server 2>/dev/null)"
		for BK_NODE in /sys/class/backlight/*/actual_brightness \
			/sys/class/backlight/*/brightness /sys/power/wakeup_count \
			/sys/power/pm_wakeup_irq; do
			[ -r "$BK_NODE" ] && printf '%s=%s\n' "$BK_NODE" "$(cat "$BK_NODE")"
		done
	} > "$SNAPSHOT_DIR/state.txt" 2>&1
	dmesg > "$SNAPSHOT_DIR/dmesg.log" 2>&1 || true
	logcat -b all -d -t 6000 -v threadtime > \
		"$SNAPSHOT_DIR/logcat.log" 2>&1 || true
	dump_command "$SNAPSHOT_DIR/power.txt" dumpsys power
	dump_command "$SNAPSHOT_DIR/display.txt" dumpsys display
}

recover_wake()
{
	[ ! -e "$ACTIVE_FILE" ] || return 0
	: > "$ACTIVE_FILE" || return 0
	trap 'rm -f "$ACTIVE_FILE"' EXIT HUP INT TERM

	[ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] || return 0
	screen_on && return 0
	wait_for_screen 8 && return 0

	guard_log "wake timeout; restarting SystemUI"
	capture_wake_state before-systemui
	BK_SYSTEMUI_PID=$(pidof com.android.systemui 2>/dev/null)
	case "$BK_SYSTEMUI_PID" in
		''|*[!0-9\ ]*) ;;
		*) kill -9 $BK_SYSTEMUI_PID 2>/dev/null || true ;;
	esac
	wait_for_screen 10 && {
		guard_log "wake recovered after SystemUI restart"
		return 0
	}

	guard_log "wake still blocked; restarting Android framework"
	capture_wake_state before-framework
	BK_SYSTEM_SERVER_PID=$(pidof system_server 2>/dev/null)
	case "$BK_SYSTEM_SERVER_PID" in
		''|*[!0-9]*) ;;
		*) kill -9 "$BK_SYSTEM_SERVER_PID" 2>/dev/null || true ;;
	esac
}

find_power_event()
{
	awk '
		/^N: Name="qpnp_pon"$/ { found = 1; next }
		found && /^H: Handlers=/ {
			for (i = 1; i <= NF; i++)
				if ($i ~ /^event[0-9]+$/) {
					print "/dev/input/" $i
					exit
				}
		}
		/^$/ { found = 0 }
	' /proc/bus/input/devices 2>/dev/null
}

daemon_running()
{
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	[ -r "/proc/$1/cmdline" ] || return 1
	case "$(tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null)" in
		*bk-wake-guard.sh*--daemon*) return 0 ;;
	esac
	return 1
}

mkdir -p "$STATE_DIR" || exit 0

if [ "${1:-}" != --daemon ]; then
	BK_OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
	daemon_running "$BK_OLD_PID" && exit 0
	rm -f "$PID_FILE" "$ACTIVE_FILE"
	nohup "$0" --daemon </dev/null >> "$LOG_FILE" 2>&1 &
	exit 0
fi

printf '%s\n' "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE" "$ACTIVE_FILE"; exit 0' EXIT HUP INT TERM
guard_log "started"

while :; do
	POWER_EVENT=$(find_power_event)
	if [ ! -r "$POWER_EVENT" ]; then
		sleep 2
		continue
	fi
	getevent -l "$POWER_EVENT" 2>/dev/null | while IFS= read -r BK_EVENT; do
		case "$BK_EVENT" in
			*EV_KEY*KEY_POWER*DOWN*|*' 0001 0074 00000001'*)
				screen_on || recover_wake &
				;;
		esac
	done
	sleep 2
done
