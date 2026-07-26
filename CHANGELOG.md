# Changelog

## [0.2.0] - 2026-07-26

### Added

- **面板扩展配置**：新增 `panel.mappings`、`panel.render`、`panel.help` 与 `panel.on_attach`，可覆盖或禁用通用树面板的键位、渲染和帮助行为；支持注入 `state` 句柄

### Changed

- **默认流程标记改为命名空间语法**：使用大小写不敏感的 `@step:<namespace>-<number>`，按命名空间分组并在组内按数字排序；不再识别 `@1` / `@1.`，配置项由 `number` 改为 `step`
- **复用 `vv-utils.tree_panel` 与 `vv-utils.state`**：窗口生命周期、折叠、导航、帮助、预览调度和宽度持久化统一交给共享实现；flow 与 Vim marks 两种模式共用用户实际调整后的宽度
- **统一树面板交互**：分组节点可用 `<CR>` 切换折叠，叶节点按 `h` 直接折叠父组，`l` / `<CR>` 打开标记并保留面板，`gf` 打开后关闭面板；自定义键位也会进入共享 `g?` 帮助
- **拆分数据与渲染职责**：分组、排序、稳定节点 ID 和过滤文本生成移入 `panel/model.lua`，winbar、节点与空状态展示移入 `panel/render.lua`

## [0.1.1] - 2026-07-24

### Added

- **跨语言扫描黑名单**：新增可覆盖的 `exclude` 配置，复用 `vv-utils.glob` 编译 VS Code 风格 glob；默认排除 JS / TS、Rust、Go、Python、Java / Kotlin / Scala、C / C++、.NET、Ruby / PHP、Swift / iOS、Dart / Flutter 的常见依赖目录、构建产物、缓存与锁文件
- **扫描回归测试**：真实调用 `rg` 验证跨语言黑名单，并确认默认遵守 `.gitignore` / `.ignore`；即使通过 `rg_extra_args = { '--no-ignore' }` 放开 ignore，显式黑名单仍然生效

## [0.1.0] - 2026-07-13

### Added

- **`/` 过滤面板**：面板内 `/` 弹出双行浮窗输入框（视觉与交互对齐 vv-explorer `prompt.lua`），实时（防抖 30ms）过滤条目——大小写不敏感，匹配 `text` + `preview` + 相对路径 + 组名；`<CR>` 保留过滤态、`<Esc>` 清过滤、失焦自动取消。flow / marks 两模式通用
- **过滤模式切换**：filter 浮窗内 `<S-Tab>` 循环三种命中模式 `Fixed`（字面子串）→ `Fuzzy`（子序列）→ `Regex`（vim 正则），mode badge 实时显示、非法正则提示 `bad pattern`；三模式都**只判命中不重排**，保住编号流程与分组顺序。匹配内核下沉为 `vv-utils.match`（`compile` 一次复用的纯函数谓词，可被其它 vv-* 插件共享）
- **Vim marks 面板**：`<Tab>` 在「流程/TODO 标记」与「vim marks」两个面板间切换；marks 面板枚举全局 `A-Z`、局部 `a-z`（默认隐藏数字/特殊 mark，可配 `marks.show`），按 Global/Buffer 分组，复用同一套预览/跳转/过滤；`d` 删除光标处 mark。把 `:marks` 接管成可视、可过滤、可跳转的面板
- **两类内置标记**：关键字标记 `@TODO` / `@BUG` / `@FIX` / `@NOTE` / `@HACK` / `@WARN` / `@PERF`（**大小写不敏感**，各自配色，面板里按关键字分组）；编号标记 `@1` / `@01` / `@17`（末尾 `.` **可选**，面板里**按数值升序**排成一条流程）。灵感来自 VSCode *Todo Tree* 与 `@数字.` 顺序流程标记
- **实时高亮**：buffer 内标记即时上色（`extmark` + 每规则一个编译好的 `vim.regex`），随 `ColorScheme` 自动重挂；含非词字符的 `@` 标记不走 `syn keyword`，逐行 `vim.regex` 匹配
- **跨文件面板**：`rg --json` 异步扫描项目 → 侧栏列表，自动分「编号 / 关键字」两类、编号组数值升序，分组之间空行分隔，每行可跳转
- **实时预览**（参照 vv-explorer）：面板里 `j`/`k` 移动，主窗口实时打开标记位置、居中并高亮该行（**防抖**，默认 138ms，焦点留在面板）；`bufadd`+`bufload` 换 buf 不抢焦点、动态预览 buffer 保持 unlisted 不污染 bufferline、切文件删旧预览。关闭面板自动还原打开前的 buffer（未固定时）
- **预览滚动**：`C-e` / `C-y` 在面板内滚动预览窗口，每次 5 行
- **面板键位**：`<CR>`/`l`/`o` 打开跳转（保留面板）、`gf` 跳转并关闭面板、`<Tab>` 切换 flow/marks、`/` 过滤、`d` 删除 mark、`h` 折叠分组、`R`/`M` 全展开/折叠、`r` 重扫、`g?` 帮助、`<Esc>` 清过滤/关闭、`q` 关闭；鼠标 `<LeftRelease>` 点击、`<RightMouse>` 定位后跳转
- **任意正则标记**：`custom` 规则支持自定义标记语法（自带 `vim_regex` + `rg_pattern`），扫描时按「命中规则」归类
- **配置**：`prefix` / `ignore_case` / `keywords` / `number` / `custom` / `position` / `width` / `max_results` / `rg_extra_args` / `highlight` / `preview` / `preview_debounce_ms` / `marks`
- **用户命令**：`:VVFlow`（面板开关）、`:VVFlowOpen` / `:VVFlowClose` / `:VVFlowRefresh`、`:VVFlowEnable` / `:VVFlowDisable` / `:VVFlowToggle`（实时高亮开关）

### Changed

- **过滤输入框骨架下沉 `vv-utils.prompt`**：与 vv-explorer 共用同一套双行浮动 filter 框，本仓 `filter.lua` 瘦成 ~60 行薄封装（只保留三模式 mode badge 元数据 + opts 适配）。纯内部重构，交互/外观不变
