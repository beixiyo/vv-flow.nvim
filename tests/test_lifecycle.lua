-- vv-flow public setup lifecycle regression

local src = debug.getinfo(1, 'S').source:gsub('^@', '')
local dir = src:match('(.*/)') or './'

vim.opt.runtimepath:prepend(vim.fs.normalize(dir .. '../../vv-utils.nvim'))
vim.opt.runtimepath:prepend(vim.fs.normalize(dir .. '..'))

local Flow = require('vv-flow')
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '-- @TODO lifecycle' })
vim.api.nvim_set_current_buf(buf)

Flow.setup({ highlight = true })

local namespace = vim.api.nvim_get_namespaces().vv_flow_highlight
assert(namespace, '实时高亮 namespace 应存在')
assert(#vim.api.nvim_get_autocmds({ group = 'vv-flow.highlight' }) == 2, 'enable 应注册 2 个 autocmd')
assert(#vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) == 1, 'enable 应创建实时高亮')

Flow.setup({ highlight = false })

assert(#vim.api.nvim_get_autocmds({ group = 'vv-flow.highlight' }) == 0, '重配 false 应清理高亮 autocmd')
assert(#vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) == 0, '重配 false 应清理 extmark')

vim.api.nvim_buf_delete(buf, { force = true })
print('PASS: setup highlight true→false 完整释放实时高亮')
