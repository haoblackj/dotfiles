---
title: WSL のシステム時刻が数秒ごとに前後へ飛ぶバグを直す
status: waiting
---

## 目的

WSL の CLOCK_REALTIME が約 5.5 秒ごとに +7.5 秒進んで直後に -8 秒戻る現象を、原因から直す。
時刻の飛びは、時間を測るテスト（bats の経過時間の確かめ）を不定に落とし、測った値の信頼を崩す。

- 出典: 端末からの入力（会話 e649f52f、2026-11-22 23:13、発言 756afd0c）。要旨（Claude の要約）: 見つかったバグを、どのセッションでいつ直すかを判断して実施する。
- 別のセッション（pre-push のテストを速くする作業）の Claude が、このセッションで今すぐ直すと判断して引き継いだ（SendMessage。判断は Claude の判断）。

## いまの方針

再起動（Windows も WSL も）をしない方法で直す。
WSL の中で二つのカーネルの設定を実行中に戻す（sudo が要るのでリーダーが打つ）。
戻したら、引き継ぎで使ったのと同じ並べ方（`time.time()` と `time.monotonic()` を並べて回す）で飛びが消えたことを確かめる。

## 判明した事実

原因は二つあり、組み合わさって今の症状になっている。

1. カーネルの `tick` が 11000 になっている（通常は 10000）。
   - 根拠: `adjtimex`（読み取りだけ）で `tick 11000`。CLOCK_MONOTONIC_RAW の 9.092 秒の間に CLOCK_MONOTONIC が 10.002 秒進んだ（比 1.100）。
   - 1 tick ごとに 11ms 進めるので、CLOCK_MONOTONIC と CLOCK_REALTIME の進み方が実際より 10% 速い。NTP サーバ（ntp.nict.jp）と比べても、段差の間の時計は 0.53 秒ごとに約 0.048 秒ずつ先行した。
   - 誰が設定したかは分からない。この distro に adjtimex、chrony、ntpd は無く、コンテナは特権も CAP_SYS_TIME も持たず、過去の Claude の会話の記録にも設定した跡が無い。`tick` は一度書かれると VM が止まるまで残る（VM は 2026-11-10 から動いている）。
2. Hyper-V の時刻同期と systemd-timesyncd が、5 秒ごとに別々の時刻を書き合っている。
   - `hv_utils` の `timesync_implicit` が Y で、ホスト（Windows）が 5 秒ごとに送る時刻の標本でゲストの時計を書き換える。WSL の時計が 10% 速いので、ゲストの時間では約 5.5 秒ごとになる。
   - 書き換えられた直後、timesyncd が時計の変更を検知して NTP に問い合わせ、約 0.27 秒後に -8 秒戻す。根拠: `timedatectl timesync-status` が毎回 `Offset: -7.99s` を示し、timesyncd の起動（19:26）からの送信 2777 回が段差の回数の見積もり（約 2550 回）とほぼ合う。journald と systemd-resolved も 5 秒ごとに時計の変更を記録している。
   - ここから、ホストの時計は NTP より約 8 秒進んでいると読める（推定。Windows 側の時刻は直接は測っていない）。
   - `/sys/module/hv_utils/parameters/timesync_implicit` は 644 で、root なら実行中に書き換えられる。
3. 二つ目だけを直しても、一つ目が残ると timesyncd は 10% のずれ（slew の上限 500ppm を超える）を段差で直すしかなく、約 32 秒ごとに数秒の段差が残る見込み。一つ目だけを直しても、ホストと NTP の 8 秒の差の綱引きが続く。両方を直す。
4. 環境: WSL2、カーネル 6.18.33.2-microsoft-standard-WSL2、systemd 255、chrony は無い。
5. Ubuntu の WSL の文書は、ゲストで NTP を使うときに `hv_utils.timesync_implicit=0` を勧めている（https://documentation.ubuntu.com/wsl/stable/explanation/time-sync/ ）。

## 判断の経緯

### 2026-11-22 採用: 再起動しない方法で直す
- 出どころ: 端末からの入力（会話 e6df2c15、2026-11-22 23:19、発言 9a2f3575）
- 要旨（Claude の要約）: Windows 側が原因でも、Windows と WSL のどちらも再起動しない方法での修正を強く望む。
- 理由: 理由の提示なし（WSL の再起動はほかのセッションも止める）。
- 状態: 有効

### 2026-11-22 採用: WSL の中で `tick` を 10000 に戻し、`timesync_implicit` を 0 にする
- 出どころ: Claude の判断
- 理由: どちらも再起動なしで効き、Windows 側に触らない。時刻の基準を NTP（timesyncd）一本にすると、ホストの時計の誤差に引きずられない。`timesync_implicit=0` でも、スリープからの復帰でホストが送る同期の指示（ICTIMESYNCFLAG_SYNC）は効く。
- 状態: 有効

### 2026-11-22 棄却: `.wslconfig` の kernelCommandLine で `timesync_implicit=0` を渡す
- 理由: Windows 側のファイルの編集と WSL の再起動が要り、再起動しない方針に反する。
- 状態: 有効

### 2026-11-22 棄却: Windows で `w32tm /resync` してホストの時計を NTP に合わせるだけにする
- 理由: `tick` の 10% のずれが残る。Windows の時計はまたずれうるので、ゲストがホストの時刻に毎回合わせる限り再発しうる。Windows の時計のずれ自体は別の話として報告に書く。
- 状態: 有効

## いまの作業

リーダーが sudo で二つの設定を戻すのを、背景の監視で待っている。
戻ったと見えたら、同じ並べ方の測定で飛びが消えたことを確かめる。

## 済んだこと

- 再現と原因の特定（上の「判明した事実」）。

## 残っていること

- 二つの設定を戻す（リーダーの sudo）。
- 測定で飛びが消えたことを確かめる。
- WSL を次に起動したときにも `timesync_implicit=0` を保つか（下の問い）。`tick` は起動のたびに 10000 に戻るので、保つ仕組みは要らない（設定した者が再び動かない限り）。

## 次に Claude がすること

- 監視が二つの設定の変化を検出したら、`time.time()` と `time.monotonic()` を 30 秒並べて段差が 0 件、両者の進みの比が 1.000 に近いことを確かめ、NTP とのずれが数十 ms に収まることも見る。結果をここに書いて送り手のセッションへ返す。

## リーダーに決めてほしいこと

- WSL を次に起動したときにも `timesync_implicit=0` を保つ仕組みを置くか。Claude の案: 置く。chezmoi の `run_onchange` スクリプトで `/etc/tmpfiles.d/` に一行（`w /sys/module/hv_utils/parameters/timesync_implicit - - - - 0`）を配る。利点は再起動を待たずに入れられ、次の起動から自動で効くこと。欠点は常設の仕組みが一つ増え、配るときに sudo が要ること。答えで何が変わるか: 置かなければ、WSL を次に起動したとき、ホストの時計が NTP とずれていれば同じ綱引きが戻る。

## 参照

- 書き置き: `ideas/bugs/2026-11-22-wsl-realtime-clock-jumps.md`（PR #120 のブランチ）
- PR #120（pre-push のテストを速くする）
- https://documentation.ubuntu.com/wsl/stable/explanation/time-sync/
