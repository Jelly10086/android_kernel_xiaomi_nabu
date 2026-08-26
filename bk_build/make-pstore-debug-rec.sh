#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
REC=${1:-$WORKSPACE/REC/V4-MODDED-TWRP-LINUX.img}
OUT=${2:-$WORKSPACE/out/REC-pstore-debug.img}
MAGISKBOOT=${MAGISKBOOT:-$WORKSPACE/out/b1-preserve-ramdisk-package/tools/magiskboot}

[ -f "$REC" ] || { echo "REC image missing: $REC" >&2; exit 2; }
[ -f "$MAGISKBOOT" ] || { echo "magiskboot is missing: $MAGISKBOOT" >&2; exit 2; }
mkdir -p "$(dirname -- "$OUT")"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nabu-rec-pstore.XXXXXX")
cp "$MAGISKBOOT" "$WORK/magiskboot"
chmod 0755 "$WORK/magiskboot"
cp "$REC" "$WORK/original.img"
(
  cd "$WORK"
  ./magiskboot unpack -h original.img >/dev/null
  grep -Eq '^cmdline=.*(^|[[:space:]])pstore\.no_console=1([[:space:]]|$)' header || \
    sed -i 's/^cmdline=\(.*\)$/cmdline=\1 pstore.no_console=1/' header
  ./magiskboot repack original.img "$OUT" >/dev/null
)
"$MAGISKBOOT" unpack -h "$OUT" >/dev/null 2>&1 || {
  echo "repacked REC failed validation" >&2
  exit 1
}
rm -f header kernel ramdisk.cpio original.img
printf '%s\n' "$OUT"
