-- vv-flow 面板纯数据模型：分组、排序、过滤文本与稳定树节点

local Path = require('vv-utils.path')

local M = {}

local MARK_GROUPS = {
  { name = 'Global A-Z', hl = 'VVFlowMarkGlobal' },
  { name = 'Buffer a-z', hl = 'VVFlowMarkBuffer' },
  { name = 'Numbered', hl = 'VVFlowMarkNumbered' },
  { name = 'Special', hl = 'VVFlowMarkSpecial' },
}

---@param root string
---@param file string
---@return string
function M.relative_path(root, file)
  local ok, relative = pcall(vim.fs.relpath, root, file)
  if ok and relative then return relative end
  return vim.fn.fnamemodify(file, ':~')
end

---@param record table
---@param root string
---@return string
function M.record_hay(record, root)
  return table.concat({
    record.text or '',
    record.preview or '',
    M.relative_path(root, record.file or ''),
    record.name or '',
  }, '\n')
end

---@param records VVFlowRecord[]
---@param rules VVFlowRule[]
---@return table[]
function M.build_flow_groups(records, rules)
  local groups = {}
  local by_name = {}
  local step_rule

  local function group_key(kind, name)
    return table.concat({ kind or '', name or '' }, '\31')
  end

  for _, rule in ipairs(rules or {}) do
    if rule.kind == 'step' then
      step_rule = rule
    else
      local group = {
        name = rule.name,
        label = rule.label,
        icon = rule.icon,
        hl = rule.hl,
        kind = rule.kind,
        markers = {},
      }
      groups[#groups + 1] = group
      by_name[group_key(rule.kind, rule.name)] = group
    end
  end

  for _, record in ipairs(records or {}) do
    local key = group_key(record.kind, record.name)
    local group = by_name[key]
    if not group then
      group = {
        name = record.name,
        label = record.kind == 'step' and step_rule
            and ('%s:%s'):format(step_rule.label, record.name)
          or record.text
          or record.name,
        icon = record.kind == 'step' and step_rule and step_rule.icon or '',
        hl = record.kind == 'step' and step_rule and step_rule.hl or 'Normal',
        kind = record.kind,
        markers = {},
      }
      groups[#groups + 1] = group
      by_name[key] = group
    end
    group.markers[#group.markers + 1] = record
  end

  local result = {}
  for _, group in ipairs(groups) do
    if group.kind == 'step' then
      table.sort(group.markers, function(left, right)
        if (left.num or 0) ~= (right.num or 0) then
          return (left.num or 0) < (right.num or 0)
        end
        if left.file ~= right.file then return left.file < right.file end
        return left.lnum < right.lnum
      end)
    else
      table.sort(group.markers, function(left, right)
        if left.file ~= right.file then return left.file < right.file end
        return left.lnum < right.lnum
      end)
    end

    if #group.markers > 0 then result[#result + 1] = group end
  end
  return result
end

---@param records table[]
---@return table[]
function M.build_mark_groups(records)
  local by_name = {}
  for _, record in ipairs(records or {}) do
    by_name[record.name] = by_name[record.name] or {}
    by_name[record.name][#by_name[record.name] + 1] = record
  end

  local groups = {}
  for _, metadata in ipairs(MARK_GROUPS) do
    local markers = by_name[metadata.name]
    if markers and #markers > 0 then
      table.sort(markers, function(left, right)
        if (left.mark or '') ~= (right.mark or '') then
          return (left.mark or '') < (right.mark or '')
        end
        return left.lnum < right.lnum
      end)
      groups[#groups + 1] = {
        name = metadata.name,
        label = metadata.name,
        icon = '',
        hl = metadata.hl,
        kind = 'mark',
        markers = markers,
      }
    end
  end
  return groups
end

---@param groups table[]
---@return integer
function M.marker_count(groups)
  local count = 0
  for _, group in ipairs(groups or {}) do count = count + #group.markers end
  return count
end

local function marker_id(mode, marker, occurrences)
  local base = table.concat({
    mode,
    marker.kind or '',
    marker.name or marker.mark_kind or '',
    Path.norm(marker.file or ''),
    tostring(marker.lnum or 0),
    tostring(marker.col or 0),
    marker.text or '',
  }, '\31')
  occurrences[base] = (occurrences[base] or 0) + 1
  return 'marker:' .. base .. '\31' .. occurrences[base]
end

---@param groups table[]
---@param root string
---@param mode string
---@return VVTreePanelNode[]
function M.nodes(groups, root, mode)
  local nodes = {}
  local occurrences = {}

  for _, group in ipairs(groups or {}) do
    local children = {}
    for _, marker in ipairs(group.markers) do
      children[#children + 1] = {
        id = marker_id(mode, marker, occurrences),
        label = marker.text,
        location = {
          file = marker.file,
          row = marker.lnum,
          col = math.max(0, (marker.col or 1) - 1),
        },
        data = {
          kind = 'marker',
          marker = marker,
          group_hl = group.hl,
          relative_path = M.relative_path(root, marker.file),
        },
      }
    end

    nodes[#nodes + 1] = {
      id = ('group:%s:%s:%s'):format(mode, group.kind, group.name),
      label = group.label,
      selectable = false,
      children = children,
      data = {
        kind = 'group',
        group = group,
      },
    }
  end

  return nodes
end

return M
