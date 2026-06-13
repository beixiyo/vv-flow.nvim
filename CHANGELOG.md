# Changelog

## [Unreleased]

### Added

- **两类内置标记**：关键字标记 `@TODO` / `@BUG` / `@FIX` / `@NOTE` / `@HACK` / `@WARN` / `@PERF`（**大小写不敏感**，各自配色，面板里按关键字分组）；编号标记 `@1` / `@01` / `@17`（末尾 `.` **可选**，面板里**按数值升序**排成一条流程）。灵感来自 VSCode *Todo Tree* 与 `@数字.` 顺序流程标记
- **实时高亮**：buffer 内标记即时上色（`extmark` + 每规则一个编译好的 `vim.regex`），随 `ColorScheme` 自动重挂；含非词字符的 `@` 标记不走 `syn keyword`，逐行 `vim.regex` 匹配
- **跨文件面板**：`rg --json` 异步扫描项目 → 侧栏列表，自动分「编号 / 关键字」两类、编号组数值升序，分组之间空行分隔，每行可跳转
- **实时预览**（参照 vv-explorer）：面板里 `j`/`k` 移动，主窗口实时打开标记位置、居中并高亮该行（**防抖**，默认 138ms，焦点留在面板）；`bufadd`+`bufload` 换 buf 不抢焦点、动态预览 buffer 保持 unlisted 不污染 bufferline、切文件删旧预览。关闭面板自动还原打开前的 buffer（未固定时）
- **预览滚动**：`C-e` / `C-y` 在面板内滚动预览窗口，每次 5 行
- **面板键位**：`<CR>`/`l`/`o` 打开跳转（保留面板）、`gf` 跳转并关闭面板、`h`/`<Tab>` 折叠、`R`/`M` 全展开/折叠、`r` 重扫、`g?` 帮助、`q` 关闭；鼠标 `<LeftRelease>` 点击、`<RightMouse>` 定位后跳转
- **任意正则标记**：`custom` 规则支持自定义标记语法（自带 `vim_regex` + `rg_pattern`），扫描时按「命中规则」归类
- **配置**：`prefix` / `ignore_case` / `keywords` / `number` / `custom` / `position` / `width` / `max_results` / `rg_extra_args` / `highlight` / `preview` / `preview_debounce_ms`
- **用户命令**：`:VVFlow`（面板开关）、`:VVFlowOpen` / `:VVFlowClose` / `:VVFlowRefresh`、`:VVFlowEnable` / `:VVFlowDisable` / `:VVFlowToggle`（实时高亮开关）
