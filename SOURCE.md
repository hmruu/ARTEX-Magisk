# ARTEX 源代码（对应二进制：Release v0.3.15-r3）

本归档是 Release `v0.3.15-r3` 中 `artex-magisk-v3.zip` 内含的 **`artex` 二进制、
内嵌前端与 skills 的对应源代码**，按 AGPL-3.0 第 6 条随二进制一并提供。

| 项目 | 说明 |
| :--- | :--- |
| 上游项目 | ARTEX —— AI 自主渗透测试系统（Go 后端 + Next.js 前端），作者 Autumn-27 |
| 上游状态 | 原仓库 `Autumn-27/ARTEX` **已被作者删除**（链接失效），本归档来自删除前的最后一份可用代码 |
| 版本 | `0.3.15`（见 `CHANGELOG.md`，发布日期 2026-10-07） |
| 许可 | **AGPL-3.0**，全文见本目录 `LICENSE` |
| 代码改动 | **无**。打包过程只生成构建产物，未修改任何源码文件 |

## 构建方式（与发布二进制一致的步骤）

环境：Debian 12 arm64 容器 · Go 1.27.2 (linux/arm64) · Node v24.22.0 · Next.js 16.2.9

```sh
# 1) 前端静态导出（在 Debian 容器内执行：Next 的 SWC 需要 linux/arm64 版本）
cd web && npm ci && NEXT_EXPORT=1 npx next build
cd .. && rm -rf server/webui/dist && mkdir -p server/webui/dist
cp -a web/out/. server/webui/dist/

# 2) 后端单二进制（前端内嵌，纯静态、无 cgo）
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -tags embedui -trimpath \
  -ldflags "-s -w -buildid= -X main.version=v0.3.15" -o artex ./cmd/artex
```

生成的 `artex` 与发布包中的二进制功能一致；构建时间戳、路径与是否压缩会导致字节差异，
因此**不承诺逐字节可复现**，但源码与构建参数即为上表所列，可据此重建。

## 归档内容说明

- 包含：全部 Go 源码（`agent/`、`server/`、`db/`、`cmd/` 等）、前端源码（`web/`）、
  skills（`skills/`）、构建脚本（`build.sh`、`install.sh`、`Dockerfile`、`docker-compose.yml`）、
  `go.mod`/`go.sum`、`package-lock.json`、`LICENSE`、`CHANGELOG.md`。
- 不包含（均为可重建的构建产物，或与本二进制无关的运行期数据）：
  `web/node_modules`、`web/.next`、`web/out`、`server/webui/dist`、`dist/`、`data/`。
- Magisk 模块的胶水脚本（`customize.sh`、`common.sh`、`service.sh`、`action.sh`、`tools.sh`、
  `uninstall.sh`）与本项目原创的 SysV 垫片 `files/app/shim/shimsysv.c` 不在本归档内，
  它们在模块仓库根目录，按 MIT 使用。
- 本归档不含任何密钥、令牌、账号或运行期数据；`config.example.json` 为上游示例配置。

## 许可与免责

- 本源码的著作权归原作者所有，按 AGPL-3.0 授权。以本源码运行网络服务时，
  AGPL-3.0 第 13 条要求向使用者提供该源码。
- 删除上游仓库是作者的决定；本归档仅用于满足「随二进制提供对应源码」的许可义务，
  不代表作者对其再次公开的认可。
- 本项目（Magisk 打包）与作者无隶属关系。
