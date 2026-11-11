#!/bin/sh
set -eu

# WSL のページキャッシュがしきい値を超えたら捨てる（haoblackj/dotfiles#88）。
threshold_kib=${WSL_DROP_CACHES_THRESHOLD_KIB:-8388608}

cache_kib() {
    awk '
        /^Cached:/ { cached = $2 }
        /^Buffers:/ { buffers = $2 }
        /^SReclaimable:/ { reclaimable = $2 }
        /^Shmem:/ { shmem = $2 }
        END { printf "%.0f\n", cached + buffers + reclaimable - shmem }
    ' /proc/meminfo
}

before_kib=$(cache_kib)
if [ "$before_kib" -le "$threshold_kib" ]; then
    exit 0
fi

sync
echo 3 > /proc/sys/vm/drop_caches
after_kib=$(cache_kib)
printf 'dropped page cache: before=%sMiB after=%sMiB threshold=%sMiB\n' \
    "$((before_kib / 1024))" "$((after_kib / 1024))" "$((threshold_kib / 1024))"
