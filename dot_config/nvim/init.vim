"neovim + vim
let s:jetpackfile = stdpath('data') .. '/site/pack/jetpack/opt/vim-jetpack/plugin/jetpack.vim'
let s:jetpackurl = "https://raw.githubusercontent.com/tani/vim-jetpack/master/plugin/jetpack.vim"
if !filereadable(s:jetpackfile)
  call system(printf('curl -fsSLo %s --create-dirs %s', s:jetpackfile, s:jetpackurl))
endif

" vim-jetpack
packadd vim-jetpack

for name in jetpack#names()
  if !jetpack#tap(name)
    call jetpack#sync()
    break
  endif
endfor

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

"IME有効化
set iminsert=1
set imsearch=-1

"挿入モードを抜ける時にIMEをオフにする設定"
if executable('zenhan')
  autocmd InsertLeave * :call system('zenhan 0')
  autocmd CmdlineLeave * :call system('zenhan 0')
endif

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

"deno Path
let g:denops#deno = $HOME . '/.deno/bin/deno'

call jetpack#begin()
 " bootstrap
 Jetpack 'tani/vim-jetpack', { 'opt': 1 }
 Jetpack 'junegunn/goyo.vim'
 Jetpack 'junegunn/limelight.vim'
 Jetpack 'vim-denops/denops.vim'
 Jetpack 'lambdalisue/kensaku.vim'
 Jetpack 'echasnovski/mini.nvim'
 Jetpack 'lambdalisue/kensaku-search.vim'
call jetpack#end()
