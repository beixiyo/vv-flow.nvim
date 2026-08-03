-- vv-flow 面板适配层
--
-- 扫描、marks、过滤与预览属于 vv-flow；树形窗口、折叠、导航、帮助和宽度状态
-- 统一交给 vv-utils.tree_panel

local Match = require('vv-utils.match')
local Async = require('vv-utils.async')
local TreePanel = require('vv-utils.tree_panel')
local Marks = require('vv-flow.marks')
local Model = require('vv-flow.panel.model')
local Render = require('vv-flow.panel.render')
local Rules = require('vv-flow.rules')
local Scan = require('vv-flow.scan')

local M = {}
local scan_scope = Async.scope({ cancel_previous = true })

local active_panel
local view = {
  root = '',
  mode = 'flow',
  records = nil,
  rules = {},
  groups = {},
  filter_query = '',
  filter_mode = 'fixed',
  filter_invalid = false,
  filter_close = nil,
}

local CE_KEY = vim.api.nvim_replace_termcodes('<C-e>', true, false, true)
local CY_KEY = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)
local SCROLL_LINES = 5

local function current_panel()
  return active_panel and active_panel:is_open() and active_panel or nil
end

local function filtered_records()
  local records = view.records or {}
  if view.filter_query == '' then
    view.filter_invalid = false
    return records
  end

  local predicate, valid = Match.compile(view.filter_query, {
    mode = view.filter_mode,
    ignore_case = true,
  })
  view.filter_invalid = not valid
  return vim.tbl_filter(function(record)
    return predicate(Model.record_hay(record, view.root))
  end, records)
end

local function rebuild(panel)
  local records = filtered_records()
  view.groups = view.mode == 'marks'
      and Model.build_mark_groups(records)
    or Model.build_flow_groups(records, view.rules)
  panel:refresh()
end

local function load_marks(panel, config)
  view.records = Marks.list(config.marks)
  rebuild(panel)
end

local function scan(panel, config)
  view.rules = Rules.build(config)
  local request = scan_scope:begin()

  local cancel = Scan.scan(view.root, view.rules, {
    prefix = config.prefix,
    max_results = config.max_results,
    exclude = config.exclude,
    rg_extra_args = config.rg_extra_args,
  }, function(records, err)
    if not request:finish() or panel ~= current_panel() then return end
    if err and err ~= 'truncated' then
      vim.notify('[vv-flow] 扫描失败：' .. err, vim.log.levels.ERROR)
    end
    view.records = records
    rebuild(panel)
  end)

  if cancel then request:set_cancel(cancel) end
end

local function target_buffer(panel)
  return panel.source_win and vim.api.nvim_win_is_valid(panel.source_win)
      and vim.api.nvim_win_get_buf(panel.source_win)
    or vim.api.nvim_get_current_buf()
end

local function refresh(panel, config)
  if view.mode == 'marks' then
    load_marks(panel, config)
    return
  end

  view.root = require('vv-utils.path').get_root(target_buffer(panel))
  view.records = nil
  view.groups = {}
  panel:refresh()
  scan(panel, config)
end

local function marker_from_node(node)
  local data = node and node.data
  return data and data.kind == 'marker' and data.marker or nil
end

local function open_marker(node, panel, config)
  local marker = marker_from_node(node)
  if not marker then return end

  local target = panel.source_win
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
  else
    vim.cmd('aboveleft vsplit')
    require('vv-utils.ui_window').show_chrome(vim.api.nvim_get_current_win())
  end

  vim.cmd('edit ' .. vim.fn.fnameescape(marker.file))
  pcall(vim.api.nvim_win_set_cursor, 0, {
    marker.lnum,
    math.max(0, (marker.col or 1) - 1),
  })
  vim.cmd('normal! zz')

  if config.preview then
    require('vv-flow.preview').promote(panel.win, panel.source_win)
  end
end

local function switch_mode(panel, config)
  view.mode = view.mode == 'marks' and 'flow' or 'marks'
  view.filter_query = ''
  view.records = nil
  view.groups = {}
  scan_scope:cancel()
  panel:refresh()

  if view.mode == 'marks' then
    load_marks(panel, config)
  else
    scan(panel, config)
  end
end

local function open_filter(panel)
  if not panel:is_open() then return end

  view.filter_close = require('vv-flow.filter').open(panel.win, {
    initial = view.filter_query,
    get_mode = function() return view.filter_mode end,
    on_cycle_mode = function()
      view.filter_mode = Match.next_mode(view.filter_mode)
      rebuild(panel)
    end,
    status = function()
      if view.filter_query == '' then return '' end
      if view.filter_invalid then return 'bad pattern' end

      local count = Model.marker_count(view.groups)
      return count == 0 and 'no matches'
        or string.format('%d match%s', count, count == 1 and '' or 'es')
    end,
    on_change = function(query)
      view.filter_query = query
      rebuild(panel)
    end,
    on_accept = function(query)
      view.filter_query = query
      rebuild(panel)
      local first
      for line, row in pairs(panel.rows) do
        if marker_from_node(row.node) and (not first or line < first) then first = line end
      end
      if first then vim.api.nvim_win_set_cursor(panel.win, { first, 0 }) end
    end,
    on_cancel = function()
      view.filter_query = ''
      rebuild(panel)
    end,
  })
end

local function delete_mark(node, panel, config)
  if view.mode ~= 'marks' then return end

  local marker = marker_from_node(node)
  if marker and Marks.delete(marker) then load_marks(panel, config) end
end

local function escape_or_close(panel)
  if view.filter_query == '' then
    panel:close()
    return
  end

  view.filter_query = ''
  rebuild(panel)
end

local function scroll_preview(panel, keys)
  local target = require('vv-flow.preview').find_main_win(panel.win)
  if not (target and vim.api.nvim_win_is_valid(target)) then return end

  local previous = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(target)
  pcall(function() vim.cmd('normal! ' .. SCROLL_LINES .. keys) end)
  if vim.api.nvim_win_is_valid(previous) then vim.api.nvim_set_current_win(previous) end
end

local function business_mappings(config)
  return {
    ['<CR>'] = {
      desc = 'open_or_toggle',
      callback = function(ctx)
        if ctx.node and ctx.node.data and ctx.node.data.kind == 'group' then
          ctx.panel:execute('toggle_node')
        else
          ctx.panel:execute('open_node')
        end
      end,
    },
    ['<Tab>'] = {
      desc = 'switch_flow_marks',
      callback = function(ctx) switch_mode(ctx.panel, config) end,
    },
    ['<C-e>'] = {
      desc = 'scroll_preview_down',
      callback = function(ctx) scroll_preview(ctx.panel, CE_KEY) end,
    },
    ['<C-y>'] = {
      desc = 'scroll_preview_up',
      callback = function(ctx) scroll_preview(ctx.panel, CY_KEY) end,
    },
    ['/'] = {
      desc = 'filter',
      callback = function(ctx) open_filter(ctx.panel) end,
    },
    d = {
      desc = 'delete_mark',
      callback = function(ctx) delete_mark(ctx.node, ctx.panel, config) end,
    },
    R = 'expand_all',
    M = 'collapse_all',
    r = 'refresh',
    ['<Esc>'] = {
      desc = 'close_or_clear_filter',
      callback = function(ctx) escape_or_close(ctx.panel) end,
    },
    ['<LeftRelease>'] = {
      desc = 'click',
      callback = function(ctx)
        if ctx.node and ctx.node.data and ctx.node.data.kind == 'group' then
          ctx.panel:execute('toggle_node')
        else
          ctx.panel:execute('open_node')
        end
      end,
    },
  }
end

local function help_options(configured)
  if configured == false then return false end

  configured = type(configured) == 'table' and configured or {}
  local options = vim.tbl_extend('force', {
    title = 'vv-flow keymaps',
    filetype = 'vv-flow-help',
    categories = { 'Navigate', 'View', 'Mode', 'Mouse' },
  }, configured)
  options.actions = vim.tbl_deep_extend('force', {
    open_or_toggle = { cat = 'Navigate' },
    scroll_preview_down = { cat = 'Navigate' },
    scroll_preview_up = { cat = 'Navigate' },
    switch_flow_marks = { cat = 'Mode' },
    filter = { cat = 'Mode' },
    delete_mark = { cat = 'Mode' },
    close_or_clear_filter = { cat = 'View' },
    click = { cat = 'Mouse' },
  }, configured.actions or {})
  return options
end

local function attach(panel, buf, config)
  local panel_config = config.panel or {}
  if panel_config.mappings ~= false then
    local mappings = vim.tbl_extend(
      'force',
      business_mappings(config),
      panel_config.mappings or {}
    )
    TreePanel.apply_default_mappings(panel, mappings)
  end

  require('vv-utils.mouse').block_visual_drag(buf)
  if panel_config.on_attach then panel_config.on_attach(panel, buf) end
  vim.wo[panel.win].winhighlight =
    'Normal:NormalFloat,CursorLine:PmenuSel,EndOfBuffer:NonText'
  vim.wo[panel.win].statusline = ' '
end

local function close_preview()
  if view.filter_close then
    pcall(view.filter_close)
    view.filter_close = nil
  end
  require('vv-flow.preview').restore()
end

local function create_panel(config)
  local panel_config = config.panel or {}
  local render = vim.tbl_extend('force', Render.create(view), panel_config.render or {})
  local panel

  panel = TreePanel.new({
    id = 'vv-flow-panel',
    filetype = 'vv-flow',
    width = config.width,
    position = config.position,
    state = config.state,
    preview_debounce_ms = config.preview_debounce_ms,
    help = help_options(panel_config.help),
    source = function() return Model.nodes(view.groups, view.root, view.mode) end,
    render = render,
    preview = config.preview and function(node)
      local marker = marker_from_node(node)
      if marker then require('vv-flow.preview').show(panel.win, panel.source_win, marker) end
    end or nil,
    open = function(node) open_marker(node, panel, config) end,
    jump = function(node) open_marker(node, panel, config) end,
    on_refresh = function() refresh(panel, config) end,
    close_preview = close_preview,
    on_attach = function(current, buf) attach(current, buf, config) end,
    on_close = function()
      scan_scope:cancel()
      if active_panel == panel then active_panel = nil end
    end,
  })
  return panel
end

---@param config VVFlowConfig
function M.open(config)
  if current_panel() then
    active_panel:open()
    return
  end

  view.root = require('vv-utils.path').get_root()
  view.mode = 'flow'
  view.records = nil
  view.groups = {}
  view.filter_query = ''
  view.filter_mode = 'fixed'
  view.filter_invalid = false

  local panel = create_panel(config)
  active_panel = panel
  panel:open()
  if config.preview then
    require('vv-flow.preview').save_origin(panel.win, panel.source_win)
  end
  scan(panel, config)
end

function M.close()
  local panel = current_panel()
  if panel then panel:close() end
end

---@param config VVFlowConfig
function M.toggle(config)
  if current_panel() then M.close() else M.open(config) end
end

---@param config VVFlowConfig
function M.refresh(config)
  local panel = current_panel()
  if panel then refresh(panel, config) end
end

function M.show_help()
  local panel = current_panel()
  if panel then panel:execute('help') end
end

return M
