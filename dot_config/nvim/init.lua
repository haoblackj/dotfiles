-- Neovimの主要設定
-- ここには他の一般的な設定やキーマッピングなどを追加できます

-- package.pathにpluginsフォルダのパスを追加する
local user_plugins_path = vim.fn.stdpath('config') .. '/plugins/?.lua'
package.path = package.path .. ';' .. user_plugins_path

-- pluginsフォルダをruntimepathに追加する
vim.opt.runtimepath:append(vim.fn.stdpath('config') .. '/plugins')

-- pluginsフォルダ内のsetup_plugin.luaをrequireする
-- 相対パスは 'plugins.setup_plugin' となる（Luaではドットを使って階層を表現します）
require('setup_plugin')

-- 他の設定や機能をここに追加することができます
-- 例: require('some_other_config')

-- denoのパス設定
vim.g['denops#deno'] = vim.fn.expand('$HOME') .. '/.deno/bin/deno'

-- leaderキーの設定
vim.g.mapleader = " "

-- バックアップファイルとスワップファイルを作らない設定
vim.opt.backup = false
vim.opt.swapfile = false

-- インデント可視化設定
vim.opt.list = true
vim.opt.listchars = 'tab:»-,trail:-,eol:↲,extends:»,precedes:«,nbsp:%'

-- エンコーディング設定
vim.opt.encoding = 'utf-8'
vim.scriptencoding('utf-8')

-- jキーを二度押しでESCキーとして機能するようにする
vim.api.nvim_set_keymap('i', 'jj', '<Esc>', {silent = true})
vim.api.nvim_set_keymap('i', 'っj', '<ESC>', {silent = true})

-- ヘルプを日本語化
vim.opt.helplang = 'ja'

-- spzenhan.exe のパスを指定
vim.g.spzenhan_executable = '/mnt/c/WorkTmp/spzenhan.vim/zenhan/spzenhan.exe'

-- インサートモードに入るたびに、直前のIMEの状態を復元する
vim.api.nvim_create_autocmd('InsertEnter', {
    pattern = '*',
    command = 'call system(g:spzenhan_executable . " " . g:previous_ime_state)'
})

-- インサートモードを離れるたびに、現在のIMEの状態を保存し、IMEを無効にする
vim.api.nvim_create_autocmd('InsertLeave', {
    pattern = '*',
    command = 'let g:previous_ime_state = system(g:spzenhan_executable . " --get")[:-2] | call system(g:spzenhan_executable . " 0")'
})

-- 行番号の表示
vim.opt.number = true

-- 挿入モードでバックスペースキーの設定
vim.opt.backspace = {'indent', 'eol', 'start'}

-- 自動でカッコ等を閉じる設定
vim.api.nvim_set_keymap('i', '{', '{}<LEFT>', {})
vim.api.nvim_set_keymap('i', '[', '[]<LEFT>', {})
vim.api.nvim_set_keymap('i', '(', '()<LEFT>', {})
vim.api.nvim_set_keymap('i', '"', '""<LEFT>', {})
vim.api.nvim_set_keymap('i', "'", "''<LEFT>", {})
vim.api.nvim_set_keymap('i', '「', '「」<LEFT>', {})
vim.api.nvim_set_keymap('i', '『', '『』<LEFT>', {})
vim.api.nvim_set_keymap('i', '〈', '〈〉<LEFT>', {})
vim.api.nvim_set_keymap('i', '《', '《》<LEFT>', {})

-- 棒状カーソルの設定
vim.g.t_SI = "\\<Esc>]50;CursorShape=1\\x7"
vim.g.t_EI = "\\<Esc>]50;CursorShape=0\\x7"
vim.api.nvim_set_keymap('i', '<Esc>', '<Esc>lh', {})

-- ヤンクするとクリップボードに保存される設定
vim.opt.clipboard:append('unnamedplus')

-- カラーテーマの設定
vim.cmd('colorscheme codedark')

-- Ctrl+nでファイルツリーを表示/非表示するキーマップ
vim.api.nvim_set_keymap('n', '<C-n>', ':Fern . -reveal=% -drawer -toggle -width=40<CR>', {})

-- シンタックスハイライトを有効にする設定
vim.cmd('filetype plugin indent on')

-- シンタックスハイライト強制設定
vim.api.nvim_create_autocmd({'BufRead', 'BufNewFile'}, {
    pattern = '*.txt',
    command = 'set filetype=txtjp'
})

-- Terminalのインサートモードからの離脱をescキーにマッピング
vim.api.nvim_set_keymap('t', '<Esc>', '<C-\\><C-n>', {})