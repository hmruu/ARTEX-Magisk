# NOTICE

本仓库是一个 Magisk 打包项目，里面混着两种来源的东西，许可范围不一样，别当成整包 MIT。

## MIT（LICENSE 文件覆盖的部分）

由本仓库作者编写的部分：

- `customize.sh`、`common.sh`、`service.sh`、`action.sh`、`tools.sh`、`uninstall.sh`
- `META-INF/com/google/android/`（Magisk 安装器入口）
- `files/app/shim/`（SysV 共享内存垫片的源码与二进制）
- `files/app/config.json`
- 文档（`README.md`、本文件）

## AGPL-3.0（不属于 MIT）

- `files/app/skills/`：来自 ARTEX。
- Release 里的 `artex` 二进制与内嵌前端：ARTEX 的编译产物，按 AGPL-3.0 分发。
  对应源码在 `source-v0.3.15` 分支 / `v0.3.15-source` 标签，AGPL-3.0 全文见该分支的 `LICENSE`。

## 其他

- rootfs 里的 Debian 12、PostgreSQL 15、Node.js、Python 等组件：各自原许可。
- 本项目与 ARTEX 作者无隶属关系。
