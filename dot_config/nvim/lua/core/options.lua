local set = vim.opt

-- エンコーディング
set.encoding = 'utf-8'

-- バックアップとスワップを無効化
set.backup = false
set.swapfile = false

-- インデント関連
set.autoindent = true
set.smartindent = true

-- 括弧表示
set.showmatch = true

-- ステータスライン
set.laststatus = 2

-- タブとスペース
set.expandtab = true
set.tabstop = 4
set.shiftwidth = 4

-- 検索オプション
set.ignorecase = true
set.smartcase = true
set.wrapscan = true
set.hlsearch = true

-- ビジュアルベル無効化
set.visualbell = false
set.errorbells = false
vim.cmd('set t_vb=')

-- シンタックスハイライト
vim.cmd('syntax on')
