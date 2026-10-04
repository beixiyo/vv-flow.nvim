local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T["step + 关键字规则都生成，step 在最前；step 规则默认大小写不敏感，且要求命名空间与末尾数字；step 规则在 ignore_case=false 时区分大小写；step.enable=false 时不生成；关键字规则默认大小写不敏感且遵守词尾；关键字规则在 ignore_case=false 时区分大小写"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local Rules = F.Rules
    local assert_eq = F.assert_eq
    local find = F.find
    local matches = F.matches
    local base_cfg = F.base_cfg
      local rules = Rules.build(base_cfg())
      assert_eq(rules[1].name, 'step', '第一条应为 step 规则')
      assert(find(rules, 'todo'), 'todo 规则存在')
      assert(find(rules, 'bug'), 'bug 规则存在')
      local step = find(Rules.build(base_cfg()), 'step')
      assert(matches(step, '@step:checkout-17'), '小写命名空间步骤必须匹配')
      assert(not matches(step, '@STEP:checkout-x'), '缺少数字后缀的步骤不得匹配')
      local step = find(Rules.build(base_cfg({
        step = { enable = true, keyword = 'STEP', ignore_case = false },
      })), 'step')
      assert(matches(step, '@STEP:checkout-17'), '大写步骤必须匹配')
      assert(not matches(step, '@step:checkout-17'), '小写步骤不得匹配')
      local rules = Rules.build(base_cfg({ step = { enable = false } }))
      assert_eq(find(rules, 'step'), nil, '步骤禁用时不得生成规则')
      local t = find(Rules.build(base_cfg()), 'todo')
      assert(matches(t, '@todo'), '小写关键字必须匹配')
      assert(not matches(t, '@TODOmore'), '关键字前缀不得匹配更长单词')
      local t = find(Rules.build(base_cfg({ ignore_case = false })), 'todo')
      assert(matches(t, '@TODO'), '大写关键字必须匹配')
      assert(not matches(t, '@todo'), '小写关键字不得匹配')
  end)
end

T["custom 规则使用提供的 Vim 正则匹配；custom 规则缺少必填字段时被忽略"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local Rules = F.Rules
    local assert_eq = F.assert_eq
    local find = F.find
    local matches = F.matches
    local base_cfg = F.base_cfg
      local rules = Rules.build(base_cfg({ custom = {
        { name = 'ticket', vim_regex = '@JIRA-\\d\\+', rg_pattern = '@JIRA-\\d+', kind = 'custom', color = '#7dcfff' },
      } }))
      local c = find(rules, 'ticket')
      assert(c, 'ticket 规则存在')
      assert(matches(c, '@JIRA-123'), '自定义编号规则必须匹配数字')
      assert(not matches(c, '@JIRA-abc'), '自定义编号规则必须拒绝非数字')
      local rules = Rules.build(base_cfg({ custom = { { name = 'bad' } } }))  -- 无 vim/rg
      assert_eq(find(rules, 'bad'), nil, '不完整 custom 被跳过')
  end)
end

T["hl_specs 为带颜色的规则生成高亮 spec；自定义前缀生效（prefix=//）"] = function()
  child.lua_func(function()
    local F = dofile(vim.env.VV_TEST_REPO .. '/tests/fixtures/smoke.lua')()
    local Rules = F.Rules
    local assert_eq = F.assert_eq
    local find = F.find
    local matches = F.matches
    local base_cfg = F.base_cfg
      local rules = Rules.build(base_cfg())
      local specs = Rules.hl_specs(rules)
      assert(specs.VVFlowKwTODO, 'TODO 高亮组存在')
      assert_eq(specs.VVFlowKwTODO.fg, '#7aa2f7', 'TODO 前景色必须正确')
      assert_eq(specs.VVFlowKwTODO.bold, true, 'TODO 必须加粗')
      assert(specs.VVFlowStep, 'step 高亮组存在')
      local step = find(Rules.build(base_cfg({ prefix = '//' })), 'step')
      assert(matches(step, '//STEP:checkout-17'), '自定义前缀步骤必须匹配')
      assert(not matches(step, '@STEP:checkout-17'), '默认前缀不得匹配')
  end)
end

return T
