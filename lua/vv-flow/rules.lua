-- vv-flow.rules — 把用户 config 编译成内部「标记规则」
--
-- 每条 rule 同时给出三种用途的形态，scan.lua 与 highlight.lua 共用一份，避免
-- 两处各写一套正则（DRY）：
--   * vim_regex   buffer 内实时高亮用（vim.regex 编译，magic 模式语法）
--   * rg_pattern  rg --json 跨文件扫描用（Rust 正则，作为独立 -e 传入）
--   * hl          高亮组名
--   * kind        'step' | 'keyword' | 'custom'  决定面板分组与排序
--
-- 设计要点：大小写不敏感按「规则粒度」处理——关键字 rule 在 rg 端用内联
-- `(?i)`、vim 端用 `\c`，故无需对 rg 开全局 -i，自定义 rule 不受影响。

local M = {}

-- 关键字默认按字母序，保证面板分组/高亮注册顺序稳定（map 遍历无序）
---@param keywords table<string, table>
---@return string[]
local function sorted_keyword_names(keywords)
  local names = {}
  for name in pairs(keywords or {}) do names[#names + 1] = name end
  table.sort(names)
  return names
end

-- 把字符串里的正则元字符转义（关键字一般是纯字母，仍保险处理）
-- 注：`/` 在 vim.regex 编译的模式里不是特殊字符，无需转义（转了也只是冗余的 \/）
---@param s string
local function vim_escape(s)
  return (s:gsub('[\\.*$^~%[%]]', '\\%0'))
end

---@param s string
local function rg_escape(s)
  return (s:gsub('[\\.+*?()|%[%]{}^$]', '\\%0'))
end

-- 由 config 编译出有序 rule 列表；顺序即面板分组顺序（step 规则优先）
---@param cfg VVFlowConfig
---@return VVFlowRule[]
function M.build(cfg)
  local rules = {}
  local prefix = cfg.prefix or '@'
  local vp = vim_escape(prefix)
  local rp = rg_escape(prefix)

  -- 流程步骤：@step:<namespace>-<number>。规则只负责整体命中，namespace 与
  -- number 由 scan 分类阶段提取，从而按业务命名空间动态分组
  if cfg.step and cfg.step.enable ~= false then
    local keyword = cfg.step.keyword or 'STEP'
    local vim_keyword = vim_escape(keyword)
    local rg_keyword = rg_escape(keyword)
    local ignore_case = cfg.step.ignore_case ~= false
    rules[#rules + 1] = {
      name = 'step',
      kind = 'step',
      label = prefix .. keyword:upper(),
      icon = cfg.step.icon or '',
      hl = 'VVFlowStep',
      color = cfg.step.color,
      vim_regex = (ignore_case and '\\c' or '\\C')
        .. vp .. vim_keyword .. ':[a-z][a-z0-9_-]*-\\d\\+\\>',
      rg_pattern = (ignore_case and '(?i)' or '')
        .. rp .. rg_keyword .. ':[a-z][a-z0-9_-]*-\\d+\\b',
    }
  end

  -- 关键字 rules：@TODO / @BUG …（默认大小写不敏感）
  local ic = cfg.ignore_case ~= false
  for _, name in ipairs(sorted_keyword_names(cfg.keywords)) do
    local spec = cfg.keywords[name] or {}
    local up = name:upper()
    local vword = vim_escape(up)
    local rword = rg_escape(up)
    rules[#rules + 1] = {
      name = name:lower(),
      kind = 'keyword',
      label = prefix .. up,
      icon = spec.icon or '',
      hl = 'VVFlowKw' .. up,
      color = spec.color,
      -- vim：`\c`(整体不敏感) + 前缀 + 词 + `\>`(词尾边界，避免 @TODOS 命中)
      vim_regex = (ic and '\\c' or '\\C') .. vp .. vword .. '\\>',
      -- rg：内联 (?i) 仅作用于本 -e，词后接 \b 边界
      rg_pattern = (ic and '(?i)' or '') .. rp .. rword .. '\\b',
    }
  end

  -- 自定义 rules：任意正则逃生舱。调用方各自提供 vim_regex / rg_pattern
  for _, c in ipairs(cfg.custom or {}) do
    if c.name and c.vim_regex and c.rg_pattern then
      rules[#rules + 1] = {
        name = c.name,
        kind = c.kind or 'custom',
        label = c.label or (prefix .. c.name),
        icon = c.icon or '',
        hl = c.hl or ('VVFlowCustom' .. c.name),
        color = c.color,
        vim_regex = c.vim_regex,
        rg_pattern = c.rg_pattern,
      }
    end
  end

  return rules
end

-- 收集所有 rule 的高亮组 → 颜色 spec，交给 vv-utils.hl.register
---@param rules VVFlowRule[]
---@return table<string, vim.api.keyset.highlight>
function M.hl_specs(rules)
  local specs = {}
  for _, r in ipairs(rules) do
    if r.color then
      specs[r.hl] = type(r.color) == 'table' and r.color or { fg = r.color, bold = true }
    end
  end
  return specs
end

return M

---@class VVFlowRule
---@field name string        规则唯一名（小写）。流程步骤固定 'step'，关键字为小写词
---@field kind 'step'|'keyword'|'custom'  分类，决定面板分组与排序
---@field label string       面板分组标题文本（如 '@TODO' / '@STEP'）
---@field icon string        分组/标记图标
---@field hl string          高亮组名
---@field color? string|table  颜色（hex 或 highlight spec）
---@field vim_regex string   buffer 实时高亮用（magic 模式）
---@field rg_pattern string  rg --json 扫描用（Rust 正则）
