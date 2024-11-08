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
  -- install = { colorscheme = { "horizon-extended" } },
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

-- Configure colorscheme
  require("horizon-extended").setup({
  	style = "neo",
  	transparent = true,
  	terminal_colors = true,
  	enable_italics = true,
  	show_end_of_buffer = false,
  	underline = false,
  	undercurl = true,
  	styles = {
  		booleans = { italic = true, bold = true },
  		comments = { italic = true, bold = false },
  		conditionals = { italic = true, bold = false },
  		delimiters = { italic = false, bold = false },
  		functions = { italic = false, bold = false },
  		keywords = { italic = true, bold = false },
  		loops = { italic = true, bold = false },
  		operators = { italic = false, bold = false },
  		properties = { italic = false, bold = false },
  		strings = { italic = false, bold = false },
  		types = { italic = false, bold = false },
  		variables = { italic = false, bold = false },
  	},
  })

  vim.cmd.colorscheme "horizon-extended"



  -- Configure Clipboard
  if vim.fn.has("wsl") == 1 then
    if vim.fn.executable("wl-copy") == 0 then
      print("wl-clipboard not found, clipboard integration won't work")
    else
      vim.g.clipboard = {
        name = "wl-clipboard (wsl)",
        copy = {
          ["+"] = 'wl-copy --foreground --type text/plain',
          ["*"] = 'wl-copy --foreground --primary --type text/plain',
            },
            paste = {
              ["+"] = (function()
                return vim.fn.systemlist('wl-paste --no-newline|sed -e "s/\r$//"', {''}, 1) -- '1' keeps empty lines
              end),
              ["*"] = (function()
                return vim.fn.systemlist('wl-paste --primary --no-newline|sed -e "s/\r$//"', {''}, 1)
              end),
            },
            cache_enabled = true
          }
        end
      end

-- Configure Novel-Mode
  require('custom_highlights').setup()
  vim.opt.termguicolors = true
  -- vim.notify("Custom highlights applied at the end of init.lua")
