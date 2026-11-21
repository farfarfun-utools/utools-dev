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
# 1. 拉取尚未克隆的子仓库（按 repos.json 中的目录结构）
node scripts/ws.mjs sync

# 2. 查看全部子仓库的分支、版本与工作区状态
node scripts/ws.mjs status

# 3. 对干净且位于默认分支的子仓库执行 fast-forward 更新
node scripts/ws.mjs sync --pull

# 4. 执行跨仓库一致性巡检（版本、清单资源、索引、窗口高度、移动端共享代码、截图路径）
node scripts/ws.mjs check
```

## 常用开发约定

- **单插件构建入口**：每个插件根目录及 `apps/utools-mobile` 均提供 `sh build.sh` 作为本地校验与 CI 的统一入口。
- **截图脚本维护**：`utools-funchat`、`utools-fundoc`、`utools-funlink`、`utools-funotp` 的 `scripts/screenshots.mjs` 和 `scripts/cdp.mjs` 由 `tools/utools-shots/build-scripts.mjs` 生成，不要只手改目标仓库的产物。
- **开发与发版规范**：详见 `skills/utools-plugin-development/SKILL.md`。

## 协议

本仓库基于 [MIT](LICENSE) 协议开源；各子仓库遵循其各自目录内的许可证。
