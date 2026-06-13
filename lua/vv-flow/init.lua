-- vv-flow.nvim — 代码流程 / TODO 标记高亮 + 可排序跳转面板（自实现，仅依赖 ripgrep）
--
-- 灵感来自 VSCode "Todo Tree" 与 `@数字.` 顺序流程标记。两类内置标记：
--   * 关键字标记 @TODO / @BUG …（大小写不敏感，各自配色）
--   * 编号标记   @1 / @01 / @17（末尾 . 可选，按数值排序读流程）
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

---@class VVFlowNumberSpec
---@field enable boolean      是否启用编号标记 @default true
---@field color? string|table 颜色 @default '#bb9af7'
---@field icon? string        图标 @default ''
---@field require_dot boolean 末尾点是否必需（false = 可选） @default false

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
---@field number VVFlowNumberSpec  编号标记配置
---@field custom VVFlowCustomRule[]  自定义任意正则标记 @default {}
---@field position 'left'|'right'  面板侧 @default 'right'
---@field width integer       面板宽度（列） @default 42
---@field max_results integer 单次扫描结果上限 @default 5000
---@field rg_extra_args string[]  追加给 rg 的额外参数 @default {}
---@field highlight boolean   启动即开启 buffer 实时高亮 @default true
---@field preview boolean     面板内光标移动时实时预览标记位置 @default true
---@field preview_debounce_ms integer  预览防抖延迟（毫秒），光标停顿后才触发；0 = 不防抖 @default 138

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
  number = { enable = true, color = '#bb9af7', icon = '', require_dot = false },
  custom = {},
  position = 'right',
  width = 42,
  max_results = 5000,
  rg_extra_args = {},
  highlight = true,
  preview = true,
  preview_debounce_ms = 138,
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

function M.open() require('vv-flow.panel').open() end
function M.close() require('vv-flow.panel').close() end
function M.toggle_panel() require('vv-flow.panel').toggle() end
function M.refresh() require('vv-flow.panel').refresh() end

-- ============================================================
-- setup
-- ============================================================

---@param opts? VVFlowConfig
function M.setup(opts)
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
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

--- 获取当前配置（只读副本）
---@return VVFlowConfig
function M.get_config()
  return vim.deepcopy(config)
end

return M
