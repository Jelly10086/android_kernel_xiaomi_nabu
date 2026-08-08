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
REB_PINNED_FILE=$REB_DIR/Re.burnout-mode.top-app
REB_PINNED_TMP=$REB_DIR/Re.burnout-mode.top-app.tmp
REB_UI_TIDS_FILE=$REB_DIR/Re.burnout-mode.ui-tids
REB_UI_TIDS_TMP=$REB_DIR/Re.burnout-mode.ui-tids.tmp
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
REB_TEMP_ENTER=70000
REB_TEMP_EXIT=80000
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
	printf '%s\n' "$2" > "$1" 2>/dev/null || true
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
	reb_write /dev/cpuset/system-background/cpus 0-3
	reb_write /dev/cpuset/foreground/cpus 0-2,4-7
	reb_write /dev/cpuset/top-app/cpus 4-7
}

reb_apply_swappiness()
{
	reb_write /proc/sys/vm/swappiness 200
	for REB_SWAPPINESS_NODE in \
		/dev/memcg/memory.swappiness \
		/dev/memcg/apps/memory.swappiness \
		/dev/memcg/system/memory.swappiness \
		/sys/fs/cgroup/bg/memory.swappiness; do
		reb_write "$REB_SWAPPINESS_NODE" 200
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

reb_setup_zram_backing()
{
	REB_ZRAM=/sys/block/zram0
	REB_ZRAM_HELPER=/data/adb/bk-kernel/bk-zram-setup
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
		# Incompressible pages do not benefit from staying in zram.  Start
		# reclaim as soon as the display is off, then age normal pages for one
		# continuous minute before writing them out.
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
		[ "$REB_ALLOWED_LIST" = "4-7" ] || REB_COMPOSER_REFRESH=1
	done
	if [ "$REB_COMPOSER_PIDS" != "$REB_LAST_COMPOSER_PIDS" ] || \
	   [ "$REB_COMPOSER_TASK_COUNT" -ne "$REB_LAST_COMPOSER_TASK_COUNT" ]; then
		REB_COMPOSER_REFRESH=1
	fi
	[ "$REB_COMPOSER_REFRESH" -eq 1 ] || return 0
	for REB_PROCESS_PID in $REB_COMPOSER_PIDS; do
		taskset -ap f0 "$REB_PROCESS_PID" >/dev/null 2>&1 || true
	done
	REB_LAST_COMPOSER_PIDS=$REB_COMPOSER_PIDS
	REB_LAST_COMPOSER_TASK_COUNT=$REB_COMPOSER_TASK_COUNT
}

reb_pid_in_top_app()
{
	[ -r "/proc/$1/cgroup" ] || return 1
	while IFS=: read -r REB_CGROUP_ID REB_CGROUP_CONTROLLERS REB_CGROUP_PATH; do
		case ",$REB_CGROUP_CONTROLLERS," in
			*,cpuset,*) [ "$REB_CGROUP_PATH" = /top-app ]; return ;;
		esac
	done < "/proc/$1/cgroup"
	return 1
}

reb_move_pid_top_app()
{
	[ -d "/proc/$1/task" ] || return 0
	for REB_TOP_TASK in /proc/$1/task/*; do
		[ -d "$REB_TOP_TASK" ] || continue
		REB_TOP_TID=${REB_TOP_TASK##*/}
		[ -w /dev/cpuset/top-app/tasks ] && \
			printf '%s\n' "$REB_TOP_TID" > /dev/cpuset/top-app/tasks 2>/dev/null || true
		[ -w /dev/stune/top-app/tasks ] && \
			printf '%s\n' "$REB_TOP_TID" > /dev/stune/top-app/tasks 2>/dev/null || true
	done
}

reb_pin_home()
{
	REB_HOME_PIDS=$(pidof com.miui.home 2>/dev/null)
	REB_HOME_TASK_COUNT=0
	REB_HOME_REFRESH=0
	for REB_PROCESS_PID in $REB_HOME_PIDS; do
		for REB_HOME_TASK in /proc/$REB_PROCESS_PID/task/*; do
			[ -d "$REB_HOME_TASK" ] && \
				REB_HOME_TASK_COUNT=$((REB_HOME_TASK_COUNT + 1))
		done
		if ! reb_pid_in_top_app "$REB_PROCESS_PID"; then
			reb_move_pid_top_app "$REB_PROCESS_PID"
			REB_HOME_REFRESH=1
		fi
		reb_read_allowed_list "$REB_PROCESS_PID"
		[ "$REB_ALLOWED_LIST" = "4-6" ] || REB_HOME_REFRESH=1
	done
	if [ "$REB_HOME_PIDS" != "$REB_LAST_HOME_PIDS" ] || \
	   [ "$REB_HOME_TASK_COUNT" -ne "$REB_LAST_HOME_TASK_COUNT" ]; then
		REB_HOME_REFRESH=1
	fi
	[ "$REB_HOME_REFRESH" -eq 1 ] || return 0
	for REB_PROCESS_PID in $REB_HOME_PIDS; do
		# Keep CPU7 available to auxiliary launcher workers.
		taskset -ap f0 "$REB_PROCESS_PID" >/dev/null 2>&1 || true
		taskset -p 70 "$REB_PROCESS_PID" >/dev/null 2>&1 || true
		for REB_HOME_TASK in /proc/$REB_PROCESS_PID/task/*; do
			[ -r "$REB_HOME_TASK/comm" ] || continue
			REB_HOME_COMM=
			IFS= read -r REB_HOME_COMM < "$REB_HOME_TASK/comm" 2>/dev/null || true
			case "$REB_HOME_COMM" in
				RenderThread|HwuiTask*|launcher*|Launcher*)
					taskset -p 70 "${REB_HOME_TASK##*/}" >/dev/null 2>&1 || true
					;;
			esac
		done
	done
	REB_LAST_HOME_PIDS=$REB_HOME_PIDS
	REB_LAST_HOME_TASK_COUNT=$REB_HOME_TASK_COUNT
}

reb_tune_transition_threads()
{
	REB_SYSTEMUI_PIDS=$(pidof com.android.systemui 2>/dev/null)
	REB_SYSTEMUI_TASK_COUNT=0
	REB_SYSTEMUI_REFRESH=0
	for REB_PROCESS_PID in $REB_SYSTEMUI_PIDS; do
		for REB_TASK in /proc/$REB_PROCESS_PID/task/*; do
			[ -d "$REB_TASK" ] && \
				REB_SYSTEMUI_TASK_COUNT=$((REB_SYSTEMUI_TASK_COUNT + 1))
		done
		if ! reb_pid_in_top_app "$REB_PROCESS_PID"; then
			reb_move_pid_top_app "$REB_PROCESS_PID"
			REB_SYSTEMUI_REFRESH=1
		fi
		reb_read_allowed_list "$REB_PROCESS_PID"
		[ "$REB_ALLOWED_LIST" = "4-7" ] || REB_SYSTEMUI_REFRESH=1
	done
	if [ "$REB_SYSTEMUI_PIDS" != "$REB_LAST_SYSTEMUI_PIDS" ] || \
	   [ "$REB_SYSTEMUI_TASK_COUNT" -ne "$REB_LAST_SYSTEMUI_TASK_COUNT" ]; then
		REB_SYSTEMUI_REFRESH=1
	fi
	[ "$REB_SYSTEMUI_REFRESH" -eq 1 ] || return 0
	for REB_PROCESS_PID in $REB_SYSTEMUI_PIDS; do
		taskset -ap f0 "$REB_PROCESS_PID" >/dev/null 2>&1 || true
	done
	rm -f "$REB_UI_TIDS_FILE" "$REB_UI_TIDS_TMP"

	: > "$REB_UI_TIDS_TMP"
	for REB_PROCESS_PID in $REB_SYSTEMUI_PIDS; do
		for REB_TASK in /proc/$REB_PROCESS_PID/task/*; do
			[ -r "$REB_TASK/comm" ] || continue
			REB_UI_TID=${REB_TASK##*/}
			REB_UI_COMM=
			IFS= read -r REB_UI_COMM < "$REB_TASK/comm" 2>/dev/null || true
			case "$REB_UI_COMM" in
				wmshell.main|wmshell.anim|miui_wm_sight|doUnLockAppAnim|SurfaceSyncGrou) ;;
				*) continue ;;
			esac
			printf '%s\n' "$REB_UI_TID" >> "$REB_UI_TIDS_TMP"
			REB_UI_ALLOWED=$(awk '/^Cpus_allowed_list:/ { print $2; exit }' \
				"$REB_TASK/status" 2>/dev/null)
			if ! grep -qx "$REB_UI_TID" "$REB_UI_TIDS_FILE" 2>/dev/null || \
			   [ "$REB_UI_ALLOWED" != "4-7" ]; then
				# Restrict only app-transition workers. CPU7 remains an EAS fallback.
				taskset -p f0 "$REB_UI_TID" >/dev/null 2>&1 || true
			fi
		done
	done
	mv -f "$REB_UI_TIDS_TMP" "$REB_UI_TIDS_FILE"
	REB_LAST_SYSTEMUI_PIDS=$REB_SYSTEMUI_PIDS
	REB_LAST_SYSTEMUI_TASK_COUNT=$REB_SYSTEMUI_TASK_COUNT
}

reb_pin_ui()
{
	reb_pin_composer
	reb_pin_home
	reb_tune_transition_threads
}

reb_apply_base()
{
	reb_apply_cpuset
	reb_apply_memory
	reb_apply_little_policy
	reb_pin_ui
}

reb_home_primary_tid()
{
	for REB_HOME_PID in $REB_HOME_PIDS; do
		[ "$1" = "$REB_HOME_PID" ] && return 0
	done
	[ -r "/proc/$1/comm" ] || return 1
	REB_HOME_COMM=
	IFS= read -r REB_HOME_COMM < "/proc/$1/comm" 2>/dev/null || return 1
	case "$REB_HOME_COMM" in
		RenderThread|HwuiTask*|launcher*|Launcher*) ;;
		*) return 1 ;;
	esac
	REB_TASK_TGID=
	while IFS= read -r REB_STATUS_LINE; do
		case "$REB_STATUS_LINE" in
			Tgid:*)
				REB_TASK_TGID=${REB_STATUS_LINE#*:}
				set -- $REB_TASK_TGID
				REB_TASK_TGID=${1:-}
				break
				;;
		esac
	done < "/proc/$1/status"
	for REB_HOME_PID in $REB_HOME_PIDS; do
		[ "$REB_TASK_TGID" = "$REB_HOME_PID" ] && return 0
	done
	return 1
}

reb_refresh_top_app()
{
	[ -r /dev/cpuset/top-app/tasks ] || return 0
	while IFS= read -r REB_TOP_TID; do
		case "$REB_TOP_TID" in ''|*[!0-9]*) continue ;; esac
		reb_home_primary_tid "$REB_TOP_TID" && continue
		reb_read_allowed_list "$REB_TOP_TID"
		[ "$REB_ALLOWED_LIST" = "4-7" ] || \
			taskset -p f0 "$REB_TOP_TID" >/dev/null 2>&1 || true
	done < /dev/cpuset/top-app/tasks
}

reb_restore_top_app()
{
	rm -f "$REB_PINNED_FILE" "$REB_PINNED_TMP"
	rm -f "$REB_UI_TIDS_FILE" "$REB_UI_TIDS_TMP"
	reb_pin_ui
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
	for REB_UFS_NODE in max_bus_bw clkscale_enable clkgate_enable auto_hibern8; do
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
	# Disabling UFS clock scaling raises the clocks before it suspends scaling.
	reb_write "$REB_UFS/clkscale_enable" 0
	reb_write "$REB_UFS/clkgate_enable" 0
	reb_write "$REB_UFS/auto_hibern8" 0

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

reb_gpu_busy()
{
	awk '{ print $1 + 0; exit }' /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null
}

reb_runnable()
{
	awk '{ split($4, value, "/"); print value[1] + 0; exit }' /proc/loadavg 2>/dev/null
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
	printf '%s mode=%s cpu=%s gpu=%s temp_mC=%s runnable=%s\n' \
		"$REB_MODE_NAME" "$1" "$REB_CPU_BUSY" "$REB_GPU_BUSY" \
		"$REB_TEMP" "$REB_RUNNABLE" > "$REB_STATUS_FILE"
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
trap 'reb_cleanup' EXIT HUP INT TERM

case "$(uname -r)" in
	4.14.190_bk-Kernel_16.2-R2.3) ;;
	*) reb_log "ignored on incompatible kernel $(uname -r)"; exit 0 ;;
esac

# service.d starts before Android reports boot completion.  Install the
# allocation reserve here so it also covers the late modem/QRTR startup burst.
reb_apply_memory

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
set -- $(reb_read_cpu_sample)
REB_PREV_TOTAL=${1:-0}
REB_PREV_IDLE=${2:-0}
REB_HIGH_COUNT=0
REB_LOW_COUNT=0
REB_COOLDOWN=0
REB_WARMUP=$REB_AUTO_DELAY_SAMPLES
REB_WB_IDLE_COUNT=0
REB_WB_MARKED=0
reb_log "started"

while :; do
	sleep "$REB_INTERVAL"
	reb_apply_base

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
	REB_GPU_BUSY=$(reb_gpu_busy)
	REB_RUNNABLE=$(reb_runnable)
	REB_TEMP=$(reb_max_temp)
	case "$REB_GPU_BUSY" in ''|*[!0-9]*) REB_GPU_BUSY=0 ;; esac
	case "$REB_RUNNABLE" in ''|*[!0-9]*) REB_RUNNABLE=0 ;; esac
	case "$REB_TEMP" in ''|*[!0-9]*) REB_TEMP=0 ;; esac
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

	if ! reb_screen_on; then
		reb_leave_mode
		REB_HIGH_COUNT=0
		REB_LOW_COUNT=0
		reb_write_status inactive
		continue
	fi

	if [ "$REB_TEMP" -ge "$REB_TEMP_EXIT" ]; then
		reb_leave_mode
		REB_COOLDOWN=24
		REB_HIGH_COUNT=0
		REB_LOW_COUNT=0
		reb_write_status cooling
		continue
	fi

	[ "$REB_COOLDOWN" -gt 0 ] && REB_COOLDOWN=$((REB_COOLDOWN - 1))

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
			if [ "$REB_TEMP" -le "$REB_TEMP_ENTER" ]; then
				reb_enter_mode
			fi
			;;
		0)
			reb_leave_mode
			;;
		auto)
			if [ "$REB_MODE" -eq 0 ] && [ "$REB_COOLDOWN" -eq 0 ] && \
			   [ "$REB_TEMP" -le "$REB_TEMP_ENTER" ] && \
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
	elif [ "$REB_COOLDOWN" -gt 0 ]; then
		reb_write_status cooling
	else
		reb_write_status inactive
	fi
done
