-- vv-flow.filter — 底部浮动过滤输入框（双行，视觉对齐 vv-explorer/prompt.lua）
--
-- 两行布局（buffer 实际 2 行，避开 floating window 里 virt_lines 不稳的坑）：
--   line 0 = 空串，用 extmark overlay 画 label：图标 + 「filter」badge + 实时匹配数状态
--   line 1 = 用户输入；空时 overlay 显示 placeholder（第一字符即覆盖），输入行保持干净
--
-- 光标锁在 line 1：CursorMoved/CursorMovedI 无差别拉回（覆盖键盘/鼠标/折叠跳转，
-- 比 keymap 黑名单稳）
--
-- 交互：边打边过滤（debounce 30ms）→ on_change；<CR> → on_accept（保留过滤态）；
-- <Esc> / normal q → on_cancel；失焦自动 on_cancel
-- 关键顺序：先 stopinsert 再 nvim_win_close（否则残留 Insert 模式，焦点回侧栏后按键写错地方）

local hl = require('vv-utils.hl')

local PROMPT_HEIGHT = 2
local LABEL_ROW = 0          -- 0-indexed：label overlay 行
local INPUT_ROW = 1          -- 0-indexed：用户输入行
local INPUT_LNUM = INPUT_ROW + 1  -- nvim_win_set_cursor 是 1-indexed

local M = {}

hl.register('vv-flow.filter.hl', {
  VVFlowFilterIcon  = { link = 'Special' },
  VVFlowFilterLabel = { link = 'Title' },
  VVFlowFilterHint  = { link = 'Comment' },
  VVFlowFilterCount = { link = 'Comment' },
  VVFlowFilterModeFixed = { link = 'Function' },
  VVFlowFilterModeFuzzy = { link = 'String' },
  VVFlowFilterModeRegex = { link = 'Constant' },
})

-- 模式显示元数据：图标 + 标签 + 高亮组。模式键取自 vv-utils.match.MODES，
-- 但「显示」是各插件自己的事（图标 / 主题），故留在本地，避免与 vv-utils 双源耦合
local MODE_DISPLAY = {
  fixed  = { icon = '', label = 'Fixed', hl = 'VVFlowFilterModeFixed' },
  subseq = { icon = '', label = 'Fuzzy', hl = 'VVFlowFilterModeFuzzy' },
  regex  = { icon = '󰑑', label = 'Regex', hl = 'VVFlowFilterModeRegex' },
}

---@param mode string
---@return {icon:string, label:string, hl:string}
local function mode_display(mode)
  return MODE_DISPLAY[mode] or { icon = '?', label = mode or '?', hl = 'VVFlowFilterLabel' }
end

-- 创建浮窗 buffer + window，贴在 panel 窗口底部 PROMPT_HEIGHT 行
---@param panel_win integer
---@param initial string
---@return integer? buf, integer? win
local function setup_floating_window(panel_win, initial)
  if not vim.api.nvim_win_is_valid(panel_win) then return nil, nil end

  local pos = vim.api.nvim_win_get_position(panel_win)
  local width = vim.api.nvim_win_get_width(panel_win)
  local height = vim.api.nvim_win_get_height(panel_win)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'vv-flow-filter'
  -- 两行：line 0 占位给 label overlay，line 1 是用户输入
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '', initial })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = pos[1] + height - PROMPT_HEIGHT,
    col = pos[2],
    width = width,
    height = PROMPT_HEIGHT,
    style = 'minimal',
    border = 'none',
    focusable = true,
    zindex = 50,
  })

  local api = vim.api
  api.nvim_set_option_value('winhighlight', 'Normal:NormalFloat', { win = win, scope = 'local' })
  api.nvim_set_option_value('signcolumn', 'no', { win = win, scope = 'local' })
  api.nvim_set_option_value('number', false, { win = win, scope = 'local' })
  api.nvim_set_option_value('cursorline', false, { win = win, scope = 'local' })
  return buf, win
end

-- 装饰：label（图标 + badge + 状态）overlay 在 line 0；placeholder overlay 在 line 1
-- 返回 redraw()，输入变化时调用刷新状态
---@param buf integer
---@param opts VVFlowFilterOpts
---@return fun() redraw
local function setup_decorations(buf, opts)
  local label_ns = vim.api.nvim_create_namespace('vv-flow-filter-label')
  local ph_ns = vim.api.nvim_create_namespace('vv-flow-filter-ph')
  local icon = opts.icon or ''
  local label = opts.label or 'filter'
  local placeholder = opts.placeholder or 'type to filter…'

  -- 有 get_mode → 画 mode badge（icon+label）+ <S-Tab> 提示；否则回退静态 label
  local function draw_label()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, label_ns, 0, -1)

    local mode = opts.get_mode and opts.get_mode()
    local segs
    if mode then
      local md = mode_display(mode)
      segs = {
        { ' ',                        'VVFlowFilterHint' },
        { md.icon .. ' ' .. md.label, md.hl },
        { '  ',                       'VVFlowFilterHint' },
        { '<S-Tab>',                  'VVFlowFilterIcon' },
        { ' switch',                  'VVFlowFilterHint' },
      }
    else
      segs = {
        { ' ',          'VVFlowFilterHint' },
        { icon .. ' ',  'VVFlowFilterIcon' },
        { label,        'VVFlowFilterLabel' },
      }
    end

    local status = opts.status and opts.status() or ''
    if status ~= '' then
      segs[#segs + 1] = { '  ·  ', 'VVFlowFilterHint' }
      segs[#segs + 1] = { status, 'VVFlowFilterCount' }
    end

    vim.api.nvim_buf_set_extmark(buf, label_ns, LABEL_ROW, 0, {
      virt_text = segs,
      virt_text_pos = 'overlay',
      right_gravity = false,
    })
  end

  local function draw_placeholder()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, ph_ns, 0, -1)
    local line = vim.api.nvim_buf_get_lines(buf, INPUT_ROW, INPUT_ROW + 1, false)[1] or ''
    if #line == 0 then
      vim.api.nvim_buf_set_extmark(buf, ph_ns, INPUT_ROW, 0, {
        virt_text = { { placeholder, 'VVFlowFilterHint' } },
        virt_text_pos = 'overlay',
        right_gravity = false,
      })
    end
  end

  return function()
    draw_label()
    draw_placeholder()
  end
end

-- 取消 / 提交 / 切模式 keymap
---@param buf integer
---@param opts VVFlowFilterOpts
---@param ctx { close: fun(), get_query: fun(): string, redraw: fun() }
local function setup_keymaps(buf, opts, ctx)
  -- stopinsert 必须先于 close：否则 prompt 关后 Insert 模式残留，焦点回侧栏时按键写到落脚 buffer
  vim.keymap.set({ 'i', 'n' }, '<Esc>', function()
    vim.cmd.stopinsert()
    ctx.close()
    opts.on_cancel()
  end, { buffer = buf, nowait = true, silent = true })

  vim.keymap.set({ 'i', 'n' }, '<CR>', function()
    local q = ctx.get_query()
    vim.cmd.stopinsert()
    ctx.close()
    opts.on_accept(q)
  end, { buffer = buf, nowait = true, silent = true })

  -- <S-Tab>：循环切换过滤模式（焦点不离开输入框），切完立即按新模式重筛 + 重画 badge
  if opts.on_cycle_mode then
    vim.keymap.set({ 'i', 'n' }, '<S-Tab>', function()
      opts.on_cycle_mode()
      ctx.redraw()
    end, { buffer = buf, nowait = true, silent = true })
  end

  -- normal 模式 q（可经 <C-c> 退到 normal 后使用）
  vim.keymap.set('n', 'q', function()
    vim.cmd.stopinsert()
    ctx.close()
    opts.on_cancel()
  end, { buffer = buf, nowait = true, silent = true })
end

---@class VVFlowFilterOpts
---@field initial?     string             初始查询（默认 ''）
---@field icon?        string             label 图标 @default
---@field label?       string             label 文案 @default 'filter'
---@field placeholder? string             空输入占位 @default 'type to filter…'
---@field status?      fun(): string      实时状态文案（如 '12 matches'），随每次输入刷新
---@field get_mode?      fun(): string      当前过滤模式键（驱动 mode badge 显示）；缺省则显示静态 label
---@field on_cycle_mode? fun()              <S-Tab>：切到下一个模式（调用方负责轮换 + 重筛）
---@field on_change    fun(query: string) 防抖后每次输入变化（实时筛选）
---@field on_accept    fun(query: string) <CR>：保留过滤态，关闭输入框
---@field on_cancel    fun()              <Esc> / normal q / 失焦：取消过滤

-- 打开过滤输入框
---@param panel_win integer                vv-flow 侧栏 window id（浮窗贴它底部、宽度对齐）
---@param opts VVFlowFilterOpts
---@return fun()? close  幂等关闭句柄；调用方应在自身销毁时调用以连带关闭浮窗
function M.open(panel_win, opts)
  local initial = opts.initial or ''
  local buf, win = setup_floating_window(panel_win, initial)
  if not buf or not win then return end

  local closed = false
  local cancel_debounce = nil
  local aug_name = 'vv-flow.filter.' .. buf

  local redraw = setup_decorations(buf, opts)
  redraw()

  local function get_query()
    return vim.api.nvim_buf_get_lines(buf, INPUT_ROW, INPUT_ROW + 1, false)[1] or ''
  end

  local function close()
    if closed then return end
    closed = true
    if cancel_debounce then pcall(cancel_debounce) end
    pcall(vim.api.nvim_del_augroup_by_name, aug_name)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  -- 光标落在输入行行尾，进入 Insert
  vim.api.nvim_win_set_cursor(win, { INPUT_LNUM, #initial })
  vim.cmd.startinsert({ bang = true })

  local aug = vim.api.nvim_create_augroup(aug_name, { clear = true })

  -- 兜底：buffer 被任何路径 wipe（含绕过 close 的外部关闭）时走 close，释放 uv timer
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = aug, buffer = buf, once = true,
    callback = function() close() end,
  })

  -- 光标锁：离开输入行就拉回
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = aug, buffer = buf,
    callback = function()
      if closed or not vim.api.nvim_win_is_valid(win) then return end
      local pos = vim.api.nvim_win_get_cursor(win)
      if pos[1] ~= INPUT_LNUM then
        pcall(vim.api.nvim_win_set_cursor, win, { INPUT_LNUM, pos[2] })
      end
    end,
  })

  -- 防抖：on_change 后 redraw（状态/匹配数依赖筛选结果，须在 on_change 之后刷新）
  local on_change_debounced
  on_change_debounced, cancel_debounce = require('vv-utils.timer').debounce(function()
    if closed or not vim.api.nvim_buf_is_valid(buf) then return end
    opts.on_change(get_query())
    redraw()
  end, 30)

  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    group = aug, buffer = buf,
    callback = function()
      redraw()  -- 占位/label 立即刷新（首字符即覆盖 placeholder），过滤走防抖
      on_change_debounced()
    end,
  })

  setup_keymaps(buf, opts, { close = close, get_query = get_query, redraw = redraw })

  -- 失焦自动取消
  vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
    group = aug, buffer = buf, once = true,
    callback = function()
      if not closed then
        close()
        opts.on_cancel()
      end
    end,
  })

  return close
end

return M
