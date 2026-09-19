# 再起動後に DNS 固定が効かない／socat 未導入で ssh-agent が起動失敗

自宅で実機検証して直す。出先では回線条件（v6 無し）とリセット済みで確認できない。

## 見えたこと

WSL を初期化 → フル bootstrap → `wsl --shutdown` で入り直した直後の状態で、2 点。

### 1. DNS が再起動後にトンネルへ戻る（解決＝中途状態の見間違い）

当初、再起動直後の `/etc/resolv.conf` が公開 DNS でなくトンネル（10.255.255.254）に見えた。
だが自宅でフル bootstrap →`wsl --shutdown`→入り直しを clean に済ませた状態で実機確認したところ、
正しく効いていた（2026-09-19）:
- `/etc/resolv.conf` は実ファイル（root:root 57 bytes）で中身は 1.1.1.1/8.8.8.8/1.0.0.1
- `/etc/wsl.conf` は chezmoi 実体を指し `[network] generateResolvConf = false` が入り、効いている
  （WSL 自動生成ヘッダが付かない＝WSL は resolv.conf を生成していない）
- `wsl-static-dns.service` は `inactive (dead)`。Type=oneshot が実行後に終了した正常状態
  （失敗なら failed）。resolv.conf が起動時刻に公開 DNS で書かれている＝起動時に走って書いた証拠

当初トンネルに見えたのは、フル bootstrap と clean な再起動が済む前の中途状態を見ていたため。
狙い（起動時に wsl-static-dns が公開 DNS を固定）は成立している。この項目はクローズ。
（任意の改善: oneshot に RemainAfterExit=yes を付けると status が active (exited) になり、
成功が読み取りやすくなる。機能上は不要。）

### 2. socat 未導入で bitwarden-ssh-agent が 203/EXEC 失敗（対応済み）

`socat` を `run_once_10` の基本 apt パッケージへ追加して自動導入にした（手動前提を撤去）。
再起動後に bitwarden-ssh-agent が active になるかは DNS と併せて実機で確認する。

## 見つけた場所

- `wsl.conf`（generateResolvConf=false、systemd=true）
- `wsl-static-dns.sh` / `wsl-static-dns.service` / `run_once_10`（DNS 固定）
- `run_once_99`（bitwarden-ssh-agent の enable/start）、README 前提 4（socat 手動導入）
