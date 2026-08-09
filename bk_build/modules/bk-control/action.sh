#!/system/bin/sh

MODDIR=${0%/*}
exec "$MODDIR/bkctl" cycle-mode
