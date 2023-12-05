local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- Neovimのleaderキーを設定する（lazy.nvimを実行する前に設定する必要があります）
vim.g.mapleader = " "

-- lazy.nvimを使ってNeovimのプラグインを管理する
require("lazy").setup({
  "vim-denops/denops.vim",
  "lambdalisue/kensaku.vim",
  "lambdalisue/kensaku-search.vim",
  "yuki-yano/fuzzy-motion.vim",
  "vim-airline/vim-airline",
  "vim-airline/vim-airline-themes",
  "tomasiser/vim-code-dark",
  "kdheepak/lazygit.nvim",
  "kihachi2000/yash.nvim",
  'lambdalisue/nerdfont.vim',
  'nvim-tree/nvim-tree.lua',
  'nvim-tree/nvim-web-devicons',
})

require("nvim-tree").setup()