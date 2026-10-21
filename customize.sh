#!/system/bin/sh
##########################################################################
# ARTEX Magisk / KernelSU / APatch 模块安装脚本
#
# 做的事：
#   1. 把 files/rootfs.tar.xz（Debian 12 arm64 + PostgreSQL 15）解压到 /data/artex/rootfs
#   2. 把 files/app/ 下的 artex 二进制、配置、skills 放进 /data/artex/app
#   3. 首次安装生成 /data/adb/artex/ports.conf
#   4. 删掉安装包里已经解压过的 rootfs 压缩包，省下 ~150MB
#
# 数据目录（/data/artex/pgdata、/data/artex/app/data）升级时不动。
#
# !! 安全约束（非常重要）!!
# 更新模块时，正在运行的服务仍然把 /dev、/proc、/sys、/data/artex/app 等
# bind 挂载在 rootfs 内部。任何情况下都不能在挂载未解除时 rm -rf rootfs ——
# 那会顺着挂载点删掉宿主的 /dev、/proc 内容。所以删除前必须：
#   a) 扫描 /proc/mounts 卸载 rootfs 下的所有挂载点；
#   b) 复查仍然有挂载就直接 abort，绝不动手。
##########################################################################
SKIPUNZIP=0
umask 022

ROOTFS=/data/artex/rootfs
APPDIR=/data/artex/app
PGDATA=/data/artex/pgdata
PERSIST=/data/adb/artex

ui_print " "
ui_print "****************************************"
ui_print "  ARTEX 渗透测试平台 · Magisk 模块"
ui_print "****************************************"
ui_print " "

# ---- 停止正在运行的服务并解除挂载（安全第一）----------------------------
mkdir -p "$PERSIST"
ui_print "- 停止旧实例并解除容器挂载"
echo "install $(date '+%Y-%m-%d %H:%M:%S')" > "$PERSIST/stopped" 2>/dev/null
rm -f "$PERSIST/gen" "$PERSIST/watchdog.pid" 2>/dev/null

for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  c=""
  read -r c 2>/dev/null < "$d/cmdline"
  case "$c" in
    /opt/artex/artex*) kill "${d#/proc/}" 2>/dev/null ;;
  esac
done
sleep 1

if [ -x "$ROOTFS/usr/lib/postgresql/15/bin/pg_ctl" ]; then
  chroot "$ROOTFS" /bin/su -s /bin/bash postgres -c "/usr/lib/postgresql/15/bin/pg_ctl -D /var/lib/postgresql/data -m immediate stop" >/dev/null 2>&1
fi

i=0
while [ "$i" -lt 5 ] && grep -q " $ROOTFS/" /proc/mounts; do
  grep " $ROOTFS/" /proc/mounts | while read -r _dev mnt _rest; do
    umount -l "$mnt" 2>/dev/null
  done
  i=$((i + 1))
  sleep 1
done

if grep -q " $ROOTFS" /proc/mounts; then
  grep " $ROOTFS" /proc/mounts >&2
  abort "! 容器仍处于挂载状态，为安全起见中止安装（请重启后再刷）"
fi

mkdir -p "$ROOTFS" "$APPDIR" "$PGDATA" "$PERSIST" "$APPDIR/logs" "$APPDIR/data" "$APPDIR/skills"

# ---- 1. 容器 rootfs ------------------------------------------------------
NEWVER=""
[ -f "$MODPATH/files/rootfs.version" ] && read -r NEWVER < "$MODPATH/files/rootfs.version"
[ -n "$NEWVER" ] || NEWVER="debian12-pg15"

VERFILE="$ROOTFS/.artex-rootfs-version"
CURVER=""
[ -f "$VERFILE" ] && read -r CURVER < "$VERFILE"

if [ "$NEWVER" = "$CURVER" ] && [ -x "$ROOTFS/bin/bash" ] && [ -x "$ROOTFS/usr/lib/postgresql/15/bin/postgres" ]; then
  ui_print "- 已有相同版本的 Debian 容器，跳过解压"
else
  if [ ! -f "$MODPATH/files/rootfs.tar.xz" ]; then
    ui_print "! 安装包内缺少 files/rootfs.tar.xz，无法安装容器"
    abort "! rootfs 缺失"
  fi
  ui_print "- 正在解压 Debian 12 容器（约 1-3 分钟，请勿断电）…"
  rm -rf "$ROOTFS"
  mkdir -p "$ROOTFS"
  xz -dc "$MODPATH/files/rootfs.tar.xz" | tar -xf - -C "$ROOTFS"
  if [ ! -x "$ROOTFS/bin/bash" ] || [ ! -x "$ROOTFS/usr/lib/postgresql/15/bin/postgres" ]; then
    ui_print "! 容器解压不完整"
    abort "! rootfs 解压失败"
  fi
  printf '%s\n' "$NEWVER" > "$VERFILE"
  ui_print "- 容器解压完成"
fi

# ---- 1.5 持久化工具层 + 重装用户工具 -------------------------------------
PERSIST_USR="$APPDIR/persist/usr-local"
PERSIST_TOOLS="$APPDIR/persist/tools"
mkdir -p "$PERSIST_USR" "$PERSIST_TOOLS"
for d in bin sbin lib share include src games; do
  mkdir -p "$PERSIST_USR/$d"
done
mkdir -p "$ROOTFS/usr/local" "$ROOTFS/opt/tools"
# 容器内 /usr/local、/opt/tools 由 service.sh 挂到持久层；此处预置挂载点

PACKAGES_LIST="$PERSIST/apt-packages.list"
if [ -f "$PACKAGES_LIST" ] && [ -s "$PACKAGES_LIST" ]; then
  PKGS=$(tr '\n' ' ' < "$PACKAGES_LIST")
  ui_print "- 重新安装用户工具：$PKGS"
  mkdir -p "$ROOTFS/proc" "$ROOTFS/dev" "$ROOTFS/dev/shm" "$ROOTFS/tmp"
  mountpoint -q "$ROOTFS/proc" || mount -t proc proc "$ROOTFS/proc" 2>/dev/null
  mountpoint -q "$ROOTFS/dev" || mount --bind /dev "$ROOTFS/dev" 2>/dev/null
  mkdir -p "$ROOTFS/etc"
  printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > "$ROOTFS/etc/resolv.conf" 2>/dev/null
  chroot "$ROOTFS" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root DEBIAN_FRONTEND=noninteractive /bin/bash -c \
    "apt-get update -qq && apt-get install -y --no-install-recommends $PKGS" >> "$PERSIST/install.log" 2>&1 \
    && ui_print "- 用户工具已恢复" || ui_print "! 用户工具恢复失败（可开机后跑 tools.sh install）"
  umount "$ROOTFS/dev" 2>/dev/null
  umount "$ROOTFS/proc" 2>/dev/null
fi

# ---- 2. 应用文件 ---------------------------------------------------------
ui_print "- 安装 ARTEX 程序文件"
cp -f "$MODPATH/files/app/artex" "$APPDIR/artex" || abort "! artex 复制失败"
chmod 755 "$APPDIR/artex"
if [ -f "$MODPATH/files/app/libsysv-shim.so" ]; then
  cp -f "$MODPATH/files/app/libsysv-shim.so" "$APPDIR/libsysv-shim.so"
  chmod 755 "$APPDIR/libsysv-shim.so"
fi
if [ ! -f "$APPDIR/config.json" ] && [ -f "$MODPATH/files/app/config.json" ]; then
  cp -f "$MODPATH/files/app/config.json" "$APPDIR/config.json"
fi
if [ -d "$MODPATH/files/app/skills" ]; then
  rm -rf "$APPDIR/skills"
  cp -R "$MODPATH/files/app/skills" "$APPDIR/skills"
fi

# ---- 3. 端口配置 ---------------------------------------------------------
if [ ! -f "$PERSIST/ports.conf" ]; then
  cat > "$PERSIST/ports.conf" <<'EOF'
# ARTEX 模块配置 —— 改完重启手机，或在模块管理器点「运行」按钮重启服务
# 浏览器访问 http://<手机IP>:WEB_PORT
WEB_PORT=8787
# 流量录制代理监听地址（只监听本机回环，留空则关闭代理）
PROXY_ADDR=127.0.0.1:8788
# 1 = 运行期间阻止系统休眠，保证随时能访问；0 = 允许休眠（更省电，但可能断连）
KEEP_AWAKE=1
EOF
  ui_print "- 已生成 $PERSIST/ports.conf（默认端口 8787）"
fi

rm -f "$PERSIST/stopped"

# ---- 4. 省空间：删掉已解压的压缩包 ---------------------------------------
rm -f "$MODPATH/files/rootfs.tar.xz"

ui_print " "
ui_print "- 安装完成！重启后自动启动"
ui_print "- 浏览器访问 http://<手机局域网IP>:8787"
ui_print "- 端口可在 /data/adb/artex/ports.conf 修改"
ui_print "- 日志: /data/adb/artex/service.log"
ui_print " "