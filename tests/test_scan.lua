-- vv-flow 扫描排除项集成测试
--
-- 运行方式：
-- nvim --headless -u NONE -l tests/test_scan.lua

local src = debug.getinfo(1, 'S').source:gsub('^@', '')
local dir = src:match('(.*/)') or './'
local root = vim.fn.fnamemodify(dir .. 'tmp-scan', ':p'):gsub('/$', '')

vim.opt.runtimepath:prepend(vim.fs.normalize(dir .. '../../vv-utils.nvim'))
vim.opt.runtimepath:prepend(vim.fs.normalize(dir .. '..'))

local Flow = require('vv-flow')
Flow.setup({ highlight = false, exclude = {} })
assert(#Flow.get_config().exclude == 0, 'exclude = {} 应能清空默认黑名单')

---@param path string
---@param content string|string[]
local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(type(content) == 'table' and content or { content }, path)
end

vim.fn.delete(root, 'rf')
write(root .. '/src/main.lua', '-- @TODO included')
write(root .. '/src/checkout.lua', '-- @STEP:Checkout-10 then @step:checkout-2')
write(root .. '/src/auth.lua', {
  '-- @step:auth-3',
  '-- invalid: @17 @STEP 4 @step:1auth-2 @step:auth-x',
})
write(root .. '/node_modules/pkg/index.js', '// @TODO excluded')
write(root .. '/pnpm-lock.yaml', '# @TODO excluded')
write(root .. '/target/debug/generated.rs', '// @TODO excluded')
write(root .. '/.venv/lib/site-packages/pkg.py', '# @TODO excluded')
write(root .. '/vendor/github.com/pkg/main.go', '// @TODO excluded')
write(root .. '/build/generated.java', '// @TODO excluded')
write(root .. '/Cargo.lock', '# @TODO excluded')
write(root .. '/poetry.lock', '# @TODO excluded')

local done = false
local records
local scan_error

require('vv-flow.scan').scan(root, {
  {
    kind = 'step',
    name = 'step',
    vim_regex = '\\c@STEP:[a-z][a-z0-9_-]*-\\d\\+\\>',
    rg_pattern = '(?i)@STEP:[a-z][a-z0-9_-]*-\\d+\\b',
  },
  {
    kind = 'keyword',
    name = 'todo',
    vim_regex = '\\c@TODO\\>',
    rg_pattern = '(?i)@TODO\\b',
  },
}, {
  prefix = '@',
  max_results = 100,
  exclude = {
    'node_modules', 'pnpm-lock.yaml',
    'target', '.venv', 'vendor', 'build',
    'Cargo.lock', 'poetry.lock',
  },
  rg_extra_args = { '--no-ignore' },
}, function(result, err)
  records = result
  scan_error = err
  done = true
end)

assert(vim.wait(5000, function() return done end), '扫描超时')
assert(scan_error == nil, scan_error)
assert(records, '扫描完成后应返回 records')
assert(#records == 4, ('预期扫描 4 条，实际 %d 条'):format(#records))

local steps = {}
local todo
for _, record in ipairs(records) do
  if record.kind == 'step' then
    steps[#steps + 1] = record
  elseif record.name == 'todo' then
    todo = record
  end
end
table.sort(steps, function(left, right)
  if left.name ~= right.name then return left.name < right.name end
  return left.num < right.num
end)

assert(todo and todo.file:match('src/main%.lua$'), 'TODO 应正常扫描')
assert(#steps == 3, '应只识别 3 个 namespaced step')
assert(steps[1].name == 'auth' and steps[1].num == 3, 'auth step 应提取命名空间与序号')
assert(steps[2].name == 'checkout' and steps[2].num == 2
    and steps[3].name == 'checkout' and steps[3].num == 10,
  'step 命名空间应转小写，并保留数字序号')

write(root .. '/.gitignore', 'ignored/')
write(root .. '/ignored/secret.lua', '-- @TODO ignored by git')
vim.fn.mkdir(root .. '/.git', 'p')

done = false
records = nil
scan_error = nil

require('vv-flow.scan').scan(root, {
  {
    kind = 'keyword',
    name = 'todo',
    vim_regex = '\\c@TODO\\>',
    rg_pattern = '(?i)@TODO\\b',
  },
}, {
  prefix = '@',
  max_results = 100,
  exclude = {},
  rg_extra_args = {},
}, function(result, err)
  records = result
  scan_error = err
  done = true
end)

assert(vim.wait(5000, function() return done end), '扫描超时')
assert(scan_error == nil, scan_error)
assert(records, '扫描完成后应返回 records')
for _, record in ipairs(records) do
  assert(not record.file:match('ignored/secret%.lua$'), '.gitignore 中的文件不应被扫描')
end

vim.fn.delete(root, 'rf')
print('PASS: 跨语言黑名单与 .gitignore 均生效')
