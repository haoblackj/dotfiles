---
title: WSL のシステム時刻が数秒ごとに前後へ飛ぶバグを直す
status: active
---

## 目的

WSL の CLOCK_REALTIME が約 5.5 秒ごとに +7.5 秒進んで直後に -8 秒戻る現象を、原因から直す。
時刻の飛びは、時間を測るテスト（bats の経過時間の確かめ）を不定に落とし、測った値の信頼を崩す。

- 出典: 端末からの入力（会話 e649f52f、2026-11-22 23:13、発言 756afd0c）。要旨（Claude の要約）: 見つかったバグを、どのセッションでいつ直すかを判断して実施する。
- 別のセッション（pre-push のテストを速くする作業）の Claude が、このセッションで今すぐ直すと判断して引き継いだ（SendMessage。判断は Claude の判断）。

## いまの方針

再起動（Windows も WSL も）をしない方法で直した。
時刻を書く仕組みを WSL 2.7 の chronyd 一つにまとめ（Ubuntu の timesyncd を disable）、chronyd が従う Windows の時計を `w32tm /resync` で NTP に合わせ直した。

## 判明した事実

直す前の症状は、二つの原因が組み合わさって起きていた（1 から 3 は調べた順に書いた途中の見立てを含み、確定した原因は 1 の「書き手は」以降と 2 と 5）。

1. カーネルの `tick` が 11000 になっていた（通常は 10000）。
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
5. timesyncd の disable と `w32tm /resync` の後（2026-11-23 02:2x〜02:3x、リーダーが打った）:
   - timesyncd は disabled、inactive。
   - Windows の時刻は WSL の時刻と 0.3 秒以内で一致し、どちらも NTP より 8.22 秒進んでいた（`powershell.exe` で読んだ。リーダーの許可）。WSL の chronyd が Windows の時計に合わせている、という推定はこれで裏付けられた。
   - `w32tm /query /status` は、最終の正常な同期が 02:31:29（ソース ntp.nict.jp）、ルート分散 16 秒。同期には成功したのに時計は 8 秒進んだまま。Windows Time はずれが `MaxAllowedPhaseOffset`（既定 300 秒）以下なら時計を一気に合わせず少しずつ寄せるので、そのためと読める（この PC の値も 300 秒だと、後で `w32tm /query /configuration` で確かめた）。10 分見ても -8.230 から -8.223 秒までしか寄っていない。
   - 02:37 に Windows から `w32tm /stripchart`（管理者権限なしで動く）で測ると、ntp.nict.jp へは IPv6 でも IPv4 でもタイムアウト（0x800705B4）した。time.windows.com と time.google.com には届き、ずれは -6.07 から -5.96 秒へ縮んでいた。WSL から ntp.nict.jp へは届くので、Windows から NICT への通信だけが届いていない（原因は未調査）。
   - Windows の時計の NTP に対する進みは、02:33 に約 8.2 秒、02:37 に約 6.0 秒、02:39 に約 4.4 秒（WSL との差 -3.8 秒から逆算）と縮んでいる。`w32tm /resync` の後、少しずつ寄せていると読める。WSL の時計は 02:38 でまだ 8.21 秒進んでいて、Windows に追いついていない。
6. 直し終えた後の測定（2026-11-23 02:41〜02:44）:
   - 02:41:03 に NTP とのずれが -0.79 秒になり、その 60 秒後に ntp.nict.jp、time.windows.com、time.google.com がそろって -0.12 秒前後、02:44 に -0.24 秒前後（Windows の時計が寄せている途中のゆらぎ）。
   - `time.time()` と `time.monotonic()` を 60 秒並べて段差 0 件。tick 10000。CLOCK_MONOTONIC_RAW の 10.0 秒に CLOCK_MONOTONIC も 10.0 秒。
7. 「Windows から ntp.nict.jp へ届かない」は、測るのに使った `w32tm /stripchart` の見かけだった（2026-11-23 02:5x に調べた。読み取りだけ、リーダーの指示）。
   - `w32tm /stripchart /packetinfo` で見ると、stripchart は NTP のバージョン 1 の問い合わせ（先頭のバイト 0x0b）を送る。WSL から同じバイトを送ると、ntp.nict.jp は IPv4 でも IPv6 でもバージョン 1 にだけ答えず、バージョン 2 から 4 には答える。time.google.com はバージョン 1 にも答える。
   - Windows の PowerShell から送ったバージョン 3 の問い合わせには、ntp.nict.jp も IPv4 と IPv6 の両方で答えた。Windows Time のサービス本体も 02:31:27 に ntp.nict.jp から有効な時刻を受け、02:31:29 に同期した（イベントログの id 37 と 35）。
   - Windows の時計が 8 秒ずれていた理由はイベントログにあった。この PC の Windows Time はドメインの時刻源から時刻を取る設定で、ドメインの相手を見つけられないエラー（id 129）が毎日続き、「使用可能なタイム スタンプが無いので約 86,000〜117,000 秒同期していない」（id 36）が 11/20 から毎日記録されている。何日も同期しないまま時計が進んだと読める（推定。設定そのものは管理者権限が要り読めていない）。
   - 02:58 に Windows の時計は time.google.com に対して -0.014 秒まで合っていた。
8. Windows Time の同期先の経緯（2026-11-23 03:0x に読んだ。読み取りだけ）:
   - イベントログの 14 日分: 11/18 まではドメインの階層の相手（`ntp.d`）から毎日有効な時刻を受けて同期していた。11/19 からドメインの相手を見つけられないエラー（id 129）が続き、同期は 11/23 02:31 まで一度も無かった。
   - 11/23 02:30 ごろ、リーダーが NICT へ同期する設定に変えた（出典は「判断の経緯」）。02:31 に手で指定した同期先（`ntp.m`）の `ntp.nict.jp,0x8` と同期した。
   - いまの設定（レジストリ、管理者権限なしで読んだ）: `Parameters\Type = NTP`、`NtpServer = ntp.nict.jp,0x8`、`NtpClient\Enabled = 1`、`Config\MinPollInterval = 10`、`MaxPollInterval = 15`（1,024〜32,768 秒）、`MaxPosPhaseCorrection` と `MaxNegPhaseCorrection` は 0xFFFFFFFF（ずれの大きさで補正を拒まない）、`LargePhaseOffset = 50000000`（100ns 単位で 5 秒。急なずれを外れ値として扱う閾値で、一気に合わせるかどうかは `MaxAllowedPhaseOffset` が決める）。`w32tm /query /peers` も同期先は ntp.nict.jp だけで、状態はアクティブ。
   - グループ ポリシーの W32Time のキー（`HKLM\SOFTWARE\Policies\Microsoft\W32Time` の下）は無い。ドメインのポリシーが設定を上書きする形跡は無い。
   - `w32tm /query /configuration`（2026-11-23 03:1x、リーダーが管理者の PowerShell で取って貼った）: 全部の値が「(ローカル)」で、ポリシーから来る値は無い。`Type: NTP`、`NtpServer: ntp.nict.jp,0x8`、`MaxAllowedPhaseOffset: 300`、`SpecialPollInterval: 3600`（`0x8` は特別な間隔を使わない印なので、間隔は `MinPollInterval` と `MaxPollInterval` で決まる）、`NtpServer` のプロバイダーは無効（この PC は時刻を配らない）。
9. 環境: WSL2、カーネル 6.18.33.2-microsoft-standard-WSL2、systemd 255、chrony は無い。
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

### 2026-11-23 採用: Windows Time を NICT へ直接同期させる
- 出どころ: 端末からの入力（会話 e6df2c15、2026-11-23 03:05、発言 ea5973e3）
- 要旨（Claude の要約）: 少し前に、Windows Time を NICT と同期するように設定した（リーダーが自分で設定した）。
- 理由: 理由の提示なし。
- 状態: 有効

### 2026-11-23 採用: Windows Time の同期先は NICT だけのままにし、数日イベントログを見る（案 A）
- 出どころ: 端末からの入力（会話 e6df2c15、2026-11-23 03:19、発言 f3af7539）
- 要旨（Claude の要約）: 同期先は案 A（いまのまま NICT だけ）にする。数日後にイベントログの id 35、37、129 を読み取りだけで確かめる。
- 理由: 理由の提示なし（Claude の推奨の案を選んだ）。
- 状態: 有効

### 2026-11-23 棄却: 同期先に time.google.com を足す（案 B）、ドメインの階層からの同期に戻す（案 C）
- 理由: 理由の提示なし（案 A を選んだ）。その時点の前提は、NICT へ直接同期する設定が全部ローカルの値で効いていること。数日のイベントログで NICT との同期が途絶えていたら、その事実を添えて出し直す。
- 状態: 有効

### 2026-11-22 棄却: `.wslconfig` の kernelCommandLine で `timesync_implicit=0` を渡す
- 理由: Windows 側のファイルの編集と WSL の再起動が要り、再起動しない方針に反する。
- 状態: 有効

### 2026-11-22 棄却: Windows で `w32tm /resync` してホストの時計を NTP に合わせるだけにする
- 理由: `tick` の 10% のずれが残る。Windows の時計はまたずれうるので、ゲストがホストの時刻に毎回合わせる限り再発しうる。Windows の時計のずれ自体は別の話として報告に書く。
- 状態: 有効

## いまの作業

なし（済んだ）。

## 済んだこと

- 再現と原因の特定（上の「判明した事実」）。
- `timesync_implicit` を 0 にした（2026-11-22 23:2x、リーダーの sudo）。5 秒ごとの段差は消えた。WSL を次に起動すると既定の 1 に戻るが、chronyd もホストの時計に合わせているので向きはそろう見込み。
- tick の書き手を ftrace で WSL の chronyd と突き止めた。
- timesyncd を止めて disable した（2026-11-23 02:08 と 02:28、リーダーの sudo）。段差は 0 件、進みの比は 1.000 になった。
- Windows の時計を `w32tm /resync` で直した（リーダーの管理者の PowerShell）。WSL の時刻も NTP に 0.3 秒以内で合った。
- PR #122（この作業記録）を main に squash で取り込んだ（コミット 9340666、2026-11-23 02:57、bot のアカウント）。変更はこの作業記録だけで、コードは変えていないので、コードレビューは受けていない。取り込んだ後の記録の直しは main に直接 push している（883b2d8）。取り込みを記録に書いたのは、別のセッション（pre-push のテストを速くする作業）の Claude で、依頼の出典は端末からの入力（会話 e649f52f、2026-11-23 03:04、発言 7eac6ee1）。

## 残っていること

- ほかのマシンの WSL（2.7 以降で chronyd が動くもの）でも timesyncd との奪い合いが起きうる。そのマシンでは手で disable する（chezmoi では配らない判断）。
- Windows Time が NICT と同期し続けているかの確かめ（2026-11-26 以降。段取りは「次に Claude がすること」）。設定（`Type = NTP`、`NtpServer = ntp.nict.jp,0x8`、全部ローカルの値）はリーダーが入れ済みで、案 A でそのまま使う。同じ設定を入れ直すときは、管理者の PowerShell で `w32tm /config /manualpeerlist:"ntp.nict.jp,0x8" /syncfromflags:manual /update` を打ってから `w32tm /resync` を打つ（どちらも再起動なし）。
- ドメインの相手が 11/19 から見つからない件そのものは、Windows Time とは別の、ドメインの側の問題として残る（ログオンやほかのドメインの機能に響きうる）。この作業では扱っていない。
- WSL を次に起動したとき、同じ飛びが戻らないかを測って確かめる（`timesync_implicit` が 1 に戻った状態で）。

## 次に Claude がすること

- 2026-11-26 以降に、Windows Time が NICT と同期し続けているかを読み取りだけで確かめる（案 A の判断から来る）。
  1. WSL から次を打つ（管理者権限は要らない。イベントログは読むだけ）。
     `powershell.exe -NoProfile -Command 'Get-WinEvent -FilterHashtable @{LogName="System"; ProviderName="Microsoft-Windows-Time-Service"; StartTime=[datetime]"2026-11-23 02:30"; Id=35,36,37,129} | Sort-Object TimeCreated | ForEach-Object { "{0:MM-dd HH:mm:ss} id={1} {2}" -f $_.TimeCreated,$_.Id,($_.Message -replace "\s+"," ") }' | iconv -f CP932 -t UTF-8`
  2. 見ること: (a) id 35 か 37 が ntp.nict.jp で、少なくとも 1 日に 1 回はある（同期の間隔は 1,024〜32,768 秒なので、間が 9 時間ほど空くのは正常の範囲）。(b) 02:30 より後に id 129（ドメインの相手を探す処理の失敗）が 0 件。(c) id 36（同期の途絶え）が 0 件。
  3. あわせて WSL から NTP（ntp.nict.jp、time.google.com）とのずれを測り、1 秒未満であることを見る。
  4. 出力にはドメインやホストの名前が出うるので、記録に書くときは伏せる（このリポジトリは公開）。
  5. 三つとも満たせば、結果を「判明した事実」に書き、`status: done` にする。満たさなければ、途絶えた時刻と id を添えて、棄却した案 B（二つ目を足す）か案 C（ドメインの階層に戻す）を「リーダーに決めてほしいこと」で出し直す。

## リーダーに決めてほしいこと

なし

## 答えの出た問い（記録として残す。答えは「判断の経緯」の 2026-11-23 の案 A）

- Windows Time の同期先に二つ目を足すか。いまは NICT へ直接同期する設定（`Type: NTP`、`NtpServer: ntp.nict.jp,0x8`、全部ローカルの値）がリーダーの手で入っていて、毎日の失敗（id 129 はドメインの相手を探す処理の失敗、id 36 はその結果の同期の途絶え）の元だったドメインの階層からの同期は使っていない。だから id 129 は今後出ない見込み（推定。数日のイベントログで確かめる）。案は三つ。
  - 案 A（Claude の推奨）: いまのまま NICT だけにして、数日イベントログを見る。利点は設定を変えずに済み、時刻源が一つで分かりやすいこと。欠点は NICT に届かない間は同期が止まること。
  - 案 B: 二つ目を足す（管理者の PowerShell で `w32tm /config /manualpeerlist:"ntp.nict.jp,0x8 time.google.com,0x8" /update`、再起動なし）。利点は片方が落ちても同期が続くこと。欠点は時刻源が混ざること（どちらも stratum 1 なので差は ms 以下の見込み）。
  - 案 C: ドメインの階層からの同期（`Type: NT5DS`）に戻し、ドメインの相手が見つからない原因をドメインの側で直す。利点はドメインの中で時刻がそろうこと。欠点はドメインの側の調べと直しが要り、直るまでまた同期が止まること。
  - 答えで何が変わるか: B なら Claude が案のコマンドを示し、リーダーが打つ。C ならドメインの側の調べを別の作業として始める。
  - この PC の管理者はリーダーで（管理者の PowerShell を打てている）、W32Time のポリシーのキーも無いので、会社などの管理で設定を変えてはいけない形跡は見当たらない。ドメインを誰が管理しているかは調べていない。

## 参照

- 書き置き: `ideas/bugs/2026-11-22-wsl-realtime-clock-jumps.md`（直した後に外した。中身は git の履歴にある）
- PR #120（pre-push のテストを速くする）
- PR #122（この作業記録）
- https://documentation.ubuntu.com/wsl/stable/explanation/time-sync/
