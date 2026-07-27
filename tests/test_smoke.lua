-- vv-flow.nvim 冒烟测试
--
-- 运行方式：nvim --headless -u NONE -l tests/test_smoke.lua
--
-- 覆盖 rules.build 生成的规则能被 Vim 正则实际匹配：内置 step / 关键字规则的
-- 大小写敏感、custom 透传、hl_specs。
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

local function matches(rule, text)
  return vim.regex(rule.vim_regex):match_str(text) ~= nil
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

test('step 规则默认大小写不敏感，且要求命名空间与末尾数字', function()
  local step = find(Rules.build(base_cfg()), 'step')
  assert(matches(step, '@step:checkout-17'), 'lowercase namespaced step should match')
  assert(not matches(step, '@STEP:checkout-x'), 'step without a numeric suffix should not match')
end)

test('step 规则在 ignore_case=false 时区分大小写', function()
  local step = find(Rules.build(base_cfg({
    step = { enable = true, keyword = 'STEP', ignore_case = false },
  })), 'step')
  assert(matches(step, '@STEP:checkout-17'), 'uppercase step should match')
  assert(not matches(step, '@step:checkout-17'), 'lowercase step should not match')
end)

test('step.enable=false 时不生成', function()
  local rules = Rules.build(base_cfg({ step = { enable = false } }))
  assert_eq(find(rules, 'step'), nil, 'step disabled')
end)

test('关键字规则默认大小写不敏感且遵守词尾', function()
  local t = find(Rules.build(base_cfg()), 'todo')
  assert(matches(t, '@todo'), 'lowercase keyword should match')
  assert(not matches(t, '@TODOmore'), 'keyword prefix should not match a longer word')
end)

test('关键字规则在 ignore_case=false 时区分大小写', function()
  local t = find(Rules.build(base_cfg({ ignore_case = false })), 'todo')
  assert(matches(t, '@TODO'), 'uppercase keyword should match')
  assert(not matches(t, '@todo'), 'lowercase keyword should not match')
end)

print('\n[rules] custom 透传')

test('custom 规则使用提供的 Vim 正则匹配', function()
  local rules = Rules.build(base_cfg({ custom = {
    { name = 'ticket', vim_regex = '@JIRA-\\d\\+', rg_pattern = '@JIRA-\\d+', kind = 'custom', color = '#7dcfff' },
  } }))
  local c = find(rules, 'ticket')
  assert(c, 'ticket 规则存在')
  assert(matches(c, '@JIRA-123'), 'custom ticket should match digits')
  assert(not matches(c, '@JIRA-abc'), 'custom ticket should reject non-digits')
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
  assert(matches(step, '//STEP:checkout-17'), 'custom prefix step should match')
  assert(not matches(step, '@STEP:checkout-17'), 'default prefix should not match')
end)

print(string.format('\n总计: %d passed, %d failed', passed, failed))
if failed > 0 then
  print('有测试未通过！')
  os.exit(1)
end
