-- vv-flow.nvim — 代码流程 / TODO 标记高亮 + 可排序跳转面板（自实现，仅依赖 ripgrep）
--
--   * 关键字标记 @TODO / @BUG …（大小写不敏感，各自配色）
--   * 流程步骤   @step:<namespace>-<number>（按命名空间分组、数字排序）
-- 也支持 custom 任意正则标记。
--
-- 能力：
--   * buffer 内实时高亮（extmark + 每 rule 一个 vim.regex）
--   * 跨文件扫描（rg --json）→ 侧栏面板，自动按「编号 / 关键字」分组，
--     编号组数值升序，每行可 <CR> 跳转
--
-- 依赖：ripgrep；Neovim >= 0.10（vim.system / vim.fs）；vv-utils
--
-- 公开 API：
--   require('vv-flow').setup(opts)
--   require('vv-flow').open() / close() / toggle_panel() / refresh()   -- 面板
--   require('vv-flow').enable() / disable()                            -- 实时高亮
--   require('vv-flow').get_config()
--
-- 用户命令（setup 注册）：
--   :VVFlow          面板开关
--   :VVFlowOpen / :VVFlowClose / :VVFlowRefresh
--   :VVFlowEnable / :VVFlowDisable / :VVFlowToggle    实时高亮开关

local Rules = require('vv-flow.rules')

local M = {}

---@class VVFlowKeywordSpec
---@field color? string|table  颜色：hex 字符串或 highlight spec @default 由内置给定
---@field icon? string         面板分组图标 @default ''

---@class VVFlowStepSpec
---@field enable boolean      是否启用流程步骤标记 @default true
---@field keyword string      固定关键字 @default 'STEP'
---@field ignore_case boolean 是否忽略关键字与命名空间大小写 @default true
---@field color? string|table 颜色 @default '#bb9af7'
---@field icon? string        图标 @default ''

---@class VVFlowCustomRule
---@field name string        唯一名（兼作面板分组键） @default 必填
---@field vim_regex string   buffer 高亮用（magic 模式 vim 正则；勿用 \< / ^ / \zs 等左边界构造） @default 必填
---@field rg_pattern string  rg 扫描用（Rust 正则） @default 必填
---@field kind? string       分组类别 @default 'custom'
---@field label? string      面板分组标题 @default prefix..name
---@field color? string|table 颜色（hex 或 highlight spec） @default 无（用 hl 链接色）
---@field icon? string       图标 @default ''
---@field hl? string         自定义高亮组名 @default 'VVFlowCustom'..name

---@class VVFlowConfig
---@field prefix string       标记前缀 @default '@'
---@field ignore_case boolean 关键字大小写不敏感 @default true
---@field keywords table<string, VVFlowKeywordSpec>  内置关键字标记表
---@field step VVFlowStepSpec  流程步骤配置
---@field custom VVFlowCustomRule[]  自定义任意正则标记 @default {}
---@field position 'left'|'right'  面板侧 @default 'right'
---@field width integer       面板宽度（列） @default 42
---@field state VVStateHandle? 面板持久状态句柄，主要用于自定义存储或测试 @default register('vv-flow', 'panel')
---@field max_results integer 单次扫描结果上限 @default 5000
---@field exclude string[]     扫描排除项（VS Code 风格 glob） @default 见 defaults.exclude
---@field rg_extra_args string[]  追加给 rg 的额外参数 @default {}
---@field highlight boolean   启动即开启 buffer 实时高亮 @default true
---@field preview boolean     面板内光标移动时实时预览标记位置 @default true
---@field preview_debounce_ms integer  预览防抖延迟（毫秒），光标停顿后才触发；0 = 不防抖 @default 138
---@field marks VVFlowMarksConfig  vim marks 面板（Tab 切换）配置
---@field panel VVFlowPanelConfig 面板渲染、快捷键和 attach 扩展 @default {}

---@class VVFlowMarksConfig
---@field show { global: boolean, buffer: boolean, numbered: boolean, special: boolean }  各类 mark 是否显示 @default global/buffer=true, numbered/special=false

---@class VVFlowPanelConfig
---@field mappings? false|VVTreePanelMappings  默认快捷键覆盖；false 禁用所有面板快捷键 @default nil
---@field render? VVTreePanelRenderers  默认渲染器的局部覆盖 @default nil
---@field help? false|VVTreePanelHelpOptions  g? 通用帮助配置；false 禁用 @default nil
---@field on_attach? fun(panel: VVTreePanel, buf: integer)  面板 buffer 创建后的扩展入口 @default nil

---@class VVFlowConfigOptions
---@field prefix? string  标记前缀 @default '@'
---@field ignore_case? boolean  关键字大小写不敏感 @default true
---@field keywords? table<string, VVFlowKeywordSpec>  内置关键字标记表 @default 内置关键字
---@field step? VVFlowStepSpec  流程步骤配置 @default 启用
---@field custom? VVFlowCustomRule[]  自定义任意正则标记 @default {}
---@field position? 'left'|'right'  面板侧 @default 'right'
---@field width? integer  面板宽度（列） @default 42
---@field state? VVStateHandle  面板持久状态句柄 @default register('vv-flow', 'panel')
---@field max_results? integer  单次扫描结果上限 @default 5000
---@field exclude? string[]  扫描排除项；空数组会清空默认值 @default 见 defaults.exclude
---@field rg_extra_args? string[]  追加给 rg 的额外参数 @default {}
---@field highlight? boolean  启动即开启实时高亮 @default true
---@field preview? boolean  面板内实时预览 @default true
---@field preview_debounce_ms? integer  预览防抖毫秒；0 表示禁用 @default 138
---@field marks? VVFlowMarksConfig  Vim marks 面板配置 @default {}
---@field panel? VVFlowPanelConfig  面板渲染、快捷键和扩展 @default {}

---@type VVFlowConfig
local defaults = {
  prefix = '@',
  ignore_case = true,
  keywords = {
    TODO = { color = '#7aa2f7', icon = '' },
    BUG  = { color = '#f7768e', icon = '' },
    FIX  = { color = '#e0af68', icon = '' },
    NOTE = { color = '#9ece6a', icon = '' },
    HACK = { color = '#ff9e64', icon = '' },
    WARN = { color = '#e0af68', icon = '' },
    PERF = { color = '#bb9af7', icon = '' },
  },
  step = {
    enable = true,
    keyword = 'STEP',
    ignore_case = true,
    color = '#bb9af7',
    icon = '',
  },
  custom = {},
  position = 'right',
  width = 42,
  state = nil,
  max_results = 5000,
  exclude = {
    -- 版本控制 / 编辑器
    '.git', '.idea', '.vscode',

    -- JS / TS 与前端构建
    'node_modules', '.pnpm', '.pnpm-store', '.yarn', '.bun',
    '.next', '.nuxt', '.output', '.svelte-kit', '.astro', '.turbo',
    'dist', 'build', 'out', 'coverage',
    'pnpm-lock.yaml', 'package-lock.json', 'npm-shrinkwrap.json',
    'yarn.lock', 'bun.lock', 'bun.lockb',

    -- Rust / Go
    'target', 'vendor', 'Cargo.lock', 'go.sum',

    -- Python
    '.venv', 'venv', '__pycache__', '.tox', '.nox',
    '.pytest_cache', '.mypy_cache', '.ruff_cache',
    'poetry.lock', 'uv.lock', 'Pipfile.lock',

    -- Java / Kotlin / Scala
    '.gradle', '.m2', '.bloop', '.metals',
    'gradle.lockfile',

    -- C / C++ / CMake
    'CMakeFiles', 'cmake-build-*',

    -- .NET
    'bin', 'obj', 'packages.lock.json',

    -- Ruby / PHP
    '.bundle', 'vendor/bundle', 'Gemfile.lock', 'composer.lock',

    -- Swift / iOS / Dart / Flutter
    'DerivedData', '.build', 'Pods', '.dart_tool',
    'Package.resolved', 'Podfile.lock', 'pubspec.lock',

    -- 通用缓存
    '.cache', '.local',
  },
  rg_extra_args = {},
  highlight = true,
  preview = true,
  preview_debounce_ms = 138,
  marks = { show = { global = true, buffer = true, numbered = false, special = false } },
  panel = {},
}

local config = defaults
local rules = {}
local hl_enabled = false
local augroup = 'vv-flow.highlight'

-- 由当前 config 重建 rules + 注册高亮组 + 喂给 highlight 模块
local function rebuild()
  rules = Rules.build(config)
  require('vv-utils.hl').register('vv-flow.rules.hl', Rules.hl_specs(rules))
  require('vv-flow.highlight').set_rules(rules)
end

-- ============================================================
-- 实时高亮 enable / disable
-- ============================================================

--- 开启 buffer 实时高亮（注册 autocmd + 回放已打开 buffer）
function M.enable()
  if hl_enabled then
    require('vv-flow.highlight').redecorate_all()
    return
  end
  hl_enabled = true
  local Hl = require('vv-flow.highlight')

  -- 仅在「文件读入 / 新建」时首次 attach；内容变更交给 on_lines 增量重绘。
  -- 不挂 BufWinEnter——它会对已 attach 的 buffer 做整缓冲区全量重绘，纯属浪费。
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
    group = vim.api.nvim_create_augroup(augroup, { clear = true }),
    callback = function(ev) Hl.attach(ev.buf) end,
  })

  -- lazy-load 时触发 buffer 的 BufReadPost 已过，主动回放
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then Hl.attach(buf) end
  end
end

--- 关闭 buffer 实时高亮
function M.disable()
  if not hl_enabled then return end
  hl_enabled = false
  vim.api.nvim_create_augroup(augroup, { clear = true })  -- 清空 autocmd
  require('vv-flow.highlight').detach_all()
end

local function toggle_highlight()
  if hl_enabled then M.disable() else M.enable() end
end

-- ============================================================
-- 面板（委托 panel 模块）
-- ============================================================

--- 获取当前配置（只读副本）
---@return VVFlowConfig
function M.get_config()
  return vim.deepcopy(config)
end

function M.open() require('vv-flow.panel').open(config) end
function M.close() require('vv-flow.panel').close() end
function M.toggle_panel() require('vv-flow.panel').toggle(config) end
function M.refresh() require('vv-flow.panel').refresh(config) end

-- ============================================================
-- setup
-- ============================================================

---@param opts? VVFlowConfigOptions
function M.setup(opts)
  local configured_state = opts and opts.state
  local configured_exclude = opts and opts.exclude
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  config.state = configured_state or require('vv-utils.state').register('vv-flow', 'panel')
  if configured_exclude then
    config.exclude = vim.deepcopy(configured_exclude)
  end
  rebuild()

  if config.highlight then M.enable() end

  -- 面板
  vim.api.nvim_create_user_command('VVFlow',        function() M.toggle_panel() end, { desc = 'vv-flow 标记面板开关' })
  vim.api.nvim_create_user_command('VVFlowOpen',    function() M.open() end, { desc = 'vv-flow 打开标记面板' })
  vim.api.nvim_create_user_command('VVFlowClose',   function() M.close() end, { desc = 'vv-flow 关闭标记面板' })
  vim.api.nvim_create_user_command('VVFlowRefresh', function() M.refresh() end, { desc = 'vv-flow 重新扫描标记' })

  -- 实时高亮（规范要求 Enable / Disable / Toggle）
  vim.api.nvim_create_user_command('VVFlowEnable',  function() M.enable() end, { desc = 'vv-flow 开启实时高亮' })
  vim.api.nvim_create_user_command('VVFlowDisable', function() M.disable() end, { desc = 'vv-flow 关闭实时高亮' })
  vim.api.nvim_create_user_command('VVFlowToggle',  toggle_highlight, { desc = 'vv-flow 切换实时高亮' })
end

return M
