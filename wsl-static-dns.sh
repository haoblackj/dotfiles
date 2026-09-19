#!/bin/sh

# WSL の /etc/resolv.conf を公開 DNS に固定する。
# dnsTunneling（トンネル）は Mirrored 環境で断続的に名前解決を落とす既知バグ
# （microsoft/WSL #41595）があるため、トンネルに依存せず公開リゾルバへ直接引く。
# nameserver は glibc の MAXNS=3 で先頭 3 つまでしか使われないので 3 つに絞る。
# 全て IPv4。v6 なし回線でも到達でき、v4 サーバでも AAAA レコードは返るので v6 の結果は失わない。
# 恒久化は wsl-static-dns.service（毎起動で実行）。generateResolvConf=false で WSL の上書きを止める。
# トレードオフ: 自宅 LAN の DNS を見ないので WSL から自宅ホスト名は引けない（IP 直打ちで代替）。
rm -f /etc/resolv.conf
{
    echo "nameserver 1.1.1.1"
    echo "nameserver 8.8.8.8"
    echo "nameserver 1.0.0.1"
} >/etc/resolv.conf
