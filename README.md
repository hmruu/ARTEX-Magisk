# ARTEX Magisk 模块

在 Android 设备上以 root 权限运行 [ARTEX](https://github.com/Autumn-27/ARTEX)
（AI 自主渗透测试系统，Go 后端 + Next.js 前端），开机自启，浏览器随时访问。

## 组成

| 层 | 内容 |
| :--- | :--- |
| Magisk 模块 | `/data/adb/modules/artex`，开机由 `service.sh` 拉起服务 |
| 容器 | Debian 12 (bookworm) arm64 rootfs，位于 `/data/artex/rootfs`，由 `chroot` 进入 |
| 数据库 | 容器内 PostgreSQL 15，数据在 `/data/artex/pgdata`（unix socket，不监听 TCP） |
| 应用 | `artex` 单二进制（前端已内嵌），位于 `/data/artex/app` |
| 配置/日志 | `/data/adb/artex/`（ports.conf、service.log） |

## 使用

1. 用 Magisk（或 KernelSU / APatch）刷入 `artex-magisk-*.zip`，重启。
2. 打开浏览器访问 `http://<手机局域网IP>:8787`。
3. 首次访问使用 `/setup` 创建管理员账号；LLM 在「系统 → LLM」里配置。

## 配置

编辑 `/data/adb/artex/ports.conf` 后重启，或在模块管理器点「运行」按钮：

```ini
WEB_PORT=8787              # 网页端口
PROXY_ADDR=127.0.0.1:8788  # 流量录制代理（仅本机，留空关闭）
KEEP_AWAKE=1               # 1=运行期间阻止休眠，保证随时可访问
```

## 常用命令

```sh
# 查看服务日志
su -c 'tail -f /data/adb/artex/service.log'

# 查看应用日志
su -c 'tail -f /data/artex/app/logs/artex.log'

# 进容器
su -c 'chroot /data/artex/rootfs /bin/bash'

# 手动重启服务
su -c '/data/adb/modules/artex/service.sh'
```

## 说明：为什么要这个 SysV 共享内存垫片

Android（GKI）内核通常关闭了 `CONFIG_SYSVIPC`，`shmget()` 直接返回 ENOSYS。
PostgreSQL 的主共享内存可以靠 `shared_memory_type = mmap` 绕开，但
`PGSharedMemoryCreate()` 在初始化阶段仍会调用一次 SysV `shmget`
（还有 `initdb` 的 bootstrap 阶段），配置项管不到这些调用。

模块自带一个 30 行的 `libsysv-shim.so`（源码见 `files/app/shim/shimsysv.c`），
把 `shmget/shmat/shmdt/shmctl` 映射到 `MAP_SHARED|MAP_ANONYMOUS` 匿名内存，
通过 `LD_PRELOAD` 只注入 PostgreSQL 进程。fork 出来的后端进程共享同一块内存，
语义与 SysV 段一致。

## 容器里装工具（python / node / apt 包）

镜像里已经预装：**python3.11 + pip + venv**、**node 24 + npm**、git、curl、wget、jq、dig、
nc、ripgrep、zip/unzip、sqlite3、nmap、vim-tiny、whois、openssl。
ARTEX 的 Bash 工具与「script(Python)」自定义工具都跑在这个容器里，PATH 已包含
`/usr/local/venv/bin`、`/usr/local/bin`、`/opt/node/bin`。

统一入口（root）：

```sh
T=/data/adb/modules/artex/tools.sh

sh $T list                        # 看已装了什么
sh $T pip install requests httpx  # Python 包（装进持久 venv）
sh $T npm install playwright      # Node 全局包（装进持久 /usr/local）
sh $T install masscan seclists    # apt 包（自动记录，模块升级会重装）
sh $T run "python3 -c 'import requests; print(requests.__version__)'"
sh $T shell                       # 进容器
```

### 什么会丢、什么不会丢

| 位置 | 内容 | 模块升级（重刷 zip）后 |
| :--- | :--- | :--- |
| `pip`（venv）→ `/data/artex/app/persist/usr-local/venv` | Python 包 / console script | ✅ 保留 |
| `npm -g` → `/data/artex/app/persist/usr-local` | Node 全局包 | ✅ 保留 |
| `/opt/tools`（bind 到 persist/tools） | 自己解压的静态工具 | ✅ 保留 |
| `tools.sh install`（apt） | 系统包，装在 rootfs 里 | ⚠️ 目录会被重写，但包名记录在 `/data/adb/artex/apt-packages.list`，刷入时自动重装 |
| `/data/artex/pgdata`、`/data/artex/app/data` | 数据库 / 任务数据 | ✅ 保留 |

想用 Playwright 的浏览器自动化：`sh $T npm install playwright && sh $T run "playwright install chromium"`（会下载 ~150MB 浏览器，装到容器 $HOME，需要时再执行）。

### 让 ARTEX 用上 venv 的 Python

ARTEX 的「script」类自定义工具需要一个 Python 解释器，启动时会自动探测并写入设置
（`python_interpreter`）。本模块 PATH 里 `/usr/local/venv/bin` 在最前，所以探测到的是
**venv 里的 python3**，通过 `tools.sh pip install` 装的包它都能 import。
若之前把解释器改成了 `/usr/bin/python3`，在「系统 → 工具」里改回 `/usr/local/venv/bin/python3` 即可。

## 数据与卸载

- 数据目录 `/data/artex/pgdata`（数据库）、`/data/artex/app`（jwt.key、SQLite、skills）。
- 升级模块 zip 时不会动数据目录。
- 卸载想保留数据：`su -c "mkdir -p /data/adb/artex && touch /data/adb/artex/.keep_on_uninstall"`