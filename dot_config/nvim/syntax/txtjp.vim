" Vim syntax file
" Language:   txtjp
" Maintainer: NONE
" Filenames:   *.txt
" Version:    1.0
" Repository: NONE
" Note:       日本語テキストの色付け
"             *.txtを全てtxtjpハイライトにする場合.vimrcに以下を設定
"             au BufRead,BufNewFile *.txt setfiletype txtjp
"             モードラインでセットする場合ファイル先頭か最終行付近に以下を記述
"             vim:ft=txtjp
" LICENSE:    MIT

if exists("b:current_syntax")
  finish
endif

" 再帰的括弧のハイライト。最大10レベルまでサポート。
function! SynBrackets(max_depth)
  let depth = a:max_depth
  while depth > 0
    execute 'syn region txtBracketL'.depth.' start=+「+ end=+」+ contains='. (depth > 1 ? 'txtBracketL'.(depth-1) : 'txtBracketL1')
    execute 'syn region txtBracketM'.depth.' start=+『+ end=+』+ contains='. (depth > 1 ? 'txtBracketM'.(depth-1) : 'txtBracketM1')
    execute 'syn region txtBracketS'.depth.' start=+（+ end=+）+ contains='. (depth > 1 ? 'txtBracketS'.(depth-1) : 'txtBracketS1')
    execute 'syn region txtBracketA'.depth.' start=+(+ end=+)+ contains='. (depth > 1 ? 'txtBracketA'.(depth-1) : 'txtBracketA1')
    let depth -= 1
  endwhile
endfunction
call SynBrackets(10)

" 各レベルの括弧ごとに異なるハイライトを設定（オプショナル）
for i in range(1, 10)
  execute 'hi def link txtBracketL'.i 'String'
  execute 'hi def link txtBracketM'.i 'Special'
  execute 'hi def link txtBracketS'.i 'PreProc'
  execute 'hi def link txtBracketA'.i 'Type'
endfor

" 半角数字はハイライト
syn match   txtInteger /\d\+/
hi def link txtInteger Number

" カタカナと半角英字はハイライト
syn match   txtLabel /[ァ-ヴ]/
syn match   txtLabel /ー/
syn match   txtLabel /☆/
syn match   txtLabel /\a/
hi def link txtLabel Label

" 適当な短めの文字数の行はタイトルハイライト
syn match txtTitle /^.\{,40}$/
hi def link txtTitle Title

" 句読点はハイライト
syn match   txtKeyword /、/
syn match   txtKeyword /。/
hi def link txtKeyword Keyword

let b:current_syntax = "txtjp"