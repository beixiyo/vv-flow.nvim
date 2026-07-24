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

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ text }, path)
end

vim.fn.delete(root, 'rf')
write(root .. '/src/main.lua', '-- @TODO included')
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
assert(#records == 1, ('预期仅扫描 1 条，实际 %d 条'):format(#records))
assert(records[1].file:match('src/main%.lua$'), records[1].file)

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
for _, record in ipairs(records) do
  assert(not record.file:match('ignored/secret%.lua$'), '.gitignore 中的文件不应被扫描')
end

vim.fn.delete(root, 'rf')
print('PASS: 跨语言黑名单与 .gitignore 均生效')
