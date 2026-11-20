#!/bin/sh
# mem-stress.sh [GB [MINUTES]]: touches a lot of physical memory without storage I/O: fills a tmpfs with GB (default
# 3) gigabytes of zeros, drops it, again and again for MINUTES (default 10). Progress (fill, time, MemAvailable) in
# /data/local/tmp/memstress.txt, "done N" at the end. Runs on the phone (toybox sh) as root; the tmpfs is mounted on
# /data/local/tmp/memtest with GB + 1 GB room and unmounted at the end:
#   hdc file send mem-stress.sh /data/local/tmp/; hdc shell 'nohup sh /data/local/tmp/mem-stress.sh 3 10 >/dev/null 2>&1 &'
# Without kernel 0011 (the reserved-memory map) it hung the phone within about 30 s; with it, `mem-stress.sh 4 10`
# ran its 10 minutes (193 fills). See docs/hang-2026-11-19.md.
M=/data/local/tmp/memtest; P=/data/local/tmp/memstress.txt; mkdir -p $M; : > $P
mount -t tmpfs -o size=$(( ${1:-3} + 1 ))G tmpfs $M || { echo "mount failed" >> $P; exit 1; }
end=$(( $(date +%s) + ${2:-10} * 60 )); i=0
while [ $(date +%s) -lt $end ]; do
  i=$((i + 1)); dd if=/dev/zero of=$M/fill bs=1M count=$(( ${1:-3} * 1024 )) 2>/dev/null
  echo "$i $(date +%T) $(grep MemAvailable /proc/meminfo | sed 's/  */ /g')" >> $P; rm -f $M/fill
done
umount $M; echo "done $i" >> $P
