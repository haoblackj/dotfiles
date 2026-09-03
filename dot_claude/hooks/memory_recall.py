#!/usr/bin/env python3
"""memory-recall: UserPromptSubmit hook.

発言と意味的に関連する保存済みメモリを検索してコンテキストに注入する。
設計: penguinEx docs/superpowers/specs/2026-07-18-memory-semantic-recall-design.md
"""
import datetime
import hashlib
import json
import math
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.request

MODEL = "@cf/baai/bge-m3"
# キャッシュの model へ書き、照合に使う値。URL には使わない。
# ベクトルの作り方を変えたら印を足して作り直しを起こす（タスク7で "#wavg1" を付ける）。
CACHE_MODEL = MODEL + "#wavg1"
THRESHOLD = 0.55
TOP_K = 3
MIN_PROMPT_CHARS = 15
MAX_PROMPT_CHARS = 2000
# 断片の大きさ。実測した最悪比率 1.0009 トークン/文字で約 6,005 トークンとなり、
# 1件あたり上限 8,192 に対して余裕 26.7%。設計9の判定にも同じ値を使う。
FRAGMENT_CHARS = 6000
BATCH_SIZE = 10  # 1リクエストの件数上限
MAX_BATCH_CHARS = 40000  # 1リクエストの合計文字数上限
# Workers AI は 1リクエストを「件数 × 最長文書」にパディングして
# 60,000トークン上限と突き合わせる（実測: 31件×8,230トークン=255,130と報告）。
# 合計文字数だけ抑えても、長い1件と短い多数が同居すると超える。
MAX_BATCH_PADDED_CHARS = 50000  # 件数 × 最長文書の文字数の上限
DEADLINE_SEC = 4.2
API_TIMEOUT_SEC = 3.0
SECRETS_PATH = os.path.expanduser(
    "~/.local/share/claude-private/secrets/cloudflare-workers-ai-token")
LOG_PATH = os.path.expanduser("~/.claude/logs/memory-recall.log")
LOG_MAX_BYTES = 5 * 1024 * 1024
LOG_GENERATIONS = 3
LOCK_PATH = LOG_PATH + ".lock"
LOCK_STALE_SEC = 60
CACHE_NAME = ".embeddings.json"
EXCLUDE = {"MEMORY.md"}


def now_stamp():
    return datetime.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")


def log_generations():
    """現行のログと退避世代のパスを新しい順に返す。存在するものだけ。"""
    paths = [LOG_PATH] + [f"{LOG_PATH}.{i}" for i in range(1, LOG_GENERATIONS + 1)]
    return [p for p in paths if os.path.exists(p)]


def acquire_rotate_lock():
    """退避用のロックを取る。取れなければ False。古いロックは奪う。"""
    for attempt in (1, 2):
        try:
            os.close(os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644))
            return True
        except FileExistsError:
            if attempt == 2:
                return False
            try:
                if time.time() - os.path.getmtime(LOCK_PATH) <= LOCK_STALE_SEC:
                    return False
                os.remove(LOCK_PATH)
            except OSError:
                return False
        except OSError:
            return False
    return False


def rotate_log_if_needed():
    """上限に達していたら世代を繰り下げる。同時実行では諦める側へ倒す。"""
    try:
        if os.path.getsize(LOG_PATH) <= LOG_MAX_BYTES:
            return
    except OSError:
        return
    if not acquire_rotate_lock():
        return
    try:
        oldest = f"{LOG_PATH}.{LOG_GENERATIONS}"
        if os.path.exists(oldest):
            os.remove(oldest)
        for i in range(LOG_GENERATIONS - 1, 0, -1):
            src = f"{LOG_PATH}.{i}"
            if os.path.exists(src):
                os.replace(src, f"{LOG_PATH}.{i + 1}")
        if os.path.exists(LOG_PATH):
            os.replace(LOG_PATH, f"{LOG_PATH}.1")
    except OSError:
        pass
    finally:
        try:
            os.remove(LOCK_PATH)
        except OSError:
            pass


def log(record):
    """1行1レコードの JSON Lines を追記する。呼び出し元を止めない。"""
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        rotate_log_if_needed()
        line = json.dumps({"ts": now_stamp(), **record}, ensure_ascii=False) + "\n"
        fd = os.open(LOG_PATH, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        try:
            os.write(fd, line.encode())
        finally:
            os.close(fd)
    except (OSError, ValueError, TypeError):
        pass


def resolve_memory_dir(transcript_path):
    # stdin由来の値は信用せず、形式検証してから使う
    base = os.path.join(os.path.expanduser("~"), ".claude", "projects") + os.sep
    if not isinstance(transcript_path, str) or not os.path.isabs(transcript_path):
        return None
    if ".." in transcript_path or not transcript_path.startswith(base):
        return None
    d = os.path.join(os.path.dirname(transcript_path), "memory")
    return d if os.path.isdir(d) else None


def normalize(vec):
    n = math.sqrt(sum(x * x for x in vec))
    if n == 0:
        return [0.0] * len(vec)
    return [round(x / n, 6) for x in vec]


def split_fragments(text):
    """文書を FRAGMENT_CHARS ごとに分ける。重なりは設けない。切り捨てもしない。"""
    if len(text) <= FRAGMENT_CHARS:
        return [text]
    return [text[i:i + FRAGMENT_CHARS]
            for i in range(0, len(text), FRAGMENT_CHARS)]


def weighted_average(vectors, weights):
    """正規化済みのベクトルを断片の文字数で重み付けして平均し、正規化して返す。

    断片ごとに索引へ載せると長い文書が枠を余分に取るため、1本へまとめる。
    """
    total = float(sum(weights)) or 1.0
    acc = [0.0] * len(vectors[0])
    for vec, w in zip(vectors, weights):
        f = w / total
        for i, x in enumerate(vec):
            acc[i] += x * f
    return normalize(acc)


def read_description(text):
    m = re.match(r"\s*---\n(.*?)\n---", text, re.S)
    if m:
        for line in m.group(1).splitlines():
            if line.strip().startswith("description:"):
                return line.split(":", 1)[1].strip().strip("\"'")
    return ""


def list_memory_files(memory_dir):
    out = {}
    for name in sorted(os.listdir(memory_dir)):
        if not name.endswith(".md") or name.startswith(".") or name in EXCLUDE:
            continue
        path = os.path.join(memory_dir, name)
        if os.path.isfile(path):
            out[name] = path
    return out


def load_cache(memory_dir):
    """(cache, reason, previous_model) を返す。書き込みの副作用は持たない。

    reason: "ok" | "absent" | "unreadable" | "model_mismatch"
    """
    empty = {"model": CACHE_MODEL, "entries": {}}
    path = os.path.join(memory_dir, CACHE_NAME)
    if not os.path.exists(path):
        return empty, "absent", None
    try:
        with open(path) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        return empty, "unreadable", None
    if not isinstance(cache, dict) or not isinstance(cache.get("entries"), dict):
        return empty, "unreadable", None
    if cache.get("model") != CACHE_MODEL:
        return empty, "model_mismatch", cache.get("model")
    return cache, "ok", None


def save_cache(memory_dir, cache):
    path = os.path.join(memory_dir, CACHE_NAME)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cache, f, ensure_ascii=False)
    os.replace(tmp, path)


def load_secrets(path=SECRETS_PATH):
    cfg = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    if "CF_ACCOUNT_ID" not in cfg or "CF_API_TOKEN" not in cfg:
        raise KeyError("CF_ACCOUNT_ID / CF_API_TOKEN missing")
    return cfg


class EmbedError(Exception):
    """埋め込み API の失敗。kind は spec 設計3の5分類。"""

    def __init__(self, kind, detail):
        super().__init__(detail.get("message") or kind)
        self.kind = kind
        self.detail = detail


def classify_http_error(e):
    """HTTPError の本文を読んで (kind, detail) を返す。

    本文を読まないと 400 の理由が分からない。事故の期間のログが
    "HTTP Error 400: Bad Request" だけだったのはこれを捨てていたため。
    """
    try:
        raw = e.read().decode("utf-8", "replace")
    except Exception:
        raw = ""
    code = None
    message = raw[:500]
    try:
        errors = (json.loads(raw) or {}).get("errors") or []
        if errors:
            code = errors[0].get("code")
            message = errors[0].get("message") or message
    except (ValueError, AttributeError):
        pass
    detail = {"http": e.code, "code": code, "message": message}
    if e.code in (401, 403):
        return "auth", detail
    if e.code == 400:
        m = re.search(r"Sequence too long:\s*(\d+)\s*>\s*(\d+)", message)
        if m:
            detail["tokens"], detail["limit"] = int(m.group(1)), int(m.group(2))
            return "document", detail
        m = re.search(r"Max context reached\s*(\d+)\s*tokens but model "
                      r"supports only\s*(\d+)", message)
        if m:
            detail["tokens"], detail["limit"] = int(m.group(1)), int(m.group(2))
            return "batch", detail
    # 5分類で閉じる。受け皿は api。
    return "api", detail


def embed_texts(texts, cfg, timeout=API_TIMEOUT_SEC):
    url = (f"https://api.cloudflare.com/client/v4/accounts/"
           f"{cfg['CF_ACCOUNT_ID']}/ai/run/{MODEL}")
    req = urllib.request.Request(
        url,
        data=json.dumps({"text": texts}).encode(),
        headers={"Authorization": f"Bearer {cfg['CF_API_TOKEN']}",
                 "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = json.load(r)
    except urllib.error.HTTPError as e:
        kind, detail = classify_http_error(e)
        raise EmbedError(kind, detail)
    except urllib.error.URLError as e:
        raise EmbedError("api", {"message": f"URLError: {e.reason}"})
    except (TimeoutError, socket.timeout) as e:
        raise EmbedError("api", {"message": f"timeout: {e}"})
    if not body.get("success"):
        raise EmbedError("api", {"message": f"workers-ai error: {body.get('errors')}"})
    return body["result"]["data"]


def make_batches(units):
    """埋め込みAPIの上限に収まるよう束を組む。

    units は (name, index, text) の並び。件数・合計文字数・パディング後文字数
    （件数×最長）の3つを同時に満たす。断片は FRAGMENT_CHARS で頭打ちなので、
    合計文字数の条件が先に効いて1リクエストは最大6断片になる。
    """
    batches = []
    cur, cur_sum, cur_max = [], 0, 0
    for item in units:
        n = len(item[2])
        nxt_max = cur_max if cur_max > n else n
        if cur and (len(cur) + 1 > BATCH_SIZE
                    or cur_sum + n > MAX_BATCH_CHARS
                    or (len(cur) + 1) * nxt_max > MAX_BATCH_PADDED_CHARS):
            batches.append(cur)
            cur, cur_sum, nxt_max = [], 0, n
        cur.append(item)
        cur_sum += n
        cur_max = nxt_max
    if cur:
        batches.append(cur)
    return batches


def process_batch(batch, cfg, deadline, collected):
    """束を埋め込む。document / batch で落ちたら割って再挑戦する。

    設計5の断片化でサイズ由来の失敗は起きなくなる見込みで、これは保険。
    成功した側の結果は捨てずに collected へ入れる。
    """
    # 再帰の入口ごとに締め切りを見る。分割の直前で1回だけ見る形にすると、
    # 深く割ったあとも締め切りを越えて呼び続ける。
    if time.monotonic() > deadline:
        return False
    try:
        vecs = embed_texts([t for _, _, t in batch], cfg)
    except EmbedError as e:
        if e.kind == "auth":
            raise
        splittable = e.kind in ("document", "batch") and len(batch) > 1
        if splittable and time.monotonic() < deadline:
            parts = 2
            if e.kind == "batch" and e.detail.get("tokens") and e.detail.get("limit"):
                parts = max(2, -(-e.detail["tokens"] // e.detail["limit"]))
            size = max(1, len(batch) // parts)
            ok = True
            for i in range(0, len(batch), size):
                ok = process_batch(batch[i:i + size], cfg, deadline, collected) and ok
            return ok
        rec = {"stage": "index", "kind": e.kind, **e.detail}
        # api は特定のファイルに紐づかない扱いなので target を付けない。
        # 付けると健診が「欠けていないファイル宛」として捨て、報告から消える。
        if e.kind in ("document", "batch"):
            if len(batch) == 1:
                name, idx, text = batch[0]
                rec["target"] = name
                rec["fragment"] = idx
                rec["span"] = [idx * FRAGMENT_CHARS,
                               idx * FRAGMENT_CHARS + len(text)]
            else:
                rec["target"] = sorted({n for n, _, _ in batch})
        log(rec)
        return False
    except Exception as e:
        # api は target を持たない（spec のログ形式）
        log({"stage": "index", "kind": "api",
             "message": f"{type(e).__name__}: {e}"})
        return False
    for (name, i, _), vec in zip(batch, vecs):
        collected.setdefault(name, {})[i] = normalize(vec)
    return True


def update_index(memory_dir, cache, cfg, deadline):
    """索引を更新する。確定はファイル単位で、全断片が揃ったものだけ書き込む。"""
    files = list_memory_files(memory_dir)
    entries = cache["entries"]
    changed = False

    # 消えたファイルの項目を取り除く。これだけでも保存する経路になる。
    for name in list(entries):
        if name not in files:
            del entries[name]
            changed = True

    pending = []
    for name, path in files.items():
        try:
            with open(path, "rb") as f:
                raw = f.read()
        except OSError as e:
            log({"stage": "index", "kind": "local", "target": name,
                 "message": f"read failed: {e}"})
            continue
        h = hashlib.sha256(raw).hexdigest()
        if entries.get(name, {}).get("hash") == h:
            continue
        text = raw.decode("utf-8", errors="replace")
        frags = split_fragments(text)
        pending.append({"name": name, "hash": h,
                        "description": read_description(text) or name,
                        "frags": frags})

    # 極端に長い1件が締め切りを食い潰さないよう、短いものから処理する。
    pending.sort(key=lambda p: sum(len(f) for f in p["frags"]))

    meta = {p["name"]: p for p in pending}
    units = [(p["name"], i, frag)
             for p in pending for i, frag in enumerate(p["frags"])]

    collected = {}
    hit_deadline = False
    stopped = False
    for batch in make_batches(units):
        if time.monotonic() > deadline:
            hit_deadline = True
            break
        try:
            process_batch(batch, cfg, deadline, collected)
        except EmbedError as e:
            # auth だけがここへ来る。鍵が直るまで何度試しても失敗するので打ち切る。
            # auth は target を持たない（spec のログ形式）
            log({"stage": "index", "kind": e.kind, **e.detail})
            stopped = True
            break

    # 全断片が揃ったファイルだけを確定する。
    # 欠けたまま平均を保存すると、ハッシュが一致するせいで二度と直らない。
    written = 0
    for name, got in collected.items():
        info = meta[name]
        if len(got) != len(info["frags"]):
            continue
        vectors = [got[i] for i in sorted(got)]
        weights = [len(f) for f in info["frags"]]
        entries[name] = {"hash": info["hash"], "description": info["description"],
                         "vector": weighted_average(vectors, weights)}
        changed = True
        written += 1

    if hit_deadline:
        log({"kind": "partial", "done": written,
             "pending": len(pending) - written})

    if changed:
        try:
            save_cache(memory_dir, cache)
        except OSError as e:
            log({"stage": "index", "kind": "local", "target": CACHE_NAME,
                 "message": f"cache save failed: {e}"})
            return False
    return not (hit_deadline or stopped) and written == len(pending)


def top_matches(qvec, entries, threshold=THRESHOLD, k=TOP_K):
    scored = []
    for name, e in entries.items():
        v = e.get("vector") or []
        if len(v) != len(qvec):
            continue
        s = sum(a * b for a, b in zip(qvec, v))
        if s >= threshold:
            scored.append((s, name, e.get("description", "")))
    scored.sort(reverse=True)
    return scored[:k]


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError as e:
        log({"stage": "startup", "kind": "local", "message": f"bad stdin payload: {e}"})
        return
    prompt = payload.get("prompt") or ""
    if not isinstance(prompt, str) or len(prompt) < MIN_PROMPT_CHARS:
        return
    memory_dir = (os.environ.get("MEMORY_RECALL_DIR")
                  or resolve_memory_dir(payload.get("transcript_path")))
    if not memory_dir or not os.path.isdir(memory_dir):
        return
    deadline = time.monotonic() + DEADLINE_SEC
    try:
        cfg = load_secrets(os.environ.get("MEMORY_RECALL_SECRETS") or SECRETS_PATH)
    except (OSError, KeyError) as e:
        log({"stage": "startup", "kind": "auth", "message": f"secrets unavailable: {e}"})
        return

    # 1. キャッシュを読む
    cache, reason, previous_model = load_cache(memory_dir)

    # 2. 捨てていたら空のキャッシュを保存し、model_mismatch なら migration を記録する。
    #    3 が失敗して早期終了する回でも済ませるため、想起より前に置く。
    if reason in ("unreadable", "model_mismatch"):
        if reason == "unreadable":
            log({"stage": "startup", "kind": "local", "target": CACHE_NAME,
                 "message": "cache unreadable; rebuilding"})
        # 件数は try の外で取る。中に入れると、ディレクトリの読み取り失敗が
        # "cache save failed" という誤ったメッセージで記録される。
        try:
            pending_count = len(list_memory_files(memory_dir))
        except OSError:
            pending_count = None
        try:
            save_cache(memory_dir, cache)
            if reason == "model_mismatch":
                log({"kind": "migration", "from": previous_model, "to": CACHE_MODEL,
                     "pending": pending_count})
        except OSError as e:
            # 保存に失敗しても想起は止めない（目標1）
            log({"stage": "startup", "kind": "local", "target": CACHE_NAME,
                 "message": f"cache save failed: {e}"})

    # 3. 発言を埋め込む
    try:
        qvec = normalize(embed_texts([prompt[:MAX_PROMPT_CHARS]], cfg)[0])
    except EmbedError as e:
        log({"stage": "query", "kind": e.kind, **e.detail})
        return
    except Exception as e:
        log({"stage": "query", "kind": "api",
             "message": f"{type(e).__name__}: {e}"})
        return

    # 4. 想起を出力する
    matches = top_matches(qvec, cache["entries"])
    if matches:
        lines = ["[memory-recall] この発言に関連しそうな保存済みメモリ:"]
        for s, name, desc in matches:
            lines.append(f"- {os.path.join(memory_dir, name)} — {desc} (類似度{s:.2f})")
        lines.append("必要ならReadで本文を確認すること。")
        print("\n".join(lines))

    # 5. 残り時間で索引を更新する。ここで何が起きても想起は既に返っている。
    try:
        update_index(memory_dir, cache, cfg, deadline)
    except Exception as e:
        log({"stage": "index", "kind": "api",
             "message": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # 最後の砦: どんな失敗でも会話を止めない
        log({"stage": "startup", "kind": "local", "message": f"unexpected: {type(e).__name__}: {e}"})
    sys.exit(0)
