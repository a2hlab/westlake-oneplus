#!/bin/sh
# io-stress.sh MINUTES: heavy /data I/O like an app's launch-input unpack (tar of a big directory, extracted again)
# plus large fsync'd writes, in a loop. Progress in /data/local/tmp/stress/progress.txt. Runs on the phone (toybox
# sh) and needs about 3 GB free on /data:
#   hdc file send io-stress.sh /data/local/tmp/; hdc shell 'nohup sh /data/local/tmp/io-stress.sh 15 >/dev/null 2>&1 &'
# On 2026-11-19 it hung the phone (release kernel, no app running) within a minute.
D=/data/local/tmp/stress; mkdir -p $D; : > $D/progress.txt
end=$(( $(date +%s) + ${1:-15} * 60 )); i=0
while [ $(date +%s) -lt $end ]; do
  i=$((i + 1)); t0=$(date +%s)
  tar -cf $D/sys.tar -C /system lib64 2>/dev/null
  rm -rf $D/x; mkdir $D/x; tar -xf $D/sys.tar -C $D/x 2>/dev/null
  dd if=/dev/zero of=$D/big.bin bs=1M count=1024 conv=fsync 2>/dev/null
  sync; echo "$i $(date +%T) $(( $(date +%s) - t0 ))s $(du -sk $D/sys.tar | cut -f1)KB" >> $D/progress.txt
  rm -rf $D/x $D/sys.tar $D/big.bin
done
echo "done $i" >> $D/progress.txt
