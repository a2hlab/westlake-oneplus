#!/bin/bash
# A corpus round on the phone with OpenHarmony 7.0 and SceneBoard (WL_OH=7.0): every app launched as an OH
# application of its own (westlake ADR-0008 managed launch, as 06-managed.sh launches one app), its evidence taken
# the way westlake-harness device/run_apps.sh takes it on the D600 board, so that the harness's lifecycle scorer
# reads both rounds alike (tools/round_score.py).
#
#   07-round.sh TAG [FIRST [LAST]]   the apps of ranks FIRST..LAST in the corpus's apps.csv (default all)
#   LIST=<file>                      only the packages listed there (one per line)
#   WAIT (45) / MINWAIT (20)         most seconds to wait for an app; leave once, MINWAIT seconds in, its log shows
#                                    it drawing and two screenshots in a row read as the app (or at once if it died)
#   SECURE_LAYER (0)                 1: FLAG_SECURE windows become OH security layers, which screenshots draw black
#   ROUND_EXTRA                      more launcher arguments for every app
#   WL_HELPERS_SRC                   the native/ directory the launcher's namespace helpers come from
#                                    (default: $WL_SC/workspace/westlake/native)
#   NET_CHECK (8.8.8.8)              an address the phone must reach before each app (empty: no check)
#   LOCALE (en-US)                   the locale apps get, as on Westlake's test board, whose language is English;
#                                    empty: the phone's own (the image's default is Chinese)
#   ORIENTATION (1)                  0: no app's bundle gets its launcher activity's screenOrientation (before
#                                    2026-11-21 none did, and a landscape game drew into a portrait window)
#   ORPHAN_KILL (1)                  0: leave app processes whose spawner is gone (see KILL_ORPHANS) and log how many
#                                    each app left: for a spawner that ends them itself
#   APP_PROCESSES (1)                0: every component runs in the launched process, as before 2026-11-21; 1:
#                                    westlake ADR-0002 app processes (WESTLAKE_APP_PROCESSES=1), a component declared
#                                    for another process runs in a process of its own
# Exit 3: /data stayed below MIN_FREE_MB; exit 4: the phone stopped answering, lost its framework stage (a reboot
# empties a RAM disk: 03-prep.sh and 04-framework.sh again; 03-prep.sh is needed after every boot) or its network.
# Run it again to resume.
#
# Per app: stage it (the harness's device/prep_apps.py: unpack, verify signatures, pin, prepare; the next app is
# staged while this one runs), make, sign and install its OH bundle, launch it, wait, then take its log, screenshot,
# hilog, process map, crash dump, spawner log and launch report into $WL_ROUND/logs/TAG/, stop it and uninstall
# its bundle. Every app gets a line in logs/TAG/results.tsv; apps with one are skipped, so running the round again
# resumes it (RETRY=1 launches the failed ones again).
#
# The phone's /data is a RAM disk unless it has its own partition (westlake-oneplus oh-7.0 scripts/14-data-partition.sh;
# then the framework stage and the input cache stay across reboots, and so does the Wi-Fi login): one app at a time,
# and nothing of an app stays. The framework is hard-linked into
# each app's bundle (a copy would take ~480 MB of RAM per app; the launcher copies it because the kernel links
# only within one encryption policy, but a RAM disk has none), so are the files every app shares (the WebView,
# runtime libraries and guests, ~325 MB: the launcher's --input-cache-link, sent once into
# /data/local/tmp/a2hlab-input-cache), the launch archive goes once it is unpacked, and the bundle's uninstall
# removes the rest. Before each app /data must have MIN_FREE_MB free.
#
# Needs (westlake/local.sh): what 06-managed.sh needs, and
#   WL_HARNESS  a westlake-harness checkout (device/prep_apps.py, harness/westlake_gap)
#   WL_ROUND    the round's directory, made by `07-round.sh --setup`: corpus/ (a view of $WL_CORPUS), manifest/
#               (a copy of $WL_MANIFEST whose app-inputs.lock.json carries the corpus pins), inputs/, logs/, launch/
#   WL_CORPUS   the corpus (apps.csv, sources.csv, dl/, $MAP/<package>/gap-map.json); WL_CORPUS_LOCK: a lock file
#               with its pins (the manifest's app-inputs.lock.json the corpus was staged with)
#   WL_GUESTS   the microG guest build every app gets (as the harness's round.sh), MAP (map120): its gap maps
set -uo pipefail
. "$(dirname "$0")/config.sh"
wl_need WL_SC WL_WESTLAKE WL_MANIFEST WL_SHIM WL_WEBVIEW_INPUT WL_HOST_BUILD WL_HARNESS WL_ROUND WL_CORPUS WL_GUESTS
MAP=${MAP:-map120}
RS=$WL_ROUND; CORPUS=$RS/corpus; M=$RS/manifest; IN=$RS/inputs
TOOLS=$WL_DIR/tools; export WL_HARNESS

if [ "${1:-}" = --setup ]; then
  # The corpus view: its files read where they are, downloads-hk.json (prep_apps.py's record) and the unpacking
  # (in the corpus directory) here. The manifest copy: the launcher finds its lock files beside its tools.
  mkdir -p "$CORPUS" "$IN" "$RS/logs" "$RS/launch" "$RS/recv"
  for f in apps.csv sources.csv dl "$MAP"; do ln -sfn "$(readlink -f "$WL_CORPUS/$f")" "$CORPUS/$f"; done
  [ -f "$CORPUS/downloads-hk.json" ] || cp "$WL_CORPUS/downloads-hk.json" "$CORPUS/" 2>/dev/null || echo '{}' > "$CORPUS/downloads-hk.json"
  rsync -a --delete --exclude .git "$WL_MANIFEST/" "$M/"
  [ -n "${WL_CORPUS_LOCK:-}" ] && python3 -I - "$M/app-inputs.lock.json" "$WL_CORPUS_LOCK" <<'PY'
import json, sys
mine = json.load(open(sys.argv[1])); theirs = json.load(open(sys.argv[2]))['applications']
pins = {k: v for k, v in theirs.items() if k.startswith('hk-')}
mine['applications'].update(pins)
open(sys.argv[1], 'w').write(json.dumps(mine, indent=1) + '\n')
print(len(pins), 'corpus pins')
PY
  echo "round directory ready: $RS"; exit 0
fi

tag=${1:?usage: $0 TAG [FIRST [LAST]] | --setup}; first=${2:-1}; last=${3:-100000}
[ -d "$M/tools" ] && [ -L "$CORPUS/dl" ] || die "run $0 --setup first"
[ -f "$WL_OUT/framework/device-report.json" ] || die "run 04-framework.sh first"
[ -x "$WL_OUT/override-op6/lib/appspawn-x" ] || die "run 02-bridge.sh first"
LOGS=$RS/logs/$tag; LAUNCH=$RS/launch; RECV=$RS/recv; mkdir -p "$LOGS" "$LAUNCH" "$RECV"
LOG=$RS/round-$tag.log; RESULTS=$LOGS/results.tsv; touch "$RESULTS"
WAIT=${WAIT:-45}; MINWAIT=${MINWAIT:-20}; MIN_FREE_MB=${MIN_FREE_MB:-1400}
# Memory: an app starts only with MIN_MEM_MB available, and is stopped early when less than STOP_MEM_MB is left.
# An app's memory and the RAM disk come out of the same 7.6 GB.
MIN_MEM_MB=${MIN_MEM_MB:-2000}; STOP_MEM_MB=${STOP_MEM_MB:-600}
say() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
# A shell command on the phone. With a time limit: when the phone hangs (crash-dump mode) in the middle of a call,
# hdc waits for it forever, and the round would never notice that the phone is gone.
dev() { timeout -k 10 "${DEV_TIMEOUT:-300}" "$WL_HDC" -t "$HDC_TARGET" shell "$@" </dev/null | tr -d '\r'; }
recv() {  # recv REMOTE LOCALNAME: into $RECV
  local to; to=$(wl_tool_path "$RECV"); case "$to" in *\\*) to="$to\\$2" ;; *) to="$to/$2" ;; esac
  rm -f "$RECV/$2"; (cd "$RECV" && timeout 60 "$WL_HDC" -t "$HDC_TARGET" file recv "$1" "$to" </dev/null >/dev/null 2>&1)
  [ -s "$RECV/$2" ]
}
free_mb() { dev "df -k /data | tail -1" | python3 -I -c 'import sys
row = sys.stdin.read().split(); print(int(row[3]) // 1024 if len(row) > 3 and row[3].isdigit() else "")'; }
# The phone's available memory in MB (MemAvailable), empty when it did not answer. /data is a RAM disk: what it holds
# and what the apps use come out of the same memory.
mem_mb() { dev "grep MemAvailable /proc/meminfo" | python3 -I -c 'import sys
row = sys.stdin.read().split(); print(int(row[1]) // 1024 if len(row) > 1 and row[1].isdigit() else "")'; }

FWREPORT=$WL_OUT/framework/device-report.json
FWSTAGE=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["stage"])' "$FWREPORT")
HOSTB=$(wl_build "$WL_HOST_BUILD")
rl=(--runtime-library appspawn-x); for l in $WL_RUNTIME_LIBS; do rl+=(--runtime-library "$l"); done
# The platform Cronet library the framework's HttpEngine loads, for every app (as the harness's override_args).
for l in $(ls "$WL_OUT/override-op6/lib" | grep -E '^libmainlinecronet\..*\.so$'); do rl+=(--runtime-library-add "$l"); done
# The locale apps get: English, as on Westlake's test board, unless LOCALE says otherwise (empty: the phone's own).
LOCALE=${LOCALE-en-US}; la=(); [ -n "$LOCALE" ] && la=(--runtime-env "WESTLAKE_LOCALE=$LOCALE")
# ADR-0002 app processes: the app's own appspawn-x starts them from the request the launcher left the app
# (WESTLAKE_SPAWN_REQUEST), under the managed launch as under the direct one.
[ "${APP_PROCESSES:-1}" = 1 ] && la+=(--runtime-env WESTLAKE_APP_PROCESSES=1)
helpers=$LAUNCH/helpers; mkdir -p "$helpers/native"
# The launcher's namespace helpers: WL_HELPERS_SRC names another westlake checkout's native/ (its source_app_namespace.c
# must match what the launcher asks of it, e.g. --android-install-path needs install_dir, westlake 43889f7/c483098).
cp "${WL_HELPERS_SRC:-$WL_SC/workspace/westlake/native}/"{source_app_namespace.c,host_spawn.c} "$WL_WESTLAKE/native/touchfwd.c" "$helpers/native/"
hsrc=${WL_HELPERS_SRC:-$WL_SC/workspace/westlake/native}
say "namespace helpers: $hsrc ($(git -C "$hsrc" rev-parse --short HEAD 2>/dev/null || echo no git), source_app_namespace.c $(sha256sum "$hsrc/source_app_namespace.c" | cut -c1-8))"

# The apps of this round, in rank order: not marked missing, not already done.
todo=()
while read -r rank pkg; do
  [ "$rank" -lt "$first" ] || [ "$rank" -gt "$last" ] && continue
  [ -n "${LIST:-}" ] && ! grep -qx "$pkg" "$LIST" && continue
  grep -q "^$pkg,missing," "$CORPUS/sources.csv" 2>/dev/null && continue
  if [ "${RETRY:-0}" = 1 ]; then grep -q "^hk-$pkg	launched" "$RESULTS" && continue
  else grep -q "^hk-$pkg	" "$RESULTS" && continue; fi
  todo+=("$pkg")
done < <(tr -d '\r' < "$CORPUS/apps.csv" | nl -ba -w1 -s' ')
say "$tag ranks $first-$last: ${#todo[@]} to launch"

prep() {  # stage packages (host only)
  WL_SC=$RS WL_CORPUS=$CORPUS WL_MANIFEST=$M MAP=$MAP python3 "$WL_HARNESS/device/prep_apps.py" "$@" >> "$LOG" 2>&1
}
result() { printf '%s\t%s\t%s\n' "hk-$1" "$2" "$3" >> "$RESULTS"; say "hk-$1 $2 $3"; }
# The launcher activity's android:screenOrientation (Android's number; nothing when it has none), from the app's
# download, for its OH ability: SceneBoard then turns the screen before the app's window is made. Kept in
# launcher-orientation.tsv, so a rerun reads each download once.
orientation_of() {
  [ "${ORIENTATION:-1}" = 0 ] && return
  grep -q -- "'--orientation'" "$M/tools/make_managed_bundle.py" || return   # a manifest from before it
  local pkg=$1 activity=$2 o download
  o=$(awk -F'\t' -v p="$pkg" -v a="$activity" '$1 == p && $2 == a {print $3; exit}' "$RS/launcher-orientation.tsv" 2>/dev/null)
  if [ -z "$o" ]; then
    download=$(ls "$CORPUS/dl/$pkg"@* 2>/dev/null | head -1)
    [ -n "$download" ] || return
    o=$(python3 -P "$TOOLS/launcher_orientation.py" --download "$download" --activity "$activity" 2>/dev/null) || return
    printf '%s\t%s\t%s\n' "$pkg" "$activity" "${o:--}" >> "$RS/launcher-orientation.tsv"
  fi
  [ "$o" = - ] || echo "$o"
}

# Start clean: no app of an earlier run, no spawner of another build, the screen on and staying on.
# App processes whose spawner is gone (parent init, uid of an app): what a stopped app leaves running. Under the managed
# launch OH's app manager ends only the processes it started, so an app's own processes (westlake ADR-0002, ":push",
# ":sandboxed_process0", ...) and its spawner's pre-initialized child outlived it, and they piled up: 31 of them,
# 4.6 GB, stopped round o70w's first phone at the memory guard (2026-11-21). OH's own apps and the host are kept.
ORPHAN_SELECT='for p in /proc/[0-9]*; do pp=$(grep PPid $p/status 2>/dev/null | grep -oE "[0-9]+");
  u=$(grep Uid $p/status 2>/dev/null | grep -oE "[0-9]+" | head -1);
  [ "$pp" = 1 ] && [ -n "$u" ] && [ "$u" -ge 20010000 ] || continue;
  case "$(ps -o args= -p ${p##*/} | tail -n 1)" in com.ohos.*|ohos.*|com.huawei.*|org.westlake.*) continue;; esac;'
KILL_ORPHANS="$ORPHAN_SELECT kill -9 \${p##*/}; done; exit 0"
COUNT_ORPHANS="n=0; $ORPHAN_SELECT n=\$((n+1)); done; echo \$n"
cleanup_board() {
  local leftover; leftover=$(cat "$RS/.installed" 2>/dev/null)
  [ -n "$leftover" ] && dev "aa force-stop $leftover >/dev/null 2>&1; bm uninstall -n $leftover >/dev/null 2>&1; exit 0" >/dev/null
  rm -f "$RS/.installed"
  dev "for p in \$(pidof appspawn-x); do kill -9 \$p; done; rm -rf /data/local/tmp/a2hlab-app-* /data/local/tmp/ev-*;
    rm -f /data/service/el1/public/westlake-registry/managed/*; exit 0" >/dev/null
  [ "${ORPHAN_KILL:-1}" = 1 ] && dev "$KILL_ORPHANS" >/dev/null
}
cleanup_board
dev "power-shell wakeup >/dev/null; power-shell timeout -o 86400000 >/dev/null; exit 0" >/dev/null


run_app() {
  local pkg=$1 key=hk-$1 in=$IN/prep-hk-$1 o=$LAUNCH/$tag-hk-$1 ev=$LOGS/hk-$1 t_app; t_app=$(date +%s)
  [ -f "$in/app-input.json" ] || { result "$pkg" not-staged "$(grep "^$key " "$LOG" | tail -1 | cut -c1-150)"; return; }
  local activity; activity=$(python3 -I -c 'import json, sys
print(json.load(open(sys.argv[1]))["application"]["launch_activity"])' "$in/app-input.json")
  # The phone answers and still has this round's framework: a reboot empties its RAM disk (03 and 04 again).
  local alive="" try
  for try in 1 2 3 4 5 6; do
    alive=$(dev "[ -d $FWSTAGE ] && echo STAGE || echo NOSTAGE" 2>/dev/null | grep -o -E 'NOSTAGE|STAGE' | head -1)
    [ -n "$alive" ] && break; sleep 20
  done
  [ -n "$alive" ] || { say "the phone does not answer: stopping"; return 4; }
  [ "$alive" = STAGE ] || { say "the phone has no framework stage (rebooted?): run 03-prep.sh and 04-framework.sh, then resume"; return 4; }
  # Apps are measured with the network up (NET_CHECK: the address pinged; empty skips the check).
  if [ -n "${NET_CHECK-8.8.8.8}" ]; then
    local net=""
    for try in 1 2 3; do
      net=$(dev "ping -c 1 -W 3 ${NET_CHECK-8.8.8.8} >/dev/null 2>&1 && echo UP" | grep -o UP); [ -n "$net" ] && break; sleep 20
    done
    [ -n "$net" ] || { say "the phone's network is down: stopping (resume once it is back)"; return 4; }
  fi
  local mb; mb=$(free_mb)
  if [ -z "$mb" ] || [ "$mb" -lt "$MIN_FREE_MB" ]; then
    cleanup_board; mb=$(free_mb)
    [ -n "$mb" ] && [ "$mb" -ge "$MIN_FREE_MB" ] || { say "DISK GUARD: /data has ${mb:-?} MB free < $MIN_FREE_MB"; return 3; }
  fi
  local mem; mem=$(mem_mb)
  if [ -z "$mem" ] || [ "$mem" -lt "$MIN_MEM_MB" ]; then
    cleanup_board; sleep 10; mem=$(mem_mb)
    # Still short after the clean-up: a reboot gives it back, and the supervisor resumes the round after it
    # (exit 4, as for a phone that went away). Before 2026-11-21 this stopped the round (exit 3, as a full /data).
    [ -n "$mem" ] && [ "$mem" -ge "$MIN_MEM_MB" ] || {
      say "MEMORY GUARD: ${mem:-?} MB available < $MIN_MEM_MB after the clean-up: rebooting the phone"
      dev "sync; reboot" >/dev/null 2>&1; return 4; }
  fi
  rm -rf "$o" "$o.log"; mkdir -p "$o"
  # Its OH bundle, named after the package; its main ability is the launcher activity, in its orientation.
  local orient; orient=$(orientation_of "$pkg" "$activity")
  if ! python3 "$M/tools/make_managed_bundle.py" --host-build "$HOSTB" --package "$pkg" --activity "$activity" \
         ${orient:+--orientation "$orient"} --out "$o/bundle" > "$o/bundle.log" 2>&1 ||
     ! python3 "$M/tools/sign_development_host.py" --workspace "$WL_SC/verify" --host-build "$o/bundle" --managed \
         --out "$o/signed" >> "$o/bundle.log" 2>&1; then
    result "$pkg" bundle-failed "$(tail -1 "$o/bundle.log" | cut -c1-150)"; return
  fi
  wl_hdc file send "$(wl_tool_path "$o/signed/source-host.hap")" /data/local/tmp/wl-round.hap >/dev/null
  echo "$pkg" > "$RS/.installed"
  local r; r=$(dev "bm install -r -p /data/local/tmp/wl-round.hap; rm -f /data/local/tmp/wl-round.hap" | tail -1)
  case "$r" in *successfully*) ;; *) result "$pkg" install-failed "$r"; rm -f "$RS/.installed"; return ;; esac
  # The kernel's clock at the start: the app's evidence keeps the kernel log from here (GPU faults in render_service
  # on this phone: round o70a's hang followed a string of them). After a hang, scripts/crashdump.py reads the
  # kernel's own log from the phone's RAM in crash-dump mode (tools/supervise-round.sh: scripts/recover-phone.sh).
  local kstart; kstart=$(dev "cut -d' ' -f1 /proc/uptime" | grep -o '^[0-9.]*' | head -1)
  # The framework, hard-linked where the launcher looks for its shared copy; the launch mark for crash dumps.
  dev "S=/data/app/el2/100/base/$pkg/files/a2hlab-shared-${FWSTAGE##*/}; [ -f \$S/.a2hlab-shared-ready ] ||
    { rm -rf \$S.part && mkdir \$S.part && cp -al $FWSTAGE/. \$S.part/ && touch \$S.part/.a2hlab-shared-ready &&
      mv -T \$S.part \$S; } || rm -rf \$S.part; touch /data/local/tmp/ev-launch.mark; power-shell wakeup >/dev/null;
    exit 0" >/dev/null
  # Launch remedies from the app's gap map (launch_args), as run_apps.sh takes them.
  local X; X=$(python3 -I -c 'import json, sys
try: print(" ".join(json.load(open(sys.argv[1])).get("launch_args", [])))
except Exception: pass' "$CORPUS/$MAP/$pkg/gap-map.json" 2>/dev/null)
  local t_probe; t_probe=$(date +%s)
  # shellcheck disable=SC2086
  timeout "${PROBE_TIMEOUT:-600}" python3 "$M/tools/probe_source_app.py" --workspace "$WL_SC/verify" \
    --westlake-source "$helpers" --framework-report "$FWREPORT" --app-input "$in" --app "$key" \
    --webview-input "$(wl_build "$WL_WEBVIEW_INPUT")" --bionic-shim-build "$(wl_build "$WL_SHIM")" \
    --runtime-library-build "$WL_OUT/override-op6" "${rl[@]}" --android-native-net-app-libraries --input-cache-link \
    --guest-build "$(wl_build "$WL_GUESTS")" --runtime-env "WESTLAKE_SECURE_LAYER=${SECURE_LAYER:-0}" \
    "${la[@]}" $X ${ROUND_EXTRA:-} \
    --host "$pkg" --managed --touch-mode off --hdc "$WL_HDC" --serial "$HDC_TARGET" --out "$o/launch" > "$o.log" 2>&1
  local rc=$? rep=$o/launch/device-report.json C="" PP="" R="" S="" sock="" t_launched; t_launched=$(date +%s)
  # The next app is staged on the host while this one runs; only now: the stager writes the lock file that the
  # launcher reads as it starts.
  [ -n "${2:-}" ] && { prep "$2" & pf=$!; }
  if [ -f "$rep" ]; then
    read -r C PP R S sock < <(python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); print(d.get("child") or "-", d.get("parent") or "-", d.get("runtime", "-"), d.get("stage", "-"),
  (d.get("socket") or "-").rsplit("/", 1)[-1])' "$rep")
    [ "$C" = - ] && C=; [ "$PP" = - ] && PP=   # no child (JSON null): a failed launch, not process "None"
    cp "$rep" "$ev.report.json"
  fi
  cp "$o.log" "$ev.launch.log"
  if [ -z "$C" ]; then
    result "$pkg" launch-failed "rc=$rc $(grep -v '^ ' "$o.log" | tail -1 | cut -c1-150)"
  else
    # The process map sampled until the process ends (to place a crash pc), its hilog; the launch archive goes.
    local m=/data/local/tmp/ev-$C.maps
    # The app goes first when memory runs out: the kernel's OOM killer otherwise picks among OH's own services too,
    # and init panics the kernel when a critical one keeps failing.
    dev "echo 1000 > /proc/$C/oom_score_adj 2>/dev/null; rm -f $S/launch-inputs.tar /data/local/tmp/ev-$C.*;
      nohup sh -c 'while [ -d /proc/$C ]; do cat /proc/$C/maps > $m.new 2>/dev/null && [ -s $m.new ] && mv $m.new $m; sleep 0.5; done' >/dev/null 2>&1 &
      nohup hilog -P $C > /data/local/tmp/ev-$C.hilog 2>/dev/null & exit 0" >/dev/null
    local err=$R/private-tmp/adapter_child_$C.stderr t0 drew="" ok=0 st n left=""
    t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt "$WAIT" ]; do
      # STATE <alive> <relayouts> <data free KB> <memory available KB>, or the phone did not answer. One hdc call can
      # come back empty while the phone runs on (round o70b, 2026-11-20 02:36: the phone was up, and the kernel log
      # reader kept reading it), so an empty answer is asked again twice, 5 s apart and with a 60 s limit each; the
      # round stops only when three answers in a row are empty.
      st=""
      for try in 1 2 3; do
        [ "$try" -gt 1 ] && { say "hk-$pkg: no answer to the state check (try $((try - 1)) of 3); asking again"; sleep 5; }
        st=$(DEV_TIMEOUT=$([ "$try" -gt 1 ] && echo 60 || echo "${DEV_TIMEOUT:-300}") dev "[ -d /proc/$C ] && a=A || a=D;
          c=\$(grep -c OH_WSA-relayout $err 2>/dev/null); f=\$(df -k /data | tail -1); m=\$(grep MemAvailable /proc/meminfo);
          set -- \$f; f=\$4; set -- \$m; echo STATE \$a \${c:-0} \$f \$2" | grep -o 'STATE [AD] [0-9]* [0-9]* [0-9]*' | head -1)
        [ -n "$st" ] && break
      done
      [ -n "$st" ] || { left="the phone stopped answering"; break; }
      local alive dfree mavail
      read -r _ alive n dfree mavail <<< "$st"
      [ "$alive" = D ] && { left="gone after $(( $(date +%s) - t0 ))s"; break; }
      [ "$dfree" -lt 204800 ] && { left="stopped: /data below 200 MB"; break; }
      [ "$mavail" -lt $((STOP_MEM_MB * 1024)) ] && { left="stopped: memory below $STOP_MEM_MB MB"; break; }
      [ -z "$drew" ] && [ "$n" -gt 0 ] && drew=$(date +%s)
      if [ -n "$drew" ] && [ $(( $(date +%s) - t0 )) -ge "$MINWAIT" ]; then
        dev "power-shell wakeup >/dev/null; snapshot_display -f /data/local/tmp/rg.jpeg >/dev/null; exit 0" >/dev/null
        if recv /data/local/tmp/rg.jpeg rg.jpeg && [ "$(python3 "$TOOLS/round_screen.py" "$RECV/rg.jpeg" 2>/dev/null)" = app ]
        then ok=$((ok + 1)); else ok=0; fi
        [ $ok -ge 2 ] && { left="on screen after $(( $(date +%s) - t0 ))s"; break; }
      fi
      sleep 2
    done
    # A phone that stopped answering has no evidence to give: the app gets no result line, so the next run of the
    # round launches it again, and the round stops here (the next app would find no phone either).
    if [ "$left" = "the phone stopped answering" ]; then
      say "hk-$pkg: the phone stopped answering during its wait; stopping the round (it runs again on resume)"
      rm -f "$ev".*
      return 4
    fi
    # The screenshot the scorer judges; then ART's thread dump of every thread into the log (what a stalled main
    # thread waits on), then the log itself, and each of the app's other processes' logs (westlake ADR-0002).
    dev "power-shell wakeup >/dev/null; snapshot_display -f /data/local/tmp/rg.jpeg >/dev/null; exit 0" >/dev/null
    recv /data/local/tmp/rg.jpeg rg.jpeg && cp "$RECV/rg.jpeg" "$ev.jpeg"
    dev "[ -d /proc/$C ] && kill -3 $C; exit 0" >/dev/null && sleep 3
    dev "cat $err" > "$ev.stderr"
    if head -c 200 "$ev.stderr" | grep -q '^\[Fail\]'; then
      say "hk-$pkg: the phone stopped answering while its evidence was taken; stopping the round (it runs again on resume)"
      rm -f "$ev".*
      return 4
    fi
    grep -o -E '\[WL-PROC\] started [^ ]+ pid=[0-9]+' "$ev.stderr" | while read -r _ _ proc pidv; do
      p=${pidv#pid=}; d=$ev.processes; mkdir -p "$d"
      f=$d/$proc.stderr; [ -e "$f" ] && f=$d/$proc-$p.stderr
      dev "[ \"\$(ps -o args= -p $p | tail -n 1)\" = '$proc' ] && kill -3 $p; exit 0" >/dev/null && sleep 2
      dev "cat $R/private-tmp/adapter_child_$p.stderr" > "$f"
    done
    # Its crash dump: faultloggerd writes faultlog/temp/cppcrash-<pid>-<ms> (hiview may move it); pids repeat,
    # so only a dump newer than the launch mark counts.
    dev "ls -t /data/log/faultlog/faultlogger/ 2>/dev/null | head -3" > "$ev.faultlogs"
    local F; F=$(dev "for f in \$(find /data/log/faultlog/temp /data/log/faultlog/faultlogger -name 'cppcrash-*' -newer /data/local/tmp/ev-launch.mark 2>/dev/null)
      do grep -q '^Pid:$C\$' \$f && echo \$f; done; exit 0" | grep '^/data/' | head -1)
    [ -n "$F" ] && dev "cat $F" > "$ev.cppcrash"
    dev "for p in \$(ps -ef | grep -e 'hilog -P $C' -e '/proc/$C ' | grep -v grep | sed 's/  */ /g' | cut -d' ' -f2); do
      kill \$p; done; exit 0" >/dev/null
    dev "cat /data/local/tmp/ev-$C.maps 2>/dev/null" > "$ev.maps"; dev "cat /data/local/tmp/ev-$C.hilog 2>/dev/null" > "$ev.hilog"
    dev "grep '^\[AppSpawnX\]' $S/parent.log 2>/dev/null" > "$ev.spawner"
    for f in "$ev.maps" "$ev.hilog" "$ev.spawner" "$ev.faultlogs" "$ev.cppcrash"; do
      [ -n "$(tr -d '[:space:]' 2>/dev/null < "$f" | head -c 1)" ] || rm -f "$f"; done
    result "$pkg" launched "child=$C ${left:-waited ${WAIT}s} relayouts=$(grep -c OH_WSA-relayout "$ev.stderr") \
launch=$((t_launched - t_probe))s turn=$(( $(date +%s) - t_app ))s"
  fi
  # Stop it. First home (the gesture from the bottom edge), so that render_service composites the desktop and not
  # the app's window when the app goes: on this phone a GPU fault in render_service followed most kills of an app
  # still on screen (round o70a's hang came at one). Then OH ends the app, then its spawner (every spawner but the
  # router, which serves every app) and the rest; the uninstall removes its files.
  dev "power-shell wakeup >/dev/null; uinput -T -m 540 2270 540 1400 300 >/dev/null 2>&1; exit 0" >/dev/null; sleep 2
  dev "aa force-stop $pkg >/dev/null 2>&1; for p in \$(pidof $pkg) $C $PP; do kill -9 \$p; done 2>/dev/null;
    sp=; for p in \$(pidof appspawn-x); do case \"\$(ps -o args= -p \$p | tail -n 1)\" in *--route*) ;; *) sp=\"\$sp \$p\";; esac; done;
    [ -n \"\$sp\" ] && { kill \$sp; sleep 2; kill -9 \$sp; } 2>/dev/null;
    bm uninstall -n $pkg >/dev/null 2>&1; rm -rf $S /data/local/tmp/ev-$C.* /data/service/el1/public/westlake-registry/managed/$pkg;
    exit 0" >/dev/null
  if [ "${ORPHAN_KILL:-1}" = 1 ]; then dev "$KILL_ORPHANS" >/dev/null   # its own processes, its spawner's pre-initialized child
  else say "$key: app processes left behind: $(dev "$COUNT_ORPHANS" | tr -d '[:space:]')"; fi
  rm -f "$RS/.installed"
  # The kernel log of the app's turn, and how many GPU faults it had.
  dev "dmesg" | python3 -I -c 'import re, sys
start = float(sys.argv[1] or 0)
for line in sys.stdin:
    m = re.match(r"\[\s*(\d+\.\d+)\]", line)
    if m and float(m.group(1)) >= start:
        sys.stdout.write(line)' "${kstart:-0}" > "$ev.kmsg" 2>/dev/null
  local faults; faults=$(grep -c -E "gpu fault|Unhandled context fault" "$ev.kmsg" 2>/dev/null)
  [ "${faults:-0}" -gt 0 ] && say "hk-$pkg: $faults GPU fault lines in the kernel log during its turn"
  [ -s "$ev.kmsg" ] || rm -f "$ev.kmsg"
  # The staged APKs go (app-input.json stays, as round.sh keeps it); the launch output once its report is kept.
  find "$in" -mindepth 1 ! -name app-input.json -delete 2>/dev/null
  rm -rf "$o"
  return 0
}

staged() { [ -f "$IN/prep-hk-$1/app-input.json" ] && ls "$IN/prep-hk-$1" | grep -qv '^app-input.json$'; }
pf=""
for ((i = 0; i < ${#todo[@]}; i++)); do
  pkg=${todo[i]}
  [ -n "$pf" ] && { wait "$pf"; pf=""; }
  staged "$pkg" || prep "$pkg"
  next=""; [ $((i + 1)) -lt ${#todo[@]} ] && ! staged "${todo[i + 1]}" && next=${todo[i + 1]}
  run_app "$pkg" "$next"; rc=$?
  [ $rc -eq 3 ] && { [ -n "$pf" ] && wait "$pf"; say "$tag stopped by the disk guard"; exit 3; }
  [ $rc -eq 4 ] && { [ -n "$pf" ] && wait "$pf"; say "$tag stopped: the phone"; exit 4; }
done
[ -n "$pf" ] && wait "$pf"
say "$tag done"
