# 实际扫描用例需要调用方已安装 ripgrep
command -v rg >/dev/null 2>&1 || {
  printf 'Flow integration tests require ripgrep (rg).\n' >&2
  exit 1
}
# 保留可选集成覆盖项；非空但无效的值必须报错
if [ -n "${VV_ICONS:-}" ]; then
  vv_test_dependency VV_ICONS vv-icons.nvim lua/vv-icons/init.lua
fi
if [ -n "${VV_BUFFERLINE:-}" ]; then
  vv_test_dependency VV_BUFFERLINE vv-bufferline.nvim lua/vv-bufferline/init.lua
fi
