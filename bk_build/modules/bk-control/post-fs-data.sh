#!/system/bin/sh

MODDIR=${0%/*}
export BK_CONTROL_DIR=$MODDIR

setup_miui_keyboard()
{
	BK_FEATURE_SOURCE=/product/etc/device_features/nabu.xml
	BK_FEATURE_DIR=/data/adb/bk-kernel/device_features
	BK_FEATURE_FILE=$BK_FEATURE_DIR/nabu.xml
	BK_FEATURE_TMP=$BK_FEATURE_FILE.tmp

	[ -f "$BK_FEATURE_SOURCE" ] || return 0
	grep -q '<bool name="support_usb_keyboard">true</bool>' \
		"$BK_FEATURE_SOURCE" 2>/dev/null && return 0
	mkdir -p "$BK_FEATURE_DIR" || return 0
	cp -f "$BK_FEATURE_SOURCE" "$BK_FEATURE_TMP" || return 0
	if grep -q 'name="support_usb_keyboard"' "$BK_FEATURE_TMP"; then
		sed -i 's#<bool name="support_usb_keyboard">false</bool>#<bool name="support_usb_keyboard">true</bool>#' \
			"$BK_FEATURE_TMP"
	else
		sed -i '/<bool name="support_iic_keyboard">/i\    <bool name="support_usb_keyboard">true</bool>' \
			"$BK_FEATURE_TMP"
	fi
	mv -f "$BK_FEATURE_TMP" "$BK_FEATURE_FILE" || return 0
	chown 0:0 "$BK_FEATURE_FILE"
	chmod 0644 "$BK_FEATURE_FILE"
	chcon u:object_r:system_file:s0 "$BK_FEATURE_FILE" 2>/dev/null || true
	mount --bind "$BK_FEATURE_FILE" "$BK_FEATURE_SOURCE"
}

setup_ufs_io()
{
	BK_UFS_SCHEDULER=/sys/block/sda/queue/scheduler
	[ -w "$BK_UFS_SCHEDULER" ] || return 0
	grep -qw noop "$BK_UFS_SCHEDULER" 2>/dev/null || return 0
	printf '%s\n' noop > "$BK_UFS_SCHEDULER" 2>/dev/null || true
}

rm -f /data/adb/post-fs-data.d/bk-zram-writeback.sh
setup_miui_keyboard
setup_ufs_io
"$MODDIR/scripts/bk-zram-writeback.sh"
