#!/bin/sh

# resolv.confの設定
{
    echo "nameserver 8.8.8.8"
    echo "nameserver 8.8.4.4"
    echo "nameserver 1.1.1.1"
    echo "nameserver 1.0.0.1"
} >/etc/resolv.conf