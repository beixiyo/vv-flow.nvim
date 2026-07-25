<div align="center">
  <h1>vv-flow.nvim</h1>
  <p><a href="./README.md">English</a> | <a href="./README.zh-CN.md">中文</a></p>
  <img src="https://github.com/beixiyo/vv-flow.nvim/releases/download/assets-2026-07-25/vv-flow.png" alt="vv-flow 演示" width="900">
  <p>想要我的 Neovim 配置？查看 <a href="https://github.com/beixiyo/dotfiles">dotfiles</a></p>
  <p>代码<strong>流程 / TODO 标记</strong>高亮 + 可排序跳转面板。自实现，仅依赖 <code>ripgrep</code> 与 <code>vv-utils</code></p>
  <p><img src="https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&amp;logoColor=white" alt="Neovim"> <img src="https://img.shields.io/badge/Lua-2C2D72?logo=lua&amp;logoColor=white" alt="Lua"></p>
</div>

灵感来自 VSCode *Todo Tree* 与 `@数字.` 顺序流程标记：在注释里埋 `@1.` `@2.` … 标注一条
跨文件流程，面板里**按编号数值排序**，顺着 `@1 → @2 → … → @17` 读懂并跳转

## 依赖

- [ripgrep](https://github.com/BurntSushi/ripgrep) — 必须，用于通过 `rg --json` 扫描项目内标记
- [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) — 必须，提供面板、输入框、匹配与计时器等共享能力

## 两类内置标记

| 类型 | 例子 | 说明 |
|------|------|------|
| **关键字标记** | `@TODO` `@BUG` `@FIX` `@NOTE` `@HACK` `@WARN` `@PERF` | **大小写不敏感**（`@todo` == `@TODO`），各自配色，面板里按关键字分组 |
| **编号标记** | `@1` `@01` `@17` `@3.` | 末尾 `.` **可选**，面板里**按数值升序**排成一条流程 |

面板**自动分两类**：`@number`（编号组，数值升序）与各关键字组，互不冲突

## 能力

- **实时高亮**：buffer 内标记即时上色（`extmark` + 每规则一个 `vim.regex`），随 `ColorScheme` 重挂
- **跨文件面板**：`rg --json` 扫描项目，默认遵守 `.gitignore` / `.ignore`，并额外应用跨语言黑名单；侧栏按分组排序，每行 `<CR>` 跳转
- **实时预览**：面板里 `j`/`k` 移动，主窗口实时打开标记位置并高亮该行（**防抖**、焦点留在面板，参照 vv-explorer）；`C-e`/`C-y` 滚动预览（每次 5 行）；关闭面板自动还原打开前的 buffer
- **`/` 过滤**：面板内 `/` 弹出输入框，实时（防抖）按子串过滤条目（大小写不敏感，匹配标记/预览/路径），两个模式通用
- **Vim marks 面板**：`<Tab>` 切到 vim marks 列表（全局 A-Z / 局部 a-z 分组），同样可预览/跳转/`d` 删除/`/` 过滤——把 `:marks` 接管成可视面板
- **任意正则**：`custom` 规则支持自定义标记语法（自带 `vim_regex` + `rg_pattern`）

## 使用

```vim
:VVFlow          " 标记面板开关（默认键 <leader>ft）
:VVFlowOpen / :VVFlowClose / :VVFlowRefresh
:VVFlowEnable / :VVFlowDisable / :VVFlowToggle   " 实时高亮开关
```

面板内：`j`/`k` 移动（**实时预览**）· `C-e`/`C-y` 滚动预览（每次 5 行）· `<CR>`/`l`/`o` 打开跳转（保留面板）· `gf` 跳转并关闭面板 · `/` 过滤 · **`<Tab>` 切换 flow ↔ vim marks** · `d` 删除 mark（marks 模式）· `h` 折叠分组 · `R`/`M` 全展开/折叠 · `r` 重扫 · `g?` 帮助 · `<Esc>` 清过滤/关闭 · `q` 关闭

## 配置（默认值）

```lua
require('vv-flow').setup({
  prefix = '@',            -- 标记前缀
  ignore_case = true,      -- 关键字大小写不敏感
  keywords = {
    TODO = { color = '#7aa2f7', icon = '' },
    BUG  = { color = '#f7768e', icon = '' },
    -- … FIX / NOTE / HACK / WARN / PERF
  },
  number = { enable = true, color = '#bb9af7', icon = '', require_dot = false },
  custom = {
    -- 任意正则标记，例：把 @link(...) 也高亮成一类
    -- { name = 'link', vim_regex = [[@link(]], rg_pattern = [[@link\(]], color = '#7dcfff' },
  },
  position = 'right',      -- 面板侧 'left'|'right'
  width = 42,
  max_results = 5000,
  -- 项目扫描黑名单（VS Code 风格 glob），默认覆盖常见生态的依赖目录、
  -- 构建产物、缓存与锁文件
  exclude = {
    'node_modules', 'dist', 'build', 'target', 'vendor', '.venv',
    '.gradle', 'bin', 'obj', 'Pods', '.dart_tool',
    'pnpm-lock.yaml', 'Cargo.lock', 'poetry.lock', 'composer.lock',
    -- 完整默认列表见 lua/vv-flow/init.lua
  },
  rg_extra_args = {},      -- 追加给 rg 的参数
  highlight = true,        -- 启动即开实时高亮
  preview = true,          -- 面板 j/k 移动时实时预览标记位置
  preview_debounce_ms = 138, -- 预览防抖（毫秒），0 = 不防抖
  marks = {                -- vim marks 面板（Tab 切换）
    show = { global = true, buffer = true, numbered = false, special = false },
  },
})
```

## 已知边界

- 编号规则是 `<prefix>\d+\.?`，会命中代码里**任意** `@数字`，如 `user@123`、CSS `@2x`
  这些一般不在意；若困扰，可设 `number.enable = false` 或用 `custom` 自定义更严格的正则
