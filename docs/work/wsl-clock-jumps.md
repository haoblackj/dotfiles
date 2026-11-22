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
WSL の中で二つのカーネルの設定を実行中に戻す（sudo が要るのでリーダーが別の端末で打つ。`!` の欄では sudo のパスワードを読めない）。
`timesync_implicit` は戻せた。`tick` は書き戻されるので、書き手を探している。
戻したら、引き継ぎで使ったのと同じ並べ方（`time.time()` と `time.monotonic()` を並べて回す）で飛びが消えたことを確かめる。

## 判明した事実

原因は二つあり、組み合わさって今の症状になっている。

1. カーネルの `tick` が 11000 になっている（通常は 10000）。
   - 根拠: `adjtimex`（読み取りだけ）で `tick 11000`。CLOCK_MONOTONIC_RAW の 9.092 秒の間に CLOCK_MONOTONIC が 10.002 秒進んだ（比 1.100）。
   - 1 tick ごとに 11ms 進めるので、CLOCK_MONOTONIC と CLOCK_REALTIME の進み方が実際より 10% 速い。NTP サーバ（ntp.nict.jp）と比べても、段差の間の時計は 0.53 秒ごとに約 0.048 秒ずつ先行した。
   - 誰が設定したかは分からない。この distro に adjtimex、chrony、ntpd は無く、コンテナは特権も CAP_SYS_TIME も持たず、過去の Claude の会話の記録にも設定した跡が無い。
   - 2026-11-22 23:2x に sudo で 10000 に戻すと一時は 10000 と読めたが、35 秒後の測定では CLOCK_MONOTONIC が RAW の 1.10 倍のままで、数分後には 11000 に戻っていた。何かが繰り返し 11000 を書いている。「一度書かれて残っているだけ」という最初の見立ては外れた。
   - 書き手は別の distro の chronyd と確定した。ftrace の instance で時刻を書くシステムコールを 90 秒記録すると（2026-11-23 00:3x、リーダーの sudo）、tick が 10000 から 11000 に戻った瞬間（mono 1096786.610）の 1ms 前に `chronyd`（PID 185）が `clock_adjtime` を呼んでいた。chronyd は約 8 秒ごとに `clock_adjtime` を 4 回ずつ呼び続け、timesyncd は 32 秒ごとに 1 回呼んでいた。この distro の PID 185 は別のプロセスで、chrony も入っていないので、chronyd は同じカーネルを共有する別の WSL の distro（別の PID の名前空間）で動いている。
   - chrony は周波数の補正が 500ppm を超えると tick を上限の ±10% まで動かす。timesyncd が時計を戻し続けるので、chronyd は時計が遅れ続けていると見て tick を上限の 11000 に張り付かせている、と読める（推定）。
   - この chronyd は WSL 自身のもの。動いている distro は Ubuntu だけで（`wsl.exe -l -v`）、Ubuntu の中にも、Ubuntu より上の名前空間が見える system distro（Azure Linux 3.0）の中にも chronyd のプロセスは見えない。ftrace の PID はカーネル全体の番号なので、chronyd は WSL の VM の最上位で動いていると読める。system distro には `/etc/chrony.conf`（`server time.windows.com`、`makestep 1.0 3`、`rtcsync`）と `/usr/sbin/chronyd` がある。WSL 2.7.11.0。
   - つまり、この Ubuntu の systemd-timesyncd（ntp.ubuntu.com）と WSL の chronyd（time.windows.com）の二つの NTP のデーモンが同じ時計を書き合っている。timesyncd は Ubuntu の WSL 用の drop-in（`/usr/lib/systemd/system/systemd-timesyncd.service.d/wsl.conf`）で WSL でも有効になっている。
2. Hyper-V の時刻同期と systemd-timesyncd が、5 秒ごとに別々の時刻を書き合っている。
   - `hv_utils` の `timesync_implicit` が Y で、ホスト（Windows）が 5 秒ごとに送る時刻の標本でゲストの時計を書き換える。WSL の時計が 10% 速いので、ゲストの時間では約 5.5 秒ごとになる。
   - 書き換えられた直後、timesyncd が時計の変更を検知して NTP に問い合わせ、約 0.27 秒後に -8 秒戻す。根拠: `timedatectl timesync-status` が毎回 `Offset: -7.99s` を示し、timesyncd の起動（19:26）からの送信 2777 回が段差の回数の見積もり（約 2550 回）とほぼ合う。journald と systemd-resolved も 5 秒ごとに時計の変更を記録している。
   - ここから、ホストの時計は NTP より約 8 秒進んでいると読める（推定。Windows 側の時刻は直接は測っていない）。
   - `/sys/module/hv_utils/parameters/timesync_implicit` は 644 で、root なら実行中に書き換えられる。WSL はカーネルの起動引数で `hv_utils.timesync_implicit=1` を明示して渡している（`/proc/cmdline`）。
   - 2026-11-22 23:2x に 0 にした後は、5 秒ごとの +7.5/-8 秒の段差が消え、timesyncd が 32 秒ごとに -2.96 秒戻す段差だけになった（tick が 11000 のままなので、32 秒で約 3 秒先行する）。
3. 二つ目だけを直しても、一つ目が残ると timesyncd は 10% のずれ（slew の上限 500ppm を超える）を段差で直すしかなく、約 32 秒ごとに数秒の段差が残る見込み。一つ目だけを直しても、ホストと NTP の 8 秒の差の綱引きが続く。両方を直す。
4. timesyncd を止めた結果（2026-11-23 02:08 に `systemctl stop`、リーダーの sudo）:
   - 止めた直後から 10 分、30 秒ずつ 20 回測って時刻の段差は 0 件。chronyd は tick を 11000 から 10834 を経て、約 2 分後（02:10:58）に 10000 へ戻した。周波数の補正は -0.3ppm 前後。
   - CLOCK_MONOTONIC_RAW の 10.0 秒に CLOCK_MONOTONIC も 10.0 秒（比 1.000）。
   - ただし時計は NTP より 8.23 秒進んだまま安定した（ntp.nict.jp、time.windows.com、ntp.ubuntu.com、time.google.com、time.cloudflare.com の五つがそろって -8.23 秒）。chronyd の設定の `server time.windows.com` とも合っていないので、chronyd は実際には Windows のホストの時計（Hyper-V の PTP など）に合わせていて、そのホストの時計が NTP より約 8.2 秒進んでいる、と読める（推定。VM の最上位の chronyd の設定と状態は、どの distro からも読めない）。
5. 環境: WSL2、カーネル 6.18.33.2-microsoft-standard-WSL2、systemd 255、chrony は無い。
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

### 2026-11-23 採用: Ubuntu の timesyncd を止め、時刻を書く NTP のデーモンを WSL の chronyd 一つにする（まず stop で試す）
- 出どころ: Claude の判断
- 理由: WSL の chronyd は WSL の部品で VM の最上位で動き、Ubuntu からは止められない。timesyncd は止めても再起動は要らず、`systemctl start` で戻せる。
- 状態: 有効

### 2026-11-23 採用: このマシンで timesyncd を disable し、Windows の時計は w32tm で直す
- 出どころ: 質問のツールへの答え（会話 e6df2c15、2026-11-23 02:2x。`prts quote` では原文未確認）
- 要旨（Claude の要約）: timesyncd はこのマシンでだけ disable する（chezmoi で全マシンに配る案は選ばなかった）。Windows の時計の約 8.2 秒のずれは、リーダーが管理者の PowerShell の `w32tm /resync` で直す。
- 理由: 理由の提示なし（Claude の推奨の案を選んだ）。
- 状態: 有効

### 2026-11-22 棄却: `.wslconfig` の kernelCommandLine で `timesync_implicit=0` を渡す
- 理由: Windows 側のファイルの編集と WSL の再起動が要り、再起動しない方針に反する。
- 状態: 有効

### 2026-11-22 棄却: Windows で `w32tm /resync` してホストの時計を NTP に合わせるだけにする
- 理由: `tick` の 10% のずれが残る。Windows の時計はまたずれうるので、ゲストがホストの時刻に毎回合わせる限り再発しうる。Windows の時計のずれ自体は別の話として報告に書く。
- 状態: 有効

## いまの作業

`tick` を 11000 に書き戻している者を探している。
Ubuntu の timesyncd を止めて、時刻を書く NTP のデーモンを WSL の chronyd 一つにした。時刻の段差は消え、時計の進みも正しくなった。
リーダーが timesyncd を disable し、Windows の時計を `w32tm /resync` で直すのを待っている。バックグラウンドの監視が両方を検出したら、NTP とのずれと時刻の段差を測り直す。

## 済んだこと

- 再現と原因の特定（上の「判明した事実」）。
- `timesync_implicit` を 0 にした（2026-11-22 23:2x、リーダーの sudo）。5 秒ごとの段差は消えた。
- tick の書き手を ftrace で WSL の chronyd と突き止めた。
- timesyncd を止めた（2026-11-23 02:08、`stop` だけ）。段差は 0 件、進みの比は 1.000 になった。

## 残っていること

- timesyncd の disable（リーダーの sudo）。
- Windows の時計の `w32tm /resync`（リーダーの管理者の PowerShell）。WSL の時刻はいま Windows の時計に合わせていて、NTP より 8.23 秒進んでいる。
- 直した後の測り直し。
- ほかのマシンの WSL（2.7 以降で chronyd が動くもの）でも timesyncd との奪い合いが起きうる。そのマシンでは手で disable する（chezmoi では配らない判断）。
- `timesync_implicit` は、chronyd もホストの時計に合わせているので、次の起動で既定の 1 に戻っても両者の向きはそろう見込み。0 を保つ仕組みは置かない案に変えた（前の問いは取り下げ）。

## 次に Claude がすること

- 下の二つの問いの答えに沿って進める。
- 結果の要約を、引き継いだ送り手のセッションへ SendMessage で返す。
- 書き手を止めたら、`time.time()` と `time.monotonic()` を 30 秒並べて段差が 0 件、CLOCK_MONOTONIC と RAW の比が 1.000 に近く、NTP とのずれが数十 ms に収まることを確かめる。結果をここに書いて送り手のセッションへ返す。

## リーダーに決めてほしいこと

- timesyncd を次の起動でも止めたままにするか。Claude の案: `sudo systemctl disable systemd-timesyncd` で止めたままにする。利点は WSL 2.7 の chronyd との奪い合いが次の起動でも戻らないこと。欠点は WSL の時刻が NTP でなく Windows の時計に従うことと、ほかのマシンの WSL では手で同じことをする必要があること（chezmoi で配るなら sudo の要る run_once スクリプトになる）。答えで何が変わるか: 止めたままにしなければ、次の起動で同じ飛びが戻る。
- Windows の時計の約 8.2 秒のずれを直すか。Claude の案: 管理者の PowerShell で `w32tm /resync` を打つ（再起動は要らない）。利点は WSL の時刻も NTP に合うこと。欠点は Windows 側の操作になること。答えで何が変わるか: 直さなければ、WSL の時刻は進みは正しいが、絶対の時刻が 8 秒ほど進んだままになる（経過時間を測るテストには影響しない）。

## 参照

- 書き置き: `ideas/bugs/2026-11-22-wsl-realtime-clock-jumps.md`（PR #120 のブランチ）
- PR #120（pre-push のテストを速くする）
- https://documentation.ubuntu.com/wsl/stable/explanation/time-sync/
