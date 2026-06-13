-- vv-flow.help — g? 帮助浮窗，委托 vv-utils.help_panel
-- action 名须与 panel.lua 里 keymap 的 desc（去掉 'vv-flow: ' 前缀）完全一致

local HelpPanel = require('vv-utils.help_panel')

local M = {}

local ACTIONS = {
  ['next']                = { cat = 'Navigate', icon = '' },
  ['prev']                = { cat = 'Navigate', icon = '' },
  ['open / expand']       = { cat = 'Navigate', icon = '' },
  ['collapse group']      = { cat = 'Navigate', icon = '' },
  ['jump / toggle group'] = { cat = 'Navigate', icon = '' },
  ['jump & close']        = { cat = 'Navigate', icon = '' },
  ['click']               = { cat = 'Navigate', icon = '' },
  ['scroll preview down'] = { cat = 'View',     icon = '' },
  ['scroll preview up']   = { cat = 'View',     icon = '' },
  ['expand all']          = { cat = 'View',     icon = '' },
  ['collapse all']        = { cat = 'View',     icon = '' },
  ['rescan']              = { cat = 'View',     icon = '' },
  ['switch flow/marks']   = { cat = 'Mode',     icon = '' },
  ['filter']              = { cat = 'Mode',     icon = '' },
  ['delete mark']         = { cat = 'Mode',     icon = '' },
  ['close / clear filter'] = { cat = 'Panel',   icon = '' },
  ['close']               = { cat = 'Panel',    icon = '' },
  ['help']                = { cat = 'Panel',    icon = '' },
}

local CATEGORIES = { 'Navigate', 'View', 'Mode', 'Panel' }

---@param source_buf integer 面板 buffer
function M.open(source_buf)
  if not (source_buf and vim.api.nvim_buf_is_valid(source_buf)) then return end
  HelpPanel.open({
    source_buf  = source_buf,
    desc_prefix = 'vv-flow: ',
    actions     = ACTIONS,
    categories  = CATEGORIES,
    title       = 'vv-flow keymaps',
    title_icon  = '',
    filetype    = 'vv-flow-help',
  })
end

return M
