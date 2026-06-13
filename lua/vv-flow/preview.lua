-- vv-flow.preview — 面板实时预览（参照 vv-explorer/preview.lua）
--
-- 光标在面板里移到某条标记 → 主窗口自动打开该文件、定位到标记行并居中、高亮该行，
-- 焦点始终留在面板（用 bufadd+bufload+win_set_buf，不 set_current_win）。
--   • 切到另一标记的文件 → 删旧动态预览 buffer（同一刻最多一个）
--   • 动态预览 buffer 保持 unlisted，不污染 bufferline
--   • <CR> 打开 → promote 为固定（listed），关闭面板不再还原
--   • 关闭面板且未固定 → 还原主窗口打开面板前的 buffer + 视图
--
-- 单实例状态（vv-flow 面板是单例）。

local hl = require('vv-utils.hl')

local M = {}

local ns = vim.api.nvim_create_namespace('vv_flow_preview')
local PANEL_FT = 'vv-flow'

hl.register('vv-flow.preview.hl', {
  VVFlowPreviewLine = { link = 'Visual' },
})

-- buf: 当前动态预览 buffer（unlisted，切换时删）；origin: 主窗原始 { win, buf, view }；
-- hl_buf: 当前承载行高亮的 buffer
---@type { buf: integer?, origin: { win: integer, buf: integer, view: table }?, hl_buf: integer? }
local pv = { buf = nil, origin = nil, hl_buf = nil }

---@param path string
local function norm(path)
  return vim.fs.normalize(path or '')
end

-- 在面板所在 tabpage 内找主编辑窗口（非面板、非浮窗）
---@param panel_win integer
---@return integer?
function M.find_main_win(panel_win)
  if not vim.api.nvim_win_is_valid(panel_win) then return nil end
  local tab = vim.api.nvim_win_get_tabpage(panel_win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if win ~= panel_win then
      local cfg = vim.api.nvim_win_get_config(win)
      local b = vim.api.nvim_win_get_buf(win)
      if cfg.relative == '' and vim.bo[b].filetype ~= PANEL_FT then
        return win
      end
    end
  end
  return nil
end

-- buf 是否还显示在 main 之外的别的窗口（别窗共用则不删）
---@param buf integer
---@param main integer
---@return boolean
local function visible_elsewhere(buf, main)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= main and vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
      return true
    end
  end
  return false
end

-- 选主窗：优先 prev_win（面板就是从它切出来的），否则同 tab 找一个
---@param panel_win integer
---@param prev_win integer?
---@return integer?
local function resolve_main(panel_win, prev_win)
  if prev_win and prev_win ~= panel_win and vim.api.nvim_win_is_valid(prev_win)
    and vim.bo[vim.api.nvim_win_get_buf(prev_win)].buftype == '' then
    return prev_win
  end
  return M.find_main_win(panel_win)
end

-- 面板打开时记录主窗原始状态，供关闭还原
---@param panel_win integer
---@param prev_win integer?
function M.save_origin(panel_win, prev_win)
  local main = resolve_main(panel_win, prev_win)
  if not main then pv.origin = nil; return end
  local view = vim.api.nvim_win_call(main, function() return vim.fn.winsaveview() end)
  pv.origin = { win = main, buf = vim.api.nvim_win_get_buf(main), view = view }
end

-- 定位光标到标记行 + 居中 + 高亮该行
---@param main integer
---@param buf integer
---@param marker VVFlowRecord
local function position(main, buf, marker)
  local lc = vim.api.nvim_buf_line_count(buf)
  local ln = math.min(marker.lnum or 1, lc)
  pcall(vim.api.nvim_win_set_cursor, main, { ln, math.max(0, (marker.col or 1) - 1) })
  vim.api.nvim_win_call(main, function() vim.cmd('normal! zz') end)

  if pv.hl_buf and pv.hl_buf ~= buf and vim.api.nvim_buf_is_valid(pv.hl_buf) then
    vim.api.nvim_buf_clear_namespace(pv.hl_buf, ns, 0, -1)
  end
  pv.hl_buf = buf
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, ln - 1, 0, { line_hl_group = 'VVFlowPreviewLine' })
end

-- 预览某条标记的文件:行
---@param panel_win integer
---@param prev_win integer?
---@param marker VVFlowRecord
function M.show(panel_win, prev_win, marker)
  if not marker or vim.fn.filereadable(marker.file) == 0 then return end
  local main = (pv.origin and vim.api.nvim_win_is_valid(pv.origin.win)) and pv.origin.win
    or resolve_main(panel_win, prev_win)
  if not main then return end

  local abs = norm(vim.fn.fnamemodify(marker.file, ':p'))
  local cur_buf = vim.api.nvim_win_get_buf(main)

  -- 同文件已显示：只重新定位，不换 buf、不删
  if norm(vim.api.nvim_buf_get_name(cur_buf)) == abs then
    position(main, cur_buf, marker)
    return
  end

  local target = vim.fn.bufadd(marker.file)
  if target == 0 then return end
  local is_fixed = vim.bo[target].buflisted  -- 用户之前主动打开过 → 固定 buf，不纳入预览删除
  if not is_fixed then vim.bo[target].buflisted = false end
  if not vim.api.nvim_buf_is_loaded(target) then vim.fn.bufload(target) end

  if not pcall(vim.api.nvim_win_set_buf, main, target) then return end

  if not is_fixed then
    vim.bo[target].buflisted = false
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(target) and pv.buf == target then
        vim.bo[target].buflisted = false
      end
    end)
  end
  if vim.bo[target].filetype == '' then
    local ft = vim.filetype.match({ buf = target, filename = marker.file })
    if ft then vim.bo[target].filetype = ft end
  end

  require('vv-utils.bufdelete').wipe_if_throwaway(cur_buf)

  local old = pv.buf
  pv.buf = is_fixed and nil or target
  if old and old ~= target and vim.api.nvim_buf_is_valid(old)
    and not vim.bo[old].modified and not vim.bo[old].buflisted
    and not visible_elsewhere(old, main) then
    pcall(vim.api.nvim_buf_delete, old, { force = false })
  end

  position(main, target, marker)
end

-- <CR> 打开：当前预览升级为固定（listed），更新 origin 为已提交文件
---@param panel_win integer
---@param prev_win integer?
function M.promote(panel_win, prev_win)
  local main = (pv.origin and vim.api.nvim_win_is_valid(pv.origin.win)) and pv.origin.win
    or resolve_main(panel_win, prev_win)
  if not main then return end
  local buf = vim.api.nvim_win_get_buf(main)
  vim.bo[buf].buflisted = true
  if pv.hl_buf and vim.api.nvim_buf_is_valid(pv.hl_buf) then
    vim.api.nvim_buf_clear_namespace(pv.hl_buf, ns, 0, -1)
  end
  pv.hl_buf = nil
  pv.buf = nil
  local view = vim.api.nvim_win_call(main, function() return vim.fn.winsaveview() end)
  pv.origin = { win = main, buf = buf, view = view }
end

-- 关闭面板：若主窗当前仍显示「未固定的动态预览」→ 还原打开前的 buffer + 视图
function M.restore()
  if pv.hl_buf and vim.api.nvim_buf_is_valid(pv.hl_buf) then
    vim.api.nvim_buf_clear_namespace(pv.hl_buf, ns, 0, -1)
  end
  local o = pv.origin
  if o and vim.api.nvim_win_is_valid(o.win) and pv.buf
    and vim.api.nvim_win_get_buf(o.win) == pv.buf and vim.api.nvim_buf_is_valid(o.buf) then
    pcall(vim.api.nvim_win_set_buf, o.win, o.buf)
    vim.api.nvim_win_call(o.win, function() vim.fn.winrestview(o.view) end)
  end
  local b = pv.buf
  if b and vim.api.nvim_buf_is_valid(b) and not vim.bo[b].modified
    and not vim.bo[b].buflisted and not visible_elsewhere(b, -1) then
    pcall(vim.api.nvim_buf_delete, b, { force = false })
  end
  pv = { buf = nil, origin = nil, hl_buf = nil }
end

return M
