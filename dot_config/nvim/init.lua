-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

-- Make sure to setup `mapleader` and `maplocalleader` before
-- loading lazy.nvim so that mappings are correct.
-- This is also a good place to setup other settings (vim.opt)
vim.g.mapleader = "\\"
vim.g.maplocalleader = "\\"

-- Setup lazy.nvim
require("lazy").setup({
  spec = {
    -- add your plugins here
    {
      { import = "plugins" }
    }
  },
  -- Configure any other settings here. See the documentation for more details.
  -- colorscheme that will be used when installing plugins.
  install = { colorscheme = { "horizon" } },
  -- automatically check for plugin updates
  checker = { enabled = true },


})

-- Configure keymapping
  require('keymaps')

-- Configure spzenhan(IMEoff)
  require('spzenhan').setup()

-- Disable netrw for nvim-tree
  vim.api.nvim_set_var('loaded_netrw', 1)
  vim.api.nvim_set_var('loaded_netrwPlugin', 1)

  -- 表示設定
  vim.opt.number = true  -- 行番号を表示
  vim.wo.number = true
  vim.wo.relativenumber = false  -- 相対行番号を無効化

  -- クリップボード関連
  vim.g.clipboard = {
    name = 'WslClipboard',
    copy = {
        ['+'] = 'xsel -bi',
        ['*'] = 'xsel -bi',
    },
    paste = {
        ['+'] = 'xsel -bo',
        ['*'] = function() return vim.fn.systemlist('xsel -bo | tr -d "\r"') end,
    },
    cache_enabled = 1,
}