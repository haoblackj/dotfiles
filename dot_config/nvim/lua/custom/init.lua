-- Desc: 基本的な設定を行う

-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

vim.cmd("autocmd!")

-- encoding
vim.o.encoding = 'utf-8'
vim.o.scriptencoding = 'utf-8'

-- visual
-- vim.o.ambiwidth = 'double'
vim.o.tabstop = 2
vim.o.softtabstop = 2
vim.o.shiftwidth = 2
vim.o.expandtab = true
vim.o.autoindent = true
vim.o.smartindent = true

vim.o.visualbell = true
vim.o.number = true
vim.o.showmatch = true
vim.o.matchtime = 1

vim.wo.number = true

-- search
vim.o.incsearch = true
vim.o.ignorecase = true
vim.o.smartcase = true
vim.o.hlsearch = true
vim.keymap.set('n', '<Esc><Esc>', ':nohl<CR>', { noremap = true, silent = true})

-- manipulation
vim.g.mapleader = ' '
vim.o.ttimeout = true
vim.o.ttimeoutlen = 50

vim.o.undofile = true
vim.o.undodir = vim.fn.stdpath('cache') .. '/undo'

-- disable netrw at the very start of your init.lua
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- txtjpの設定
vim.api.nvim_create_autocmd({"BufRead", "BufNewFile"}, {
    pattern = "*.txt",
    command = "set filetype=txtjp",
  })

-- disable netrw at the very start of your init.lua
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- set termguicolors to enable highlight groups
vim.opt.termguicolors = true

-- empty setup using defaults
-- require("nvim-tree").setup()

-- OR setup with some options
-- require("nvim-tree").setup({
--   sort = {
--     sorter = "case_sensitive",
--   },
--   view = {
--     width = 30,
--   },
--   renderer = {
--     group_empty = true,
--   },
--   filters = {
--     dotfiles = true,
--   },
-- })

--kensaku-search
vim.keymap.set('c', '<CR>', '<Plug>(kensaku-search-replace)<CR>')

--furzy-motion
vim.keymap.set('n', 'S', '<cmd>FuzzyMotion<CR>')
vim.cmd("let g:fuzzy_motion_matchers = ['kensaku', 'fzf']")

-- Clipboard settings for WSL
vim.opt.clipboard = "unnamedplus"
if vim.fn.has("wsl") == 1 then
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
end

-- spzenhan.exe のパスを指定
vim.g.spzenhan_executable = '/mnt/c/WorkTmp/spzenhan.vim/zenhan/spzenhan.exe'

-- グローバル変数を追跡するための初期化
vim.g.previous_ime_state = 0

-- インサートモードに入るたび、直前のIMEの状態を復元
vim.api.nvim_create_autocmd("InsertEnter", {
    pattern = "*",
    callback = function()
        vim.fn.system(vim.g.spzenhan_executable .. ' ' .. vim.g.previous_ime_state)
    end
})

-- インサートモードを離れるたび、IMEの状態を保存し無効化
vim.api.nvim_create_autocmd("InsertLeave", {
    pattern = "*",
    callback = function()
        vim.g.previous_ime_state = vim.fn.system(vim.g.spzenhan_executable .. ' --get'):gsub("\n", "")
        vim.fn.system(vim.g.spzenhan_executable .. ' 0')
    end
})

-- .txt ファイルの折り返しを有効にする
vim.api.nvim_create_autocmd("FileType", {
    pattern = "txtjp",
    callback = function()
        vim.opt_local.wrap = true
    end
})