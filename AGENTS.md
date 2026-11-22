# utools-dev 工作区指引

本仓库是 `farfarfun-utools` 组织的聚合工作区，各子仓库通过 `repos.json` 组织在以下目录中：

- `plugins/utools-fun*`：11 个 uTools 插件
- `apps/utools-mobile`：FunMobile Android 应用（复用 FunOTP / FunLink 的纯业务逻辑）
- `tools/utools-shots`：FunChat / FunDoc / FunLink / FunOTP 的截图脚本生成端
- `index/utools-plugins`：全组织插件索引仓库
- `skills/utools-plugin-development`：插件开发、品牌、AI 工具与发布联动规范

## 操作规则

1. **子仓库独立提交**：`apps/`、`index/`、`plugins/`、`skills/`、`tools/` 均在根仓库 `.gitignore` 中忽略，改动需进入对应子仓库检查 `git status` 和提交，不要试图把子仓库加入根仓库暂存区。
2. **变更前后跑跨仓巡检**：修改版本、窗口高度、共享业务模块或工具路径后，运行 `node scripts/ws.mjs check` 验证跨仓库一致性。
3. **遵循开发规范**：涉及插件功能、图标、AI 工具、截图或发版时，先阅读 `skills/utools-plugin-development/SKILL.md` 及上级工作区 `AGENTS.md`（注意其中关于 GitHub Actions 执行构建/打包的约束）。
4. **不要手改生成物**：四个 Vue 插件的 `scripts/screenshots.mjs` 与 `scripts/cdp.mjs` 由 `tools/utools-shots/build-scripts.mjs` 生成；修改骨架或分镜请改 `tools/utools-shots/` 后重新生成。
