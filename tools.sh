#!/system/bin/sh
##########################################################################
# artex-tools —— 给容器安装 / 管理工具的便捷入口
#
# 用法（root）：
#   sh /data/adb/modules/artex/tools.sh list                 查看已装工具
#   sh /data/adb/modules/artex/tools.sh install nmap masscan  # apt 装包（记录并持久化清单）
#   sh /data/adb/modules/artex/tools.sh pip install requests  # pip 装到持久层 /usr/local
#   sh /data/adb/modules/artex/tools.sh npm i -g @playwright/cli
#   sh /data/adb/modules/artex/tools.sh run "python3 -V"      # 直接在容器里跑命令
#   sh /data/adb/modules/artex/tools.sh shell                 # 进容器 shell
#
# 持久化说明：
#   - apt 包装在容器 rootfs 内，但包名记录在 /data/adb/artex/apt-packages.list，
#     模块升级重解压 rootfs 时 customize.sh 会自动重装。
#   - pip / npm 全局安装走 --prefix=/usr/local，该目录由 service.sh 挂到
#     /data/artex/app/persist/usr-local，模块升级不受影响，永久保留。
##########################################################################
MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/artex
. "$MODDIR/common.sh"

LIST_FILE="$PERSIST/apt-packages.list"

usage() {
  sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

ensure_running() {
  ensure_mounts || true
}

case "$1" in
  list)
    ensure_venv
    echo "== apt 已记录的用户安装包 =="
    [ -f "$LIST_FILE" ] && cat "$LIST_FILE" || echo "(无)"
    echo
    echo "== 容器内常用工具 =="
    ensure_running
    ctr /bin/bash -c 'for c in python3 pip3 node npm git curl wget jq dig nc rg nmap sqlite3 zip unzip; do printf "%-10s %s\n" "$c" "$(command -v $c 2>/dev/null || echo MISSING)"; done'
    echo
    echo "== 持久层 =="
    du -sh "$APPDIR/persist" 2>/dev/null
    ;;
  install)
    shift
    [ "$#" -ge 1 ] || { echo "用法: tools.sh install <apt 包名...>"; exit 1; }
    ensure_running
    echo "== apt-get install $* =="
    ctr /bin/bash -c "apt-get update -qq && apt-get install -y --no-install-recommends $*"
    if [ $? -eq 0 ]; then
      for p in "$@"; do
        grep -qx "$p" "$LIST_FILE" 2>/dev/null || echo "$p" >> "$LIST_FILE"
      done
      echo "== 已记录到 $LIST_FILE（模块升级会自动重装）"
    else
      echo "!! 安装失败，未记录"
      exit 1
    fi
    ;;
  pip)
    shift
    [ "$1" = "install" ] && shift
    [ "$#" -ge 1 ] || { echo "用法: tools.sh pip <包名...>"; exit 1; }
    ensure_running
    IDX="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
    ensure_venv
    ctr /bin/bash -c "python3 -m pip install -i $IDX $*"
    ;;
  npm)
    shift
    [ "$1" = "install" ] && shift
    [ "$1" = "-g" ] && shift
    [ "$#" -ge 1 ] || { echo "用法: tools.sh npm <包名...>"; exit 1; }
    ensure_running
    REG="${NPM_REGISTRY:-https://registry.npmmirror.com}"
    ctr /bin/bash -c "npm install -g --prefix=/usr/local --registry=$REG $*"
    ;;
  run)
    shift
    ensure_running
    exec ctr /bin/bash -c "$*"
    ;;
  shell)
    ensure_running
    exec ctr /bin/bash
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "未知子命令: $1"; usage
    ;;
esac
