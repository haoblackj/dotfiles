# test_memory_recall.py の test_does_not_write がファイルを閉じず ResourceWarning を出す

## 見えたこと

2026-10-13 に dotfiles の main へ push したとき、pre-push の pytest で `dot_claude/hooks/tests/test_memory_recall.py::TestLoadCacheReason::test_does_not_write` から `PytestUnraisableExceptionWarning`（中身は `ResourceWarning: unclosed file <_io.TextIOWrapper name='/tmp/.../.embeddings.json'>`）が2件出た。
テスト自体は通っている（119 passed, 2 warnings）。

## 見つけた場所

`dot_claude/hooks/tests/test_memory_recall.py` の 447 行（`before = open(path).read()`）と 449 行（`self.assertEqual(open(path).read(), before)`）。
