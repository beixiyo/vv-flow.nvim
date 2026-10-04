# Changelog

## 0.2.1 - 2026-08-04

### Fixed

- 刷新、切换至 Vim marks 或关闭面板时终止旧的 `rg` 扫描进程

## 0.2.0 - 2026-07-26

### Added

- 新增 `panel.mappings`、`panel.render`、`panel.help`、`panel.on_attach` 扩展配置，支持覆盖或禁用面板行为及注入 `state` 句柄

### Breaking

- 流程标记改为大小写不敏感的 `@step:<namespace>-<number>`，按命名空间分组、组内按数字排序；旧 `@1` / `@1.` 标记需迁移到新语法，配置项 `number` 改为 `step`

### Changed

- flow 与 Vim marks 两种模式共用并持久化用户调整后的面板宽度
- 统一树面板交互：分组按 `<CR>` 切换折叠，叶节点按 `h` 折叠父组，`l` / `<CR>` 打开并保留面板，`gf` 打开后关闭；自定义键位纳入 `g?` 帮助

## 0.1.1 - 2026-07-24

### Added

- 新增可覆盖的 `exclude` 配置，支持 VS Code 风格 glob，默认遵守 `.gitignore` / `.ignore` 并排除常见生态的依赖、构建产物、缓存与锁文件；即使 `rg_extra_args = { '--no-ignore' }`，显式排除项仍生效

## 0.1.0 - 2026-07-13

### Added

- `/` 实时过滤 flow / marks 条目，大小写不敏感地匹配标记、预览、路径与组名；`<CR>` 保留过滤、`<Esc>` 清除、失焦取消
- 过滤框内 `<S-Tab>` 切换 Fixed / Fuzzy / Regex，提示非法正则，过滤不改变流程与分组顺序
- `<Tab>` 切换 Vim marks 面板，按全局 / 局部分组并支持预览、跳转、过滤及 `d` 删除；`marks.show` 可显示默认隐藏的数字 / 特殊 mark
- 内置大小写不敏感的关键字标记与 `@数字` 流程标记（末尾 `.` 可选），分别按关键字分组和按数值排序
- 标记实时高亮随主题更新，跨文件面板通过 `rg` 异步扫描项目并支持跳转
- 移动时防抖预览且焦点留在面板，临时预览不污染 bufferline，关闭时还原未固定的原 buffer；`C-e` / `C-y` 每次滚动预览 5 行
- 面板支持折叠、重扫、帮助与鼠标跳转，完整键位见 README
- `custom` 支持通过 `vim_regex` 与 `rg_pattern` 定义任意正则标记
- 新增面板命令 `:VVFlow`、`:VVFlowOpen` / `:VVFlowClose` / `:VVFlowRefresh`，及高亮命令 `:VVFlowEnable` / `:VVFlowDisable` / `:VVFlowToggle`
