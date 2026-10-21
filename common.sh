#!/system/bin/sh
##########################################################################
# ARTEX Magisk 模块 —— 公共函数
#
# 布局：
#   $ROOTFS   /data/artex/rootfs   Debian 12 (bookworm) rootfs（刷入时解压）
#   $APPDIR   /data/artex/app      artex 二进制 + 配置 + skills + 数据（bind 到容器 /opt/artex）
#   $PGDATA   /data/artex/pgdata   PostgreSQL 数据目录（bind 到容器 /var/lib/postgresql/data）
#   $PERSIST  /data/adb/artex      端口配置、日志、停止开关（卸载/升级都不碰数据）
##########################################################################

ROOTFS=/data/artex/rootfs
APPDIR=/data/artex/app
PGDATA=/data/artex/pgdata
PERSIST=/data/adb/artex
LOG_FILE="$PERSIST/service.log"
PORTS_CONF="$PERSIST/ports.conf"
STOP_FLAG="$PERSIST/stopped"
GEN_FILE="$PERSIST/gen"
PID_WATCHDOG="$PERSIST/watchdog.pid"
PG_BIN=/usr/lib/postgresql/15/bin
PGSOCK=/run/postgresql
PGPORT=5433
ARTEX_LOG="$APPDIR/logs/artex.log"
PG_LOG="$APPDIR/logs/postgresql.log"
SHIM=/opt/artex/libsysv-shim.so

WEB_PORT=8787
PROXY_ADDR=127.0.0.1:8788
KEEP_AWAKE=1

mkdir -p "$PERSIST" 2>/dev/null

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null
}

load_ports() {
  WEB_PORT=8787
  PROXY_ADDR=127.0.0.1:8788
  KEEP_AWAKE=1
  if [ -f "$PORTS_CONF" ]; then
    . "$PORTS_CONF" 2>/dev/null || true
  fi
  case "$WEB_PORT" in
    ''|*[!0-9]*) WEB_PORT=8787 ;;
  esac
  [ "$WEB_PORT" -ge 1 ] 2>/dev/null && [ "$WEB_PORT" -le 65535 ] || WEB_PORT=8787
  [ -n "$PROXY_ADDR" ] || PROXY_ADDR=127.0.0.1:8788
  [ -n "$KEEP_AWAKE" ] || KEEP_AWAKE=1
}

write_default_ports() {
  [ -f "$PORTS_CONF" ] && return 0
  cat > "$PORTS_CONF" <<'EOF'
# ARTEX 模块配置 —— 改完重启手机，或在模块管理器点「运行」按钮重启服务
# 浏览器访问 http://<手机IP>:WEB_PORT
WEB_PORT=8787
# 流量录制代理监听地址（只监听本机回环，留空则关闭代理）
PROXY_ADDR=127.0.0.1:8788
# 1 = 运行期间阻止系统休眠，保证随时能访问；0 = 允许休眠（更省电，但可能断连）
KEEP_AWAKE=1
EOF
}

# ---- 容器执行 ------------------------------------------------------------
# 容器内 PATH：持久层 venv 优先，其次是 /usr/local（bind 到 persist）、node、/opt/tools
CTR_PATH=/usr/local/venv/bin:/usr/local/sbin:/usr/local/bin:/opt/node/bin:/opt/tools/bin:/usr/sbin:/usr/bin:/sbin:/bin

ctr() {
  chroot "$ROOTFS" /usr/bin/env -i \
    PATH="$CTR_PATH" \
    HOME=/root TMPDIR=/tmp "$@"
}

# 持久层 venv：pip 装的东西（含 console script）都在 /usr/local/venv，
# 而 /usr/local 绑定到 $APPDIR/persist/usr-local —— 模块升级重灌 rootfs 也不会丢。
ensure_venv() {
  [ -x "$ROOTFS/usr/local/venv/bin/python3" ] && return 0
  log "创建持久化 python 虚拟环境 /usr/local/venv"
  ctr /bin/bash -c "python3 -m venv --system-site-packages /usr/local/venv" >> "$LOG_FILE" 2>&1
}

as_pg() {
  chroot "$ROOTFS" /bin/su -s /bin/bash postgres -c "$1"
}

# ---- 挂载 ----------------------------------------------------------------
ensure_mounts() {
  [ -d "$ROOTFS" ] || return 1
  mkdir -p "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" "$ROOTFS/tmp" \
           "$ROOTFS/run" "$ROOTFS/run/postgresql" "$ROOTFS/var/log" \
           "$ROOTFS/opt/artex" "$ROOTFS/var/lib/postgresql/data"
  chmod 1777 "$ROOTFS/tmp" 2>/dev/null
  mountpoint -q "$ROOTFS/proc" || mount -t proc proc "$ROOTFS/proc" 2>/dev/null
  mountpoint -q "$ROOTFS/sys"  || mount -t sysfs sysfs "$ROOTFS/sys" 2>/dev/null
  mountpoint -q "$ROOTFS/dev"  || mount --bind /dev "$ROOTFS/dev" 2>/dev/null
  mountpoint -q "$ROOTFS/dev/shm" || mount -t tmpfs -o size=256m,mode=1777 tmpfs "$ROOTFS/dev/shm" 2>/dev/null
  mountpoint -q "$ROOTFS/opt/artex" || mount --bind "$APPDIR" "$ROOTFS/opt/artex" 2>/dev/null
  mountpoint -q "$ROOTFS/var/lib/postgresql/data" || mount --bind "$PGDATA" "$ROOTFS/var/lib/postgresql/data" 2>/dev/null
  # 持久化工具层：容器内 /usr/local 与 /opt/tools 落到 $APPDIR/persist，
  # 模块升级重解压 rootfs 也不会丢用户自己装的东西
  mkdir -p "$APPDIR/persist/usr-local" "$APPDIR/persist/tools"
  mountpoint -q "$ROOTFS/usr/local" || mount --bind "$APPDIR/persist/usr-local" "$ROOTFS/usr/local" 2>/dev/null
  mountpoint -q "$ROOTFS/opt/tools" || mount --bind "$APPDIR/persist/tools" "$ROOTFS/opt/tools" 2>/dev/null
  chroot "$ROOTFS" /bin/chown postgres:postgres /run/postgresql 2>/dev/null
  chroot "$ROOTFS" /bin/chmod 2775 /run/postgresql 2>/dev/null
  return 0
}

umount_all() {
  for d in var/lib/postgresql/data opt/artex opt/tools usr/local dev/shm dev sys proc; do
    mountpoint -q "$ROOTFS/$d" && umount "$ROOTFS/$d" 2>/dev/null
  done
}

# ---- 进程探测 ------------------------------------------------------------
proc_alive() {
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    c=""
    # /proc/<pid>/cmdline 用 NUL 分隔且无结尾换行，read 返回非 0 但变量已赋值
    read -r c 2>/dev/null < "$d/cmdline"
    case "$c" in
      $1*) return 0 ;;
    esac
  done
  return 1
}

pg_running() {
  as_pg "$PG_BIN/pg_ctl -D /var/lib/postgresql/data status" >/dev/null 2>&1
}

artex_running() {
  proc_alive /opt/artex/artex
}

# ---- PostgreSQL ----------------------------------------------------------
init_pg() {
  [ -f "$PGDATA/PG_VERSION" ] && return 0
  log "首次启动：初始化 PostgreSQL 数据目录"
  mkdir -p "$PGDATA"
  chroot "$ROOTFS" /bin/chown -R postgres:postgres /var/lib/postgresql/data 2>/dev/null
  chroot "$ROOTFS" /bin/chmod 700 /var/lib/postgresql/data 2>/dev/null
  as_pg "LD_PRELOAD=$SHIM $PG_BIN/initdb -D /var/lib/postgresql/data -U postgres -A trust --encoding=UTF8 --locale=C.UTF-8" >> "$LOG_FILE" 2>&1
  if [ ! -f "$PGDATA/PG_VERSION" ]; then
    log "!! initdb 失败，见 $LOG_FILE"
    return 1
  fi
  cat >> "$PGDATA/postgresql.conf" <<'EOF'

# ---- ARTEX on Android ----
# Android 内核没有 SysV 共享内存（shmget 返回 ENOSYS），必须用 mmap
shared_memory_type = mmap
dynamic_shared_memory_type = mmap
listen_addresses = ''
unix_socket_directories = '/run/postgresql'
port = 5432
fsync = off
synchronous_commit = off
full_page_writes = off
log_min_messages = warning
# 模块里删掉了 libLLVM（省 ~130MB），JIT 必须关掉
jit = off
EOF
  log "PostgreSQL 初始化完成"
  return 0
}

start_pg() {
  pg_running && return 0
  init_pg || return 1
  mkdir -p "$APPDIR/logs"
  # PostgreSQL 以 postgres 用户运行，日志目录必须让它可写
  chroot "$ROOTFS" /bin/chown postgres:postgres /opt/artex/logs 2>/dev/null
  chroot "$ROOTFS" /bin/chmod 775 /opt/artex/logs 2>/dev/null
  log "启动 PostgreSQL"
  as_pg "LD_PRELOAD=$SHIM $PG_BIN/pg_ctl -D /var/lib/postgresql/data -l /opt/artex/logs/postgresql.log -w -t 60 start" >> "$LOG_FILE" 2>&1
  if pg_running; then
    log "PostgreSQL 已就绪 (socket $PGSOCK:$PGPORT)"
    return 0
  fi
  log "!! PostgreSQL 启动失败，见 $PG_LOG"
  return 1
}

stop_pg() {
  as_pg "$PG_BIN/pg_ctl -D /var/lib/postgresql/data -m fast -w -t 30 stop" >> "$LOG_FILE" 2>&1
}

# ---- ARTEX ---------------------------------------------------------------
artex_dsn() {
  echo "postgres://postgres@/artex?host=$PGSOCK&sslmode=disable"
}

start_artex() {
  if artex_running; then
    log "ARTEX 已在运行，跳过启动"
    return 0
  fi
  mkdir -p "$APPDIR/logs" "$APPDIR/data" "$APPDIR/skills"
  dsn=$(artex_dsn)
  log "启动 ARTEX (web=:$WEB_PORT proxy=$PROXY_ADDR)"
  ensure_venv
  nohup chroot "$ROOTFS" /usr/bin/env -i \
    PATH="$CTR_PATH" \
    HOME=/root TMPDIR=/tmp TZ=Asia/Shanghai \
    ARTEX_PG_DSN="$dsn" \
    /opt/artex/artex --addr ":$WEB_PORT" --data /opt/artex/data --proxy "$PROXY_ADDR" \
    >> "$ARTEX_LOG" 2>&1 &
  echo $! > "$PERSIST/artex.pid"
  sleep 2
  if artex_running; then
    log "ARTEX 已启动，访问 http://127.0.0.1:$WEB_PORT"
    return 0
  fi
  log "!! ARTEX 启动失败，见 $ARTEX_LOG"
  return 1
}

stop_artex() {
  if [ -f "$PERSIST/artex.pid" ]; then
    pid=$(cat "$PERSIST/artex.pid" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  fi
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    c=""
    read -r c 2>/dev/null < "$d/cmdline"
    case "$c" in
      /opt/artex/artex*) kill "${d#/proc/}" 2>/dev/null ;;
    esac
  done
  rm -f "$PERSIST/artex.pid"
}

# ---- 守护循环 ------------------------------------------------------------
stop_watchdog() {
  if [ -f "$PID_WATCHDOG" ]; then
    pid=$(cat "$PID_WATCHDOG" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$PID_WATCHDOG"
  fi
}

start_watchdog() {
  gen=$(date '+%s' 2>/dev/null)
  printf '%s\n' "$gen" > "$GEN_FILE" 2>/dev/null
  (
    while true; do
      sleep 30
      now=""
      [ -f "$GEN_FILE" ] && read -r now 2>/dev/null < "$GEN_FILE"
      [ "$now" = "$gen" ] || exit 0
      [ -f "$STOP_FLAG" ] && exit 0
      load_ports
      pg_running || { log "守护：PostgreSQL 掉线，重新拉起"; start_pg; }
      artex_running || { log "守护：ARTEX 掉线，重新拉起"; start_artex; }
    done
  ) &
  echo $! > "$PID_WATCHDOG"
}

# ---- 唤醒锁 --------------------------------------------------------------
keep_awake() {
  [ "$KEEP_AWAKE" = "1" ] || return 0
  echo "artex" > /sys/power/wake_lock 2>/dev/null
}
release_awake() {
  echo "artex" > /sys/power/wake_unlock 2>/dev/null
}
