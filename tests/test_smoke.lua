-- vv-flow.nvim 冒烟测试
--
-- 运行方式：luajit tests/test_smoke.lua（纯逻辑测试）
-- 或在 nvim 中 :luafile tests/test_smoke.lua
--
-- 覆盖 rules.build 的规则编译（纯 lua，不依赖 nvim API）：内置 step / 关键字规则的
-- vim 正则与 rg 正则构造、大小写敏感、custom 透传、hl_specs。
-- 实时高亮 / 扫描 / 面板 / 预览等依赖 nvim API 的运行时行为见仓库 README 的 headless 验证。

-- 把插件 lua/ 加入 package.path（相对本脚本定位）
local src = debug.getinfo(1, 'S').source:gsub('^@', '')
local dir = src:match('(.*/)') or './'
package.path = dir .. '../lua/?.lua;' .. dir .. '../lua/?/init.lua;' .. package.path

local Rules = require('vv-flow.rules')

local passed, failed = 0, 0

---@param name string
---@param fn fun()
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('  PASS: ' .. name)
  else
    failed = failed + 1
    print('  FAIL: ' .. name .. ' — ' .. tostring(err))
  end
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format('%s: expected %q, got %q', msg or 'assert_eq', tostring(expected), tostring(actual)))
  end
end

---@param rules VVFlowRule[]
---@param name string
local function find(rules, name)
  for _, r in ipairs(rules) do
    if r.name == name then return r end
  end
end

-- 基础配置（模拟 setup 后的 config）
local function base_cfg(over)
  local cfg = {
    prefix = '@',
    ignore_case = true,
    step = { enable = true, keyword = 'STEP', ignore_case = true, color = '#bb9af7', icon = '' },
    keywords = { TODO = { color = '#7aa2f7' }, BUG = { color = '#f7768e' } },
    custom = {},
  }
  for k, v in pairs(over or {}) do cfg[k] = v end
  return cfg
end

print('\n[rules] 内置规则构造')

test('step + 关键字规则都生成，step 在最前', function()
  local rules = Rules.build(base_cfg())
  assert_eq(rules[1].name, 'step', '第一条应为 step 规则')
  assert(find(rules, 'todo'), 'todo 规则存在')
  assert(find(rules, 'bug'), 'bug 规则存在')
end)

test('step 规则：命名空间 + 末尾数字，默认大小写不敏感', function()
  local step = find(Rules.build(base_cfg()), 'step')
  assert_eq(step.vim_regex, '\\c@STEP:[a-z][a-z0-9_-]*-\\d\\+\\>', 'step vim_regex')
  assert_eq(step.rg_pattern, '(?i)@STEP:[a-z][a-z0-9_-]*-\\d+\\b', 'step rg_pattern')
  assert_eq(step.kind, 'step', 'step kind')
end)

test('step 规则：ignore_case=false 时区分大小写', function()
  local step = find(Rules.build(base_cfg({
    step = { enable = true, keyword = 'STEP', ignore_case = false },
  })), 'step')
  assert_eq(step.vim_regex, '\\C@STEP:[a-z][a-z0-9_-]*-\\d\\+\\>', 'case-sensitive vim_regex')
  assert_eq(step.rg_pattern, '@STEP:[a-z][a-z0-9_-]*-\\d+\\b', 'case-sensitive rg_pattern')
end)

test('step.enable=false 时不生成', function()
  local rules = Rules.build(base_cfg({ step = { enable = false } }))
  assert_eq(find(rules, 'step'), nil, 'step disabled')
end)

test('关键字规则：大小写不敏感（vim \\c，rg (?i)，词尾 \\> / \\b）', function()
  local t = find(Rules.build(base_cfg()), 'todo')
  assert_eq(t.vim_regex, '\\c@TODO\\>', 'todo vim_regex')
  assert_eq(t.rg_pattern, '(?i)@TODO\\b', 'todo rg_pattern')
  assert_eq(t.hl, 'VVFlowKwTODO', 'todo hl name')
  assert_eq(t.label, '@TODO', 'todo label')
end)

test('关键字规则：ignore_case=false 时区分大小写（\\C，无 (?i)）', function()
  local t = find(Rules.build(base_cfg({ ignore_case = false })), 'todo')
  assert_eq(t.vim_regex, '\\C@TODO\\>', 'todo vim_regex (case-sensitive)')
  assert_eq(t.rg_pattern, '@TODO\\b', 'todo rg_pattern (case-sensitive)')
end)

print('\n[rules] custom 透传')

test('custom 规则按提供的 vim/rg 正则与 name 透传', function()
  local rules = Rules.build(base_cfg({ custom = {
    { name = 'ticket', vim_regex = '@JIRA-\\d\\+', rg_pattern = '@JIRA-\\d+', kind = 'custom', color = '#7dcfff' },
  } }))
  local c = find(rules, 'ticket')
  assert(c, 'ticket 规则存在')
  assert_eq(c.vim_regex, '@JIRA-\\d\\+', 'ticket vim_regex')
  assert_eq(c.rg_pattern, '@JIRA-\\d+', 'ticket rg_pattern')
  assert_eq(c.kind, 'custom', 'ticket kind')
end)

test('custom 规则缺少必填字段时被忽略', function()
  local rules = Rules.build(base_cfg({ custom = { { name = 'bad' } } }))  -- 无 vim/rg
  assert_eq(find(rules, 'bad'), nil, '不完整 custom 被跳过')
end)

print('\n[rules] hl_specs')

test('hl_specs 为带颜色的规则生成高亮 spec', function()
  local rules = Rules.build(base_cfg())
  local specs = Rules.hl_specs(rules)
  assert(specs.VVFlowKwTODO, 'TODO 高亮组存在')
  assert_eq(specs.VVFlowKwTODO.fg, '#7aa2f7', 'TODO fg')
  assert_eq(specs.VVFlowKwTODO.bold, true, 'TODO bold')
  assert(specs.VVFlowStep, 'step 高亮组存在')
end)

test('自定义前缀生效（prefix=//）', function()
  local step = find(Rules.build(base_cfg({ prefix = '//' })), 'step')
  assert_eq(step.vim_regex, '\\c//STEP:[a-z][a-z0-9_-]*-\\d\\+\\>', 'custom prefix vim_regex')
  assert_eq(step.rg_pattern, '(?i)//STEP:[a-z][a-z0-9_-]*-\\d+\\b', 'custom prefix rg_pattern')
end)

print(string.format('\n总计: %d passed, %d failed', passed, failed))
if failed > 0 then
  print('有测试未通过！')
  os.exit(1)
end
