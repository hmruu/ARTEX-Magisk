#!/system/bin/sh
##########################################################################
# ARTEX Magisk 模块 —— 动作按钮：停止 / 启动 切换 + 状态摘要
##########################################################################
MODDIR=${0%/*}
. "$MODDIR/common.sh"
load_ports

ip=""
for iface in wlan0 eth0; do
  a=$(ip -4 addr show "$iface" 2>/dev/null | grep -o 'inet [0-9.]*' | head -1 | cut -d' ' -f2)
  [ -n "$a" ] && { ip=$a; break; }
done

echo "=========== ARTEX ==========="
if [ -f "$STOP_FLAG" ]; then
  echo "状态: 已手动停止"
  rm -f "$STOP_FLAG"
  ensure_mounts
  keep_awake
  start_pg && start_artex
  start_watchdog
  echo "已启动。访问 http://${ip:-<手机IP>}:$WEB_PORT"
else
  echo "状态: 运行中"
  pg_running && echo "  PostgreSQL: 运行中" || echo "  PostgreSQL: 未运行"
  artex_running && echo "  ARTEX: 运行中" || echo "  ARTEX: 未运行"
  echo "  访问地址: http://${ip:-<手机IP>}:$WEB_PORT"
  echo "  日志: $ARTEX_LOG"
  echo "$(date '+%Y-%m-%d %H:%M:%S') 用户按下停止" > "$STOP_FLAG"
  stop_watchdog
  stop_artex
  stop_pg
  release_awake
  echo "已停止。再次点「运行」恢复。"
fi
echo "============================="
