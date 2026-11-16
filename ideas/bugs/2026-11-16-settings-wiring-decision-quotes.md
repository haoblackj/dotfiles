# settings-wiring.bats の guard-decision-quotes.py の配線のテストが落ちる

## 見えたこと

issue #91 の作業で全部の bats を走らせたら、`dot_claude/hooks/settings-wiring.bats` の「guard-decision-quotes.py が PreToolUse の Bash に配線されている」が `AssertionError: PreToolUse: []` で落ちた。
`linked/claude/settings.json` には、HEAD（364159b）でも本チェックアウトの作業コピーでも `decision-quotes` の文字列が無かった。

## 見つけた場所

`dot_claude/hooks/settings-wiring.bats` の 145 行目あたり、`linked/claude/settings.json`
