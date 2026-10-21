#!/system/bin/sh
##########################################################################
# ARTEX Magisk 模块卸载脚本
#
# 默认清理：运行中的进程、容器 rootfs、应用目录、数据库、持久化配置
# 想保留数据（重装后继续用）：
#   su -c "mkdir -p /data/adb/artex && touch /data/adb/artex/.keep_on_uninstall"
#
# 安全约束：rm -rf /data/artex 之前必须先解除 rootfs 下的所有 bind 挂载，
# 否则会顺着挂载点删掉宿主的 /dev、/proc。卸载失败要 abort，绝不硬来。
##########################################################################
ROOTFS=/data/artex/rootfs
PERSIST=/data/adb/artex
KEEP="$PERSIST/.keep_on_uninstall"

_log() { echo "[artex-uninstall] $1" >&2; }

mkdir -p "$PERSIST" 2>/dev/null
echo "uninstall $(date '+%Y-%m-%d %H:%M:%S')" > "$PERSIST/stopped" 2>/dev/null

# 守护进程自退
if [ -f "$PERSIST/watchdog.pid" ]; then
  pid=$(cat "$PERSIST/watchdog.pid" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
fi
rm -f "$PERSIST/gen" "$PERSIST/watchdog.pid" 2>/dev/null

# 停 ARTEX
for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  c=""
  read -r c 2>/dev/null < "$d/cmdline"
  case "$c" in
    /opt/artex/artex*) kill "${d#/proc/}" 2>/dev/null ;;
  esac
done
sleep 1

# 停 PostgreSQL
if [ -x "$ROOTFS/usr/lib/postgresql/15/bin/pg_ctl" ]; then
  chroot "$ROOTFS" /bin/su -s /bin/bash postgres -c "/usr/lib/postgresql/15/bin/pg_ctl -D /var/lib/postgresql/data -m fast stop" >/dev/null 2>&1
fi

echo "artex" > /sys/power/wake_unlock 2>/dev/null

if [ -f "$KEEP" ]; then
  _log "检测到保留标记，跳过数据清理"
  _log "如需彻底删除：su -c \"rm -rf /data/artex $PERSIST\""
else
  # 解除 rootfs 下全部挂载（含 /dev /proc /sys /opt/artex /var/lib/postgresql/data）
  i=0
  while [ "$i" -lt 5 ] && grep -q " $ROOTFS/" /proc/mounts; do
    grep " $ROOTFS/" /proc/mounts | while read -r _dev mnt _rest; do
      umount -l "$mnt" 2>/dev/null
    done
    i=$((i + 1))
    sleep 1
  done
  if grep -q " $ROOTFS" /proc/mounts; then
    _log "容器仍处于挂载状态，为安全起见跳过删除；请重启后再卸载"
    exit 1
  fi
  _log "清理 /data/artex"
  rm -rf /data/artex
  _log "清理 $PERSIST"
  rm -rf "$PERSIST"
fi

_log "卸载完成；重启后模块目录会被 Magisk 自动删除"
