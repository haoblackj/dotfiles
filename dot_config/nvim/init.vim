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

"deno Path
let g:denops#deno = $HOME . '/.deno/bin/deno'

call jetpack#begin()
 Jetpack 'tani/vim-jetpack', { 'opt': 1 } "bootstrap
 Jetpack 'junegunn/goyo.vim'
 Jetpack 'junegunn/limelight.vim'
 Jetpack 'vim-denops/denops.vim'
 Jetpack 'lambdalisue/kensaku.vim'
 Jetpack 'echasnovski/mini.nvim'
 Jetpack 'lambdalisue/kensaku-search.vim'
 Jetpack 'yuki-yano/fuzzy-motion.vim'
call jetpack#end()




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
