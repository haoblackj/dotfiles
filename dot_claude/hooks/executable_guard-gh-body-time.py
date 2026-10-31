#!/usr/bin/env python3
# GitHub の本文に、時計を見ずに推測した時刻を書く事故を防ぐ PreToolUse フック。
# 規約だけでは防げなかったため、手書きの時刻を検出して止める（dotfiles#75）。
#
# 判定の方針:
#   - シェルのコマンド境界から gh の書き込みを探す。引用中の言及は通す。
#   - 対象があればコマンド全体と入力ファイルの先頭 1 MB を検査する。
#   - 全角を正規化し、Markdown のコードを除いて数字の時刻を探す。
#     $(date ...) などシェルが計算する時刻には数字が現れないので通る。
#   - 入力やファイルが読めない場合は、フックの都合で作業を止めない。

import json
from pathlib import Path
import re
import shlex
import sys
import unicodedata


ASSIGNMENT = re.compile(r'^[A-Za-z_][A-Za-z_0-9]*=')
TIME = re.compile(
    r'(?:(?<![A-Za-z_\d.:])|(?<=-[bn])|(?<=\d{4}-\d{2}-\d{2}T))'
    r'(?:[01]?\d|2[0-3]):[0-5]\d(?!\d)(?::[0-5]\d(?!\d))?'
    r'|(?<!\d)(?:[01]?\d|2[0-4])\s*時(?!間|限|点)'
    r'|(?:午前|午後|朝|夜|夕方|深夜|正午)\s*\d+'
    r'|(?<![\w.])\d{1,2}(?::[0-5]\d)?\s*(?:a\.?m\.?|p\.?m\.?)(?![a-z])',
    re.IGNORECASE,
)
GUIDANCE = """本文の手書きの時刻は推測で書かれやすいため止めました（haoblackj/dotfiles#75）。
検出箇所:
{hits}
時刻はシェルに計算させてください。いま: $(date '+%Y-%m-%d %H:%M')
過去のコメントの投稿時刻: $(gh api repos/<o>/<r>/issues/comments/<ID> --jq .created_at)（UTC）。
JST にするなら: $(date -d "$(gh api ... --jq .created_at)" '+%Y-%m-%d %H:%M')
例:
gh issue comment 89 -R o/r --body "$(cat <<EOF
## 状態（$(date '+%Y-%m-%d %H:%M')）
...
EOF
)"
区切りは引用せず <<EOF にしてください。<<'EOF' では $(date) が展開されません。
本文に $ やバッククォートを文字として書くときは \\$、\\` にしてください。
--body-file のファイルには時刻を書かず、時刻の無い本文を渡してください。
ログなどの時刻を引用するときはコードの囲みかインラインコードに入れてください。"""


def options(args):
    """値を取る本文・API オプションを、結合形も含めて読む。"""
    names = {'--body', '--body-file', '--title', '--notes', '--notes-file',
             '--input', '--field', '--raw-field', '--method', '--header',
             '--hostname', '--jq', '--template', '-b', '-F', '-f', '-X',
             '-H', '-q', '-t', '-n'}
    i = 0
    while i < len(args):
        word = args[i]
        if word == '--':
            break
        key, sep, value = word.partition('=')
        if sep and key in names:
            yield key, value
        elif word in names:
            i += 1
            if i < len(args):
                yield word, args[i]
        elif len(word) > 2 and word[:2] in names and not word.startswith('--'):
            yield word[:2], word[2:]
        elif not word.startswith('-'):
            yield '', word
        i += 1


def invocation(tokens):
    i = 0
    while i < len(tokens):
        word = tokens[i]
        if ASSIGNMENT.match(word) or word in ('command', 'exec', 'time', 'nohup', 'then', 'do', '!', '{'):
            i += 1
        elif word == 'env':
            i += 1
            while i < len(tokens):
                if tokens[i] in ('-u', '--unset', '-C', '--chdir', '-S', '--split-string'):
                    i += 2
                elif tokens[i].startswith('-') or ASSIGNMENT.match(tokens[i]):
                    i += 1
                else:
                    break
        else:
            break
    if i >= len(tokens) or not (tokens[i] == 'gh' or tokens[i].endswith('/gh')):
        return None
    i += 1
    while i < len(tokens):
        if tokens[i] in ('-R', '--repo'):
            i += 2
        elif tokens[i].startswith('--repo='):
            i += 1
        else:
            break
    args = tokens[i:]
    if not args:
        return None
    kind = args[0]
    if kind == 'api':
        opts = list(options(args[1:]))
        endpoint = next((v for k, v in opts if not k), None)
        if endpoint == 'graphql':
            writes = any(re.search(r'\bmutation\b', arg) for arg in args[1:])
        else:
            writes = any(k in ('-f', '-F', '--field', '--raw-field', '--input')
                         or (k in ('-X', '--method') and v.upper() in ('POST', 'PATCH', 'PUT'))
                         for k, v in opts)
    else:
        pair = tuple(args[:2])
        if pair not in ({(k, a) for k in ('issue', 'pr') for a in ('comment', 'create', 'edit')}
                        | {('pr', 'review'), ('release', 'create'), ('release', 'edit')}):
            return None
        opts = list(options(args[2:]))
        # ラベル等だけの編集は本文を書かない。タイトルの手書き時刻も検査する。
        writes = args[1] != 'edit' or any(
            k in ('--body', '-b', '--body-file', '-F', '--title', '--notes', '-n', '--notes-file')
            for k, _ in opts)
    return (kind, opts) if writes else None


def targets(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|()\n')
    lexer.whitespace = ' \t'
    lexer.whitespace_split = True
    tokens = []
    fallback = False
    try:
        for token in lexer:
            tokens.append(token)
    except ValueError:
        # ヒアドキュメントのアポストロフィ等で分割できないときは広く拾う。
        fallback = bool(re.search(
            r'(?:^|[;&|(\n])\s*gh\s+(?:issue|pr|release|api)\b', command))
        if not fallback:
            return []
    found = []
    segment = []
    for token in tokens + [';']:
        if token and all(c in ';&|()\n' for c in token):
            item = invocation(segment)
            if item:
                found.append(item)
            segment = []
        else:
            segment.append(token)
    # 分割できた先頭部分のファイル指定も検査し、対象判定は生の正規表現で補う。
    return found + ([('fallback', [])] if fallback else [])


def input_paths(found):
    for kind, opts in found:
        for key, value in opts:
            if key in ('--body-file', '--notes-file', '--input') or (
                    key == '-F' and kind in ('issue', 'pr', 'release')):
                yield value
            elif kind == 'api' and key in ('-F', '--field'):
                _, sep, path = value.partition('=@')
                if sep:
                    yield path


def without_code(text):
    # 位置と改行を保ったままコードを空白にし、検出位置を元の行へ対応させる。
    def blank(value):
        return re.sub(r'[^\n]', ' ', value)

    lines = []
    fence = None
    for line in text.splitlines(keepends=True):
        if fence:
            closing = re.match(
                r'^[ \t]*' + re.escape(fence[0]) + '{' + str(fence[1])
                + r''',}[ \t]*(?:["']|$)''', line.rstrip('\r\n'))
            if closing:
                lines.append(blank(line[:closing.end()]) + line[closing.end():])
                fence = None
            else:
                lines.append(blank(line))
        else:
            opening = re.match(r'^[ \t]*(`{3,}|~{3,})', line)
            if not opening:
                # --body "``` のように本文がフェンスで始まる場合も扱う。
                opening = re.match(
                    r'''^.*?(?:--body(?:=|\s+)|-b\s*|--notes(?:=|\s+)|-n\s*)["'](`{3,}|~{3,})''',
                    line)
            # 同じ行に対があるバッククォートはインラインコードとして扱う。
            if opening and opening[1] in line[opening.end():]:
                opening = None
            if opening:
                run = opening[1]
                fence = (run[0], len(run))
                lines.append(blank(line))
            else:
                lines.append(line)
    text = ''.join(lines)
    # 同じ本数のバッククォートだけを対として扱う（複数行も許す）。
    runs = list(re.finditer(r'`+', text))
    chars = list(text)
    i = 0
    while i < len(runs):
        end = next((j for j in range(i + 1, len(runs))
                    if len(runs[j][0]) == len(runs[i][0])), None)
        if end is None:
            i += 1
            continue
        start_pos, end_pos = runs[i].start(), runs[end].end()
        chars[start_pos:end_pos] = blank(text[start_pos:end_pos])
        i = end + 1
    return ''.join(chars)


def findings(source, text):
    text = unicodedata.normalize('NFKC', text)
    masked = without_code(text)
    seen = set()
    for match in TIME.finditer(masked):
        line_start = text.rfind('\n', 0, match.start()) + 1
        line_end = text.find('\n', match.end())
        if line_end < 0:
            line_end = len(text)
        start = max(line_start, match.start() - 25)
        end = min(line_end, start + 60)
        snippet = text[start:end].strip()
        line_number = text.count('\n', 0, match.start()) + 1
        hit = f'{source}:{line_number}: {snippet}'
        if hit not in seen:
            seen.add(hit)
            yield hit


def main():
    try:
        payload = json.load(sys.stdin)
        command = payload.get('tool_input', {}).get('command')
        if not isinstance(command, str) or not command:
            return
        found = targets(command)
        if not found:
            return
        hits = list(findings('コマンド', command))[:5]
        cwd = Path(payload.get('cwd') or Path.cwd())
        for name in dict.fromkeys(input_paths(found)):
            if name == '-' or len(hits) >= 5:
                continue
            try:
                path = Path(name).expanduser()
                if not path.is_absolute():
                    path = cwd / path
                with path.open('rb') as stream:
                    content = stream.read(1024 * 1024).decode('utf-8', errors='replace')
                hits.extend(list(findings(name, content))[:5 - len(hits)])
            except (OSError, ValueError, RuntimeError):
                continue
        if hits:
            reason = GUIDANCE.format(hits='\n'.join('- ' + hit for hit in hits))
            print(json.dumps({'hookSpecificOutput': {
                'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                'permissionDecisionReason': reason}}, ensure_ascii=False))
    except Exception:
        # 入力不備やフック自身の例外で Claude の作業を止めない。
        return


if __name__ == '__main__':
    main()
