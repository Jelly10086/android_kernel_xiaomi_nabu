#!/system/bin/sh
# bk-Kernel runtime policy for nabu. Kernel thermal limits remain authoritative.

PATH=/system/bin:/system/xbin:/vendor/bin
export PATH
umask 077

REB_MODE_NAME=Re.burnout-mode
REB_DIR=/data/adb/bk-kernel
REB_PID_FILE=$REB_DIR/Re.burnout-mode.pid
REB_LOG_FILE=$REB_DIR/Re.burnout-mode.log
REB_STATUS_FILE=$REB_DIR/Re.burnout-mode.status
REB_FORCE_FILE=$REB_DIR/Re.burnout-mode.force
REB_DISABLE_FILE=$REB_DIR/Re.burnout-mode.disabled
REB_RESTORE_FILE=$REB_DIR/Re.burnout-mode.restore
REB_BOOT_FILE=$REB_DIR/Re.burnout-mode.boot_id
REB_WB_STATE_FILE=$REB_DIR/zram-writeback.state
REB_CONFIG_FILE=$REB_DIR/control.conf
REB_PINNED_FILE=$REB_DIR/Re.burnout-mode.top-app
REB_PINNED_TMP=$REB_DIR/Re.burnout-mode.top-app.tmp
REB_UI_TIDS_FILE=$REB_DIR/Re.burnout-mode.ui-tids
REB_UI_TIDS_TMP=$REB_DIR/Re.burnout-mode.ui-tids.tmp
REB_TOP_CPU_FILE=/dev/.bk-reburnout-top-cpu
REB_TOP_CPU_TMP=/dev/.bk-reburnout-top-cpu.tmp
REB_TOP_CPU_SORTED=/dev/.bk-reburnout-top-cpu.sorted
REB_INTERVAL=5
REB_ENTER_SAMPLES=6
REB_EXIT_SAMPLES=12
REB_AUTO_DELAY_SAMPLES=24
REB_CPU_ENTER=85
REB_CPU_EXIT=45
REB_GPU_ENTER=70
REB_GPU_EXIT=35
REB_RUNNABLE_ENTER=7
REB_RUNNABLE_EXIT=3
REB_TASK_GUARD=6200
REB_TASK_GUARD_SAMPLES=2
REB_TASK_GUARD_COOLDOWN_SAMPLES=24
REB_TOUCH_EVENT_CPU_LIMIT=80
REB_TOUCH_EVENT_CPU_SAMPLES=2
REB_TOUCH_EVENT_RESTART_LIMIT=1
REB_WB_FLUSH_SAMPLES=12
REB_WB_DAY_SECONDS=86400
REB_WB_DAILY_PAGES=65536
REB_WB_BACKING_PAGES=262144

reb_log()
{
	printf '%s %s: %s\n' "$(date '+%F %T')" "$REB_MODE_NAME" "$*" >> "$REB_LOG_FILE"
}

reb_write()
{
	[ -w "$1" ] || return 0
	REB_CURRENT_VALUE=
	IFS= read -r REB_CURRENT_VALUE < "$1" 2>/dev/null || true
	[ "$REB_CURRENT_VALUE" = "$2" ] && return 0
	printf '%s\n' "$2" 2>/dev/null > "$1" || true
}

reb_config_get()
{
	REB_CONFIG_VALUE=$2
	[ -r "$REB_CONFIG_FILE" ] || return 0
	while IFS='=' read -r REB_CONFIG_KEY REB_CONFIG_ENTRY; do
		[ "$REB_CONFIG_KEY" = "$1" ] || continue
		REB_CONFIG_VALUE=$REB_CONFIG_ENTRY
		return 0
	done < "$REB_CONFIG_FILE"
}

reb_daemon_running()
{
	[ -n "$1" ] && [ -r "/proc/$1/cmdline" ] || return 1
	case "$(tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null)" in
		*bk-reburnout.sh*--daemon*) return 0 ;;
	esac
	return 1
}

reb_apply_cpuset()
{
	reb_write /dev/cpuset/background/cpus 0-2
	reb_write /dev/cpuset/system-background/cpus 0-2,4-7
	reb_write /dev/cpuset/foreground/cpus 0-2,4-7
	reb_write /dev/cpuset/audio-app/cpus 0-2,4-7
	reb_write /dev/cpuset/top-app/cpus 0-7
}

reb_apply_swappiness()
{
	reb_config_get swappiness 180
	case "$REB_CONFIG_VALUE" in 160|180) ;; *) REB_CONFIG_VALUE=180 ;; esac
	reb_write /proc/sys/vm/swappiness "$REB_CONFIG_VALUE"
	for REB_SWAPPINESS_NODE in \
		/dev/memcg/memory.swappiness \
		/dev/memcg/apps/memory.swappiness \
		/dev/memcg/system/memory.swappiness \
		/sys/fs/cgroup/bg/memory.swappiness; do
		reb_write "$REB_SWAPPINESS_NODE" "$REB_CONFIG_VALUE"
	done
}

reb_apply_little_policy()
{
	REB_LITTLE_POLICY=/sys/devices/system/cpu/cpufreq/policy0
	[ -d "$REB_LITTLE_POLICY" ] || return 0
	reb_write "$REB_LITTLE_POLICY/scaling_governor" schedutil
	reb_write "$REB_LITTLE_POLICY/scaling_min_freq" 672000
	reb_write "$REB_LITTLE_POLICY/schedutil/up_rate_limit_us" 0
	reb_write "$REB_LITTLE_POLICY/schedutil/down_rate_limit_us" 10000
	reb_write "$REB_LITTLE_POLICY/schedutil/hispeed_load" 75
	reb_write "$REB_LITTLE_POLICY/schedutil/hispeed_freq" 1708800
	reb_write "$REB_LITTLE_POLICY/schedutil/pl" 1
}

reb_apply_memory()
{
	# Keep a usable atomic reserve during the QRTR/glink burst at boot.  The
	# stock 9 MiB minimum produced repeatable order-0 allocation failures.
	reb_write /proc/sys/vm/min_free_kbytes 32768
	reb_write /proc/sys/vm/watermark_scale_factor 10
	reb_write /proc/sys/vm/page-cluster 0
	reb_apply_swappiness
}

reb_init_process_reclaim()
{
	REB_RECLAIM_DIR=/sys/module/process_reclaim/parameters
	[ -d "$REB_RECLAIM_DIR" ] || return 0
	reb_write "$REB_RECLAIM_DIR/cancel_process_reclaim" 1
	reb_write "$REB_RECLAIM_DIR/enable_process_reclaim" 0
	reb_write "$REB_RECLAIM_DIR/min_score_adj" 500
	reb_write "$REB_RECLAIM_DIR/per_swap_size" 256
	reb_write "$REB_RECLAIM_DIR/pressure_min" 65
	reb_write "$REB_RECLAIM_DIR/pressure_max" 90
	reb_write "$REB_RECLAIM_DIR/swap_opt_eff" 30
}

reb_process_reclaim_tick()
{
	REB_RECLAIM_DIR=/sys/module/process_reclaim/parameters
	[ -d "$REB_RECLAIM_DIR" ] || return 0
	reb_write "$REB_RECLAIM_DIR/min_score_adj" 500
	reb_write "$REB_RECLAIM_DIR/per_swap_size" 256
	reb_write "$REB_RECLAIM_DIR/pressure_min" 65
	reb_write "$REB_RECLAIM_DIR/pressure_max" 90
	reb_write "$REB_RECLAIM_DIR/swap_opt_eff" 30
	REB_RECLAIM_MEM=$(awk '/^MemAvailable:/ { print $2; exit }' \
		/proc/meminfo 2>/dev/null)
	case "$REB_RECLAIM_MEM" in ''|*[!0-9]*) REB_RECLAIM_MEM=0 ;; esac
	if ! reb_screen_on && [ "$REB_RECLAIM_MEM" -le 2097152 ] && \
	   [ "$REB_CPU_BUSY" -le 35 ] && [ "$REB_GPU_BUSY" -le 10 ] && \
	   [ "$REB_RUNNABLE" -le 2 ]; then
		reb_write "$REB_RECLAIM_DIR/cancel_process_reclaim" 0
		reb_write "$REB_RECLAIM_DIR/enable_process_reclaim" 1
	else
		reb_write "$REB_RECLAIM_DIR/cancel_process_reclaim" 1
		reb_write "$REB_RECLAIM_DIR/enable_process_reclaim" 0
	fi
}

reb_setup_zram_backing()
{
	REB_ZRAM=/sys/block/zram0
	REB_ZRAM_HELPER=${BK_CONTROL_DIR:-/data/adb/modules/bk-control}/bin/bk-zram-setup
	REB_ZRAM_BACKING=$(cat "$REB_ZRAM/backing_dev" 2>/dev/null)
	[ "$REB_ZRAM_BACKING" = none ] || return 0
	[ -x "$REB_ZRAM_HELPER" ] || {
		reb_log "zram backing helper missing"
		return 0
	}
	"$REB_ZRAM_HELPER"
	REB_ZRAM_RESULT=$?
	reb_log "zram backing result=$REB_ZRAM_RESULT backing=$(cat "$REB_ZRAM/backing_dev" 2>/dev/null) limit=$(cat "$REB_ZRAM/writeback_limit" 2>/dev/null) enabled=$(cat "$REB_ZRAM/writeback_limit_enable" 2>/dev/null)"
}

reb_refill_writeback_limit()
{
	[ -n "$REB_BOOT_ID" ] || return 0
	REB_WB_UPTIME=0
	IFS=' .' read -r REB_WB_UPTIME REB_WB_UNUSED < /proc/uptime 2>/dev/null || return 0
	case "$REB_WB_UPTIME" in ''|*[!0-9]*) return 0 ;; esac
	REB_WB_DAY=$((REB_WB_UPTIME / REB_WB_DAY_SECONDS))
	[ "$REB_WB_DAY" -gt 0 ] || return 0

	REB_WB_STATE_BOOT=
	REB_WB_STATE_DAY=-1
	if [ -r "$REB_WB_STATE_FILE" ]; then
		IFS=' ' read -r REB_WB_STATE_BOOT REB_WB_STATE_DAY \
			< "$REB_WB_STATE_FILE" 2>/dev/null || true
	fi
	case "$REB_WB_STATE_DAY" in ''|*[!0-9]*) REB_WB_STATE_DAY=-1 ;; esac
	if [ "$REB_WB_STATE_BOOT" = "$REB_BOOT_ID" ] && \
	   [ "$REB_WB_STATE_DAY" -ge "$REB_WB_DAY" ]; then
		return 0
	fi

	set -- $(cat /sys/block/zram0/bd_stat 2>/dev/null)
	REB_WB_BACKED=${1:-0}
	case "$REB_WB_BACKED" in ''|*[!0-9]*) return 0 ;; esac
	REB_WB_HEADROOM=$((REB_WB_BACKING_PAGES - REB_WB_BACKED))
	[ "$REB_WB_HEADROOM" -gt 0 ] || return 0
	REB_WB_REFILL=$REB_WB_DAILY_PAGES
	[ "$REB_WB_REFILL" -le "$REB_WB_HEADROOM" ] || \
		REB_WB_REFILL=$REB_WB_HEADROOM

	if printf '%s\n' "$REB_WB_REFILL" > \
	   /sys/block/zram0/writeback_limit 2>/dev/null; then
		printf '%s %s\n' "$REB_BOOT_ID" "$REB_WB_DAY" > \
			"$REB_WB_STATE_FILE"
		reb_log "zram daily budget pages=$REB_WB_REFILL bd_pages=$REB_WB_BACKED"
	fi
}

reb_zram_writeback_tick()
{
	REB_ZRAM=/sys/block/zram0
	reb_config_get protected_writeback 1
	[ "$REB_CONFIG_VALUE" = 1 ] || {
		REB_WB_IDLE_COUNT=0
		REB_WB_MARKED=0
		return 0
	}
	REB_ZRAM_BACKING=$(cat "$REB_ZRAM/backing_dev" 2>/dev/null)
	if [ -z "$REB_ZRAM_BACKING" ] || [ "$REB_ZRAM_BACKING" = none ]; then
		REB_WB_IDLE_COUNT=0
		REB_WB_MARKED=0
		return 0
	fi
	if reb_screen_on; then
		REB_WB_IDLE_COUNT=0
		REB_WB_MARKED=0
		return 0
	fi
	REB_MEM_AVAILABLE=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null)
	case "$REB_MEM_AVAILABLE" in ''|*[!0-9]*) REB_MEM_AVAILABLE=0 ;; esac
	if [ "$REB_MEM_AVAILABLE" -gt 2097152 ] || \
	   [ "${REB_CPU_BUSY:-0}" -gt 35 ] || \
	   [ "${REB_GPU_BUSY:-0}" -gt 10 ] || \
	   [ "${REB_RUNNABLE:-0}" -gt 2 ] || \
	   reb_protected_ui_has_swap; then
		REB_WB_IDLE_COUNT=0
		REB_WB_MARKED=0
		return 0
	fi
	REB_ZRAM_LIMIT=$(cat "$REB_ZRAM/writeback_limit" 2>/dev/null)
	case "$REB_ZRAM_LIMIT" in ''|*[!0-9]*) return 0 ;; esac
	if [ "$REB_ZRAM_LIMIT" -eq 0 ]; then
		reb_refill_writeback_limit
		REB_ZRAM_LIMIT=$(cat "$REB_ZRAM/writeback_limit" 2>/dev/null)
		case "$REB_ZRAM_LIMIT" in ''|*[!0-9]*) return 0 ;; esac
	fi
	[ "$REB_ZRAM_LIMIT" -gt 0 ] || return 0

	REB_WB_IDLE_COUNT=$((REB_WB_IDLE_COUNT + 1))
	if [ "$REB_WB_IDLE_COUNT" -eq 1 ]; then
		# Age slots only while the display is off, memory is low and user-facing
		# work is quiet. Protected UI processes are kept out of swap separately.
		printf '%s\n' huge > "$REB_ZRAM/writeback" 2>/dev/null || true
		if printf '%s\n' all > "$REB_ZRAM/idle" 2>/dev/null; then
			REB_WB_MARKED=1
		fi
		reb_log "zram writeback started bd_stat=$(cat "$REB_ZRAM/bd_stat" 2>/dev/null)"
	elif [ "$REB_WB_IDLE_COUNT" -ge "$REB_WB_FLUSH_SAMPLES" ]; then
		if [ "$REB_WB_MARKED" -eq 1 ] && \
		   printf '%s\n' idle > "$REB_ZRAM/writeback" 2>/dev/null; then
			reb_log "zram writeback bd_stat=$(cat "$REB_ZRAM/bd_stat" 2>/dev/null)"
		fi
		REB_WB_IDLE_COUNT=0
		REB_WB_MARKED=0
	fi
}

reb_protected_ui_has_swap()
{
	for REB_PROTECTED_PID in $REB_HOME_PIDS $REB_SYSTEMUI_PIDS; do
		[ -r "/proc/$REB_PROTECTED_PID/status" ] || continue
		REB_PROTECTED_SWAP=$(awk '/^VmSwap:/ { print $2; exit }' \
			"/proc/$REB_PROTECTED_PID/status" 2>/dev/null)
		case "$REB_PROTECTED_SWAP" in ''|*[!0-9]*) continue ;; esac
		[ "$REB_PROTECTED_SWAP" -gt 0 ] && return 0
	done
	return 1
}

reb_read_allowed_list()
{
	REB_ALLOWED_LIST=
	[ -r "/proc/$1/status" ] || return 0
	while IFS= read -r REB_STATUS_LINE; do
		case "$REB_STATUS_LINE" in
			Cpus_allowed_list:*)
				REB_ALLOWED_LIST=${REB_STATUS_LINE#*:}
				set -- $REB_ALLOWED_LIST
				REB_ALLOWED_LIST=${1:-}
				return 0
				;;
		esac
	done < "/proc/$1/status"
}

reb_update_perf_taskset()
{
	REB_PERF_ONLINE=0
	for REB_PERF_CPU in 4 5 6 7; do
		REB_PERF_ONLINE_NODE=/sys/devices/system/cpu/cpu$REB_PERF_CPU/online
		if [ ! -r "$REB_PERF_ONLINE_NODE" ] || \
		   [ "$(cat "$REB_PERF_ONLINE_NODE" 2>/dev/null)" = 1 ]; then
			REB_PERF_ONLINE=$((REB_PERF_ONLINE + 1))
		fi
	done
	if [ "$REB_PERF_ONLINE" -ge 3 ]; then
		REB_NEW_PERF_TASKSET=f0
	else
		REB_NEW_PERF_TASKSET=f7
	fi
	[ "$REB_PERF_TASKSET" = "$REB_NEW_PERF_TASKSET" ] && return 0
	REB_PERF_TASKSET=$REB_NEW_PERF_TASKSET
	REB_LAST_COMPOSER_TASK_COUNT=-1
	REB_LAST_HOME_TASK_COUNT=-1
	REB_LAST_SYSTEMUI_TASK_COUNT=-1
	rm -f "$REB_UI_TIDS_FILE" "$REB_UI_TIDS_TMP"
	reb_log "ui affinity mask=$REB_PERF_TASKSET perf_cpus=$REB_PERF_ONLINE"
}

reb_allowed_matches_perf()
{
	case "$REB_PERF_TASKSET:$REB_ALLOWED_LIST" in
		f0:4*|f0:5*|f0:6*|f0:7*|f7:0-2,4*) return 0 ;;
	esac
	return 1
}

reb_pin_composer()
{
	REB_COMPOSER_PIDS=$(pidof vendor.qti.hardware.display.composer-service 2>/dev/null)
	REB_COMPOSER_TASK_COUNT=0
	REB_COMPOSER_REFRESH=0
	for REB_PROCESS_PID in $REB_COMPOSER_PIDS; do
		for REB_COMPOSER_TASK in /proc/$REB_PROCESS_PID/task/*; do
			[ -d "$REB_COMPOSER_TASK" ] && \
				REB_COMPOSER_TASK_COUNT=$((REB_COMPOSER_TASK_COUNT + 1))
		done
		reb_read_allowed_list "$REB_PROCESS_PID"
		reb_allowed_matches_perf || REB_COMPOSER_REFRESH=1
	done
	if [ "$REB_COMPOSER_PIDS" != "$REB_LAST_COMPOSER_PIDS" ] || \
	   [ "$REB_COMPOSER_TASK_COUNT" -ne "$REB_LAST_COMPOSER_TASK_COUNT" ]; then
		REB_COMPOSER_REFRESH=1
	fi
	[ "$REB_COMPOSER_REFRESH" -eq 1 ] || return 0
	for REB_PROCESS_PID in $REB_COMPOSER_PIDS; do
		taskset -ap "$REB_PERF_TASKSET" "$REB_PROCESS_PID" >/dev/null 2>&1 || true
	done
	REB_LAST_COMPOSER_PIDS=$REB_COMPOSER_PIDS
	REB_LAST_COMPOSER_TASK_COUNT=$REB_COMPOSER_TASK_COUNT
}

reb_pin_home()
{
	# Android owns cpuset membership.  Repeated cgroup moves can block fork.
	REB_HOME_PIDS=$(pidof com.miui.home 2>/dev/null)
	REB_HOME_TASK_COUNT=0
	REB_HOME_REFRESH=0
	for REB_PROCESS_PID in $REB_HOME_PIDS; do
		for REB_HOME_TASK in /proc/$REB_PROCESS_PID/task/*; do
			[ -d "$REB_HOME_TASK" ] && \
				REB_HOME_TASK_COUNT=$((REB_HOME_TASK_COUNT + 1))
		done
		reb_read_allowed_list "$REB_PROCESS_PID"
		case "$REB_ALLOWED_LIST" in
			4*|0-2,4*) ;;
			*) REB_HOME_REFRESH=1 ;;
		esac
	done
	if [ "$REB_HOME_PIDS" != "$REB_LAST_HOME_PIDS" ] || \
	   [ "$REB_HOME_TASK_COUNT" -ne "$REB_LAST_HOME_TASK_COUNT" ]; then
		REB_HOME_REFRESH=1
	fi
	for REB_PROCESS_PID in $REB_HOME_PIDS; do
		if [ "$REB_HOME_REFRESH" -eq 1 ]; then
			if [ "$REB_WIDGET_MODE" -eq 1 ]; then
				taskset -ap "$REB_PERF_TASKSET" "$REB_PROCESS_PID" >/dev/null 2>&1 || true
				taskset -p "$REB_PERF_TASKSET" "$REB_PROCESS_PID" >/dev/null 2>&1 || true
			else
				taskset -ap f7 "$REB_PROCESS_PID" >/dev/null 2>&1 || true
				# Keep launcher input dispatch on the performance cluster.
				taskset -p "$REB_PERF_TASKSET" "$REB_PROCESS_PID" >/dev/null 2>&1 || true
			fi
		fi
		for REB_HOME_TASK in /proc/$REB_PROCESS_PID/task/*; do
			[ -r "$REB_HOME_TASK/comm" ] || continue
			REB_HOME_COMM=
			IFS= read -r REB_HOME_COMM < "$REB_HOME_TASK/comm" 2>/dev/null || true
			case "$REB_HOME_COMM" in
				RenderThread|HwuiTask*|hwuiTask*|HomeShellAnim|\
				SurfaceSyncGrou|AnimThread*|FsGestureSecond)
					reb_read_allowed_list "${REB_HOME_TASK##*/}"
					reb_allowed_matches_perf || \
						taskset -p "$REB_PERF_TASKSET" "${REB_HOME_TASK##*/}" >/dev/null 2>&1 || true
					;;
			esac
		done
	done
	REB_LAST_HOME_PIDS=$REB_HOME_PIDS
	REB_LAST_HOME_TASK_COUNT=$REB_HOME_TASK_COUNT
}

reb_tune_transition_threads()
{
	# Keep SystemUI in its framework-managed cgroup and tune affinity only.
	REB_SYSTEMUI_PIDS=$(pidof com.android.systemui 2>/dev/null)
	REB_SYSTEMUI_TASK_COUNT=0
	REB_SYSTEMUI_REFRESH=0
	for REB_PROCESS_PID in $REB_SYSTEMUI_PIDS; do
		for REB_TASK in /proc/$REB_PROCESS_PID/task/*; do
			[ -d "$REB_TASK" ] && \
				REB_SYSTEMUI_TASK_COUNT=$((REB_SYSTEMUI_TASK_COUNT + 1))
		done
		reb_read_allowed_list "$REB_PROCESS_PID"
		case "$REB_ALLOWED_LIST" in
			0-2,4*) ;;
			*) REB_SYSTEMUI_REFRESH=1 ;;
		esac
	done
	if [ "$REB_SYSTEMUI_PIDS" != "$REB_LAST_SYSTEMUI_PIDS" ] || \
	   [ "$REB_SYSTEMUI_TASK_COUNT" -ne "$REB_LAST_SYSTEMUI_TASK_COUNT" ]; then
		REB_SYSTEMUI_REFRESH=1
	fi
	if [ "$REB_SYSTEMUI_REFRESH" -eq 1 ]; then
		for REB_PROCESS_PID in $REB_SYSTEMUI_PIDS; do
			taskset -ap f7 "$REB_PROCESS_PID" >/dev/null 2>&1 || true
			taskset -p f7 "$REB_PROCESS_PID" >/dev/null 2>&1 || true
		done
		rm -f "$REB_UI_TIDS_FILE" "$REB_UI_TIDS_TMP"
	fi

	: > "$REB_UI_TIDS_TMP"
	for REB_PROCESS_PID in $REB_SYSTEMUI_PIDS; do
		for REB_TASK in /proc/$REB_PROCESS_PID/task/*; do
			[ -r "$REB_TASK/comm" ] || continue
			REB_UI_TID=${REB_TASK##*/}
			REB_UI_COMM=
			IFS= read -r REB_UI_COMM < "$REB_TASK/comm" 2>/dev/null || true
			case "$REB_UI_COMM" in
				wmshell.main|wmshell.anim|miui_wm_sight|doUnLockAppAnim|\
				SurfaceSyncGrou|RenderThread|ControlCenterTr) ;;
				*) continue ;;
			esac
			printf '%s\n' "$REB_UI_TID" >> "$REB_UI_TIDS_TMP"
			REB_UI_ALLOWED=$(awk '/^Cpus_allowed_list:/ { print $2; exit }' \
				"$REB_TASK/status" 2>/dev/null)
			REB_ALLOWED_LIST=$REB_UI_ALLOWED
			if ! grep -qx "$REB_UI_TID" "$REB_UI_TIDS_FILE" 2>/dev/null || \
			   ! reb_allowed_matches_perf; then
				# Keep transition workers on the usable performance set.
				taskset -p "$REB_PERF_TASKSET" "$REB_UI_TID" >/dev/null 2>&1 || true
			fi
		done
	done
	mv -f "$REB_UI_TIDS_TMP" "$REB_UI_TIDS_FILE"
	REB_LAST_SYSTEMUI_PIDS=$REB_SYSTEMUI_PIDS
	REB_LAST_SYSTEMUI_TASK_COUNT=$REB_SYSTEMUI_TASK_COUNT
}

reb_tune_audio()
{
	reb_config_get audio_boost 1
	[ "$REB_CONFIG_VALUE" = 1 ] || return 0
	for REB_AUDIO_PID in $(pidof audioserver android.hardware.audio.service 2>/dev/null); do
		[ -d "/proc/$REB_AUDIO_PID/task" ] || continue
		taskset -p f7 "$REB_AUDIO_PID" >/dev/null 2>&1 || true
		for REB_AUDIO_TASK in /proc/$REB_AUDIO_PID/task/*; do
			[ -r "$REB_AUDIO_TASK/comm" ] || continue
			REB_AUDIO_TID=${REB_AUDIO_TASK##*/}
			REB_AUDIO_COMM=
			IFS= read -r REB_AUDIO_COMM < "$REB_AUDIO_TASK/comm" 2>/dev/null || true
			case "$REB_AUDIO_COMM" in
				FastMixer|AudioOut*|AudioFlinger*|ApmAudio|ApmOutput|effect|writer)
					reb_read_allowed_list "$REB_AUDIO_TID"
					reb_allowed_matches_perf || \
						taskset -p "$REB_PERF_TASKSET" "$REB_AUDIO_TID" >/dev/null 2>&1 || true
					;;
			esac
		done
	done
}

reb_widget_boost_tick()
{
	reb_config_get widget_boost 1
	if [ "$REB_CONFIG_VALUE" != 1 ] || [ -z "$REB_HOME_PIDS" ]; then
		REB_WIDGET_MODE=0
		REB_WIDGET_HIGH_COUNT=0
		REB_WIDGET_LOW_COUNT=0
		REB_HOME_PREV_JIFFIES=
		return 0
	fi

	set -- $REB_HOME_PIDS
	REB_WIDGET_HOME_PID=${1:-}
	[ -r "/proc/$REB_WIDGET_HOME_PID/stat" ] || return 0
	REB_WIDGET_ADJ=$(cat "/proc/$REB_WIDGET_HOME_PID/oom_score_adj" 2>/dev/null)
	case "$REB_WIDGET_ADJ" in ''|*[!0-9-]*) REB_WIDGET_ADJ=1000 ;; esac
	REB_TOP_STAT=
	IFS= read -r REB_TOP_STAT < "/proc/$REB_WIDGET_HOME_PID/stat" 2>/dev/null || return 0
	REB_TOP_STAT=${REB_TOP_STAT#*) }
	set -- $REB_TOP_STAT
	[ "$#" -ge 13 ] || return 0
	REB_HOME_JIFFIES=$((${12} + ${13}))
	if [ -n "$REB_HOME_PREV_JIFFIES" ]; then
		REB_HOME_DELTA=$((REB_HOME_JIFFIES - REB_HOME_PREV_JIFFIES))
	else
		REB_HOME_DELTA=0
	fi
	REB_HOME_PREV_JIFFIES=$REB_HOME_JIFFIES

	if [ "$REB_WIDGET_ADJ" -le 0 ] && [ "$REB_HOME_DELTA" -ge 25 ]; then
		REB_WIDGET_HIGH_COUNT=$((REB_WIDGET_HIGH_COUNT + 1))
		REB_WIDGET_LOW_COUNT=0
	else
		REB_WIDGET_HIGH_COUNT=0
		REB_WIDGET_LOW_COUNT=$((REB_WIDGET_LOW_COUNT + 1))
	fi

	if [ "$REB_WIDGET_MODE" -eq 0 ] && [ "$REB_WIDGET_HIGH_COUNT" -ge 1 ]; then
		REB_WIDGET_MODE=1
		reb_log "widget boost enabled pid=$REB_WIDGET_HOME_PID delta=$REB_HOME_DELTA"
	elif [ "$REB_WIDGET_MODE" -eq 1 ] && [ "$REB_WIDGET_LOW_COUNT" -ge 3 ]; then
		REB_WIDGET_MODE=0
		reb_log "widget boost disabled"
		for REB_PROCESS_PID in $REB_HOME_PIDS; do
			taskset -ap f7 "$REB_PROCESS_PID" >/dev/null 2>&1 || true
		done
		REB_LAST_HOME_TASK_COUNT=-1
	fi

	if [ "$REB_WIDGET_MODE" -eq 1 ]; then
		for REB_PROCESS_PID in $REB_HOME_PIDS; do
			taskset -ap "$REB_PERF_TASKSET" "$REB_PROCESS_PID" >/dev/null 2>&1 || true
		done
	fi
}

reb_pin_ui()
{
	reb_update_perf_taskset
	reb_pin_composer
	REB_HOME_PIDS=$(pidof com.miui.home 2>/dev/null)
	reb_widget_boost_tick
	reb_pin_home
	reb_tune_transition_threads
	reb_tune_audio
}

reb_apply_base()
{
	reb_apply_cpuset
	reb_apply_memory
	reb_apply_little_policy
}

reb_read_tid_identity()
{
	REB_TOP_TGID=
	REB_TOP_COMM=
	[ -r "/proc/$1/status" ] && [ -r "/proc/$1/comm" ] || return 1
	IFS= read -r REB_TOP_COMM < "/proc/$1/comm" 2>/dev/null || return 1
	while IFS= read -r REB_STATUS_LINE; do
		case "$REB_STATUS_LINE" in
			Tgid:*)
				REB_TOP_TGID=${REB_STATUS_LINE#*:}
				set -- $REB_TOP_TGID
				REB_TOP_TGID=${1:-}
				break
				;;
		esac
	done < "/proc/$1/status"
	case "$REB_TOP_TGID" in ''|*[!0-9]*) return 1 ;; esac
	return 0
}

reb_managed_ui_tgid()
{
	for REB_UI_PID in $REB_HOME_PIDS $REB_SYSTEMUI_PIDS $REB_COMPOSER_PIDS; do
		[ "$1" = "$REB_UI_PID" ] && return 0
	done
	return 1
}

reb_top_thread_is_heavy()
{
	[ "$REB_TOP_TID" = "$REB_TOP_TGID" ] && return 0
	case "$REB_TOP_COMM" in
		RenderThread|HwuiTask*|hwuiTask*|GLThread*|UnityMain|\
		UnityGfxDeviceW|GameThread|RHIThread|UE4|UnrealThread*|\
		GLES*|Vulkan*|VkThread*) return 0 ;;
	esac
	return 1
}

reb_read_cpu_jiffies()
{
	REB_TOP_STAT=
	REB_TOP_JIFFIES=
	IFS= read -r REB_TOP_STAT < "/proc/$1/task/$2/stat" 2>/dev/null || return 1
	REB_TOP_STAT=${REB_TOP_STAT#*) }
	set -- $REB_TOP_STAT
	[ "$#" -ge 13 ] || return 1
	case "${12}" in ''|*[!0-9]*) return 1 ;; esac
	case "${13}" in ''|*[!0-9]*) return 1 ;; esac
	REB_TOP_JIFFIES=$((${12} + ${13}))
}

reb_sample_top_cpu()
{
	REB_TOP_CPU_TIDS=
	: > "$REB_TOP_CPU_TMP"
	while IFS= read -r REB_TOP_TID; do
		case "$REB_TOP_TID" in ''|*[!0-9]*) continue ;; esac
		reb_read_tid_identity "$REB_TOP_TID" || continue
		reb_managed_ui_tgid "$REB_TOP_TGID" && continue
		reb_read_cpu_jiffies "$REB_TOP_TGID" "$REB_TOP_TID" || continue
		printf '%s %s\n' "$REB_TOP_TID" "$REB_TOP_JIFFIES" >> "$REB_TOP_CPU_TMP"
	done < /dev/cpuset/top-app/tasks
	sort -n "$REB_TOP_CPU_TMP" > "$REB_TOP_CPU_SORTED"
	if [ -s "$REB_TOP_CPU_FILE" ]; then
		REB_TOP_CPU_TIDS=$(awk 'NR == FNR { old[$1] = $2; next }
			($1 in old) && $2 > old[$1] { print $2 - old[$1], $1 }' \
			"$REB_TOP_CPU_FILE" "$REB_TOP_CPU_SORTED" | \
			sort -nr | head -n 2 | awk '{ print $2 }')
	fi
	mv -f "$REB_TOP_CPU_SORTED" "$REB_TOP_CPU_FILE"
}

reb_tid_is_cpu_heavy()
{
	for REB_CPU_TID in $REB_TOP_CPU_TIDS; do
		[ "$1" = "$REB_CPU_TID" ] && return 0
	done
	return 1
}

reb_refresh_top_app()
{
	[ -r /dev/cpuset/top-app/tasks ] || return 0
	reb_sample_top_cpu
	: > "$REB_PINNED_TMP"
	while IFS= read -r REB_TOP_TID; do
		case "$REB_TOP_TID" in ''|*[!0-9]*) continue ;; esac
		reb_read_tid_identity "$REB_TOP_TID" || continue
		reb_managed_ui_tgid "$REB_TOP_TGID" && continue
		reb_top_thread_is_heavy || \
			reb_tid_is_cpu_heavy "$REB_TOP_TID" || continue
		reb_read_allowed_list "$REB_TOP_TID"
		reb_allowed_matches_perf || \
			taskset -p "$REB_PERF_TASKSET" "$REB_TOP_TID" >/dev/null 2>&1 || continue
		printf '%s\n' "$REB_TOP_TID" >> "$REB_PINNED_TMP"
	done < /dev/cpuset/top-app/tasks
	if [ -r "$REB_PINNED_FILE" ]; then
		while IFS= read -r REB_OLD_TID; do
			case "$REB_OLD_TID" in ''|*[!0-9]*) continue ;; esac
			grep -qx "$REB_OLD_TID" "$REB_PINNED_TMP" 2>/dev/null && continue
			[ -d "/proc/$REB_OLD_TID" ] && \
				taskset -p ff "$REB_OLD_TID" >/dev/null 2>&1 || true
		done < "$REB_PINNED_FILE"
	fi
	mv -f "$REB_PINNED_TMP" "$REB_PINNED_FILE"
}

reb_restore_top_app()
{
	if [ -r "$REB_PINNED_FILE" ]; then
		while IFS= read -r REB_TOP_TID; do
			case "$REB_TOP_TID" in ''|*[!0-9]*) continue ;; esac
			[ -d "/proc/$REB_TOP_TID" ] && \
				taskset -p ff "$REB_TOP_TID" >/dev/null 2>&1 || true
		done < "$REB_PINNED_FILE"
	fi
	rm -f "$REB_PINNED_FILE" "$REB_PINNED_TMP"
	rm -f "$REB_UI_TIDS_FILE" "$REB_UI_TIDS_TMP"
	rm -f "$REB_TOP_CPU_FILE" "$REB_TOP_CPU_TMP" "$REB_TOP_CPU_SORTED"
	reb_screen_on && reb_pin_ui
}

reb_save_node()
{
	[ -r "$1" ] && [ -w "$1" ] || return 0
	REB_SAVED_VALUE=$(cat "$1" 2>/dev/null) || return 0
	printf '%s|%s\n' "$1" "$REB_SAVED_VALUE" >> "$REB_RESTORE_FILE"
}

reb_save_devfreq_min()
{
	[ -r "$1/min_freq" ] && [ -w "$1/min_freq" ] || return 0
	REB_SAVED_VALUE=$(awk '{ print $1; exit }' \
		"$1/available_frequencies" 2>/dev/null)
	case "$REB_SAVED_VALUE" in
		''|*[!0-9]*) REB_SAVED_VALUE=$(cat "$1/min_freq" 2>/dev/null) ;;
	esac
	[ -n "$REB_SAVED_VALUE" ] && \
		printf '%s|%s\n' "$1/min_freq" "$REB_SAVED_VALUE" >> "$REB_RESTORE_FILE"
}

reb_save_mode_nodes()
{
	: > "$REB_RESTORE_FILE"
	printf '%s\n' "$REB_BOOT_ID" > "$REB_BOOT_FILE"

	for REB_POLICY in /sys/devices/system/cpu/cpufreq/policy*; do
		reb_save_node "$REB_POLICY/scaling_governor"
	done
	reb_save_node /sys/class/kgsl/kgsl-3d0/devfreq/min_freq
	reb_save_node /sys/class/devfreq/1d84000.ufshc/governor
	reb_save_devfreq_min /sys/class/devfreq/1d84000.ufshc

	REB_UFS=/sys/devices/platform/soc/1d84000.ufshc
	for REB_UFS_NODE in max_bus_bw; do
		reb_save_node "$REB_UFS/$REB_UFS_NODE"
	done

	for REB_BUS in \
		/sys/class/devfreq/soc:qcom,cpu-cpu-llcc-bw \
		/sys/class/devfreq/soc:qcom,cpu-llcc-ddr-bw \
		/sys/class/devfreq/soc:qcom,cpu*-cpu-l3-lat \
		/sys/class/devfreq/soc:qcom,cpu*-cpu-llcc-lat \
		/sys/class/devfreq/soc:qcom,cpu*-llcc-ddr-lat \
		/sys/class/devfreq/soc:qcom,cpu*-cpu-ddr-latfloor \
		/sys/class/devfreq/soc:qcom,gpubw; do
		if [ -d "$REB_BUS" ]; then
			reb_save_node "$REB_BUS/governor"
			reb_save_devfreq_min "$REB_BUS"
		fi
	done
}

reb_enforce_mode_nodes()
{
	for REB_POLICY in /sys/devices/system/cpu/cpufreq/policy*; do
		reb_write "$REB_POLICY/scaling_governor" performance
	done
	REB_GPU_MAX=$(cat /sys/class/kgsl/kgsl-3d0/devfreq/max_freq 2>/dev/null)
	case "$REB_GPU_MAX" in
		''|*[!0-9]*) ;;
		*) reb_write /sys/class/kgsl/kgsl-3d0/devfreq/min_freq "$REB_GPU_MAX" ;;
	esac
	REB_UFS_DEVFREQ=/sys/class/devfreq/1d84000.ufshc
	REB_UFS_MAX=$(cat "$REB_UFS_DEVFREQ/max_freq" 2>/dev/null)
	case "$REB_UFS_MAX" in
		''|*[!0-9]*) ;;
		*) reb_write "$REB_UFS_DEVFREQ/min_freq" "$REB_UFS_MAX" ;;
	esac

	REB_UFS=/sys/devices/platform/soc/1d84000.ufshc
	reb_write "$REB_UFS/max_bus_bw" 1

	for REB_BUS in \
		/sys/class/devfreq/soc:qcom,cpu-cpu-llcc-bw \
		/sys/class/devfreq/soc:qcom,cpu-llcc-ddr-bw \
		/sys/class/devfreq/soc:qcom,cpu*-cpu-l3-lat \
		/sys/class/devfreq/soc:qcom,cpu*-cpu-llcc-lat \
		/sys/class/devfreq/soc:qcom,cpu*-llcc-ddr-lat \
		/sys/class/devfreq/soc:qcom,cpu*-cpu-ddr-latfloor \
		/sys/class/devfreq/soc:qcom,gpubw; do
		[ -r "$REB_BUS/max_freq" ] || continue
		case "${REB_BUS##*/}" in
			soc:qcom,gpubw)
				# bw_vbif cannot be reattached after switching away on this
				# driver.  Its minimum vote alone locks GPU bandwidth safely.
				;;
			*) reb_write "$REB_BUS/governor" performance ;;
		esac
		REB_BUS_MAX=$(cat "$REB_BUS/max_freq" 2>/dev/null)
		case "$REB_BUS_MAX" in ''|*[!0-9]*) continue ;; esac
		[ "$REB_BUS_MAX" -gt 0 ] && reb_write "$REB_BUS/min_freq" "$REB_BUS_MAX"
	done
}

reb_restore_mode_nodes()
{
	if [ -r "$REB_RESTORE_FILE" ]; then
		while IFS='|' read -r REB_RESTORE_NODE REB_RESTORE_VALUE; do
			[ -n "$REB_RESTORE_NODE" ] && \
				reb_write "$REB_RESTORE_NODE" "$REB_RESTORE_VALUE"
		done < "$REB_RESTORE_FILE"
	fi
	rm -f "$REB_RESTORE_FILE" "$REB_BOOT_FILE"
}

reb_enter_mode()
{
	[ "$REB_MODE" -eq 0 ] || return 0
	reb_save_mode_nodes
	REB_MODE=1
	reb_enforce_mode_nodes
	reb_log "enabled cpu=$REB_CPU_BUSY gpu=$REB_GPU_BUSY temp_mC=$REB_TEMP runnable=$REB_RUNNABLE"
}

reb_leave_mode()
{
	[ "$REB_MODE" -eq 1 ] || return 0
	reb_restore_top_app
	reb_restore_mode_nodes
	REB_MODE=0
	reb_apply_base
	reb_log "disabled"
}

reb_read_cpu_sample()
{
	awk '/^cpu / { idle=$5+$6; total=0; for (i=2; i<=NF; i++) total+=$i; printf "%.0f %.0f\n", total, idle; exit }' /proc/stat
}

reb_touchevent_guard_tick()
{
	REB_TOUCH_PID=$(pidof toucheventcheck 2>/dev/null)
	set -- $REB_TOUCH_PID
	REB_TOUCH_PID=${1:-}
	case "$REB_TOUCH_PID" in
		''|*[!0-9]*)
			REB_TOUCH_LAST_PID=
			REB_TOUCH_LAST_JIFFIES=
			REB_TOUCH_HIGH_COUNT=0
			return 0
			;;
	esac

	REB_TOUCH_JIFFIES=0
	for REB_TOUCH_TASK_STAT in /proc/$REB_TOUCH_PID/task/*/stat; do
		[ -r "$REB_TOUCH_TASK_STAT" ] || continue
		REB_TOUCH_STAT=
		IFS= read -r REB_TOUCH_STAT < "$REB_TOUCH_TASK_STAT" 2>/dev/null || continue
		REB_TOUCH_STAT=${REB_TOUCH_STAT#*) }
		set -- $REB_TOUCH_STAT
		[ "$#" -ge 13 ] || continue
		case "${12}" in ''|*[!0-9]*) continue ;; esac
		case "${13}" in ''|*[!0-9]*) continue ;; esac
		REB_TOUCH_JIFFIES=$((REB_TOUCH_JIFFIES + ${12} + ${13}))
	done

	if [ "$REB_TOUCH_PID" = "$REB_TOUCH_LAST_PID" ] && \
	   [ -n "$REB_TOUCH_LAST_JIFFIES" ] && [ "$REB_DELTA_TOTAL" -gt 0 ]; then
		REB_TOUCH_DELTA=$((REB_TOUCH_JIFFIES - REB_TOUCH_LAST_JIFFIES))
		[ "$REB_TOUCH_DELTA" -ge 0 ] || REB_TOUCH_DELTA=0
		REB_TOUCH_CPU=$((800 * REB_TOUCH_DELTA / REB_DELTA_TOTAL))
		if [ "$REB_TOUCH_CPU" -ge "$REB_TOUCH_EVENT_CPU_LIMIT" ]; then
			REB_TOUCH_HIGH_COUNT=$((REB_TOUCH_HIGH_COUNT + 1))
		else
			REB_TOUCH_HIGH_COUNT=0
		fi
		if [ "$REB_TOUCH_HIGH_COUNT" -ge "$REB_TOUCH_EVENT_CPU_SAMPLES" ]; then
			setprop ctl.stop toucheventcheck 2>/dev/null || true
			kill "$REB_TOUCH_PID" 2>/dev/null || true
			if [ "$REB_TOUCH_RESTARTS" -lt "$REB_TOUCH_EVENT_RESTART_LIMIT" ] && \
			   [ -r /sys/class/touch/touch_dev/suspend_state ]; then
				REB_TOUCH_RESTARTS=$((REB_TOUCH_RESTARTS + 1))
				reb_log "restarted runaway toucheventcheck pid=$REB_TOUCH_PID cpu=$REB_TOUCH_CPU attempt=$REB_TOUCH_RESTARTS"
				sleep 1
				setprop ctl.start toucheventcheck 2>/dev/null || true
			else
				reb_log "stopped runaway toucheventcheck pid=$REB_TOUCH_PID cpu=$REB_TOUCH_CPU"
			fi
			REB_TOUCH_LAST_PID=
			REB_TOUCH_LAST_JIFFIES=
			REB_TOUCH_HIGH_COUNT=0
			return 0
		fi
	fi
	REB_TOUCH_LAST_PID=$REB_TOUCH_PID
	REB_TOUCH_LAST_JIFFIES=$REB_TOUCH_JIFFIES
}

reb_gpu_busy()
{
	awk '{ print $1 + 0; exit }' /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null
}

reb_load_sample()
{
	awk '{ split($4, value, "/"); print value[1] + 0, value[2] + 0; exit }' \
		/proc/loadavg 2>/dev/null
}

reb_max_temp()
{
	REB_MAX_TEMP=0
	for REB_ZONE in /sys/class/thermal/thermal_zone*; do
		REB_ZONE_TYPE=$(cat "$REB_ZONE/type" 2>/dev/null)
		case "$REB_ZONE_TYPE" in
			cpu-*-usr|gpuss-*-usr|cpu_therm) ;;
			*) continue ;;
		esac
		REB_ZONE_TEMP=$(cat "$REB_ZONE/temp" 2>/dev/null)
		case "$REB_ZONE_TEMP" in ''|*[!0-9]*) continue ;; esac
		[ "$REB_ZONE_TEMP" -le 150000 ] || continue
		[ "$REB_ZONE_TEMP" -gt "$REB_MAX_TEMP" ] && REB_MAX_TEMP=$REB_ZONE_TEMP
	done
	printf '%s\n' "$REB_MAX_TEMP"
}

reb_screen_on()
{
	REB_BACKLIGHT_FOUND=0
	for REB_BACKLIGHT in /sys/class/backlight/*/brightness \
		/sys/class/leds/lcd-backlight/brightness; do
		[ -r "$REB_BACKLIGHT" ] || continue
		REB_BACKLIGHT_FOUND=1
		REB_BRIGHTNESS=$(cat "$REB_BACKLIGHT" 2>/dev/null)
		case "$REB_BRIGHTNESS" in ''|*[!0-9]*) continue ;; esac
		[ "$REB_BRIGHTNESS" -gt 0 ] && return 0
	done
	[ "$REB_BACKLIGHT_FOUND" -eq 0 ] && return 0
	return 1
}

reb_write_status()
{
	printf '%s mode=%s cpu=%s gpu=%s temp_mC=%s runnable=%s tasks=%s\n' \
		"$REB_MODE_NAME" "$1" "$REB_CPU_BUSY" "$REB_GPU_BUSY" \
		"$REB_TEMP" "$REB_RUNNABLE" "$REB_TASKS" > "$REB_STATUS_FILE"
}

reb_cleanup()
{
	trap - EXIT HUP INT TERM
	reb_leave_mode
	rm -f "$REB_PID_FILE" "$REB_UI_TIDS_FILE" "$REB_UI_TIDS_TMP"
	exit 0
}

mkdir -p "$REB_DIR" || exit 0
chmod 0700 "$REB_DIR" 2>/dev/null || true

if [ "${1:-}" != "--daemon" ]; then
	REB_OLD_PID=$(cat "$REB_PID_FILE" 2>/dev/null)
	reb_daemon_running "$REB_OLD_PID" && exit 0
	rm -f "$REB_PID_FILE"
	: > "$REB_LOG_FILE"
	nohup "$0" --daemon </dev/null >> "$REB_LOG_FILE" 2>&1 &
	exit 0
fi

REB_OLD_PID=$(cat "$REB_PID_FILE" 2>/dev/null)
if reb_daemon_running "$REB_OLD_PID" && [ "$REB_OLD_PID" != "$$" ]; then
	exit 0
fi
printf '%s\n' "$$" > "$REB_PID_FILE"
REB_MODE=0
REB_LAST_COMPOSER_PIDS=
REB_LAST_COMPOSER_TASK_COUNT=-1
REB_LAST_HOME_PIDS=
REB_LAST_HOME_TASK_COUNT=-1
REB_LAST_SYSTEMUI_PIDS=
REB_LAST_SYSTEMUI_TASK_COUNT=-1
REB_WIDGET_MODE=0
REB_WIDGET_HIGH_COUNT=0
REB_WIDGET_LOW_COUNT=0
REB_HOME_PREV_JIFFIES=
REB_PERF_TASKSET=
REB_TOUCH_LAST_PID=
REB_TOUCH_LAST_JIFFIES=
REB_TOUCH_HIGH_COUNT=0
trap 'reb_cleanup' EXIT HUP INT TERM

case "$(uname -r)" in
	4.14.336_bk-Kernel_17.0-b3k1) ;;
	*) reb_log "ignored on incompatible kernel $(uname -r)"; exit 0 ;;
esac

# service.d starts before Android reports boot completion.  Install the
# allocation reserve here so it also covers the late modem/QRTR startup burst.
reb_apply_memory
reb_init_process_reclaim

while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
	sleep 2
done

# HyperOS may configure zram before its encrypted per-boot backing directory
# and a free loop node are both available.  The kernel accepts this first late
# backing attachment without resetting active swap.
reb_setup_zram_backing

REB_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
if [ -r "$REB_RESTORE_FILE" ]; then
	REB_SAVED_BOOT_ID=$(cat "$REB_BOOT_FILE" 2>/dev/null)
	if [ -n "$REB_BOOT_ID" ] && [ "$REB_SAVED_BOOT_ID" = "$REB_BOOT_ID" ]; then
		reb_restore_top_app
		reb_restore_mode_nodes
		reb_log "restored state left by an interrupted daemon"
	else
		rm -f "$REB_RESTORE_FILE" "$REB_BOOT_FILE" \
			"$REB_PINNED_FILE" "$REB_PINNED_TMP" \
			"$REB_UI_TIDS_FILE" "$REB_UI_TIDS_TMP"
	fi
fi

reb_apply_base
reb_screen_on && reb_pin_ui
set -- $(reb_read_cpu_sample)
REB_PREV_TOTAL=${1:-0}
REB_PREV_IDLE=${2:-0}
REB_HIGH_COUNT=0
REB_LOW_COUNT=0
REB_WARMUP=$REB_AUTO_DELAY_SAMPLES
REB_WB_IDLE_COUNT=0
REB_WB_MARKED=0
REB_TASK_HIGH_COUNT=0
REB_TASK_GUARD_COOLDOWN=0
REB_TOUCH_RESTARTS=0
reb_log "started"

while :; do
	sleep "$REB_INTERVAL"
	reb_apply_base
	REB_SCREEN_ACTIVE=0
	if reb_screen_on; then
		REB_SCREEN_ACTIVE=1
		reb_pin_ui
	fi

	set -- $(reb_read_cpu_sample)
	REB_TOTAL=${1:-0}
	REB_IDLE=${2:-0}
	REB_DELTA_TOTAL=$((REB_TOTAL - REB_PREV_TOTAL))
	REB_DELTA_IDLE=$((REB_IDLE - REB_PREV_IDLE))
	if [ "$REB_DELTA_TOTAL" -gt 0 ]; then
		REB_CPU_BUSY=$((100 * (REB_DELTA_TOTAL - REB_DELTA_IDLE) / REB_DELTA_TOTAL))
	else
		REB_CPU_BUSY=0
	fi
	REB_PREV_TOTAL=$REB_TOTAL
	REB_PREV_IDLE=$REB_IDLE
	reb_touchevent_guard_tick
	REB_GPU_BUSY=$(reb_gpu_busy)
	set -- $(reb_load_sample)
	REB_RUNNABLE=${1:-0}
	REB_TASKS=${2:-0}
	REB_TEMP=$(reb_max_temp)
	case "$REB_GPU_BUSY" in ''|*[!0-9]*) REB_GPU_BUSY=0 ;; esac
	case "$REB_RUNNABLE" in ''|*[!0-9]*) REB_RUNNABLE=0 ;; esac
	case "$REB_TASKS" in ''|*[!0-9]*) REB_TASKS=0 ;; esac
	case "$REB_TEMP" in ''|*[!0-9]*) REB_TEMP=0 ;; esac
	[ "$REB_TASK_GUARD_COOLDOWN" -gt 0 ] && \
		REB_TASK_GUARD_COOLDOWN=$((REB_TASK_GUARD_COOLDOWN - 1))
	if [ "$REB_TASK_GUARD_COOLDOWN" -eq 0 ] && \
	   [ "$REB_TASKS" -ge "$REB_TASK_GUARD" ]; then
		REB_TASK_HIGH_COUNT=$((REB_TASK_HIGH_COUNT + 1))
	else
		REB_TASK_HIGH_COUNT=0
	fi
	if [ "$REB_TASK_HIGH_COUNT" -ge "$REB_TASK_GUARD_SAMPLES" ]; then
		reb_init_process_reclaim
		reb_leave_mode
		am kill-all >/dev/null 2>&1 || true
		REB_TASK_HIGH_COUNT=0
		REB_TASK_GUARD_COOLDOWN=$REB_TASK_GUARD_COOLDOWN_SAMPLES
		reb_write_status guarded
		reb_log "trimmed cached processes task guard tasks=$REB_TASKS"
		continue
	fi
	reb_process_reclaim_tick
	reb_zram_writeback_tick

	if [ -e "$REB_DISABLE_FILE" ]; then
		reb_leave_mode
		reb_write_status disabled
		continue
	fi

	REB_FORCE=$(cat "$REB_FORCE_FILE" 2>/dev/null)
	case "$REB_FORCE" in 1|on) REB_FORCE=1 ;; 0|off) REB_FORCE=0 ;; *) REB_FORCE=auto ;; esac

	if [ "$REB_FORCE" = auto ] && [ "$REB_WARMUP" -gt 0 ]; then
		reb_leave_mode
		REB_WARMUP=$((REB_WARMUP - 1))
		REB_HIGH_COUNT=0
		REB_LOW_COUNT=0
		reb_write_status warming
		continue
	fi

	if [ "$REB_SCREEN_ACTIVE" -eq 0 ]; then
		reb_leave_mode
		REB_HIGH_COUNT=0
		REB_LOW_COUNT=0
		reb_write_status inactive
		continue
	fi

	if [ "$REB_CPU_BUSY" -ge "$REB_CPU_ENTER" ] || \
	   [ "$REB_GPU_BUSY" -ge "$REB_GPU_ENTER" ] || \
	   [ "$REB_RUNNABLE" -ge "$REB_RUNNABLE_ENTER" ]; then
		REB_HIGH_COUNT=$((REB_HIGH_COUNT + 1))
	else
		REB_HIGH_COUNT=0
	fi

	if [ "$REB_CPU_BUSY" -le "$REB_CPU_EXIT" ] && \
	   [ "$REB_GPU_BUSY" -le "$REB_GPU_EXIT" ] && \
	   [ "$REB_RUNNABLE" -le "$REB_RUNNABLE_EXIT" ]; then
		REB_LOW_COUNT=$((REB_LOW_COUNT + 1))
	else
		REB_LOW_COUNT=0
	fi

	case "$REB_FORCE" in
		1)
			reb_enter_mode
			;;
		0)
			reb_leave_mode
			;;
		auto)
			if [ "$REB_MODE" -eq 0 ] && \
			   [ "$REB_HIGH_COUNT" -ge "$REB_ENTER_SAMPLES" ]; then
				reb_enter_mode
			elif [ "$REB_MODE" -eq 1 ] && \
			     [ "$REB_LOW_COUNT" -ge "$REB_EXIT_SAMPLES" ]; then
				reb_leave_mode
			fi
			;;
	esac

	if [ "$REB_MODE" -eq 1 ]; then
		reb_refresh_top_app
		reb_enforce_mode_nodes
		reb_write_status active
	else
		reb_write_status inactive
	fi
done
