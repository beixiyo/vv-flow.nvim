-- vv-flow tree_panel 渲染器：紧凑展示模式、分组、位置与预览摘要

local Path = require('vv-utils.path')

local M = {}

require('vv-utils.hl').register('vv-flow.panel.hl', {
  VVFlowPanelTitle = { link = 'Title' },
  VVFlowPanelChevron = { link = 'Comment' },
  VVFlowPanelCount = { link = 'Comment' },
  VVFlowPanelPath = { link = 'Comment' },
  VVFlowPanelPreview = { link = 'Comment' },
  VVFlowPanelEmpty = { link = 'Comment' },
  VVFlowMarkGlobal = { link = 'Identifier' },
  VVFlowMarkBuffer = { link = 'Function' },
  VVFlowMarkNumbered = { link = 'Number' },
  VVFlowMarkSpecial = { link = 'Special' },
})

local function mode_title(mode)
  return mode == 'marks' and 'Vim Marks' or 'Flow Marks'
end

---@param view table
---@return VVTreePanelRenderers
function M.create(view)
  return {
    winbar = function()
      local count = require('vv-flow.panel.model').marker_count(view.groups)
      local filter = view.filter_query ~= '' and ('  /' .. view.filter_query) or ''
      return {
        chunks = {
          { '  ' .. mode_title(view.mode), 'VVFlowPanelTitle' },
          { ('  %d marks · %d groups%s'):format(count, #view.groups, filter), 'VVFlowPanelCount' },
        },
      }
    end,
    node = function(ctx)
      local data = ctx.node.data or {}
      if data.kind == 'group' then
        local group = data.group
        local marker = ctx.folded and ' ' or ' '
        local icon = group.icon ~= '' and (group.icon .. ' ') or ''
        return {
          chunks = {
            { string.rep('  ', ctx.depth) .. marker, 'VVFlowPanelChevron' },
            { icon .. group.label, group.hl },
          },
          virt_text = {
            { tostring(#group.markers), 'VVFlowPanelCount' },
          },
        }
      end

      local marker = data.marker
      local relative = Path.collapse_middle(data.relative_path or '', {
        head = 1,
        tail = 2,
      })
      local location = ('%s:%d'):format(relative, marker.lnum)
      local preview = vim.trim(marker.preview or '')
      if vim.fn.strdisplaywidth(preview) > 48 then
        preview = vim.fn.strcharpart(preview, 0, 45) .. '…'
      end

      return {
        chunks = {
          { string.rep('  ', ctx.depth) .. '  ', 'Comment' },
          { marker.text or '', data.group_hl },
          { '  ' .. location, 'VVFlowPanelPath' },
        },
        virt_text = preview ~= '' and {
          { '  ' .. preview, 'VVFlowPanelPreview' },
        } or nil,
        virt_text_pos = 'eol',
      }
    end,
    empty = function()
      if view.records == nil then
        return { text = '  Scanning…', hl = 'VVFlowPanelEmpty' }
      end
      if view.filter_query ~= '' then
        return {
          text = ("  No matches for '%s'"):format(view.filter_query),
          hl = 'VVFlowPanelEmpty',
        }
      end
      return {
        text = view.mode == 'marks' and '  No marks' or '  No flow marks',
        hl = 'VVFlowPanelEmpty',
      }
    end,
  }
end

return M
