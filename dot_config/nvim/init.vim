" vim-plug なかったら落としてくる
if empty(glob('$HOME/.local/share/nvim/site/autoload/plug.vim'))
  silent !curl -fLo $HOME/.local/share/nvim/site/autoload/plug.vim --create-dirs
    \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
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
  Plug 'vim-airline/vim-airline'
  Plug 'vim-airline/vim-airline-themes'
  Plug 'tomasiser/vim-code-dark'
  Plug 'lambdalisue/fern.vim'
  Plug 'lambdalisue/fern-git-status.vim'
  Plug 'lambdalisue/nerdfont.vim'
  Plug 'lambdalisue/fern-renderer-nerdfont.vim'
  Plug 'lambdalisue/glyph-palette.vim'
  Plug 'airblade/vim-gitgutter'
  Plug 'kdheepak/lazygit.nvim'
call plug#end()

"leaderキーを設定
let mapleader = " "


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

"以下のコードは検索でEnterを押下したときに、
"英数字入力で日本語を検索できるようにするためのもの
cnoremap <CR> <Plug>(kensaku-search-replace)<CR>

"以下のコードは、「S」を押すと、画面内の文字列に英数字入力で
"fuzzymotionできるようにするためのもの
nnoremap S :FuzzyMotion<CR>
let g:fuzzy_motion_matchers = ['kensaku', 'fzf']

"論理行と表示行移動をスワップしました
"vscodeでは読み込みません
if !exists('g:vscode')
  nnoremap k gk
  nnoremap gk k
  nnoremap j gj
  nnoremap gj j
  nnoremap 0 g0
  nnoremap g0 0
  nnoremap ^ g^
  nnoremap g^ ^
  nnoremap $ g$
  nnoremap g$ $
  inoremap <Down> <C-o>gj
  inoremap <Up>   <C-o>gk
endif

"vim-airline
let g:airline#extensions#tabline#enabled = 1
" ステータスラインに表示する項目を変更する
let g:airline#extensions#default#layout = [
  \ [ 'a', 'b', 'c' ],
  \ ['z']
  \ ]
let g:airline_section_c = '%t %M'
let g:airline_section_z = get(g:, 'airline_linecolumn_prefix', '').'%3l:%-2v'
" 変更がなければdiffの行数を表示しない
let g:airline#extensions#hunks#non_zero_only = 1

" タブラインの表示を変更する
let g:airline#extensions#tabline#fnamemod = ':t'
let g:airline#extensions#tabline#show_buffers = 1
let g:airline#extensions#tabline#show_splits = 0
let g:airline#extensions#tabline#show_tabs = 1
let g:airline#extensions#tabline#show_tab_nr = 0
let g:airline#extensions#tabline#show_tab_type = 1
let g:airline#extensions#tabline#show_close_button = 0

"カラーテーマ
colorscheme codedark
let g:airline_theme = 'codedark'

" Ctrl+nでファイルツリーを表示/非表示する
nnoremap <C-n> :Fern . -reveal=% -drawer -toggle -width=40<CR>

" アイコンを表示する
let g:fern#renderer = 'nerdfont'

" アイコンに色をつける
augroup my-glyph-palette
  autocmd! *
  autocmd FileType fern call glyph_palette#apply()
  autocmd FileType nerdtree,startify call glyph_palette#apply()
augroup END

"lazygitを呼び出すキーマップ
nnoremap <silent> <leader>gg :LazyGit<CR>

"シンタックスハイライトを有効にするための箇所
filetype plugin indent on

"シンタックスハイライト強制設定
au BufRead,BufNewFile *.txt set filetype=txtjp

"Terminalのインサートモードからの離脱をescキーにマッピング
:tnoremap <Esc> <C-\><C-n>

"TerminalをVSCodeのように現在のウィンドウの下に開く
command! -nargs=* T split | wincmd j | resize 8 | terminal <args>

"常にインサートモードでTerminalを開く
autocmd TermOpen * startinsert
