" Vim syntax file
" Language:   txtjp
" Maintainer: NONE
" Fienames:   *.txt
" Version:    1.0
" Repository: NONE
" Note:       日本語テキストの色付
"             *.txtを全てtxtjpハイライトににする場合.vimrcに以下を設定
"             au BufRead,BufNewFile *.txt setfiletype txtjp
"             モードラインでセットする場合ファイル先頭か最終行付近に以下を記述
"             vim:ft=txtjp
" LICENSE:    MIT

if exists("b:current_syntax")
  finish
endif

" 鉤括弧文字列はハイライト
syn match   txtString /『.\{-}』/
syn match   txtString /「.\{-}」/
hi def link txtString String

"丸括弧文字列はコメントハイライト
syn match   txtConstant /（.\{-}）/
syn match   txtConstant /(.\{-})/
hi def link txtConstant Comment

"半角数字はハイライト
syn match   txtInteger /\d/
hi def link txtInteger Number

"カタカナと半角英字はハイライト
syn match   txtLabel /[ァ-ヴ]/
syn match   txtLabel /ー/
syn match   txtLabel /☆/
syn match   txtLabel /\a/
hi def link txtLabel Label

"適当な短めの文字数の行はタイトルハイライト
syn match txtTitle /^.\{,40}$/
hi def link txtTitle Title

"句読点はハイライト
syn match   txtKeyword /、/
syn match   txtKeyword /。/
hi def link txtKeyword Keyword

let b:current_syntax = "txtjp"
