#!/system/bin/sh
############################################
# meta-mm metamount.sh
############################################

MODDIR="${0%/*}"

# Binary path (architecture-specific binary selected during installation)
BINARY="$MODDIR/mmd"

if [ ! -f "$BINARY" ]; then
    # 只修改这里：把log改为echo输出到标准错误
    echo "ERROR: Binary not found: $BINARY" >&2
    exit 1
fi

# Set environment variables
export MODULE_METADATA_DIR="/data/adb/modules"

$BINARY

EXIT_CODE=$?

if [ "$EXIT_CODE" = 0 ]; then
    /data/adb/ksud kernel notify-module-mounted
fi

exit 0
