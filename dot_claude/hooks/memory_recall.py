#!/usr/bin/env python3
"""memory-recall: UserPromptSubmit hook.

発言と意味的に関連する保存済みメモリを検索してコンテキストに注入する。
設計: penguinEx docs/superpowers/specs/2026-07-18-memory-semantic-recall-design.md
"""
import hashlib
import json
import math
import os
import re
import sys
import time
import urllib.request

MODEL = "@cf/baai/bge-m3"
THRESHOLD = 0.5
TOP_K = 3
MIN_PROMPT_CHARS = 15
MAX_PROMPT_CHARS = 2000
MAX_DOC_CHARS = 20000  # 本文全文が原則。異常に長いファイルだけ抑える安全弁
BATCH_SIZE = 10
DEADLINE_SEC = 4.2
RESERVE_FOR_QUERY_SEC = 1.2
API_TIMEOUT_SEC = 3.0
SECRETS_PATH = os.path.expanduser(
    "~/.local/share/claude-private/secrets/cloudflare-workers-ai-token")
LOG_PATH = os.path.expanduser("~/.claude/logs/memory-recall.log")
LOG_MAX_BYTES = 5 * 1024 * 1024
CACHE_NAME = ".embeddings.json"
EXCLUDE = {"MEMORY.md"}


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > LOG_MAX_BYTES:
            open(LOG_PATH, "w").close()
        with open(LOG_PATH, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}\n")
    except OSError:
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
    path = os.path.join(memory_dir, CACHE_NAME)
    try:
        with open(path) as f:
            cache = json.load(f)
        if (not isinstance(cache, dict)
                or cache.get("model") != MODEL
                or not isinstance(cache.get("entries"), dict)):
            raise ValueError("model mismatch or bad shape")
        return cache
    except (OSError, ValueError):
        return {"model": MODEL, "entries": {}}


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
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = json.load(r)
    if not body.get("success"):
        raise RuntimeError(f"workers-ai error: {body.get('errors')}")
    return body["result"]["data"]


def update_index(memory_dir, cache, cfg, deadline):
    files = list_memory_files(memory_dir)
    entries = cache["entries"]
    changed = False
    for name in list(entries):
        if name not in files:
            del entries[name]
            changed = True
    pending = []
    for name, path in files.items():
        with open(path, "rb") as f:
            raw = f.read()
        h = hashlib.sha256(raw).hexdigest()
        if entries.get(name, {}).get("hash") != h:
            text = raw.decode("utf-8", errors="replace")
            desc = read_description(text) or name
            pending.append((name, h, desc, text[:MAX_DOC_CHARS]))
    done_all = True
    try:
        for i in range(0, len(pending), BATCH_SIZE):
            if time.monotonic() > deadline - RESERVE_FOR_QUERY_SEC:
                done_all = False
                break
            batch = pending[i:i + BATCH_SIZE]
            vecs = embed_texts([t for _, _, _, t in batch], cfg)
            for (name, h, desc, _), vec in zip(batch, vecs):
                entries[name] = {"hash": h, "description": desc,
                                 "vector": normalize(vec)}
            changed = True
    finally:
        if changed:
            save_cache(memory_dir, cache)
    return done_all
