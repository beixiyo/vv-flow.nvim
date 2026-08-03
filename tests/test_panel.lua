-- vv-flow tree_panel 集成与纯模型回归
-- 运行：nvim --headless -u NONE -l tests/test_panel.lua

local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fn.fnamemodify(this, ':h:h')
local utils = vim.fs.normalize(root .. '/../vv-utils.nvim')
vim.opt.runtimepath:prepend(utils)
vim.opt.runtimepath:prepend(root)

local Model = require('vv-flow.panel.model')
local State = require('vv-utils.state')

local records = {
  {
    file = root .. '/src/deep/feature.lua',
    lnum = 17,
    col = 3,
    text = '@step:checkout-17',
    preview = 'finish feature',
    kind = 'step',
    name = 'checkout',
    num = 17,
  },
  {
    file = root .. '/src/start.lua',
    lnum = 2,
    col = 1,
    text = '@STEP:Checkout-2',
    preview = 'start feature',
    kind = 'step',
    name = 'checkout',
    num = 2,
  },
}
local rules = {
  {
    name = 'step',
    label = '@STEP',
    icon = '',
    hl = 'VVFlowStep',
    kind = 'step',
    vim_regex = '\\c@STEP:[a-z][a-z0-9_-]*-\\d\\+\\>',
    rg_pattern = '(?i)@STEP:[a-z][a-z0-9_-]*-\\d+\\b',
  },
}

local groups = Model.build_flow_groups(records, rules)
assert(#groups == 1 and groups[1].markers[1].num == 2
    and groups[1].markers[2].num == 17,
  '同一命名空间内的 step 标记应按数值排序')
assert(groups[1].name == 'checkout' and groups[1].label == '@STEP:checkout',
  'step 应按规范化后的命名空间动态分组')
assert(Model.marker_count(groups) == 2, '分组计数应等于 marker 总数')
assert(Model.record_hay(records[1], root):find('src/deep/feature.lua', 1, true),
  '过滤文本应包含面板显示的相对路径')

local collision_groups = Model.build_flow_groups({
  vim.tbl_extend('force', records[1], { name = 'todo' }),
  {
    file = root .. '/src/todo.lua',
    lnum = 1,
    col = 1,
    text = '@TODO',
    preview = 'todo keyword',
    kind = 'keyword',
    name = 'todo',
  },
}, {
  rules[1],
  {
    name = 'todo',
    label = '@TODO',
    icon = '',
    hl = 'VVFlowKwTODO',
    kind = 'keyword',
    vim_regex = '\\c@TODO\\>',
    rg_pattern = '(?i)@TODO\\b',
  },
})
assert(#collision_groups == 2
    and collision_groups[1].kind == 'keyword'
    and collision_groups[2].kind == 'step',
  '同名 step 命名空间与关键字必须保持独立分组')

local nodes = Model.nodes(groups, root, 'flow')
local repeated = Model.nodes(groups, root, 'flow')
assert(nodes[1].id == repeated[1].id
    and nodes[1].children[1].id == repeated[1].children[1].id,
  '相同输入应生成稳定 node id')

local duplicate_groups = Model.build_flow_groups({ records[1], vim.deepcopy(records[1]) }, rules)
local duplicate_nodes = Model.nodes(duplicate_groups, root, 'flow')
assert(duplicate_nodes[1].children[1].id ~= duplicate_nodes[1].children[2].id,
  '完全相同的记录也必须生成唯一 node id')

local mark_groups = Model.build_mark_groups({
  { name = 'Buffer a-z', mark = 'z', lnum = 2 },
  { name = 'Global A-Z', mark = 'B', lnum = 1 },
  { name = 'Global A-Z', mark = 'A', lnum = 9 },
})
assert(mark_groups[1].name == 'Global A-Z'
    and mark_groups[1].markers[1].mark == 'A'
    and mark_groups[2].name == 'Buffer a-z',
  'marks 应按固定分组顺序与 mark 字符排序')

local target = vim.fn.tempname() .. '.lua'
vim.fn.writefile({
  '-- @TODO first',
  'return true',
}, target)
vim.cmd.edit(vim.fn.fnameescape(target))
local source_win = vim.api.nvim_get_current_win()

local Scan = require('vv-flow.scan')
local scan_calls = 0
local async_scan = false
local pending_scans = {}
local cancelled_scans = 0
rawset(Scan, 'scan', function(_, _, _, callback)
  scan_calls = scan_calls + 1
  local function records(label)
    return { {
      file = target,
      lnum = 1,
      col = 4,
      text = '@TODO-' .. label,
      preview = '-- @TODO ' .. label,
      kind = 'keyword',
      name = 'todo',
    } }
  end

  if not async_scan then
    callback(records('first'))
    return function() end
  end

  local pending = { callback = callback, cancelled = false, records = records }
  pending_scans[#pending_scans + 1] = pending
  return function()
    if pending.cancelled then return end
    pending.cancelled = true
    cancelled_scans = cancelled_scans + 1
  end
end)

local custom_context
local Flow = require('vv-flow')
local state_path = vim.fn.tempname()
Flow.setup({
  highlight = false,
  preview = false,
  position = 'left',
  width = 31,
  state = State.register('vv-flow-test', 'panel', { path = state_path }),
  panel = {
    mappings = {
      x = {
        desc = 'inspect',
        callback = function(ctx) custom_context = ctx end,
      },
    },
  },
})

Flow.open()
local panel_win = vim.api.nvim_get_current_win()
local panel_buf = vim.api.nvim_get_current_buf()
assert(vim.bo[panel_buf].filetype == 'vv-flow', '打开后应使用 vv-flow tree panel buffer')
assert(vim.fn.win_screenpos(panel_win)[2] < vim.fn.win_screenpos(source_win)[2],
  'position=left 应把面板放在来源窗口左侧')
assert(vim.wo[panel_win].winbar:find('Flow Marks', 1, true),
  'flow 模式与统计应固定显示在 winbar')

local lines = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)
assert(#lines == 2 and lines[1]:find('@TODO', 1, true)
    and lines[2]:find(vim.fn.fnamemodify(target, ':t'), 1, true),
  'tree panel 应渲染分组与 marker 节点: ' .. vim.inspect(lines))
assert(vim.fn.maparg('j', 'n', false, true).buffer == 1
    and vim.fn.maparg('<C-N>', 'n', false, true).buffer == 1
    and vim.fn.maparg('gf', 'n', false, true).buffer == 1,
  '默认树导航与 gf 行为应由 tree_panel 注册')

vim.fn.maparg('r', 'n', false, true).callback()
assert(scan_calls == 2, 'r 应重新扫描 flow 记录')

vim.fn.maparg('x', 'n', false, true).callback()
assert(custom_context and custom_context.node.data.kind == 'group',
  '自定义 mapping 应收到 tree_panel context')

vim.api.nvim_win_set_cursor(panel_win, { 2, 0 })
vim.fn.maparg('h', 'n', false, true).callback()
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 1
    and #vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false) == 1,
  '叶节点按一次 h 应直接折叠父分组并聚焦父节点')
vim.fn.maparg('l', 'n', false, true).callback()
assert(#vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false) == 2,
  'l 应展开当前分组')

vim.api.nvim_win_set_cursor(panel_win, { 1, 0 })
vim.fn.maparg('<CR>', 'n', false, true).callback()
assert(#vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false) == 1,
  'CR 在分组上应切换折叠状态')
vim.fn.maparg('<CR>', 'n', false, true).callback()

vim.api.nvim_win_set_cursor(panel_win, { 2, 0 })
vim.fn.maparg('l', 'n', false, true).callback()
assert(vim.api.nvim_get_current_win() == source_win
    and vim.api.nvim_win_is_valid(panel_win),
  'l 在 marker 上应进入文件但保留面板')

vim.api.nvim_set_current_win(panel_win)
vim.api.nvim_win_set_cursor(panel_win, { 2, 0 })
vim.fn.maparg('<CR>', 'n', false, true).callback()
assert(vim.api.nvim_get_current_win() == source_win
    and vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == vim.uv.fs_realpath(target)
    and vim.api.nvim_win_is_valid(panel_win),
  'CR 在 marker 上应进入文件但保留面板')

vim.api.nvim_set_current_win(panel_win)
vim.fn.maparg('<Tab>', 'n', false, true).callback()
assert(vim.wo[panel_win].winbar:find('Vim Marks', 1, true),
  'Tab 应切换到 Vim marks 模式')
vim.fn.maparg('<Tab>', 'n', false, true).callback()
assert(vim.wo[panel_win].winbar:find('Flow Marks', 1, true),
  '再次 Tab 应切回 flow 模式')

vim.fn.maparg('g?', 'n', false, true).callback()
assert(vim.bo.filetype == 'vv-flow-help', 'g? 应打开 tree_panel 通用帮助')
assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('inspect', 1, true),
  '自定义 mapping 描述应进入通用帮助')
vim.fn.maparg('q', 'n', false, true).callback()
assert(vim.api.nvim_get_current_win() == panel_win, '关闭帮助应回到 vv-flow 面板')

vim.cmd('vertical resize 39')
Flow.close()
Flow.open()
panel_win = vim.api.nvim_get_current_win()
assert(vim.api.nvim_win_get_width(panel_win) == 39,
  '关闭再打开应通过 vv-utils state 恢复实际 resize 宽度')

vim.api.nvim_win_set_cursor(panel_win, { 2, 0 })
vim.fn.maparg('gf', 'n', false, true).callback()
assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == vim.uv.fs_realpath(target)
    and #vim.api.nvim_list_wins() == 1,
  'gf 应进入 marker 并关闭面板')

async_scan = true
Flow.open()
Flow.refresh()
assert(pending_scans[1].cancelled and cancelled_scans == 1,
  '刷新 B 应物理取消在途扫描 A')
pending_scans[2].callback(pending_scans[2].records('second'))
pending_scans[1].callback(pending_scans[1].records('stale'))
panel_win = vim.api.nvim_get_current_win()
panel_buf = vim.api.nvim_get_current_buf()
local async_lines = table.concat(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false), '\n')
assert(async_lines:find('second', 1, true) and not async_lines:find('stale', 1, true),
  'A 慢 B 快时旧 callback 不得覆盖 B 的面板状态: ' .. async_lines)

Flow.refresh()
local queued_after_close = pending_scans[3]
Flow.close()
assert(queued_after_close.cancelled and cancelled_scans == 2,
  '关闭面板应物理取消当前扫描')
queued_after_close.callback(queued_after_close.records('resurrected'))
assert(#vim.api.nvim_list_wins() == 1,
  '关闭后已排队 callback 不得重新挂载面板')

vim.fn.delete(target)
vim.fn.delete(state_path)
print('[PASS] vv-flow panel model / tree_panel integration')
