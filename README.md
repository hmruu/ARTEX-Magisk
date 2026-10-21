# ARTEX Magisk 模块

把 ARTEX 装进 Android 的 Magisk 模块。刷完重启，浏览器打开 `http://手机IP:8787` 就能用。

ARTEX 是套 AI 自主渗透测试系统（Go 后端 + Next.js 前端），原本要求 Docker 加 PostgreSQL。
Android 上这两样都不好使：bionic 拒绝执行 glibc 程序，系统里也没有 PostgreSQL。
所以这里的办法是往手机里塞一个 Debian 12 arm64 的 rootfs，用 chroot 跑起来，
容器里装 PostgreSQL 15 和 artex 本体，只把 8787 端口露给宿主。

在 Android 14 + Magisk alpha 上实测可用。arm64，Android 10 以上应该都行，KernelSU / APatch 没试过。

## 装

1. 到 [Releases](../../releases/latest) 下 `artex-magisk-v3.zip`（144 MB）
2. Magisk → 模块 → 从本地安装 → 选这个 zip，重启
3. 打开 `http://<手机局域网IP>:8787`，第一次进去会让你设密码

首次开机会跑 initdb 建库，等 20–60 秒，期间打不开是正常的。
进度看日志：

```sh
su -c 'tail -f /data/adb/artex/service.log'
```

不想重启也可以走命令行（手动把 update 目录挪过去）：

```sh
su -c 'magisk --install-module /sdcard/Download/artex-magisk-v3.zip'
su -c 'cp -a /data/adb/modules_update/artex/. /data/adb/modules/artex/ && rm -rf /data/adb/modules_update/artex && sh /data/adb/modules/artex/service.sh'
```

## 用

端口和两个开关都在 `/data/adb/artex/ports.conf`，改完重启手机或在模块卡片上点「运行」：

```ini
WEB_PORT=8787              # 网页端口
PROXY_ADDR=127.0.0.1:8788  # 流量录制代理，只监听本机；留空就关掉
KEEP_AWAKE=1               # 开着不睡，保证随时能连；嫌费电改 0
```

几个常用命令：

```sh
su -c 'tail -f /data/artex/app/logs/artex.log'      # 应用日志
su -c 'tail -f /data/artex/app/logs/postgresql.log' # 数据库日志
su -c 'chroot /data/artex/rootfs /bin/bash'         # 进容器
su -c '/data/adb/modules/artex/service.sh'          # 重启服务
su -c 'curl -s http://127.0.0.1:8787/api/health'    # 健康检查
```

东西都在这几个位置：

| 路径 | 是什么 |
| :--- | :--- |
| `/data/adb/modules/artex/` | 模块本体（脚本、`tools.sh`） |
| `/data/adb/artex/` | `ports.conf`、`service.log`、`apt-packages.list` |
| `/data/artex/rootfs/` | Debian 容器，约 648 MB |
| `/data/artex/app/` | `artex` 二进制、`skills/`、`jwt.key`、`data/`、`persist/` |
| `/data/artex/pgdata/` | PostgreSQL 数据目录 |

## 加工具

容器里已经带了 Python 3.11（含 pip、venv）、Node 24、git、curl、wget、jq、dig、nc、
ripgrep、sqlite3、nmap、vim-tiny。ARTEX 的 Bash 工具和 Python 脚本工具都在这个容器里跑，
PATH 里已经包含 `/usr/local/venv/bin`、`/usr/local/bin`、`/opt/node/bin`。

再装东西用 `tools.sh`：

```sh
T=/data/adb/modules/artex/tools.sh

sh $T list                        # 看看有啥
sh $T pip install requests httpx  # Python 包
sh $T npm install playwright      # Node 全局包
sh $T install masscan seclists    # apt 包
sh $T run "python3 -c 'import requests; print(requests.__version__)'"
sh $T shell
```

持久化这块容易踩：pip 和 npm 装到 `/data/artex/app/persist/usr-local`（容器里的
`/usr/local` 和 `/opt/tools` 都 bind 到这里），重刷模块不会丢；
apt 包装在 rootfs 里，重刷会被冲掉，但包名记在 `/data/adb/artex/apt-packages.list`，
刷入时自动重装（要联网）。数据库和任务数据一直在 `/data/artex`，不受影响。

想用 Playwright 抓浏览器：`sh $T npm install playwright && sh $T run "playwright install chromium"`，
浏览器约 150 MB，按需再装。

## 实现

```
Magisk service.sh
└── chroot /data/artex/rootfs          Debian 12 arm64
    ├── /opt/artex        ← /data/artex/app
    ├── /usr/local        ← /data/artex/app/persist/usr-local
    ├── /opt/tools        ← /data/artex/app/persist/tools
    ├── /var/lib/postgresql/data ← /data/artex/pgdata
    ├── PostgreSQL 15     只走 /run/postgresql 的 unix socket，不开 TCP
    └── /opt/artex/artex  Go 单二进制，前端已内嵌
```

守护进程每 30 秒查一次 PostgreSQL 和 artex 在不在，掉了就拉起来。

有个坑值得单独说一句：Android 的 GKI 内核基本都关了 `CONFIG_SYSVIPC`，`shmget` 直接返回
ENOSYS，PostgreSQL 连 `initdb` 都过不去：

```
FATAL:  could not create shared memory segment: Function not implemented
DETAIL:  Failed system call was shmget(key=4452628, size=56, 03600)
```

`shared_memory_type = mmap` 能绕开主共享内存，但 initdb 的 bootstrap 和
`PGSharedMemoryCreate()` 内部还会直接调 SysV，这两处没有配置项能管。
所以模块里带了个 30 行的 `libsysv-shim.so`（源码在 `files/app/shim/shimsysv.c`），
把这几个调用映射到 `MAP_SHARED|MAP_ANONYMOUS`，靠 `LD_PRELOAD` 只注入 PostgreSQL。

## 已知问题

- **DNS 不走 VPN**。容器里的 `/etc/resolv.conf` 写死 `223.5.5.5 / 119.29.29.29`，
  ARTEX 的 Go 解析器读的就是它，所以走 VPN 或内网 DNS 时，域名解析结果可能和手机浏览器不一样。
  改法：`su -c 'printf "nameserver 1.1.1.1\n" > /data/artex/rootfs/etc/resolv.conf'` 后重启。
- **手动 `pg_ctl start` 会失败**，因为没带 `LD_PRELOAD`。日常别手起，用 `service.sh` 或 `tools.sh`。
- **内存紧的机器会被系统杀**。守护 30 秒内会拉回来，但如果一直不够内存就会反复重启；
  可以调小 `/data/artex/pgdata/postgresql.conf` 里的 `shared_buffers`。
- **MIUI / HyperOS 这类系统喜欢杀后台**，`KEEP_AWAKE` 只防休眠，不防厂商清理，得去电池设置里放行。
- **升级方式**：直接再刷新 zip。rootfs 会重新解压，数据目录和持久层不动。
  卸载想留数据就先 `su -c 'mkdir -p /data/adb/artex && touch /data/adb/artex/.keep_on_uninstall'`。
- 只支持 arm64。x86 模拟器、32 位设备用不了。

## 从源码构建

构建得在 Debian 容器里做（Next 的 SWC 只有 linux/arm64 版，Go 交叉编译没问题）：

```sh
# 前端静态导出
cd web && npm ci && NEXT_EXPORT=1 npx next build
cd .. && rm -rf server/webui/dist && mkdir -p server/webui/dist && cp -a web/out/. server/webui/dist/

# 后端（前端内嵌，纯静态）
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -tags embedui -trimpath \
  -ldflags "-s -w -buildid= -X main.version=v0.3.15" -o artex ./cmd/artex
```

ARTEX 源码在上游仓库被作者删除后，我把对应源码放进
[`source-v0.3.15`](../../tree/source-v0.3.15) 分支（标签 `v0.3.15-source`），
里面 `SOURCE.md` 写了完整环境和命令。ARTEX 本体是 AGPL-3.0。
