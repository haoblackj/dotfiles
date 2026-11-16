#!/usr/bin/env python3
# `## 決定` で始まる本文を GitHub へ書く前に、リーダーの言葉として書いた引用が
# リーダーの実際の発言と一字一句同じかを確かめる PreToolUse フック（dotfiles#86）。
# 決定のコメントにリーダーの言葉を強めて書いたり、Claude の案を決めたこととして
# 混ぜたりする事故を、規約ではなく機械で防ぐ。
#
# 判定の方針:
#   - gh の書き込みの見分け方と本文ファイルの拾い方は guard-gh-body-time.py と同じ。
#   - 本文が `## 決定` で始まるときだけ見る。
#   - `### リーダーが決めたこと` の節では、各項目に「」の引用があり、どの引用も
#     リーダーの発言に含まれていることを求める。
#   - 節の外でも、「リーダー」の直後（同じ句の中）に置いた引用は同じく確かめる。
#   - リーダーの発言は、このセッションと同じフォルダの transcript（14 日以内）の
#     利用者の発言と、prts の指摘（notes.jsonl）から集める。
#   - 空白と全角半角の違いは無視し、「…」で省いた所は前後を別々に探す。
#   - 入力や記録が読めない場合は、フックの都合で作業を止めない。

import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time
import unicodedata

HERE = Path(__file__).resolve().parent
LEADER_SECTION = 'リーダーが決めたこと'
RECENT_SECONDS = 14 * 24 * 3600
NOT_LEADER = ('<task-notification', '<system-reminder', '<command-', '<local-command',
              '<cross-session-message', '<agent-message', 'Another Claude session sent',
              'This session is being continued', 'Stop hook feedback', '[SYSTEM NOTIFICATION')
QUOTE = re.compile(r'「([^「」]*)」')
NEAR_LEADER = re.compile(r'リーダー[^。\n「」]{0,12}「([^「」]*)」')
ELLIPSIS = re.compile(r'…+|\.{3,}|⋯+')
# 引用符を付けずにリーダーの言葉として書いた形。「（リーダー、日付）」のように
# 言い換えた文をリーダーの言葉として載せると、引用の確かめをすり抜ける。
ATTRIBUTION = re.compile(
    r'リーダー(?:の(?:要件|言葉|発言|指示))?[:：]'
    r'|[（(]リーダー(?:の(?:要件|言葉|発言|指示))?(?:[、,][^（()）]*)?[)）]')

GUIDANCE = """決定のコメントのリーダーの言葉の引用を確かめられなかったので止めました（haoblackj/dotfiles#86）。
{problems}
リーダーが決めたことは、リーダーの発言か prts の指摘から一字一句写して引用してください。
言葉を強めたり、言い換えたりしないでください。省く所は … でつないでください。
リーダーが答えていない案は、`### リーダーが決めたこと` に入れず、別の節に書いてください。
形の例:
## 決定: <題>
### リーダーが決めたこと
- <決めたこと>（リーダー「<発言の一部をそのまま>」）
### Claude の案（リーダーの答え待ち）
- <案>"""


def load_body_time():
    for name in ('guard-gh-body-time.py', 'executable_guard-gh-body-time.py'):
        path = HERE / name
        if path.exists():
            spec = importlib.util.spec_from_file_location('guard_gh_body_time', path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    return None


def bodies(helper, command, cwd):
    found = helper.targets(command)
    for kind, opts in found:
        for key, value in opts:
            if key in ('--body', '-b'):
                yield value
            elif kind == 'api' and key in ('-f', '--raw-field', '-F', '--field'):
                field, sep, rest = value.partition('=')
                if sep and field == 'body' and not rest.startswith('@'):
                    yield rest
    for name in dict.fromkeys(helper.input_paths(found)):
        if name == '-':
            continue
        try:
            path = Path(name).expanduser()
            if not path.is_absolute():
                path = cwd / path
            with path.open('rb') as stream:
                yield stream.read(1024 * 1024).decode('utf-8', errors='replace')
        except (OSError, ValueError):
            continue


def squash(text):
    return re.sub(r'\s+', '', unicodedata.normalize('NFKC', text))


def leader_texts(transcript_path):
    texts = []
    now = time.time()
    if transcript_path:
        folder = Path(transcript_path).expanduser().parent
        for path in folder.glob('*.jsonl'):
            try:
                if now - path.stat().st_mtime > RECENT_SECONDS and str(path) != str(Path(transcript_path).expanduser()):
                    continue
                with path.open(encoding='utf-8', errors='replace') as stream:
                    for line in stream:
                        if '"user"' not in line:
                            continue
                        try:
                            entry = json.loads(line)
                        except ValueError:
                            continue
                        if entry.get('type') != 'user' or entry.get('isMeta') or entry.get('isCompactSummary'):
                            continue
                        content = (entry.get('message') or {}).get('content')
                        if isinstance(content, list):
                            content = '\n'.join(b.get('text', '') for b in content
                                                if isinstance(b, dict) and b.get('type') == 'text')
                        if isinstance(content, str) and content and not content.lstrip().startswith(NOT_LEADER):
                            texts.append(content)
            except OSError:
                continue
    wishes = Path(os.environ.get('PRTS_WISHES_DIR') or Path.home() / '.local/share/prts/wishes')
    for path in wishes.glob('*/notes.jsonl'):
        try:
            with path.open(encoding='utf-8', errors='replace') as stream:
                for line in stream:
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    if entry.get('op') == 'add' and isinstance(entry.get('text'), str):
                        texts.append(entry['text'])
        except OSError:
            continue
    return squash('\n'.join(texts))


def spoken(quote, corpus):
    parts = [squash(p) for p in ELLIPSIS.split(quote)]
    # 中身の無い「」は、引用ではなく記号の説明として書かれたもの。
    return all(p in corpus for p in parts if p)


def problems(body, corpus):
    found = []
    section = None
    item = None

    def close_item():
        if item is not None and section == LEADER_SECTION and not QUOTE.search(item[1]):
            found.append(f'- 引用の無い項目（{item[0]} 行目）: {item[1].strip()[:60]}')

    lines = body.splitlines()
    for number, line in enumerate(lines, 1):
        line = re.sub(r'`[^`]*`', '', line)
        heading = re.match(r'^(#{2,6})\s*(.*)$', line)
        if heading:
            close_item()
            item = None
            section = heading[2].strip() if len(heading[1]) >= 3 else None
            if section and section.startswith(LEADER_SECTION):
                section = LEADER_SECTION
            continue
        if section == LEADER_SECTION:
            if re.match(r'^[-*]\s', line):
                close_item()
                item = [number, line]
            elif item is not None and line.strip():
                item[1] += '\n' + line
            quotes = QUOTE.findall(line)
        else:
            quotes = NEAR_LEADER.findall(line)
            if ATTRIBUTION.search(line) and not QUOTE.search(line):
                found.append(f'- 引用符の無いリーダーの言葉（{number} 行目）: {line.strip()[:60]}')
        for quote in quotes:
            if not spoken(quote, corpus):
                found.append(f'- リーダーの発言に見つからない引用（{number} 行目）: 「{quote[:60]}」')
    close_item()
    return found


def main():
    try:
        payload = json.load(sys.stdin)
        command = payload.get('tool_input', {}).get('command')
        if not isinstance(command, str) or 'gh' not in command:
            return
        helper = load_body_time()
        if helper is None:
            return
        cwd = Path(payload.get('cwd') or Path.cwd())
        texts = [b for b in bodies(helper, command, cwd) if b.lstrip().startswith('## 決定')]
        if not texts:
            return
        corpus = leader_texts(payload.get('transcript_path'))
        if not corpus:
            return
        found = []
        for text in texts:
            found.extend(problems(text, corpus))
        if found:
            reason = GUIDANCE.format(problems='\n'.join(found[:8]))
            print(json.dumps({'hookSpecificOutput': {
                'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                'permissionDecisionReason': reason}}, ensure_ascii=False))
    except Exception:
        # 入力不備やフック自身の例外で Claude の作業を止めない。
        return


if __name__ == '__main__':
    main()
