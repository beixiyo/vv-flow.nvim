-- vv-flow.filter — 底部浮动过滤输入框
--
-- 骨架已下沉到 vv-utils.prompt（与 vv-explorer 共用同一套双行浮窗）。本文件只保留
-- vv-flow 特有的部分：三种过滤模式（fixed/subseq/regex）的 mode badge 显示元数据，
-- 以及把 panel 的 opts 适配到 vv-utils.prompt 的契约。

local hl = require('vv-utils.hl')
local Prompt = require('vv-utils.prompt')

local M = {}

hl.register('vv-flow.filter.hl', {
  VVFlowFilterModeFixed = { link = 'Function' },
  VVFlowFilterModeFuzzy = { link = 'String' },
  VVFlowFilterModeRegex = { link = 'Constant' },
})

-- 模式显示元数据：图标 + 标签 + 高亮组。模式键与 vv-utils.match.MODES 对齐，
-- 但「显示」是 vv-flow 自己的事（图标 / 主题），故留在本地
local MODE_DISPLAY = {
  fixed  = { icon = '', label = 'Fixed', hl = 'VVFlowFilterModeFixed' },
  subseq = { icon = '', label = 'Fuzzy', hl = 'VVFlowFilterModeFuzzy' },
  regex  = { icon = '󰑑', label = 'Regex', hl = 'VVFlowFilterModeRegex' },
}

---@param mode string
---@return {icon:string, label:string, hl:string}
local function mode_display(mode)
  return MODE_DISPLAY[mode] or { icon = '?', label = mode or '?', hl = 'VVPromptLabel' }
end

---@class VVFlowFilterOpts
---@field initial?       string             初始查询 @default ''
---@field status?        fun(): string      实时状态文案（如 '12 matches'）
---@field get_mode?      fun(): string      当前过滤模式键（驱动 mode badge）
---@field on_cycle_mode? fun()              # <S-Tab>：切到下一个模式（调用方负责轮换 + 重筛）
---@field on_change      fun(query: string) 防抖后每次输入变化（实时筛选）
---@field on_accept      fun(query: string) # <CR>：保留过滤态，关闭输入框
---@field on_cancel      fun()              # <Esc> / normal q / 失焦：取消过滤

-- 打开过滤输入框
---@param panel_win integer    vv-flow 侧栏 window id
---@param opts VVFlowFilterOpts
---@return fun()? close  幂等关闭句柄；面板托管，关面板时一并调用
function M.open(panel_win, opts)
  local handle = Prompt.open(panel_win, {
    initial       = opts.initial,
    filetype      = 'vv-flow-filter',
    mode_display  = mode_display,
    get_mode      = opts.get_mode,
    on_cycle_mode = opts.on_cycle_mode,
    get_status    = opts.status,
    on_change     = opts.on_change,
    on_accept     = opts.on_accept,
    on_cancel     = opts.on_cancel,
  })
  return handle and handle.close
end

return M
