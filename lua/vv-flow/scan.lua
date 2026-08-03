-- vv-flow.scan — 用 rg --json 跨文件扫描标记
--
-- 流程沿用 vv-replace/search.lua：每条 rule 一个 -e，rg 输出 NDJSON 流式收集，
-- 进程结束后一次性解析 + 分类，回调返回扁平 record 列表。ripgrep 已是项目硬依赖。
--
-- 分类优先按命中的 rule；只有规则无法完整回测时，才按文本字面兜底。

local M = {}
local Glob = require('vv-utils.glob')

-- 解析一批 NDJSON 行，返回已解析对象 + 遗留的不完整尾串
---@param text string
---@param buffer string
---@return any[] parsed, string new_buffer
local function parse_ndjson_chunk(text, buffer)
  local parsed = {}
  local combined = buffer .. text
  local start = 1
  while true do
    local nl = combined:find('\n', start, true)
    if not nl then break end
    local line = combined:sub(start, nl - 1)
    start = nl + 1
    if #line > 0 then
      local ok, obj = pcall(vim.json.decode, line)
      if ok then parsed[#parsed + 1] = obj end
    end
  end
  return parsed, combined:sub(start)
end

-- 兜底：按匹配文本字面归类（当没有 rule 完整匹配时用）
---@param text string 匹配到的标记文本，如 '@TODO'
---@param prefix string
---@return { kind: string, name: string, num: integer? }
local function classify_by_text(text, prefix)
  local body = text
  if prefix ~= '' and text:sub(1, #prefix) == prefix then
    body = text:sub(#prefix + 1)
  end
  local word = body:match('^%a[%w_]*')
  if word then
    return { kind = 'keyword', name = word:lower() }
  end
  return { kind = 'custom', name = text }
end

-- 预编译各 rule 的 vim.regex，供「按命中规则」归类
---@param rules VVFlowScanRule[]
local function compile_matchers(rules)
  local matchers = {}
  for _, r in ipairs(rules) do
    local ok, re = pcall(vim.regex, r.vim_regex)
    matchers[#matchers + 1] = { rule = r, regex = ok and re or nil }
  end
  return matchers
end

-- 归类：rg 多 -e 一起跑时 submatch 不带「哪条规则命中」，故对匹配文本逐条回测，
-- 取第一条「完整匹配」的 rule 决定 kind/name（custom 规则的 name 也才能对上面板分组）；
-- 全不中再退回字面派生
---@param text string
---@param prefix string
---@param matchers { rule: VVFlowScanRule, regex: any }[]
---@return { kind: string, name: string, num: integer? }
local function classify(text, prefix, matchers)
  for _, m in ipairs(matchers) do
    if m.regex then
      local s, e = m.regex:match_str(text)

      if s == 0 and e == #text then
        if m.rule.kind == 'step' then
          local namespace, number = text:match(':([%a][%w_-]*)%-(%d+)$')

          if namespace and number then
            return {
              kind = 'step',
              name = namespace:lower(),
              num = tonumber(number),
            }
          end
        end
        return { kind = m.rule.kind, name = m.rule.name }
      end
    end
  end
  return classify_by_text(text, prefix)
end

-- 构造 rg 参数
---@param rules VVFlowScanRule[]
---@param root string
---@param opts { max_results: integer, exclude: string[], rg_extra_args: string[] }
---@return string[]? args
---@return string? error
local function build_args(rules, root, opts)
  local args = { '--json', '--color=never', '--line-number', '--no-heading', '--max-columns=1000' }
  for _, r in ipairs(rules) do
    args[#args + 1] = '-e'
    args[#args + 1] = r.rg_pattern
  end

  for _, source in ipairs(opts.exclude or {}) do
    local patterns, err = Glob.compile_rg(source, { negate = true })
    if not patterns then
      return nil, ('无效的扫描排除项 %q：%s'):format(source, err)
    end
    for _, pattern in ipairs(patterns) do
      args[#args + 1] = '--glob'
      args[#args + 1] = pattern
    end
  end

  for _, extra in ipairs(opts.rg_extra_args or {}) do
    args[#args + 1] = extra
  end
  args[#args + 1] = root

  return args, nil
end

-- 异步扫描；cb(records) 在主线程回调
---@param root string
---@param rules VVFlowScanRule[]
---@param opts { prefix: string, max_results: integer, exclude: string[], rg_extra_args: string[] }
---@param cb fun(records: VVFlowRecord[], err?: string)
---@return fun() cancel
function M.scan(root, rules, opts, cb)
  if #rules == 0 then
    cb({})
    return function() end
  end

  local matchers = compile_matchers(rules)
  local args, args_err = build_args(rules, root, opts)

  if not args then
    cb({}, args_err)
    return function() end
  end

  local collected = {}

  local stdout_buf = ''
  local stderr_buf = ''

  local finished = false
  local delivered = false
  local cancelled = false

  local max = opts.max_results or 5000
  local truncated = false
  local collected_count = 0

  local function collect_match(obj)
    if obj.type ~= 'match' then return end

    local data = obj.data or {}
    local path = data.path and data.path.text
    local lnum = data.line_number

    if not path or not lnum then return end

    local kept = {}

    for _, sm in ipairs(data.submatches or {}) do
      if sm.match and sm.match.text then
        if collected_count < max then
          kept[#kept + 1] = sm
          collected_count = collected_count + 1
        else
          truncated = true
        end
      end
    end

    if #kept > 0 then
      data.submatches = kept
      collected[#collected + 1] = obj
    end
  end

  local job
  job = vim.system({ 'rg', unpack(args) }, {
    text = true,
    cwd = root,

    stdout = function(err, data)
      if finished or cancelled or err or not data then return end
      local parsed, new_buf = parse_ndjson_chunk(data, stdout_buf)
      stdout_buf = new_buf
      for _, obj in ipairs(parsed) do
        collect_match(obj)
      end
      if truncated and job then
        pcall(function() job:kill('sigterm') end)
      end
    end,

    stderr = function(err, data)
      if cancelled or err or not data then return end
      stderr_buf = stderr_buf .. data
    end,
  }, function(result)
    if finished or cancelled then return end
    finished = true

    vim.schedule(function()
      if cancelled then return end
      if #stdout_buf > 0 then
        local ok, obj = pcall(vim.json.decode, stdout_buf)
        if ok then collect_match(obj) end
      end

      -- code 0 = 有匹配，1 = 无匹配（正常）。其余（如 2 = 部分文件不可读，或被
      -- SIGTERM 截断）只要已收集到结果就照常投递——避免「单个不可读目录 / 截断」
      -- 把整张面板清空。仅在「非 0/1 且无任何收集且非截断」时才当真错误。
      local hard_err = result.code ~= 0 and result.code ~= 1 and not truncated and #collected == 0
      if hard_err then
        delivered = true
        cb({}, stderr_buf ~= '' and vim.trim(stderr_buf) or ('rg exit ' .. tostring(result.code)))
        return
      end

      local records = {}

      for _, obj in ipairs(collected) do
        local data = obj.data
        local path = data.path and data.path.text
        local lnum = data.line_number
        local line_text = (data.lines and data.lines.text) or ''

        if path and lnum then
          for _, sm in ipairs(data.submatches or {}) do
            local text = sm.match and sm.match.text

            if text then
              local meta = classify(text, opts.prefix, matchers)
              records[#records + 1] = {
                file = path,
                lnum = lnum,
                col = (sm.start or 0) + 1,  -- rg start 为 0-based byte → 1-based
                text = text,
                preview = vim.trim(line_text),
                kind = meta.kind,
                name = meta.name,
                num = meta.num,
              }
            end
          end
        end
      end

      delivered = true
      cb(records, truncated and 'truncated' or nil)
    end)
  end)

  return function()
    if cancelled or delivered then return end
    cancelled = true
    if job then pcall(function() job:kill('sigterm') end) end
  end
end

return M

---@class VVFlowRecord
---@field file string      绝对路径
---@field lnum integer     1-based 行号
---@field col integer      1-based 列
---@field text string      匹配到的标记文本（如 '@TODO' / '@step:auth-2'）
---@field preview string   该行去空白后的内容，作面板预览
---@field kind 'step'|'keyword'|'custom'
---@field name string      归组键（step 命名空间或小写关键字名）
---@field num? integer     step 序号（供数值排序）

---@class VVFlowScanRule
---@field name string  规则唯一名
---@field kind 'step'|'keyword'|'custom'  标记分类
---@field vim_regex string  buffer 高亮用 Vim 正则
---@field rg_pattern string  rg 扫描用 Rust 正则
