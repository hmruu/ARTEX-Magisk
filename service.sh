#!/system/bin/sh
##########################################################################
# ARTEX Magisk 模块 —— late_start service：开机拉起 PostgreSQL + ARTEX
##########################################################################
MODDIR=${0%/*}
. "$MODDIR/common.sh"

log "========================================="
log "ARTEX 模块启动 (MODDIR=$MODDIR)"
write_default_ports
load_ports
log "端口: WEB_PORT=$WEB_PORT  PROXY_ADDR=$PROXY_ADDR  KEEP_AWAKE=$KEEP_AWAKE"
log "========================================="

if [ ! -d "$ROOTFS" ]; then
  log "!! 找不到容器 rootfs ($ROOTFS)，模块可能安装不完整，请重新刷入"
  exit 1
fi
if [ ! -x "$APPDIR/artex" ]; then
  log "!! 找不到 artex 可执行文件 ($APPDIR/artex)，请重新刷入模块"
  exit 1
fi

# 手动停止开关：用户点「运行」按钮停过，就不自动拉起（跨重启保持）
if [ -f "$STOP_FLAG" ]; then
  log "检测到停止开关 $STOP_FLAG，本次不启动"
  exit 0
fi

ensure_mounts
stop_watchdog
keep_awake

start_pg || { log "PostgreSQL 未就绪，放弃本次启动"; release_awake; exit 1; }
start_artex || { log "ARTEX 未启动，守护进程会继续重试"; }

start_watchdog
log "启动流程结束"
exit 0
