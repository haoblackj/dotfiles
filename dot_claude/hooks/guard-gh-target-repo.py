#!/usr/bin/env python3
# gh が投稿先を暗黙に選んで他人のリポジトリへ書く事故を防ぐ PreToolUse フック。
# 2026-11-02、origin（haoblackj）と upstream（kot149）を持つ作業コピーで
# -R なしの gh issue create が upstream に issue を立てた（bot では閉じられなかった）。
#
# 判定の方針:
#   - シェルのコマンド境界から gh の書き込みを探す。引用中の言及は通す。
#   - 投稿先が -R / --repo、URL、gh api のパスのどれでも名指しされていなければ止める。
#   - 名指しされた持ち主が GH_WRITE_OWNERS（既定 haoblackj）に無ければ、リーダーに許可を求める。
#   - gh api graphql はノード ID で対象を名指しするので、暗黙の選択は起きず通す。
#   - 入力が読めない場合は、フックの都合で作業を止めない。

import json
import os
import re
import shlex
import sys

ASSIGNMENT = re.compile(r'^[A-Za-z_][A-Za-z_0-9]*=')
URL_REPO = re.compile(r'^https?://github\.com/([^/\s]+)/([^/\s]+)/')
API_REPO = re.compile(r'^/?repos/([^/\s]+)/([^/\s]+)')
WRITES = {
    'issue': {'create', 'comment', 'edit', 'close', 'reopen', 'delete', 'lock', 'unlock',
              'pin', 'unpin', 'transfer', 'develop'},
    'pr': {'create', 'comment', 'edit', 'close', 'reopen', 'merge', 'review', 'ready',
           'lock', 'unlock'},
    'label': {'create', 'edit', 'delete', 'clone'},
    'release': {'create', 'edit', 'delete', 'upload', 'delete-asset'},
    'workflow': {'run', 'enable', 'disable'},
    'run': {'rerun', 'cancel', 'delete'},
    'secret': {'set', 'delete'},
    'variable': {'set', 'delete'},
    'cache': {'delete'},
}
API_VALUE_OPTS = {'-f', '-F', '--field', '--raw-field', '--input', '-X', '--method', '-H',
                  '--header', '--hostname', '-q', '--jq', '-t', '--template', '--cache'}
DENY = """GitHub への書き込みで、投稿先のリポジトリが名指しされていないため止めました。
gh は作業コピーの remote から投稿先を選ぶため、upstream（他人のリポジトリ）に書くことがあります。
-R owner/repo（gh api なら repos/owner/repo/... のパス）で投稿先を明示してください。
対象: {command}"""
ASK = """GitHub への書き込みの投稿先が、リーダーの持ち物でないリポジトリ（{repos}）です。
他人のリポジトリへの書き込みは、投稿先と本文を示して許可を得てから行います。
対象: {command}"""


def invocation(tokens):
    """トークン列が gh の呼び出しなら gh の後ろの引数を返す。"""
    i = 0
    while i < len(tokens):
        word = tokens[i]
        if ASSIGNMENT.match(word) or word in ('command', 'exec', 'time', 'nohup', 'then', 'do',
                                              '!', '{'):
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
    return tokens[i + 1:]


def repo_flag(args):
    for i, word in enumerate(args):
        if word in ('-R', '--repo') and i + 1 < len(args):
            return args[i + 1]
        if word.startswith('--repo='):
            return word.split('=', 1)[1]
        if word.startswith('-R') and len(word) > 2:
            return word[2:]
    return None


def target(args):
    """書き込みなら (kind, [owner/repo...] or None) を、読み取りなら None を返す。"""
    repo = repo_flag(args)
    rest = []
    skip = False
    for i, word in enumerate(args):
        if skip:
            skip = False
            continue
        if word in ('-R', '--repo'):
            skip = True
            continue
        if word.startswith('--repo=') or (word.startswith('-R') and len(word) > 2):
            continue
        rest.append(word)
    if not rest:
        return None
    kind = rest[0]
    if kind == 'api':
        endpoint, writes, i = None, False, 1
        while i < len(rest):
            word = rest[i]
            key = word.split('=', 1)[0] if word.startswith('--') else word[:2]
            if word in API_VALUE_OPTS:
                value = rest[i + 1] if i + 1 < len(rest) else ''
                if word in ('-f', '-F', '--field', '--raw-field', '--input'):
                    writes = True
                if word in ('-X', '--method') and value.upper() in ('POST', 'PATCH', 'PUT',
                                                                    'DELETE'):
                    writes = True
                i += 2
                continue
            if key in ('-f', '-F') or key in ('--field', '--raw-field', '--input'):
                writes = True
            elif key in ('-X', '--method'):
                value = word.split('=', 1)[1] if word.startswith('--') else word[2:]
                writes = writes or value.upper() in ('POST', 'PATCH', 'PUT', 'DELETE')
            elif not word.startswith('-') and endpoint is None:
                endpoint = word
            i += 1
        if not writes or endpoint is None or endpoint == 'graphql':
            return None
        m = API_REPO.match(endpoint)
        if m is None:
            return None
        if '{' in m.group(0):
            return ('api', None)
        return ('api', [f'{m.group(1)}/{m.group(2)}'])
    if len(rest) < 2 or rest[1] not in WRITES.get(kind, ()):
        return None
    if repo:
        return (kind, [repo])
    urls = [m for word in rest[2:] if (m := URL_REPO.match(word))]
    if urls:
        return (kind, [f'{m.group(1)}/{m.group(2)}' for m in urls])
    return (kind, None)


def invocations(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|()\n')
    lexer.whitespace = ' \t'
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        # 分割できないコマンドは、gh の書き込みらしい部分だけを粗く拾う。
        tokens = []
        for m in re.finditer(r'(?:^|[;&|(\n])\s*(gh\s[^;&|\n]*)', command):
            try:
                tokens += shlex.split(m.group(1)) + [';']
            except ValueError:
                tokens += m.group(1).split() + [';']
    segment = []
    for token in tokens + [';']:
        if token and all(c in ';&|()\n' for c in token):
            args = invocation(segment)
            if args is not None:
                yield args
            segment = []
        else:
            segment.append(token)


def decision(command, owners):
    """('deny' | 'ask' | None, reason)"""
    foreign = []
    for args in invocations(command):
        found = target(args)
        if found is None:
            continue
        _, repos = found
        if repos is None:
            return 'deny', DENY.format(command=command[:300])
        foreign += [r for r in repos if r.split('/', 1)[0] not in owners]
    if foreign:
        return 'ask', ASK.format(repos=', '.join(dict.fromkeys(foreign)), command=command[:300])
    return None, ''


def main():
    try:
        payload = json.load(sys.stdin)
        command = payload.get('tool_input', {}).get('command')
        if not isinstance(command, str) or 'gh' not in command:
            return
        owners = {o for o in os.environ.get('GH_WRITE_OWNERS', 'haoblackj').split(',') if o}
        verdict, reason = decision(command, owners)
        if verdict:
            print(json.dumps({'hookSpecificOutput': {
                'hookEventName': 'PreToolUse',
                'permissionDecision': verdict,
                'permissionDecisionReason': reason,
            }}, ensure_ascii=False))
    except (ValueError, KeyError, TypeError, AttributeError):
        return


if __name__ == '__main__':
    main()
