-- 场景运行时初始化夹具；不参与 mini.test 收集。
return function()
  -- vv-flow.nvim 冒烟测试
  --
  --
  -- 覆盖 rules.build 生成的规则能被 Vim 正则实际匹配：内置 step / 关键字规则的
  -- 大小写敏感、custom 透传、hl_specs。
  -- 实时高亮 / 扫描 / 面板 / 预览等依赖 nvim API 的运行时行为见仓库 README 的 headless 验证。

  -- 把插件 lua/ 加入 package.path（相对本脚本定位）

  local Rules = require('vv-flow.rules')


  local function assert_eq(actual, expected, msg)
    if actual ~= expected then
      error(string.format('%s：期望 %q，实际 %q', msg or 'assert_eq', tostring(expected), tostring(actual)))
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
  return { Rules = Rules, assert_eq = assert_eq, find = find, matches = matches, base_cfg = base_cfg }
end
