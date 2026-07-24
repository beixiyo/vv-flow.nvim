<div align="center">
  <h1>vv-flow.nvim</h1>
  <p><a href="./README.md">English</a> | <a href="./README.zh-CN.md">中文</a></p>
  <img src="./docs/assets/vv-flow.png" alt="vv-flow demo" width="900">
  <p>Want my Neovim config? See <a href="https://github.com/beixiyo/dotfiles">dotfiles</a></p>
  <p>Highlight code <strong>flow / TODO markers</strong> and navigate them in a sortable panel. Built from scratch with only <code>ripgrep</code> and <code>vv-utils</code> as dependencies</p>
  <p><img src="https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&amp;logoColor=white" alt="Neovim"> <img src="https://img.shields.io/badge/Lua-2C2D72?logo=lua&amp;logoColor=white" alt="Lua"></p>
</div>

Inspired by VSCode's *Todo Tree* and ordered flow markers written as `@number.`: place `@1.`, `@2.`, and so on in comments to describe a flow across files. The panel sorts them **numerically**, so you can follow and navigate `@1 → @2 → … → @17`

## Requirements

- [ripgrep](https://github.com/BurntSushi/ripgrep) — required for project-wide marker scanning through `rg --json`
- [vv-utils.nvim](https://github.com/beixiyo/vv-utils.nvim) — shared panel, prompt, matching, and timer utilities

## Two built-in marker types

| Type | Examples | Description |
|------|----------|-------------|
| **Keyword markers** | `@TODO` `@BUG` `@FIX` `@NOTE` `@HACK` `@WARN` `@PERF` | **Case-insensitive** (`@todo` == `@TODO`), individually colored, and grouped by keyword in the panel |
| **Numbered markers** | `@1` `@01` `@17` `@3.` | The trailing `.` is **optional**; entries are sorted in **ascending numerical order** to form a flow |

The panel **automatically separates both types**: numbered markers appear in an `@number` group sorted numerically, while each keyword has its own group, with no conflicts between them

## Features

- **Live highlighting**: markers are colored immediately inside the buffer (`extmark` + one `vim.regex` per rule), with highlights reapplied on `ColorScheme`
- **Cross-file panel**: scans the project with `rg --json`, respects `.gitignore` / `.ignore` by default, and applies an additional cross-language exclusion list; press `<CR>` on any entry to navigate to it
- **Live preview**: moving with `j`/`k` in the panel opens the marker location in the main window and highlights its line in real time (**debounced**, while focus remains in the panel, following vv-explorer); scroll the preview by 5 lines with `C-e`/`C-y`; closing the panel restores the buffer that was open beforehand
- **`/` filtering**: press `/` in the panel to open an input box and filter entries by substring in real time (debounced and case-insensitive, matching markers, previews, and paths); available in both modes
- **Vim marks panel**: press `<Tab>` to switch to a Vim marks list, with global A-Z and buffer-local a-z marks grouped separately; it supports the same preview, navigation, `d` deletion, and `/` filtering, replacing `:marks` with a visual panel
- **Arbitrary regular expressions**: `custom` rules support custom marker syntax with both `vim_regex` and `rg_pattern`

## Usage

```vim
:VVFlow          " Toggle the marker panel (default key: <leader>ft)
:VVFlowOpen / :VVFlowClose / :VVFlowRefresh
:VVFlowEnable / :VVFlowDisable / :VVFlowToggle   " Toggle live highlighting
```

Inside the panel: move with `j`/`k` (**live preview**) · scroll the preview by 5 lines with `C-e`/`C-y` · open and navigate while keeping the panel with `<CR>`/`l`/`o` · navigate and close the panel with `gf` · filter with `/` · **switch between flow ↔ Vim marks with `<Tab>`** · delete a mark with `d` (marks mode) · collapse a group with `h` · expand/collapse all with `R`/`M` · rescan with `r` · open help with `g?` · clear the filter or close with `<Esc>` · close with `q`

## Configuration (defaults)

```lua
require('vv-flow').setup({
  prefix = '@',            -- Marker prefix
  ignore_case = true,      -- Case-insensitive keywords
  keywords = {
    TODO = { color = '#7aa2f7', icon = '' },
    BUG  = { color = '#f7768e', icon = '' },
    -- … FIX / NOTE / HACK / WARN / PERF
  },
  number = { enable = true, color = '#bb9af7', icon = '', require_dot = false },
  custom = {
    -- Arbitrary regex marker; for example, highlight @link(...) as its own type
    -- { name = 'link', vim_regex = [[@link(]], rg_pattern = [[@link\(]], color = '#7dcfff' },
  },
  position = 'right',      -- Panel side: 'left'|'right'
  width = 42,
  max_results = 5000,
  -- VS Code-style globs excluded from project scans. Defaults cover dependency
  -- directories, build output, caches, and lockfiles across common ecosystems
  exclude = {
    'node_modules', 'dist', 'build', 'target', 'vendor', '.venv',
    '.gradle', 'bin', 'obj', 'Pods', '.dart_tool',
    'pnpm-lock.yaml', 'Cargo.lock', 'poetry.lock', 'composer.lock',
    -- See lua/vv-flow/init.lua for the complete default list
  },
  rg_extra_args = {},      -- Additional arguments passed to rg
  highlight = true,        -- Enable live highlighting on startup
  preview = true,          -- Live-preview marker locations while moving with j/k
  preview_debounce_ms = 138, -- Preview debounce in milliseconds; 0 disables debouncing
  marks = {                -- Vim marks panel (switch with Tab)
    show = { global = true, buffer = true, numbered = false, special = false },
  },
})
```

## Known limitations

- The numbered-marker rule is `<prefix>\d+\.?`, so it matches **any** `@number` in code, including `user@123` and CSS `@2x`. These matches are usually harmless; if they are distracting, set `number.enable = false` or define a stricter regular expression with `custom`
