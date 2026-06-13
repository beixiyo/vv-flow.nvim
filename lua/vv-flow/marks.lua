-- vv-flow.marks — 把 vim marks 列成与 scan.lua 同契约的 VVFlowRecord[]
--
-- 产出供面板渲染：每条 mark 一条 record（kind='mark'），额外带 mark（裸字符，
-- 删除用）与 mark_kind（global/buffer/numbered/special，删除分派用）。
--
-- 数据来源（均 headless 实测确认）：
--   * 全局 A-Z/0-9：vim.fn.getmarklist()（无参），每项带 mark/file/pos；
--     file 可能被 ~ 缩写，须 fnamemodify(':p') 还原绝对路径；未加载文件 pos[1]==0
--     不可信，路径只认 file。
--   * 局部 a-z/特殊：vim.fn.getmarklist(bufnr)，每项只有 mark/pos 无 file，
--     路径取 nvim_buf_get_name(pos[1])。
--   * pos[2]=1based lnum，pos[3]=1based col，直接对接契约。
--
-- vim 无 mark 变化事件 → 面板靠手动刷新，本模块不挂 autocmd。

local M = {}

-- 按裸字符分类，决定 mark_kind 与面板分组名
---@param bare string  裸 mark 字符（不含前导单引号）
---@return string mark_kind, string name
local function classify(bare)
  if bare:match('^%u$') then return 'global',   'Global A-Z' end
  if bare:match('^%l$') then return 'buffer',   'Buffer a-z' end
  if bare:match('^%d$') then return 'numbered', 'Numbered'   end
  return 'special', 'Special'
end

-- 默认展示 global+buffer，隐藏 numbered+special
local DEFAULT_SHOW = { global = true, buffer = true, numbered = false, special = false }

-- 构造一个「取某文件某行内容」的读取器：
--   * buffer 已加载 → nvim_buf_get_lines（最新内容）
--   * 未加载 → readfile（越界返回 nil 安全），对同一文件缓存避免重复读盘；
--     不可读文件缓存为 false，后续直接返回空串。不做 bufload。
---@return fun(abs: string, lnum: integer): string
local function make_line_reader()
  local cache = {}
  return function(abs, lnum)
    local bnr = vim.fn.bufnr(abs)
    if bnr > 0 and vim.api.nvim_buf_is_loaded(bnr) then
      return (vim.api.nvim_buf_get_lines(bnr, lnum - 1, lnum, false))[1] or ''
    end

    local c = cache[abs]
    if c == nil then
      local ok, data = pcall(vim.fn.readfile, abs)
      c = (ok and data) or false
      cache[abs] = c
    end
    if not c then return '' end
    return c[lnum] or ''
  end
end

-- 把一条 getmarklist 项规整成 record；非法（无路径 / 行号 < 1）返回 nil
---@param mark string   带前导单引号的 mark（如 "'A"）
---@param abs string    绝对路径（可能为空）
---@param lnum integer  1based 行号
---@param col integer   1based 列
---@param read_line fun(abs: string, lnum: integer): string
---@return VVFlowRecord?
local function to_record(mark, abs, lnum, col, read_line)
  if not abs or abs == '' then return nil end
  if not lnum or lnum < 1 then return nil end

  local bare = mark:sub(2)
  local mark_kind, name = classify(bare)
  local line = read_line(abs, lnum)

  return {
    file = abs,
    lnum = lnum,
    col = math.max(1, col or 1),
    text = "'" .. bare,
    preview = vim.trim(line),
    kind = 'mark',
    name = name,
    mark = bare,
    mark_kind = mark_kind,
  }
end

-- 列出全部（按 show 过滤）的 mark records
---@param opts? { show?: table<string, boolean> }
---@return VVFlowRecord[]
function M.list(opts)
  opts = opts or {}
  local show = vim.tbl_extend('force', DEFAULT_SHOW, opts.show or {})
  local read_line = make_line_reader()
  local records = {}

  local function push(rec)
    if rec and show[rec.mark_kind] then
      records[#records + 1] = rec
    end
  end

  -- 全局 A-Z / 0-9：file 须还原绝对路径；行列取自 pos[2]/pos[3]
  for _, m in ipairs(vim.fn.getmarklist()) do
    local abs = m.file and vim.fn.fnamemodify(m.file, ':p') or ''
    local pos = m.pos or {}
    push(to_record(m.mark, abs, pos[2], pos[3], read_line))
  end

  -- 局部 a-z / 特殊：只遍历 listed 且 loaded 的 buffer；路径取自 pos 里的 bufnr
  for _, bnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.buflisted(bnr) == 1 and vim.api.nvim_buf_is_loaded(bnr) then
      for _, m in ipairs(vim.fn.getmarklist(bnr)) do
        local pos = m.pos or {}
        local owner = pos[1] and pos[1] > 0 and pos[1] or bnr
        local abs = vim.api.nvim_buf_get_name(owner)
        push(to_record(m.mark, abs, pos[2], pos[3], read_line))
      end
    end
  end

  return records
end

-- 删除一条 mark：
--   * global：nvim_del_mark(bare)（传小写会报错，故仅 global 走这里）
--   * buffer/special：nvim_buf_del_mark(bnr, bare)
--   * 全失败兜底：:delmarks bare
---@param record table  需含 .mark / .mark_kind / .file
---@return boolean
function M.delete(record)
  if not record or not record.mark then return false end
  local bare = record.mark

  if record.mark_kind == 'global' or record.mark_kind == 'numbered' then
    local ok = pcall(vim.api.nvim_del_mark, bare)
    if ok then return true end
  else
    local bnr = record.file and vim.fn.bufnr(record.file) or -1
    if bnr > 0 then
      local ok = pcall(vim.api.nvim_buf_del_mark, bnr, bare)
      if ok then return true end
    end
  end

  -- 兜底：不区分类型，按裸字符删
  return pcall(vim.cmd, 'delmarks ' .. bare)
end

return M
