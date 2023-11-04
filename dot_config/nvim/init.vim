" vim-plug なかったら落としてくる
if empty(glob('$HOME/.local/share/nvim/site/autoload/plug.vim'))
  silent !curl -fLo $HOME/.local/share/nvim/site/autoload/plug.vim --create-dirs
    \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  autocmd VimEnter * PlugInstall --sync | source $MYVIMRC
endif

" 足りないプラグインがあれば :PlugInstall を実行
autocmd VimEnter * if len(filter(values(g:plugs), '!isdirectory(v:val.dir)'))
  \| PlugInstall --sync | source $MYVIMRC
\| endif

"deno Path
let g:denops#deno = $HOME . '/.deno/bin/deno'

call plug#begin('$HOME/.local/share/nvim/plugged')
 Plug 'vim-denops/denops.vim'
 Plug 'lambdalisue/kensaku.vim'
 Plug 'echasnovski/mini.nvim'
 Plug 'lambdalisue/kensaku-search.vim'
 Plug 'yuki-yano/fuzzy-motion.vim'
call plug#end()




" バックアップファイルを作らない
set nobackup

" スワップファイルを作らない
 set noswapfile

"インデント可視化
set list
set listchars=tab:»-,trail:-,eol:↲,extends:»,precedes:«,nbsp:%

" エンコーディング
set encoding=utf-8
scriptencoding utf-8

"jキーを二度押しでESCキー
inoremap <silent> jj <Esc>
inoremap <silent> っj <ESC>

"help日本語化
set helplang=ja

" spzenhan.exe のパスを指定
let g:spzenhan#executable = '/mnt/c/WorkTmp/spzenhan.vim/zenhan/spzenhan.exe'

" グローバル変数を定義して、直前のインサートモードでのIMEの状態を追跡します
let g:previous_ime_state = 0

" インサートモードに入るたびに、直前のIMEの状態を復元します
autocmd InsertEnter * call system(g:spzenhan#executable . ' ' . g:previous_ime_state)

" インサートモードを離れるたびに、現在のIMEの状態を保存し、IMEを無効にします
autocmd InsertLeave * let g:previous_ime_state = system(g:spzenhan#executable . ' --get')[:-2] | call system(g:spzenhan#executable . ' 0')



"行番号を表示
set number

" 挿入モードでバックスペースで削除できるようにする
set backspace=indent,eol,start

" 自動でカッコ等を閉じる
inoremap { {}<LEFT>
inoremap [ []<LEFT>
inoremap ( ()<LEFT>
inoremap " ""<LEFT>
inoremap ' ''<LEFT>
inoremap 「 「」<LEFT>
inoremap 『 『』<LEFT>
inoremap 〈 〈〉<LEFT>
inoremap 《 《》<LEFT>

"棒状カーソル"
let &t_SI = "\<Esc>]50;CursorShape=1\x7"
let &t_EI = "\<Esc>]50;CursorShape=0\x7"
inoremap <Esc> <Esc>lh

" ヤンクするとクリップボードに保存される
set clipboard+=unnamedplus
let g:clipboard = {
  \   'name': 'win32yank-wsl',
  \   'copy': {
  \      '+': 'win32yank -i --crlf',
  \      '*': 'win32yank -i --crlf',
  \    },
  \   'paste': {
  \      '+': 'win32yank -o --lf',
  \      '*': 'win32yank -o --lf',
  \   },
  \   'cache_enabled': 0,
  \ }

" 以下のコードはコマンドラインモードでEnterキーが押されたときに、
" kensakuプラグインの検索と置換の機能を実行するように設定します。
cnoremap <CR> <Plug>(kensaku-search-replace)<CR>

" 以下のコードはノーマルモードでSキーが押されたときに、
" FuzzyMotionコマンドを実行するように設定します。
nnoremap S :FuzzyMotion<CR>

" 以下のコードはfuzzy_motionプラグインのマッチャーとしてkensakuとfzfを設定します。
let g:fuzzy_motion_matchers = ['kensaku', 'fzf']
