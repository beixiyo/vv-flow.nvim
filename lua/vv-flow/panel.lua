-- vv-flow.panel — 标记列表侧栏（自动分组 + 排序 + 跳转）
--
-- 分组：编号组（@number）按数值升序，关键字组（@todo/@bug…）各自成组、按
-- 文件→行排序，两类互不冲突。渲染、line_map、折叠抄 vv-task-panel/ui.lua；
-- 跳转抄 vv-replace/actions.lua（edit + set_cursor + zz）；鼠标遵循 AGENTS 规范。

local hl = require('vv-utils.hl')
local Match = require('vv-utils.match')
local Scan = require('vv-flow.scan')
local Rules = require('vv-flow.rules')
local Marks = require('vv-flow.marks')

local M = {}

local ns = vim.api.nvim_create_namespace('vv_flow_panel')

-- mode: 'flow'（rg 扫描的流程/TODO 标记）| 'marks'（vim marks）。Tab 切换，两模式共用 filter
-- filter_mode: 'fixed'|'subseq'|'regex'（filter 浮窗内 <S-Tab> 轮换），filter_invalid 标记非法 regex
---@type { buf: integer?, win: integer?, prev_win: integer?, root: string?, groups: table[]?, records: table[]?, rules: table[]?, mode: string, filter_query: string, filter_mode: string, filter_invalid: boolean?, filter_close: fun()?, scan_token: integer, preview_enabled: boolean?, preview_cancel: fun()? }
local state = { buf = nil, win = nil, prev_win = nil, root = nil, groups = nil, records = nil, rules = nil, mode = 'flow', filter_query = '', filter_mode = 'fixed', scan_token = 0 }

-- 行 → 数据映射：{ kind='group'|'marker', group_idx, marker? }
---@type table<integer, table>
local line_map = {}

-- 前置声明：数据层（rebuild/do_scan/load_marks）被交互层与 create_buf 引用，互相也有引用
local rebuild, do_scan, load_marks

local CHEV_OPEN = '▾'
local CHEV_CLOSED = '▸'

local CE_KEY = vim.api.nvim_replace_termcodes('<C-e>', true, false, true)
local CY_KEY = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)
local SCROLL_LINES = 5  -- C-e / C-y 一次滚动行数（与 vv-explorer 一致）

hl.register('vv-flow.panel.hl', {
  VVFlowPanelTitle     = { link = 'Title' },
  VVFlowPanelTitleIcon = { link = 'Special' },
  VVFlowPanelSep       = { link = 'Comment' },
  VVFlowPanelChevron   = { link = 'Comment' },
  VVFlowPanelGroup     = { link = 'Directory' },
  VVFlowPanelCount     = { link = 'Comment' },
  VVFlowPanelPath      = { link = 'Comment' },
  VVFlowPanelLnum      = { link = 'Number' },
  VVFlowPanelPreview   = { link = 'Comment' },
  VVFlowPanelEmpty     = { link = 'Comment' },
  VVFlowPanelFooter    = { link = 'Comment' },
  VVFlowMarkGlobal     = { link = 'Identifier' },
  VVFlowMarkBuffer     = { link = 'Function' },
  VVFlowMarkNumbered   = { link = 'Number' },
  VVFlowMarkSpecial    = { link = 'Special' },
})

-- ============================================================
-- 数据：扫描结果 → 有序分组
-- ============================================================

-- 路径相对 root 显示
---@param root string
---@param file string
---@return string
local function relpath(root, file)
  local ok, rel = pcall(vim.fs.relpath, root, file)
  if ok and rel then return rel end
  if root and root ~= '' and file:sub(1, #root + 1) == root .. '/' then
    return file:sub(#root + 2)
  end
  -- 不在 root 之下（如 marks 模式指向别处的 mark）：用 ~ 缩写而非只剩 basename，
  -- 保留路径区分度（~/other-proj/lib/foo.lua、/etc/hosts）
  return vim.fn.fnamemodify(file, ':~')
end

-- 把 records 按 rules 顺序归组并排序
---@param records VVFlowRecord[]
---@param rules VVFlowRule[]
---@return table[] groups
local function build_groups(records, rules)
  -- 按 rule 顺序建空组 + name→idx 索引
  local groups = {}
  local idx_by_name = {}
  for _, r in ipairs(rules) do
    groups[#groups + 1] = {
      name = r.name, label = r.label, icon = r.icon, hl = r.hl, kind = r.kind,
      markers = {}, open = true,
    }
    idx_by_name[r.name] = #groups
  end

  -- 归桶；未匹配到 rule 的 record 兜底成一个以其 name 命名的组
  for _, rec in ipairs(records) do
    local gi = idx_by_name[rec.name]
    if not gi then
      groups[#groups + 1] = {
        name = rec.name, label = rec.text or rec.name, icon = '', hl = 'Normal',
        kind = rec.kind, markers = {}, open = true,
      }
      gi = #groups
      idx_by_name[rec.name] = gi
    end
    table.insert(groups[gi].markers, rec)
  end

  -- 组内排序
  for _, g in ipairs(groups) do
    if g.kind == 'number' then
      table.sort(g.markers, function(a, b)
        if (a.num or 0) ~= (b.num or 0) then return (a.num or 0) < (b.num or 0) end
        if a.file ~= b.file then return a.file < b.file end
        return a.lnum < b.lnum
      end)
    else
      table.sort(g.markers, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.lnum < b.lnum
      end)
    end
  end

  -- 丢掉空组
  local out = {}
  for _, g in ipairs(groups) do
    if #g.markers > 0 then out[#out + 1] = g end
  end
  return out
end

-- mark 面板分组：按固定顺序成组、组内按 mark 字符排序
local MARK_GROUPS = {
  { name = 'Global A-Z', hl = 'VVFlowMarkGlobal' },
  { name = 'Buffer a-z', hl = 'VVFlowMarkBuffer' },
  { name = 'Numbered',   hl = 'VVFlowMarkNumbered' },
  { name = 'Special',    hl = 'VVFlowMarkSpecial' },
}

---@param records table[]
---@return table[]
local function build_mark_groups(records)
  local by_name = {}
  for _, r in ipairs(records) do
    by_name[r.name] = by_name[r.name] or {}
    table.insert(by_name[r.name], r)
  end
  local out = {}
  for _, meta in ipairs(MARK_GROUPS) do
    local items = by_name[meta.name]
    if items and #items > 0 then
      table.sort(items, function(a, b)
        if (a.mark or '') ~= (b.mark or '') then return (a.mark or '') < (b.mark or '') end
        return a.lnum < b.lnum
      end)
      out[#out + 1] = {
        name = meta.name, label = meta.name, icon = '', hl = meta.hl,
        kind = 'mark', markers = items, open = true,
      }
    end
  end
  return out
end

-- filter 干草堆：标记原文 + 整行 + 相对路径 + 组名拼成一条字符串
-- 用与渲染相同的 relpath 口径，过滤词与面板里看到的路径一致
---@param rec table
---@return string
local function record_hay(rec)
  local rel = relpath(state.root or '', rec.file or '')
  return (rec.text or '') .. '\n' .. (rec.preview or '') .. '\n' .. rel .. '\n' .. (rec.name or '')
end

-- ============================================================
-- 渲染
-- ============================================================

local function render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end

  line_map = {}
  local lines, marks = {}, {}
  local function mark(row, col, ecol, group)
    table.insert(marks, { row, col, { end_col = ecol, hl_group = group } })
  end

  local groups = state.groups
  local total = 0
  for _, g in ipairs(groups or {}) do total = total + #g.markers end

  -- 头部
  local title_icon = ''
  local title_text = state.mode == 'marks' and 'Vim Marks' or 'Flow Marks'
  local title = '  ' .. title_icon .. '  ' .. title_text
  lines[#lines + 1] = title
  mark(0, 2, 2 + #title_icon, 'VVFlowPanelTitleIcon')
  mark(0, 2 + #title_icon, #title, 'VVFlowPanelTitle')
  local count_txt = string.format('  %d marks · %d groups', total, #(groups or {}))
  if (state.filter_query or '') ~= '' then count_txt = count_txt .. '  /' .. state.filter_query end
  table.insert(marks, { 0, #title, { virt_text = { { count_txt, 'VVFlowPanelCount' } }, virt_text_pos = 'eol' } })

  local sep = string.rep('─', 28)
  lines[#lines + 1] = sep
  mark(1, 0, #sep, 'VVFlowPanelSep')  -- end_col 须为字节长度，-1 会被 API 拒绝
  lines[#lines + 1] = ''

  if state.records == nil then
    local s = '  Scanning…'
    lines[#lines + 1] = s
    mark(#lines - 1, 0, #s, 'VVFlowPanelEmpty')
  elseif total == 0 then
    local s
    if (state.filter_query or '') ~= '' then
      s = string.format("  (no matches for '%s')", state.filter_query)
    elseif state.mode == 'marks' then
      s = '  (no marks)'
    else
      s = '  (no marks found)'
    end
    lines[#lines + 1] = s
    mark(#lines - 1, 0, #s, 'VVFlowPanelEmpty')
  else
    for gidx, g in ipairs(groups) do
      if gidx > 1 then lines[#lines + 1] = '' end  -- 组间分隔（空行）
      local chev = g.open and CHEV_OPEN or CHEV_CLOSED
      local icon = (g.icon ~= '' and (g.icon .. ' ')) or ''
      local head = string.format('%s %s%s', chev, icon, g.label)
      lines[#lines + 1] = head
      local hli = #lines - 1
      line_map[#lines] = { kind = 'group', group_idx = gidx }
      mark(hli, 0, #chev, 'VVFlowPanelChevron')
      mark(hli, #chev + 1, #head, g.hl)
      table.insert(marks, { hli, #head, { virt_text = {
        { string.format('  (%d)', #g.markers), 'VVFlowPanelCount' },
      }, virt_text_pos = 'eol' } })

      if g.open then
        for _, mk in ipairs(g.markers) do
          local rel = relpath(state.root or '', mk.file)
          local loc = string.format('%s:%d', rel, mk.lnum)
          local line = string.format('   %s  %s', mk.text, loc)
          lines[#lines + 1] = line
          local li = #lines - 1
          line_map[#lines] = { kind = 'marker', group_idx = gidx, marker = mk }

          local m_start = 3
          local m_end = m_start + #mk.text
          local loc_start = m_end + 2
          local path_end = loc_start + #rel
          mark(li, m_start, m_end, g.hl)
          mark(li, loc_start, path_end, 'VVFlowPanelPath')
          mark(li, path_end, #line, 'VVFlowPanelLnum')

          if mk.preview ~= '' then
            local prev = mk.preview
            if #prev > 60 then prev = prev:sub(1, 57) .. '…' end
            table.insert(marks, { li, #line, { virt_text = {
              { '  ' .. prev, 'VVFlowPanelPreview' },
            }, virt_text_pos = 'eol' } })
          end
        end
      end
    end
  end

  lines[#lines + 1] = ''
  local footer = state.mode == 'marks'
    and '  Preview j/k · Open ↵ · Delete d · Filter / · Flow Tab · Close q'
    or  '  Preview j/k · Open ↵ · Filter / · Marks Tab · Help g? · Close q'
  lines[#lines + 1] = footer
  mark(#lines - 1, 0, #footer, 'VVFlowPanelFooter')

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, m[1], m[2], m[3])
  end
end

-- 用当前 records + filter + mode 重建分组并渲染（前置声明的赋值）
rebuild = function()
  local recs = state.records or {}
  local q = state.filter_query or ''
  if q ~= '' then
    -- 编译一次查询谓词（按 filter_mode），再测每条 record；非法 regex 记 filter_invalid
    local pred, ok = Match.compile(q, { mode = state.filter_mode, ignore_case = true })
    state.filter_invalid = not ok
    recs = vim.tbl_filter(function(r) return pred(record_hay(r)) end, recs)
  else
    state.filter_invalid = false
  end
  if state.mode == 'marks' then
    state.groups = build_mark_groups(recs)
  else
    state.groups = build_groups(recs, state.rules or {})
  end
  render()
end

-- 载入 vim marks（同步）
load_marks = function()
  local cfg = require('vv-flow').get_config()
  state.records = Marks.list(cfg.marks)
  rebuild()
end

-- ============================================================
-- 交互
-- ============================================================

-- 选一个用于打开文件的「非面板普通窗口」；找不到返回 nil
local function pick_target_win()
  local w = state.prev_win
  if w and w ~= state.win and vim.api.nvim_win_is_valid(w) then return w end
  w = vim.fn.win_getid(vim.fn.winnr('#'))
  if w and w ~= 0 and w ~= state.win and vim.api.nvim_win_is_valid(w) then return w end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= state.win and vim.api.nvim_win_is_valid(win)
      and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == '' then
      return win
    end
  end
  return nil
end

local function jump(marker)
  local target = pick_target_win()
  if target then
    pcall(vim.api.nvim_set_current_win, target)
  else
    -- 面板是唯一窗口：从面板腾出一个普通窗口再 edit，避免把文件载进面板窗口本身
    vim.cmd('aboveleft vsplit')
    require('vv-utils.ui_window').show_chrome(vim.api.nvim_get_current_win())
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(marker.file))
  pcall(vim.api.nvim_win_set_cursor, 0, { marker.lnum, math.max(0, (marker.col or 1) - 1) })
  vim.cmd('normal! zz')
  -- 预览升级为固定（listed），关闭面板不再还原此文件
  if state.preview_enabled then
    pcall(function() require('vv-flow.preview').promote(state.win, state.prev_win) end)
  end
end

local function toggle_group(gidx)
  local g = state.groups and state.groups[gidx]
  if not g then return end
  g.open = not g.open
  render()
end

local function on_enter()
  local info = line_map[vim.fn.line('.')]
  if not info then return end
  if info.kind == 'group' then
    toggle_group(info.group_idx)
  elseif info.kind == 'marker' then
    jump(info.marker)
  end
end

local function expand_all(open)
  for _, g in ipairs(state.groups or {}) do g.open = open end
  render()
end

-- 选择行（标记 + 分组头）升序
local function selectable_lines()
  local ls = {}
  for lnum in pairs(line_map) do ls[#ls + 1] = lnum end
  table.sort(ls)
  return ls
end

-- j/k 在「选择行」间吸附移动（移动即触发防抖预览），到顶/底回绕
---@param dir 'j'|'k'
local function navigate(dir)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
  local ls = selectable_lines()
  if #ls == 0 then return end
  local cur = vim.api.nvim_win_get_cursor(state.win)[1]
  local dst
  if dir == 'j' then
    for _, l in ipairs(ls) do if l > cur then dst = l break end end
    dst = dst or ls[1]
  else
    for i = #ls, 1, -1 do if ls[i] < cur then dst = ls[i] break end end
    dst = dst or ls[#ls]
  end
  vim.api.nvim_win_set_cursor(state.win, { dst, 0 })
end

-- l / o / →：分组头展开，标记行跳转
local function on_open()
  local info = line_map[vim.fn.line('.')]
  if not info then return end
  if info.kind == 'group' then
    local g = state.groups and state.groups[info.group_idx]
    if g and not g.open then g.open = true render() end
  elseif info.kind == 'marker' then
    jump(info.marker)
  end
end

-- gf：跳到标记的文件:行，并关闭面板（区别于 <CR> 的「打开但保留面板」）
local function jump_close()
  local info = line_map[vim.fn.line('.')]
  if info and info.kind == 'marker' then
    jump(info.marker)
    M.close()
  end
end

-- h / ←：折叠当前行所属分组，光标移到该组标题
local function collapse_current()
  local info = line_map[vim.fn.line('.')]
  if not info or not state.groups then return end
  local gidx = info.group_idx
  local g = state.groups[gidx]
  if not g then return end
  if g.open then g.open = false render() end
  for lnum, m in pairs(line_map) do
    if m.kind == 'group' and m.group_idx == gidx then
      pcall(vim.api.nvim_win_set_cursor, state.win, { lnum, 0 })
      break
    end
  end
end

-- <Tab>：在 flow 标记面板 ↔ vim marks 面板间切换（清空 filter 后重载）
local function switch_mode()
  state.mode = (state.mode == 'marks') and 'flow' or 'marks'
  state.filter_query = ''
  state.records = nil
  state.scan_token = state.scan_token + 1  -- 作废在途的 flow 扫描回调，避免其覆盖 records
  if state.mode == 'marks' then
    load_marks()
  else
    render()  -- 先画 Scanning…
    do_scan()
  end
end

-- /：打开过滤输入框，实时筛 records（两模式通用）
local function open_filter()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
  -- 记录浮窗 close 句柄，面板被任何路径关闭时一并关掉（见 cleanup），避免浮窗变孤儿
  state.filter_close = require('vv-flow.filter').open(state.win, {
    initial = state.filter_query or '',
    get_mode = function() return state.filter_mode end,
    on_cycle_mode = function()
      state.filter_mode = Match.next_mode(state.filter_mode)
      rebuild()  -- 按新模式立即重筛（badge 由 filter 的 ctx.redraw 刷新）
    end,
    status = function()
      if (state.filter_query or '') == '' then return '' end
      if state.filter_invalid then return 'bad pattern' end
      local n = 0
      for _, g in ipairs(state.groups or {}) do n = n + #g.markers end
      return n == 0 and 'no matches' or string.format('%d match%s', n, n == 1 and '' or 'es')
    end,
    on_change = function(q)
      state.filter_query = q
      rebuild()
    end,
    on_accept = function(q)
      state.filter_query = q
      rebuild()
      -- 跳到首条匹配的标记行（跳过分组头），过滤后立即预览首条命中
      local first
      for _, l in ipairs(selectable_lines()) do
        if (line_map[l] or {}).kind == 'marker' then first = l break end
      end
      if first then pcall(vim.api.nvim_win_set_cursor, state.win, { first, 0 }) end
    end,
    on_cancel = function()
      state.filter_query = ''
      rebuild()
    end,
  })
end

-- d：删除光标所在的 vim mark（仅 marks 模式），删后重载
local function delete_mark()
  if state.mode ~= 'marks' then return end
  local info = line_map[vim.fn.line('.')]
  if not (info and info.kind == 'marker' and info.marker) then return end
  if Marks.delete(info.marker) then load_marks() end
end

-- <Esc>：有过滤先清过滤，否则关面板
local function on_esc()
  if (state.filter_query or '') ~= '' then
    state.filter_query = ''
    rebuild()
  else
    M.close()
  end
end

-- ============================================================
-- 实时预览（参照 vv-explorer：CursorMoved + 防抖，焦点留在面板）
-- ============================================================

local function do_preview()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
  if vim.api.nvim_get_current_win() ~= state.win then return end
  local info = line_map[vim.fn.line('.')]
  if info and info.kind == 'marker' then
    require('vv-flow.preview').show(state.win, state.prev_win, info.marker)
  end
end

---@param debounce_ms integer
local function attach_preview(debounce_ms)
  local cb
  if debounce_ms and debounce_ms > 0 then
    cb, state.preview_cancel = require('vv-utils.timer').debounce(do_preview, debounce_ms)
  else
    cb = do_preview
  end
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = vim.api.nvim_create_augroup('vv-flow.preview', { clear = true }),
    buffer = state.buf,
    callback = cb,
  })
end

local function detach_preview()
  if state.preview_cancel then
    pcall(state.preview_cancel)
    state.preview_cancel = nil
  end
  pcall(vim.api.nvim_del_augroup_by_name, 'vv-flow.preview')
end

-- C-e / C-y：滚动预览窗口（暂借焦点 normal! 5<C-e/y> 再切回面板，参照 vv-explorer）
---@param keys string  CE_KEY | CY_KEY
local function scroll_preview(keys)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
  local target = require('vv-flow.preview').find_main_win(state.win)
  if not (target and vim.api.nvim_win_is_valid(target)) then return end
  local prev = vim.api.nvim_get_current_win()
  local cmd = 'normal! ' .. SCROLL_LINES .. keys
  if prev == target then
    pcall(vim.cmd, cmd)
    return
  end
  pcall(vim.api.nvim_set_current_win, target)
  pcall(vim.cmd, cmd)
  if vim.api.nvim_win_is_valid(prev) then
    pcall(vim.api.nvim_set_current_win, prev)
  end
end

-- ============================================================
-- 窗口
-- ============================================================

local function reset_state()
  state.win = nil
  state.buf = nil
  state.prev_win = nil
  state.groups = nil
  state.records = nil
  state.rules = nil
  state.mode = 'flow'
  state.filter_query = ''
  state.filter_mode = 'fixed'
  state.filter_invalid = nil
  state.filter_close = nil
  state.preview_enabled = nil
  state.preview_cancel = nil
  line_map = {}
end

-- 统一清理：停防抖 + 还原主窗（未固定的预览）+ 复位状态。
-- 供 M.close 与 BufWipeout（外部 :q / <C-w>c 关闭面板）共用，幂等。
local function cleanup()
  if state.filter_close then
    pcall(state.filter_close)  -- 关掉可能仍开着的过滤浮窗（幂等），释放其 timer/augroup/buffer
    state.filter_close = nil
  end
  detach_preview()
  if state.preview_enabled then
    pcall(function() require('vv-flow.preview').restore() end)
  end
  reset_state()
end

local function create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'vv-flow'
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false

  local map = function(lhs, rhs, action)
    vim.keymap.set('n', lhs, rhs, {
      buffer = buf, silent = true, nowait = true, desc = 'vv-flow: ' .. action,
    })
  end
  map('<CR>',  on_enter,                       'jump / toggle group')
  map('<Tab>', switch_mode,                    'switch flow/marks')
  map('j',       function() navigate('j') end, 'next')
  map('k',       function() navigate('k') end, 'prev')
  map('<Down>',  function() navigate('j') end, 'next')
  map('<Up>',    function() navigate('k') end, 'prev')
  map('l',       on_open,                       'open / expand')
  map('o',       on_open,                       'open / expand')
  map('<Right>', on_open,                       'open / expand')
  map('gf',      jump_close,                    'jump & close')
  map('h',       collapse_current,              'collapse group')
  map('<Left>',  collapse_current,              'collapse group')
  map('<C-e>',   function() scroll_preview(CE_KEY) end, 'scroll preview down')
  map('<C-y>',   function() scroll_preview(CY_KEY) end, 'scroll preview up')
  map('/',       open_filter,                   'filter')
  map('d',       delete_mark,                   'delete mark')
  map('R',     function() expand_all(true) end, 'expand all')
  map('M',     function() expand_all(false) end, 'collapse all')
  map('r',     function() M.refresh() end,      'rescan')
  map('q',     function() M.close() end,        'close')
  map('<Esc>', on_esc,                          'close / clear filter')
  map('g?',    function() M.show_help() end,    'help')

  -- 鼠标：左键松开 = 跳转/折叠；右键 = 定位后同 <CR>；屏蔽默认 visual 选区
  map('<LeftRelease>', on_enter, 'click')
  vim.keymap.set('n', '<RightMouse>', function()
    local pos = vim.fn.getmousepos()
    if pos.line > 0 and state.win and vim.api.nvim_win_is_valid(state.win) then
      pcall(vim.api.nvim_win_set_cursor, state.win, { pos.line, 0 })
    end
    on_enter()
  end, { buffer = buf, silent = true, nowait = true, desc = 'vv-flow: click' })
  -- 必须含 <3-LeftMouse>/<4-LeftMouse>：三击=选行、四击=选块，漏了「快速点几下」会误触发
  for _, key in ipairs({ '<LeftDrag>', '<2-LeftMouse>', '<3-LeftMouse>', '<4-LeftMouse>', '<RightRelease>', '<2-RightMouse>', '<3-RightMouse>', '<4-RightMouse>' }) do
    vim.keymap.set({ 'n', 'x' }, key, '<Nop>', { buffer = buf, silent = true })
  end
  vim.keymap.set('x', '<RightMouse>', '<Esc>', { buffer = buf, silent = true })
  -- 跨窗口点进面板再拖拽 / 多击时 buffer-local 映射拦不住，靠 ModeChanged 守卫兜底
  require('vv-utils.mouse').block_visual_drag(buf)

  return buf
end

-- 触发一次扫描（flow 模式），完成后存 records + rebuild（赋值给前置声明）
do_scan = function()
  local Flow = require('vv-flow')
  local cfg = Flow.get_config()
  local rules = Rules.build(cfg)
  state.rules = rules
  state.scan_token = state.scan_token + 1
  local token = state.scan_token

  Scan.scan(state.root, rules, {
    prefix = cfg.prefix or '@',
    max_results = cfg.max_results,
    rg_extra_args = cfg.rg_extra_args,
  }, function(records, err)
    if token ~= state.scan_token then return end  -- 已被新扫描取代
    if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
    if err and err ~= 'truncated' then
      vim.notify('[vv-flow] 扫描失败：' .. err, vim.log.levels.ERROR)
    end
    state.records = records
    rebuild()
  end)
end

function M.open()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  local Flow = require('vv-flow')
  local cfg = Flow.get_config()

  state.prev_win = vim.api.nvim_get_current_win()
  state.root = require('vv-utils.path').get_root(vim.api.nvim_get_current_buf())
  state.mode = 'flow'
  state.filter_query = ''
  state.records = nil
  state.groups = nil
  state.buf = create_buf()
  pcall(vim.api.nvim_buf_set_name, state.buf, 'vv-flow://' .. (state.root or ''))

  local side = cfg.position == 'left' and 'topleft' or 'botright'
  vim.cmd(string.format('%s %dvsplit', side, cfg.width or 42))
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)

  require('vv-utils.ui_window').hide_chrome(state.win, { cursorline = true, winfixwidth = true })
  vim.wo[state.win].winhighlight = 'Normal:NormalFloat,CursorLine:PmenuSel,EndOfBuffer:NonText'
  vim.wo[state.win].statusline = ' '

  -- 实时预览：记录主窗原始状态（供关闭还原）+ 挂 CursorMoved 防抖
  state.preview_enabled = cfg.preview ~= false
  if state.preview_enabled then
    require('vv-flow.preview').save_origin(state.win, state.prev_win)
    attach_preview(cfg.preview_debounce_ms or 138)
  end

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = state.buf, once = true, callback = cleanup,
  })

  render()  -- 先画 "Scanning…"
  do_scan()
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)  -- → BufWipeout → cleanup（含还原主窗）
  else
    cleanup()
  end
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

function M.refresh()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  if state.mode == 'marks' then
    load_marks()
    return
  end
  state.root = require('vv-utils.path').get_root(state.prev_win and vim.api.nvim_win_is_valid(state.prev_win)
    and vim.api.nvim_win_get_buf(state.prev_win) or vim.api.nvim_get_current_buf())
  do_scan()
end

function M.show_help()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  require('vv-flow.help').open(state.buf)
end

return M
