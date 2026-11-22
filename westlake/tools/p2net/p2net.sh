#!/bin/bash
# p2net.sh up | down [--pc] | status: a network for a phone without Wi-Fi, through the PC (README, "A phone
# without Wi-Fi"). Path:
#   phone eth0 (tapfwd: a TAP interface) -> 127.0.0.1:PORT on the phone -> hdc rport over USB -> Windows
#   localhost:PORT -> WSL localhost forwarding -> bridge.py -> passt (user-space NAT + DHCP + DNS) -> the PC's network
# OH's EthernetManager adopts any interface named (eth|usb)<n>, runs DHCP on it and registers it as a network
# (NetConnManager's HTTP probe then marks it validated); Westlake reports it to apps as TYPE_ETHERNET.
#
#   up      start what is missing (PC side, rport, tapfwd on the phone); safe to repeat. Run it after every boot of
#           the phone and every WSL start: nothing of it persists on either side.
#   down    stop tapfwd (eth0 goes, OH drops the network) and remove the rport; --pc: also stop passt and the bridge
#   status  one screen of state
#
# Settings (environment or westlake/local.sh):
#   P2NET_TARGET   hdc target of the phone (required)   P2NET_SERIAL  its boot serial, ohos.boot.sn (required):
#                  every action checks it first, so the tunnel never lands on another device
#   P2NET_BUILD    build.sh's output: tapfwd, passt-root/ (required)
#   P2NET_PORT     39921        P2NET_MAC  locally administered, from the boot serial (02:<serial>:01)
#   P2NET_RUN      /dev/shm/p2net-run: socket, pids, logs (in RAM: the tunnel keeps going if the work disk drops)
set -u
D=$(cd "$(dirname "$0")" && pwd)
. "$D/../../config.sh" >/dev/null 2>&1
T=${P2NET_TARGET:?set P2NET_TARGET (the phone hdc target)}
SN=${P2NET_SERIAL:?set P2NET_SERIAL (the phone boot serial)}
B=${P2NET_BUILD:?set P2NET_BUILD (tools/p2net/build.sh output)}
RUN=${P2NET_RUN:-/dev/shm/p2net-run}
PORT=${P2NET_PORT:-39921}
if [ -z "${P2NET_MAC:-}" ]; then
  [[ $SN =~ ^[0-9a-f]{8}$ ]] || { echo "p2net: set P2NET_MAC (boot serial $SN is not 8 hex digits)" >&2; exit 2; }
  P2NET_MAC="02:${SN:0:2}:${SN:2:2}:${SN:4:2}:${SN:6:2}:01"
fi
HDC_BIN=${WL_HDC:-${HDC:?no hdc (westlake/local.sh)}}
BIN=/data/local/tmp/tapfwd
mkdir -p "$RUN"

h() { (cd /mnt/c 2>/dev/null || cd /; timeout 60 "$HDC_BIN" -t "$T" "$@" </dev/null 2>&1 | tr -d '\r'); }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
win_path() { if [[ $HDC_BIN == *.exe ]] || [ -n "${HDC_EXE:-}" ]; then wslpath -w "$(readlink -f "$1")"; else readlink -f "$1"; fi; }

check_phone() {
  local sn
  sn=$(h shell param get ohos.boot.sn | tr -d ' \n')
  if [ "$sn" != "$SN" ]; then
    echo "p2net: target $T answers boot serial '$sn', expected $SN: refusing" >&2
    exit 3
  fi
}

pc_up() {
  if alive "$RUN/passt.pid" && alive "$RUN/bridge.pid"; then return 0; fi
  pc_down
  rm -f "$RUN/passt.sock"
  setsid nohup "$B/passt-root/usr/bin/passt" -f -4 -s "$RUN/passt.sock" -t none -u none -m 1500 \
    >> "$RUN/passt.log" 2>&1 < /dev/null &
  echo $! > "$RUN/passt.pid"
  for _ in $(seq 1 50); do [ -S "$RUN/passt.sock" ] && break; sleep 0.1; done
  setsid nohup python3 -I "$D/bridge.py" "$PORT" "$RUN/passt.sock" >> "$RUN/bridge.log" 2>&1 < /dev/null &
  echo $! > "$RUN/bridge.pid"
  sleep 0.5
  alive "$RUN/passt.pid" && alive "$RUN/bridge.pid" || { echo "p2net: passt or the bridge did not start ($RUN)" >&2; exit 5; }
  # passt answers ICMP (a round's NET_CHECK ping) through ping sockets: our group must be in this range, which is
  # "1 0" (none) after every WSL start.
  local g lo hi; g=$(id -g)
  read -r lo hi < /proc/sys/net/ipv4/ping_group_range
  if [ "$g" -lt "$lo" ] || [ "$g" -gt "$hi" ]; then
    (cd /mnt/c && timeout 30 /mnt/c/Windows/System32/wsl.exe -d "${WSL_DISTRO_NAME:-Ubuntu-24.04}" -u root -e /bin/sh -c \
      "echo '$g $g' > /proc/sys/net/ipv4/ping_group_range" >/dev/null 2>&1)
  fi
  echo "p2net: PC side up (passt $(cat "$RUN/passt.pid"), bridge $(cat "$RUN/bridge.pid"))"
}

pc_down() {
  for p in bridge passt; do
    if alive "$RUN/$p.pid"; then kill "$(cat "$RUN/$p.pid")"; fi
    rm -f "$RUN/$p.pid"
  done
}

rport_present() { h fport ls | grep -qE "$T +tcp:$PORT tcp:$PORT +\[Reverse\]"; }

up() {
  check_phone
  pc_up
  # hdc can drop an add silently (seen right after a removal): add, then check.
  for _ in 1 2 3 4 5; do
    rport_present && break
    h rport "tcp:$PORT" "tcp:$PORT" >/dev/null
    sleep 1
  done
  rport_present || { echo "p2net: hdc rport tcp:$PORT did not stick" >&2; exit 4; }
  local want have running
  want=$(sha256sum "$B/tapfwd" | cut -d' ' -f1)
  have=$(h shell "sha256sum $BIN 2>/dev/null" | cut -d' ' -f1)
  running=$(h shell 'pidof tapfwd' | tr -d ' \n')
  if [ "$want" != "$have" ]; then
    # A running older copy keeps working; UPGRADE=1 replaces it (eth0 goes for a moment).
    if [ -n "$running" ] && [ "${UPGRADE:-0}" = 1 ]; then h shell "kill $running" >/dev/null; sleep 1; running=; fi
    if [ -z "$running" ]; then
      h file send "$(win_path "$B/tapfwd")" "$BIN" >/dev/null
      h shell "chmod 755 $BIN" >/dev/null
    fi
  fi
  [ -n "$running" ] || h shell "$BIN -d -m $P2NET_MAC $PORT" >/dev/null
  for _ in $(seq 1 15); do
    h shell 'ifconfig eth0 2>/dev/null' | grep -q 'inet addr' && break
    sleep 2
  done
  status
}

down() {
  check_phone
  h shell 'p=$(pidof tapfwd); [ -n "$p" ] && kill $p; echo "stopped tapfwd $p"'
  if rport_present; then h fport rm "tcp:$PORT" "tcp:$PORT"; fi
  if [ "${1:-}" = "--pc" ]; then pc_down; echo "p2net: PC side stopped"; fi
}

status() {
  echo "PC: passt $(alive "$RUN/passt.pid" && cat "$RUN/passt.pid" || echo DOWN), bridge $(alive "$RUN/bridge.pid" && cat "$RUN/bridge.pid" || echo DOWN), ping_group_range $(tr '\t' ' ' < /proc/sys/net/ipv4/ping_group_range)"
  echo "rport: $(rport_present && echo present || echo MISSING)"
  tail -2 "$RUN/bridge.log" 2>/dev/null | sed 's/^/bridge: /'
  h shell 'echo "phone: tapfwd pid $(pidof tapfwd)"; ifconfig eth0 2>/dev/null | grep -E "inet addr|RX bytes"; hidumper -s 1151 2>/dev/null | grep -E "NetId|ConnStat|IsAvailable" | head -3; ping -c 1 -W 3 8.8.8.8 2>&1 | grep -E "packet loss"; tail -2 /data/local/tmp/tapfwd.log'
}

case "${1:-status}" in
  up) up ;;
  down) shift; down "${1:-}" ;;
  status) status ;;
  *) echo "usage: $0 up | down [--pc] | status" >&2; exit 2 ;;
esac
