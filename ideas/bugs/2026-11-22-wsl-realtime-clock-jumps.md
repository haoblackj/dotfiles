# WSL のシステム時刻（CLOCK_REALTIME）が数秒ごとに前後へ飛ぶ

## 見えたこと

pre-push のテストの所要時間を測っていて気づいた（2026-11-22 22:35 JST）。

- CLOCK_REALTIME が約 5.5 秒ごとに +7.43 秒進み、約 0.27 秒後に -7.93 秒戻る。CLOCK_MONOTONIC は連続している。
- CLOCK_MONOTONIC で 40 秒の間に、CLOCK_REALTIME は 36.5 秒しか進まなかった。
- `systemd-timesyncd` は active で、`timedatectl` は `System clock synchronized: yes`。
- `bats -T` の所要時間が、走らせるたびに別の無関係なテストで 7.5 秒前後に見える。

## 見つけた場所

WSL2（Linux 6.18.33.2-microsoft-standard-WSL2）。Python の `time.time()` と `time.monotonic()` を並べて回して観測した。
