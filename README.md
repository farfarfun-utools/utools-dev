# utools-dev

[farfarfun-utools](https://github.com/farfarfun-utools) 组织的本地聚合开发工作区。

本仓库通过 [repos.json](repos.json) 和 [scripts/ws.mjs](scripts/ws.mjs) 管理组织下的 13 个独立子仓库（插件、移动端、索引、截图工具链与开发规范），子仓库目录本身被 `.gitignore` 忽略，各自保留独立的 Git 历史、分支与 CI/Release 流程。

## 目录结构

| 目录 | 说明 | 包含仓库 |
| :--- | :--- | :--- |
| `plugins/` | 9 个本地优先的 uTools 插件 | `utools-funcalc`, `utools-funcalendar`, `utools-funchat`, `utools-fundoc`, `utools-funimage`, `utools-funlink`, `utools-funotp`, `utools-funqr`, `utools-funvideo` |
| `apps/` | 移动端伴侣应用 | `utools-mobile`（FunMobile Android：内置 FunOTP + FunLink） |
| `tools/` | 跨仓库共享工具 | `utools-shots`（4 个 Vue 插件的 CDP 截图脚本生成与预览工具链） |
| `index/` | 组织插件总索引 | `utools-plugins` |
| `skills/` | 开发与发布规范 Skill | `utools-plugin-development` |

## 快速开始

```sh
# 1. 拉取尚未克隆的子仓库（并发克隆，按 repos.json 目录结构）
node scripts/ws.mjs init

# 2. 查看根仓库与全部子仓库的分支、版本与工作区状态
node scripts/ws.mjs status

# 3. 并发更新干净且位于 master 分支的子仓库（fast-forward）
node scripts/ws.mjs sync --pull

# 4. 清理已合并到 master 的本地旧分支（加 --dry-run 先预览）
node scripts/ws.mjs prune --dry-run

# 5. 执行跨仓库一致性巡检（版本、清单资源、索引、窗口高度、移动端共享代码、截图路径）
node scripts/ws.mjs check

# 6. 编译/使用机一键拉取最新并构建全部插件（新 clone 会自动初始化子仓库）
sh scripts/build.sh

# 仅构建单个或指定几个插件（支持短别名 otp/chat/doc/link/calc/calendar/image/qr/video、大小写不敏感、空格或逗号分隔；只拉取并校验对应插件）
sh scripts/build.sh otp
sh scripts/build.sh funchat fundoc
sh scripts/build.sh --no-pull otp,link

# 编译/使用机推荐：仅增量构建本次有更新或尚未编译的插件（加 --fast 跳过已由 CI 跑过的 lint/单测）
sh scripts/build.sh --fast --changed

# 仅增量构建（保留完整 lint/类型检查/单测）
sh scripts/build.sh --changed

# 纯编译机镜像模式：强同步到 origin/master 后构建（会丢弃本地修改）
sh scripts/build.sh --reset

# 预览执行计划 / 查看全部插件别名与编译状态
sh scripts/build.sh --list
sh scripts/build.sh --dry-run
```

## 常用开发约定

- **单插件构建入口**：每个插件根目录及 `apps/utools-mobile` 均提供 `sh build.sh` 作为本地校验与 CI 的统一入口。
- **截图脚本维护**：`utools-funchat`、`utools-fundoc`、`utools-funlink`、`utools-funotp` 的 `scripts/screenshots.mjs` 和 `scripts/cdp.mjs` 由 `tools/utools-shots/build-scripts.mjs` 生成，不要只手改目标仓库的产物。
- **开发与发版规范**：详见 `skills/utools-plugin-development/SKILL.md`。

## 协议

本仓库基于 [MIT](LICENSE) 协议开源；各子仓库遵循其各自目录内的许可证。
