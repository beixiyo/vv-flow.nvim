-- vv-flow.highlight — buffer 内标记实时高亮
--
-- 为何不用 vv-log-hl 的 `syn keyword`：标记含非词字符（`@`、数字、`.`），
-- syn keyword 只认整词、且大小写规则受限，表达不了 `@\d+\.?`。故走
-- extmark + 每 rule 一个编译好的 vim.regex 逐行匹配——任意 vim 正则都能高亮。
--
-- attach 机制（幂等 token + on_lines 增量重绘）整体沿用 vv-log-hl/badge.lua：
-- 同一 buffer 不叠加回调；行增删时多重绘一行，避免漂移残留。

local M = {}

local ns = vim.api.nvim_create_namespace('vv_flow_highlight')

-- buffer -> { enabled }。条目存在即 C 层 on_lines 回调已挂（一个 buffer 终生只挂一次，
-- 直到 buffer 被 wipe）。enable / disable 只翻转 enabled，不重复 nvim_buf_attach。
---@type table<integer, { enabled: boolean }>
local tracked = {}

-- 编译后的规则：{ regex = vim.regex, hl = string }
---@type { regex: any, hl: string }[]
local compiled = {}

local PRIORITY = 200  -- 高于 treesitter(100)，确保注释里的标记能盖住注释色

-- 检测左边界敏感构造：decorate_line 逐子串迭代会把每个子串起点当成「行首」，
-- 含 \< / 行首 ^ / \zs / lookbehind 的（custom）正则在行内第二处起会假命中，提前告警
---@param vim_regex string
local function warn_left_anchor(vim_regex)
  if vim_regex:find('\\<', 1, true)
    or vim_regex:find('\\zs', 1, true)
    or vim_regex:find('\\@<', 1, true)
    or vim_regex:find('\\c^', 1, true) or vim_regex:find('\\C^', 1, true)
    or vim_regex:sub(1, 1) == '^' then
    vim.notify(
      string.format('[vv-flow] custom 正则含左边界构造（\\< / ^ / \\zs / lookbehind），'
        .. '行内多处匹配可能错位：%s', vim_regex),
      vim.log.levels.WARN
    )
  end
end

--- 用编译好的 rules 刷新本模块状态（setup / config 变更时调用）
---@param rules VVFlowRule[]
function M.set_rules(rules)
  compiled = {}
  for _, r in ipairs(rules) do
    local ok, re = pcall(vim.regex, r.vim_regex)
    if ok then
      compiled[#compiled + 1] = { regex = re, hl = r.hl }
      warn_left_anchor(r.vim_regex)
    else
      vim.notify(
        string.format('[vv-flow] 无效 vim 正则，已跳过：%s', r.vim_regex),
        vim.log.levels.WARN
      )
    end
  end
end

--- 为一行打所有规则的高亮
---@param bufnr integer
---@param lnum integer 0-indexed
---@param line string
local function decorate_line(bufnr, lnum, line)
  if line == '' then return end
  for _, r in ipairs(compiled) do
    local from = 0
    while from <= #line do
      -- match_str 在「子串」上找首个匹配，返回 0-based byte 起止（end 为开区间）
      local s, e = r.regex:match_str(line:sub(from + 1))
      if not s then break end
      local cs, ce = from + s, from + e
      if ce > cs then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum, cs, {
          end_col = ce,
          hl_group = r.hl,
          priority = PRIORITY,
        })
        from = ce
      else
        from = cs + 1  -- 零宽匹配：跳过不打 extmark，+1 防死循环
      end
    end
  end
end

---@param bufnr integer
---@param start_line integer 0-indexed 含
---@param end_line integer 0-indexed 不含（-1 到末尾）
local function decorate_range(bufnr, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
  for i, line in ipairs(lines) do
    decorate_line(bufnr, start_line + i - 1, line)
  end
end

---@param bufnr integer
local function decorate_buf(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  decorate_range(bufnr, 0, -1)
end

--- 该 buffer 是否应被高亮（仅普通文件 buffer）
---@param bufnr integer
---@return boolean
local function should_attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if vim.bo[bufnr].buftype ~= '' then return false end
  return true
end

--- 启用某 buffer 的标记高亮（一个 buffer 终生只挂一次 on_lines；重复调用仅重绘）
---@param bufnr? integer
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not should_attach(bufnr) then return end
  if #compiled == 0 then return end

  local t = tracked[bufnr]
  if t then
    -- 已挂回调（可能是 disable 后重新 enable）：置 enabled 并重绘，不再 buf_attach
    t.enabled = true
    decorate_buf(bufnr)
    return
  end

  tracked[bufnr] = { enabled = true }
  decorate_buf(bufnr)

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, _, firstline, _, new_lastline)
      local st = tracked[buf]
      if not st then return true end      -- 条目已清（buffer wipe）→ 解绑
      if not st.enabled then return end   -- 暂禁用：保留回调但不重绘
      vim.schedule(function()
        local st2 = tracked[buf]
        if not st2 or not st2.enabled or not vim.api.nvim_buf_is_valid(buf) then return end
        local hi = math.min(new_lastline + 1, vim.api.nvim_buf_line_count(buf))
        vim.api.nvim_buf_clear_namespace(buf, ns, firstline, hi)
        decorate_range(buf, firstline, hi)
      end)
    end,
    on_detach = function(_, buf)
      tracked[buf] = nil
    end,
  })
end

--- 解除单个 buffer 的高亮（保留 C 层回调，仅置 dormant + 清 extmark）
---@param bufnr? integer
function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local t = tracked[bufnr]
  if t then t.enabled = false end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

--- 解除所有 buffer 的高亮（供 disable）
function M.detach_all()
  for buf, t in pairs(tracked) do
    t.enabled = false
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
end

--- 重新装饰所有启用中的 buffer（rules 变更后用）
function M.redecorate_all()
  for buf, t in pairs(tracked) do
    if t.enabled and vim.api.nvim_buf_is_valid(buf) then decorate_buf(buf) end
  end
end

return M
