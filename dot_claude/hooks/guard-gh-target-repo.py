#!/usr/bin/env python3
# GitHub への書き込みを、リーダー（GH_WRITE_OWNERS、既定 haoblackj）の持ち物に限る PreToolUse フック。
# 外部のリポジトリへの起票、コメント、言及は、リーダーの指示で当面すべて禁止（2026-11-02）。
#   - 2026-11-02、upstream を持つ作業コピーで -R なしの gh issue create が他人のリポジトリに
#     issue を立てた（bot では閉じられなかった）。
#   - 同日、自分の issue の状態コメントに他人の issue の参照を書き、相手の issue に参照の記録を
#     残した（本文を書き換えても記録は消えない）。
#
# 判定の方針（確かめられないものは止める）:
#   - Bash のコマンドを区切りごとに読み、cd を追って作業フォルダを決める。
#   - gh: 書き込みの投稿先を -R / URL / gh api のパスで確かめる。名指しが無い、持ち主が違う、
#     確かめられない（gists などリポジトリ外、{owner} の置き換え、--fill）ときは止める。
#     gh api graphql の mutation は、書き込む先のノード ID の持ち主を GitHub に問い合わせ、
#     すべてリーダーの持ち物と確かめられたときだけ通す。
#     gh の alias は gh alias list で展開してから同じ判定に掛け、シェルの alias は止める。
#     拡張コマンドは中身を読んで決めたもの（EXTENSIONS）だけ判定し、ほかは止める。
#     gh を中で呼ぶ ghf と gh-pr-body も、gh の呼び出しに読み替えて同じ判定に掛ける。
#   - git push: 送り先の remote の URL を git に聞き、リーダーの持ち物でなければ止める。
#     送る commit のメッセージに他人の issue / PR への参照があれば止める。
#   - curl / wget の GitHub API への書き込みは、パスの持ち主で判定する（graphql は止める）。
#     そのほかのプログラムが GitHub API に触れる（コマンドかスクリプトに api.github.com がある）
#     ときは止める。
#   - 書き込みの本文（コマンドの文字列、--body-file などのファイル、標準入力に流すファイルや
#     ヒアドキュメント、$(cat file)）に、他人の issue / PR への参照か、リーダー以外への
#     @メンションがあれば止める。標準入力の出どころが読めないときも止める。
#     redirect.github.com 経由の URL は相手に参照の記録を残さないので通し、止めるときは
#     その URL への書き換えを案内する（2026-11-03）。
#   - GitHub 用の MCP ツールは、書き込みの owner と本文で同じ判定をする。

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

OWN_ACCOUNTS = {'penguinex-agent'}
ASSIGNMENT = re.compile(r'^[A-Za-z_][A-Za-z_0-9]*=')
# re.ASCII: GitHub は日本語の直後（「別件はowner/repo#4」「確認@user」）でもリンクするので、
# \w を ASCII に限り、日本語を語の境界として扱う。
REFERENCE = re.compile(
    r'(?<![\w./-])([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)#\d+'
    r'|https?://github\.com/([^/\s]+)/([^/\s]+)/(?:issues|pull|discussions|commit)/\w+', re.ASCII)
MENTION = re.compile(r'(?<![\w.@/`-])@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))(?![\w.-]*\.\w)', re.ASCII)
HTTP_PROGRAMS = ('curl', 'wget', 'http', 'https', 'xh')
# ghf（zsh のプラグイン atusy/gh-fzf）は引数をそのまま gh に渡し、パイプの標準入力があれば
# その中身を最後の引数に足す。
GH_PROGRAMS = ('gh', 'ghf')
PIPED_ARG = '<標準入力>'
# gh を中で呼ぶ自作のスクリプト（~/.local/bin）。gh の引数に読み替えて同じ判定に掛ける。
GH_WRAPPERS = ('gh-pr-body',)


def gh_pr_body_args(args):
    """gh-pr-body の引数を、中で呼ぶ gh pr edit の引数に読み替える。get は読み取り。"""
    sub, rest = (args[0], args[1:]) if args else ('', [])
    if rest[:1] == ['--force']:
        rest = rest[1:]
    if sub == 'get':
        return []
    if sub == 'set' and len(rest) == 3:
        repo, number, body = rest
    elif sub == 'restore' and len(rest) == 3:
        body, repo, number = rest
    else:
        return []  # 使い方の誤りで、スクリプトは何もせず終わる
    return ['pr', 'edit', number, '-R', repo, '--body-file', body]
MAX_DEPTH = 5
GITHUB_URL_REPO = re.compile(r'github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$')
URL_REPO = re.compile(r'^https?://github\.com/([^/\s]+)/([^/\s]+)')
API_REPO = re.compile(r'(?:^|api\.github\.com)/?repos/([^/\s?]+)/([^/\s?]+)')
NODE_ID = re.compile(r'\b[A-Z][A-Za-z]{0,7}_[A-Za-z0-9_-]{6,}\b')
WRITES = {
    'issue': {'create', 'comment', 'edit', 'close', 'reopen', 'delete', 'lock', 'unlock',
              'pin', 'unpin', 'transfer', 'develop'},
    'pr': {'create', 'comment', 'edit', 'close', 'reopen', 'merge', 'review', 'ready',
           'lock', 'unlock', 'revert', 'update-branch'},
    'discussion': {'create', 'comment', 'edit'},
    'agent-task': {'create'},
    'skill': {'publish'},
    'label': {'create', 'edit', 'delete', 'clone'},
    'release': {'create', 'edit', 'delete', 'upload', 'delete-asset'},
    'repo': {'create', 'fork', 'edit', 'delete', 'rename', 'archive', 'unarchive', 'sync'},
    'gist': {'create', 'edit', 'delete', 'clone', 'rename'},
    'workflow': {'run', 'enable', 'disable'},
    'run': {'rerun', 'cancel', 'delete'},
    'secret': {'set', 'delete'},
    'variable': {'set', 'delete'},
    'cache': {'delete'},
}
NESTED_WRITES = {('repo', 'autolink'): {'create', 'delete'},
                 ('repo', 'deploy-key'): {'add', 'delete'}}
REPO_OPTIONAL = {('gist', 'create'), ('gist', 'edit'), ('gist', 'delete'), ('gist', 'clone'),
                 ('gist', 'rename')}
# gh 2.103 の組み込みのコマンドと、ヘルプの話題。これ以外の最初の語は alias か拡張コマンドで、
# フックからは中身が見えないので、alias は展開し、拡張は EXTENSIONS で判定する。
BUILTINS = {'auth', 'browse', 'codespace', 'discussion', 'gist', 'issue', 'org', 'pr', 'project',
            'release', 'repo', 'skill', 'cache', 'run', 'workflow', 'agent-task', 'alias', 'api',
            'attestation', 'completion', 'config', 'copilot', 'extension', 'gpg-key', 'label',
            'licenses', 'preview', 'ruleset', 'search', 'secret', 'ssh-key', 'status', 'variable',
            'help', 'version', 'accessibility', 'actions', 'environment', 'exit-codes',
            'formatting', 'mintty', 'reference', 'telemetry'}
# 中身を読んで判定を決めた拡張（2026-11-03）。None は GitHub へ書き込まないもの
# （q は自分のリポジトリの一覧と clone、token は App の token の発行と失効）。
# dep は依存の更新の PR をまとめて承認、マージする。引数なしは対話の画面で、既定は承認。
EXTENSIONS = {'q': None, 'token': None,
              'dep': {'reads': {'list', 'groups', 'completion', 'help'}}}
# 後ろの語をコマンドとして実行するもの。gh がこれらの引数にあれば、呼び出しとして判定する。
RUNNERS = {'timeout', 'xargs', 'nice', 'ionice', 'stdbuf', 'watch', 'sudo', 'doas', 'unbuffer',
           'flock', 'chronic', 'nohup', 'time', 'exec', 'command', 'env'}
API_VALUE_OPTS = {'-f', '-F', '--field', '--raw-field', '--input', '-X', '--method', '-H',
                  '--header', '--hostname', '-q', '--jq', '-t', '--template', '--cache',
                  '-p', '--preview'}
BODY_FILE_OPTS = {'--body-file', '-F', '--notes-file', '--input'}
STDIN_FRIENDLY = {'cat', 'echo', 'printf', 'jq', 'sed', 'head', 'tail', 'tr', 'envsubst', 'tee'}
WRITE_METHODS = {'POST', 'PATCH', 'PUT', 'DELETE'}
MCP_WRITE_WORDS = ('create', 'update', 'add', 'delete', 'remove', 'merge', 'push', 'comment',
                   'fork', 'edit', 'close', 'reopen', 'assign', 'request', 'submit', 'write',
                   'mark', 'dismiss', 'lock', 'set')

RULE = '外部のリポジトリへの起票、コメント、言及は、リーダーの指示で当面すべて禁止です（2026-11-02）。'
RETRY_LIMIT = ('\n同じ書き込みをこのフックに 2 回止められたら、書き方を変えて通そうとせず、投稿先と本文を'
               '示してリーダーに明示的な許可を求めてください。')
REASONS = {
    'unnamed': '投稿先のリポジトリを確かめられません（{detail}）。-R owner/repo（gh api なら '
               'repos/owner/repo/... のパス）で投稿先を名指ししてください。',
    'foreign': '書き込み先がリーダーの持ち物ではありません（{detail}）。' + RULE +
               ' 必要なら本文を示して、リーダーに手で投稿してもらってください。',
    'reference': '本文に、リーダーの持ち物でないリポジトリの issue / PR への参照があります（{detail}）。'
                 '相手の issue に参照の記録が残り、書き換えても消えません。リンクが要るなら、矢印の'
                 '先の redirect.github.com の URL に書き換えてください（相手に記録が残りません。'
                 '短縮形の owner/repo#N は使いません）。',
    'mention': '本文に、リーダー以外への @メンションがあります（{detail}）。相手に通知が届きます。'
               '役割や例はバッククォートで囲んでください。' + RULE,
    'stdin': '本文を標準入力から渡していて、その出どころを読めません（{detail}）。本文をファイルに'
             '書き、--body-file などでファイルを渡してください。',
    'unverified': '書き込み先を確かめられないため止めました（{detail}）。' + RULE,
}


class Deny(Exception):
    def __init__(self, kind, detail):
        super().__init__(kind)
        self.kind = kind
        self.detail = detail

    def reason(self, command):
        return (REASONS[self.kind].format(detail=self.detail) + RETRY_LIMIT +
                f'\n対象: {command[:300]}')


def owner_of(slug):
    return slug.split('/', 1)[0]


# --- reading text ------------------------------------------------------------------------

def read_text(name, cwd):
    try:
        path = Path(name).expanduser()
        if not path.is_absolute():
            path = Path(cwd or Path.cwd()) / path
        with path.open('rb') as stream:
            return stream.read(1024 * 1024).decode('utf-8', errors='replace')
    except (OSError, ValueError, RuntimeError):
        return None


def without_code(text):
    text = re.sub(r'```.*?(```|$)', ' ', text, flags=re.S)
    text = re.sub(r'~~~.*?(~~~|$)', ' ', text, flags=re.S)
    return re.sub(r'`[^`\n]*`', ' ', text)


def redirect_url(ref):
    """参照を、相手に参照の記録を残さない redirect.github.com の URL に書き換える。
    owner/repo#N は issue か PR か分からないが、/issues/N は PR なら GitHub が転送する。"""
    if ref.startswith('http'):
        return re.sub(r'^https?://github\.com/', 'https://redirect.github.com/', ref)
    slug, _, number = ref.partition('#')
    return f'https://redirect.github.com/{slug}/issues/{number}'


def check_body(text, owners):
    """他人の issue / PR への参照と、リーダー以外への @メンションを探す。"""
    refs = {}
    for m in REFERENCE.finditer(text):
        owner = m.group(1) or m.group(3)
        if owner not in owners:
            refs[m.group(0)] = redirect_url(m.group(0))
    if refs:
        raise Deny('reference', '; '.join(f'{ref} → {url}' for ref, url in refs.items()))
    mentions = [m.group(1) for m in MENTION.finditer(without_code(text))
                if m.group(1) not in owners and m.group(1) not in OWN_ACCOUNTS]
    if mentions:
        raise Deny('mention', ', '.join('@' + m for m in dict.fromkeys(mentions)))


# --- shell parsing -----------------------------------------------------------------------

def split_command(command):
    """コマンドを (区切り, トークン列) の並びにする。区切りは直前の区切り記号。"""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|()\n<>')
    lexer.whitespace = ' \t'
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        tokens = None
    if tokens is None:
        # ヒアドキュメントの中のアポストロフィなどで分割できないときは、ヒアドキュメントを
        # 外した行で分割し直す（ヒアドキュメントの本文はコマンドの文字列として検査済み）。
        stripped = re.sub(r"<<-?\s*['\"]?(\w+)['\"]?.*?^\1\s*$", '<< HEREDOC', command,
                          flags=re.S | re.M)
        try:
            lexer = shlex.shlex(stripped, posix=True, punctuation_chars=';&|()\n<>')
            lexer.whitespace = ' \t'
            lexer.whitespace_split = True
            tokens = list(lexer)
        except ValueError:
            tokens = stripped.split()
    segments = []
    current = []
    sep = ';'
    for token in tokens + [';']:
        if token and all(c in ';&|()\n' for c in token):
            segments.append((sep, current))
            current = []
            sep = token
        else:
            current.append(token)
    return segments


def strip_prefix(tokens):
    """環境変数の代入や env、command などの前置きを外したトークン列。"""
    i = 0
    while i < len(tokens):
        word = tokens[i]
        if ASSIGNMENT.match(word) or word in ('command', 'exec', 'time', 'nohup', 'then', 'do',
                                              '!', '{', 'sudo'):
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
    return tokens[i:]


def redirects(tokens):
    """(< の入力ファイル, ヒアドキュメントの有無, リダイレクトを除いたトークン列)"""
    stdin_file, heredoc, rest = None, False, []
    i = 0
    while i < len(tokens):
        if tokens[i] == '<' and i + 1 < len(tokens) and tokens[i + 1] == '<':
            heredoc = True
            i += 3
            continue
        if tokens[i] == '<' and i + 1 < len(tokens):
            stdin_file = tokens[i + 1]
            i += 2
            continue
        if tokens[i] == '>' and i + 1 < len(tokens):
            i += 2 if tokens[i + 1] != '>' else 3
            continue
        rest.append(tokens[i])
        i += 1
    return stdin_file, heredoc, rest


def program(tokens):
    return Path(tokens[0]).name if tokens else ''


# --- gh ------------------------------------------------------------------------------------

def repo_flag(args):
    for i, word in enumerate(args):
        if word in ('-R', '--repo') and i + 1 < len(args):
            return args[i + 1]
        if word.startswith('--repo='):
            return word.split('=', 1)[1]
        if word.startswith('-R') and len(word) > 2:
            return word[2:]
    return None


def without_repo_flag(args):
    rest, skip = [], False
    for word in args:
        if skip:
            skip = False
        elif word in ('-R', '--repo'):
            skip = True
        elif not (word.startswith('--repo=') or (word.startswith('-R') and len(word) > 2)):
            rest.append(word)
    return rest


def api_parts(rest):
    """gh api の (endpoint, 書き込みか, 値の一覧)"""
    endpoint, writes, values, i = None, False, [], 1
    while i < len(rest):
        word = rest[i]
        if word in API_VALUE_OPTS:
            value = rest[i + 1] if i + 1 < len(rest) else ''
            if word in ('-f', '-F', '--field', '--raw-field', '--input'):
                writes = True
                values.append((word, value))
            if word in ('-X', '--method') and value.upper() in WRITE_METHODS:
                writes = True
            i += 2
            continue
        if word.startswith(('--field=', '--raw-field=', '--input=')):
            writes = True
            key, value = word.split('=', 1)
            values.append((key, value))
        elif word.startswith(('-f', '-F')) and len(word) > 2:
            writes = True
            values.append((word[:2], word[2:]))
        elif word.startswith('--method=') or (word.startswith('-X') and len(word) > 2):
            value = word.split('=', 1)[1] if word.startswith('--') else word[2:]
            writes = writes or value.upper() in WRITE_METHODS
        elif not word.startswith('-') and endpoint is None:
            endpoint = word
        i += 1
    return endpoint, writes, values


def body_file_names(args):
    """書き込みの本文を渡すファイル名（'-' は標準入力）。"""
    for i, word in enumerate(args):
        value = None
        if word in BODY_FILE_OPTS and i + 1 < len(args):
            value = args[i + 1]
        elif word.startswith(('--body-file=', '--input=', '--notes-file=')):
            value = word.split('=', 1)[1]
        elif word in ('-f', '--field', '--raw-field') and i + 1 < len(args):
            value = args[i + 1]
        if value is None:
            continue
        _, sep, path = value.partition('=@')
        if sep:
            yield path
        elif '=' not in value:
            yield value


def graphql_targets(values, resolve_node_owner, owners):
    texts = [v.split('=', 1)[1] if '=' in v else v for _, v in values]
    query = next((t for k, t in zip(values, texts) if k[1].startswith('query=')), '')
    if not re.search(r'\bmutation\b', query):
        return
    ids = set()
    for text in texts:
        ids.update(NODE_ID.findall(text))
    ids.discard('IC')
    if not ids:
        raise Deny('unverified', 'graphql の mutation で、書き込む先のノード ID が見つかりません')
    for node_id in sorted(ids):
        owner = resolve_node_owner(node_id)
        if owner is None:
            raise Deny('unverified', f'ノード ID {node_id} の持ち主を確かめられません')
        if owner not in owners:
            raise Deny('foreign', f'ノード ID {node_id} は {owner} の持ち物')


def gh_aliases():
    """gh alias list の {名前: 展開}。読めなければ空（未知のサブコマンドとして止まる）。"""
    try:
        out = subprocess.run(['gh', 'alias', 'list'], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    table = {}
    for line in out.stdout.splitlines():
        name, sep, expansion = line.partition(':')
        if sep and name.strip() and not name.startswith(' '):
            table[name.strip()] = expansion.strip()
    return table


def expand_alias(expansion, extra):
    """gh と同じく $1.. を後ろの引数で置き換え、使わなかった引数を末尾に足す。"""
    used = set()

    def replace(m):
        n = int(m.group(1))
        if 0 < n <= len(extra):
            used.add(n - 1)
            return extra[n - 1]
        return m.group(0)

    words = [re.sub(r'\$(\d+)', replace, w) for w in shlex.split(expansion)]
    return words + [w for i, w in enumerate(extra) if i not in used]


def asks_help(rest):
    """gh <cmd> [<sub>] --help の形か。--help がオプションの値（--title --help）のときは偽。"""
    return (len(rest) <= 3 and rest[-1] in ('--help', '-h')
            and all(not w.startswith('-') for w in rest[:-1]))


def check_extension(name, rest, repo, owners):
    rule = EXTENSIONS[name]
    if rule is None:
        return False
    sub = rest[1] if len(rest) > 1 and not rest[1].startswith('-') else None
    if sub in rule['reads'] or asks_help(rest):
        return False
    targets = [t for t in (repo or '').split(',') if t]
    for i, word in enumerate(rest):
        if word == '--owner' and i + 1 < len(rest):
            targets.append(rest[i + 1] + '/*')
        elif word.startswith('--owner='):
            targets.append(word.split('=', 1)[1] + '/*')
    if not targets:
        raise Deny('unnamed', f'gh {name} {sub or "（対話の画面）"}')
    foreign = [t for t in targets if owner_of(t) not in owners]
    if foreign:
        raise Deny('foreign', ', '.join(dict.fromkeys(foreign)))
    return True


def check_gh(args, owners, resolve_node_owner, call=True, depth=0):
    """gh の呼び出しを調べ、書き込みなら True。call が偽なら gh は単なる語の位置にあり
    （brew upgrade gh など）、知らないサブコマンドでも止めない。"""
    repo = repo_flag(args)
    rest = without_repo_flag(args)
    if not rest or rest[0].startswith('-') or asks_help(rest):
        return False
    kind = rest[0].strip('`')
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]*', kind):
        # 日本語の文の「gh が」などは呼び出しではない。$c のような変数は中身を確かめられない。
        if call and '$' in kind:
            raise Deny('unverified', f'gh のサブコマンド {kind} を確かめられません')
        return False
    if kind not in BUILTINS:
        aliases = gh_aliases()
        if kind in aliases:
            expansion = aliases[kind]
            if expansion.startswith('!'):
                raise Deny('unverified', f'gh {kind} はシェルを実行する alias（{expansion}）')
            if depth >= MAX_DEPTH:
                raise Deny('unverified', f'gh {kind} の alias を展開しきれません')
            expanded = (['-R', repo] if repo else []) + expand_alias(expansion, rest[1:])
            return check_gh(expanded, owners, resolve_node_owner, True, depth + 1)
        if kind in EXTENSIONS:
            return check_extension(kind, rest, repo, owners)
        if call:
            raise Deny('unverified', f'gh {kind} は中身を判定できないサブコマンド（拡張か alias）')
        return False
    if kind == 'api':
        endpoint, writes, values = api_parts(rest)
        if not writes or endpoint is None:
            return False
        if endpoint == 'graphql':
            graphql_targets(values, resolve_node_owner, owners)
            return True
        m = API_REPO.match(endpoint)
        if m is None:
            raise Deny('unverified', f'gh api の書き込み先 {endpoint} はリポジトリの外')
        if '{' in m.group(0):
            raise Deny('unnamed', f'gh api のパス {endpoint}')
        if m.group(1) not in owners:
            raise Deny('foreign', f'{m.group(1)}/{m.group(2)}')
        return True
    nested = NESTED_WRITES.get((kind, rest[1] if len(rest) > 1 else None))
    if nested is not None:
        if len(rest) < 3 or rest[2] not in nested:
            return False
    elif len(rest) < 2 or rest[1] not in WRITES.get(kind, ()):
        return False
    if any(w in ('--fill', '--fill-first', '--fill-verbose') for w in rest):
        raise Deny('unverified', '--fill は commit のメッセージを本文にする')
    if (kind, rest[1]) in REPO_OPTIONAL:
        return True
    targets = []
    if repo:
        targets.append(repo)
    targets += [f'{m.group(1)}/{m.group(2)}' for w in rest[2:] if (m := URL_REPO.match(w))]
    if kind == 'repo':
        targets += [w for w in rest[2:] if re.fullmatch(r'[\w.-]+/[\w.-]+', w)]
    if not targets:
        raise Deny('unnamed', f'gh {kind} {rest[1]}')
    foreign = [t for t in targets if owner_of(t) not in owners]
    if foreign:
        raise Deny('foreign', ', '.join(dict.fromkeys(foreign)))
    return True


# --- git push ------------------------------------------------------------------------------

def git_output(cwd, *args):
    try:
        out = subprocess.run(['git', '-C', str(cwd or Path.cwd()), *args], capture_output=True,
                             text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def check_git(tokens, cwd, owners):
    args = tokens[1:]
    while args and args[0] in ('-C', '-c'):
        if args[0] == '-C' and len(args) > 1:
            cwd = str(Path(cwd or Path.cwd()) / args[1])
        args = args[2:]
    if not args or args[0] != 'push':
        return
    positional = [a for a in args[1:] if not a.startswith('-')]
    remote = positional[0] if positional else None
    if remote is None:
        branch = git_output(cwd, 'symbolic-ref', '--short', 'HEAD')
        remote = (git_output(cwd, 'config', f'branch.{branch}.pushRemote') if branch else None) \
            or git_output(cwd, 'config', 'remote.pushDefault') \
            or (git_output(cwd, 'config', f'branch.{branch}.remote') if branch else None) \
            or 'origin'
    url = remote if re.search(r'[:/]', remote) else (
        git_output(cwd, 'remote', 'get-url', '--push', remote))
    if not url:
        raise Deny('unverified', f'git push の送り先 {remote} の URL を確かめられません')
    m = GITHUB_URL_REPO.search(url)
    if m is None:
        raise Deny('unverified', f'git push の送り先 {url} は GitHub の名指しの形ではありません')
    if m.group(1) not in owners:
        raise Deny('foreign', f'git push の送り先 {m.group(1)}/{m.group(2)}')
    messages = git_output(cwd, 'log', '--format=%B', 'HEAD', '--not', '--remotes')
    if messages is None:
        raise Deny('unverified', '送る commit のメッセージを読めません')
    check_body(messages, owners)


# --- curl and other programs ---------------------------------------------------------------

def check_http(tokens, owners):
    urls = [t for t in tokens if 'github.com' in t and t.startswith('http')]
    api = [u for u in urls if 'api.github.com' in u or 'uploads.github.com' in u]
    if not api:
        return
    writes = any(t in ('-d', '--data', '--data-raw', '--data-binary', '--data-urlencode',
                       '-F', '--form', '--json', '-T', '--upload-file', '--post-data',
                       '--post-file', '--body-data', '--body-file')
                 or t.startswith(('--data', '--json', '--post-'))
                 for t in tokens)
    for i, t in enumerate(tokens):
        if t in ('-X', '--request', '--method') and i + 1 < len(tokens):
            writes = writes or tokens[i + 1].upper() in WRITE_METHODS
        elif t.startswith(('-X', '--request=', '--method=')) and len(t) > 2:
            writes = writes or t.split('=', 1)[-1].lstrip('-X').upper() in WRITE_METHODS
    if not writes:
        return
    for url in api:
        m = API_REPO.search(url)
        if m is None:
            raise Deny('unverified', f'{url} はリポジトリのパスではありません')
        if m.group(1) not in owners:
            raise Deny('foreign', f'{m.group(1)}/{m.group(2)}')


def check_program(tokens, cwd, owners, resolve_node_owner, depth):
    """GitHub API に触れるそのほかのプログラムを止め、シェルのスクリプトは中身を同じ判定に掛ける。

    シェル以外のコードの中の gh の呼び出しは探さない（リーダー、2026-11-03）。'gh' の文字列で
    止めると、過去の Bash のコマンド約 3.4 万件のうち約 40 件の正当な処理（research-design の
    post_design.py などリーダーの issue への投稿と、会話の記録を読む処理）を止め、他人の
    リポジトリへの書き込みは 1 件も含まれていなかった。プロセスを起動する API と並ぶときだけ
    止める形に狭めても同じだった。
    """
    name = program(tokens)
    if name in ('gh', 'git', 'curl', 'wget', 'http', 'https', 'xh') or name in STDIN_FRIENDLY:
        return
    texts = [' '.join(tokens)]
    # 実行するスクリプトだけ中身を読む（テストの引数などは読まない）。
    script = None
    if re.fullmatch(r'(python|python3|python3\.\d+|node|bash|sh|zsh|ruby|perl|deno|bun)', name) \
            and '-m' not in tokens and '-c' not in tokens:
        script = next((t for t in tokens[1:] if not t.startswith('-')), None)
    elif tokens and '/' in tokens[0]:
        script = tokens[0]  # ./x.sh や ~/bin/x.py のようにパスで直接実行するもの
    text = read_text(script, cwd) if script else None
    if text:
        texts.append(text)
        first = text.split('\n', 1)[0]
        if (name in ('bash', 'sh', 'zsh') or re.search(r'^#!.*\b(?:ba|z)?sh\b', first)) and depth < MAX_DEPTH:
            analyse(text, owners, cwd, resolve_node_owner, depth + 1)
    for text in texts:
        if re.search(r'(?:api|uploads)\.github\.com', text, re.I):
            raise Deny('unverified', f'{name} が GitHub API に触れます')


# --- whole command ---------------------------------------------------------------------------

def stdin_text(segments, index, cwd):
    """index の呼び出しが標準入力から読む本文。読めなければ Deny。"""
    sep, tokens = segments[index]
    stdin_file, heredoc, _ = redirects(tokens)
    if heredoc:
        return ''  # 本文はコマンドの文字列に含まれ、全体で検査する
    if stdin_file:
        text = read_text(stdin_file, cwd)
        if text is None:
            raise Deny('stdin', f'{stdin_file} を読めません')
        return text
    if sep != '|':
        raise Deny('stdin', '標準入力に何も渡していません')
    texts = []
    j = index
    while j > 0 and segments[j][0] == '|':
        j -= 1
        prev = strip_prefix(redirects(segments[j][1])[2])
        if program(prev) not in STDIN_FRIENDLY:
            raise Deny('stdin', f'{program(prev) or "?"} の出力')
        for arg in prev[1:]:
            if not arg.startswith('-'):
                text = read_text(arg, cwd)
                if text is not None:
                    texts.append(text)
    return '\n'.join(texts)


def substitution_texts(command, cwd):
    for m in re.finditer(r'\$\(\s*(?:cat\s+|<\s*)([^)]+)\)', command):
        try:
            names = shlex.split(m.group(1))
        except ValueError:
            continue  # $(cat <<'EOF' ... EOF) の本文はコマンドの文字列に含まれ、全体で検査済み
        for name in names:
            text = read_text(name, cwd)
            if text is not None:
                yield text


def resolve_node_owner_via_gh(node_id):
    query = ('query($id:ID!){node(id:$id){... on RepositoryNode{repository{owner{login}}}'
             '... on Repository{owner{login}}}}')
    try:
        out = subprocess.run(['gh', 'api', 'graphql', '-f', f'query={query}', '-f', f'id={node_id}'],
                             capture_output=True, text=True, timeout=10)
        node = json.loads(out.stdout)['data']['node']
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError):
        return None
    if not node:
        return None
    return ((node.get('repository') or {}).get('owner') or node.get('owner') or {}).get('login')


def analyse(command, owners, cwd, resolve_node_owner, depth=0):
    """コマンドを調べ、止めるべきなら Deny を投げる。"""
    segments = split_command(command)
    writes = False
    for index, (_, raw) in enumerate(segments):
        stdin_file, heredoc, without_redirects = redirects(raw)
        tokens = strip_prefix(without_redirects)
        name = program(tokens)
        if name == 'cd' and len(tokens) > 1:
            cwd = str(Path(cwd or Path.cwd()) / Path(tokens[1]).expanduser())
            continue
        # bash -c "..." や ssh host "..." の引数の文字列は、コマンドとして実行されうるので同じ判定に
        # 掛ける。gh と git の引数（本文やコミットのメッセージ）はデータなので読み直さない。
        if name not in GH_PROGRAMS + GH_WRAPPERS + ('git',) and depth < MAX_DEPTH:
            for word in without_redirects:
                if re.search(r'\s', word):
                    analyse(word, owners, cwd, resolve_node_owner, depth + 1)
        if name == 'git':
            check_git(tokens, cwd, owners)
        elif name not in GH_PROGRAMS + GH_WRAPPERS + HTTP_PROGRAMS:
            check_program(tokens, cwd, owners, resolve_node_owner, depth)
        # timeout や xargs などの前置きが何であっても、その後ろの gh / curl に同じ判定を掛ける。
        for at, word in enumerate(without_redirects):
            found = program([word.strip('`')])
            if found in GH_WRAPPERS:
                args = gh_pr_body_args(without_redirects[at + 1:])
                if check_gh(args, owners, resolve_node_owner):
                    writes = True
                    for file_name in body_file_names(args):
                        text = read_text(file_name, cwd)
                        if text is None:
                            raise Deny('stdin', f'{file_name} を読めません')
                        check_body(text, owners)
            elif found in GH_PROGRAMS:
                args = without_redirects[at + 1:]
                piped = found == 'ghf' and segments[index][0] == '|'
                if piped:
                    args = args + [PIPED_ARG]
                call = at == len(without_redirects) - len(tokens) or name in RUNNERS
                if check_gh(args, owners, resolve_node_owner, call):
                    if piped:
                        raise Deny('stdin', 'ghf はパイプの標準入力を gh の引数に足します')
                    writes = True
                    for file_name in body_file_names(args):
                        text = (stdin_text(segments, index, cwd) if file_name == '-'
                                else read_text(file_name, cwd))
                        if text is None:
                            raise Deny('stdin', f'{file_name} を読めません')
                        check_body(text, owners)
            elif found in HTTP_PROGRAMS:
                check_http(without_redirects[at:], owners)
    if writes:
        check_body(command, owners)
        for text in substitution_texts(command, cwd):
            check_body(text, owners)


def decision(command, owners, cwd=None, resolve_node_owner=resolve_node_owner_via_gh):
    """('deny' | None, reason)"""
    try:
        analyse(command, owners, cwd, resolve_node_owner)
    except Deny as deny:
        return 'deny', deny.reason(command)
    return None, ''


# --- MCP tools -------------------------------------------------------------------------------

def mcp_decision(tool_name, tool_input, owners):
    name = tool_name.lower()
    if 'github' not in name:
        return None, ''
    action = name.rsplit('__', 1)[-1]
    if not any(word in action for word in MCP_WRITE_WORDS):
        return None, ''
    try:
        owner = tool_input.get('owner')
        repo = tool_input.get('repo') or tool_input.get('repository') or ''
        if not owner and isinstance(repo, str) and '/' in repo:
            owner = owner_of(repo)
        if not owner:
            raise Deny('unnamed', f'{tool_name} の owner')
        if owner not in owners:
            raise Deny('foreign', f'{owner}/{repo}')
        check_body(json.dumps(tool_input, ensure_ascii=False), owners)
    except Deny as deny:
        return 'deny', deny.reason(f'{tool_name} {json.dumps(tool_input, ensure_ascii=False)}')
    return None, ''


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    owners = {o for o in os.environ.get('GH_WRITE_OWNERS', 'haoblackj').split(',') if o}
    tool = payload.get('tool_name') or 'Bash'
    tool_input = payload.get('tool_input') or {}
    if tool == 'Bash':
        command = tool_input.get('command')
        if not isinstance(command, str):
            return
        verdict, reason = decision(command, owners, payload.get('cwd'))
    else:
        verdict, reason = mcp_decision(tool, tool_input, owners)
    if verdict:
        print(json.dumps({'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': verdict,
            'permissionDecisionReason': reason,
        }}, ensure_ascii=False))


if __name__ == '__main__':
    main()
