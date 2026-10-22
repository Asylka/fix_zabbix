#!/bin/sh
# Offline, single systemd start and 300-second observation. No Zabbix kill/stop,
# reboot, firewall changes, HA/config/DB edits, package installation or enable.
set -u
umask 077
ZS_UNIT=zabbix-server.service
ZS_CONFIG=/etc/zabbix/zabbix_server.conf
ZS_LOG=/var/log/zabbix/zabbix_server.log
ZS_DROPIN=/run/systemd/system/zabbix-server.service.d/zzzz-start-observe.conf
ZS_MODE=
ZS_OUT=
ZS_SINCE=
ZS_UNTIL=
ZS_START_SENT=0
ZS_MONO_START=
ZS_FIRST_PID=
ZS_FIRST_ID=
ZS_SEEN_RUNNING=0
ZS_CRITICAL=0
ZS_INCOMPLETE=0
ZS_CAP=16777216

zs_usage() {
    cat <<'HELP'
Usage: sudo sh zabbix_start_observe.sh --start
       sudo sh zabbix_start_observe.sh --diagnose-only
Optional: --config /absolute/config --log-file /absolute/log
--start requires an unmasked, disabled, inactive/failed service, no existing
zabbix_server processes, no unit jobs and a free local TCP port 10051.
One systemctl start --no-block; then observe for 300 seconds from that request.
A runtime drop-in sets Restart=no and is LEFT IN PLACE for review, even on failure.
--diagnose-only observes for 300 seconds without any systemd changes.
Preparation and final collection/archiving take additional time.
The supplied config/log paths are diagnostic sources, not changes to ExecStart.
No internet is needed. Keep this terminal open until the archive path is printed.
Reports contain internal hostnames/addresses and log text; redaction is partial.
Exit 0: no classified critical finding, running at end; not proof of fresh metrics.
Exit 1: critical/suspected failure; 2: start refused/error; 3: incomplete collection.
HELP
}

zs_parse() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --start|--diagnose-only)
                [ -z "$ZS_MODE" ] || return 2
                ZS_MODE=${1#--}; shift ;;
            --config|--log-file)
                [ "$#" -ge 2 ] || return 2
                case "$2" in /*) ;; *) return 2 ;; esac
                case "$1" in --config) ZS_CONFIG=$2 ;; *) ZS_LOG=$2 ;; esac
                shift 2 ;;
            *) return 2 ;;
        esac
    done
    [ -n "$ZS_MODE" ]
}

zs_log() { printf '[%s] %s\n' "$(date '+%F %T%z')" "$*" | tee -a "$ZS_OUT/run.log"; }
zs_redact() { awk '{s=tolower($0); if(s~/password|passwd|secret|token|tlspsk|private.?key/) print "[REDACTED: potentially secret-bearing line]"; else print}'; }
zs_note() { printf '%s\n' "$*" >> "$ZS_OUT/collection-notes.txt"; ZS_INCOMPLETE=1; }
zs_critical() { printf '%s\n' "$*" >> "$ZS_OUT/critical-events.txt"; ZS_CRITICAL=1; }
zs_ctl() { timeout -k 3 15 systemctl "$@"; }
zs_now() { awk '{print int($1)}' /proc/uptime; }
zs_prop() { awk -F= -v k="$2" '$1==k {n++;v=substr($0,length(k)+2)} END {if(n!=1)exit 1;print v}' "$1"; }

zs_capture() {
    local name=$1 seconds=$2 code
    shift 2
    (timeout -k 3 "$seconds" "$@"; printf '%s\n' "$?" > "$ZS_OUT/$name.exit-code") 2>&1 |
        zs_redact | head -c "$ZS_CAP" > "$ZS_OUT/$name.txt"
    code=unknown
    [ ! -r "$ZS_OUT/$name.exit-code" ] || read -r code < "$ZS_OUT/$name.exit-code"
    printf '%s exit=%s bytes=%s\n' "$name" "$code" "$(wc -c < "$ZS_OUT/$name.txt")" >> "$ZS_OUT/captures.txt"
    if [ "$code" != 0 ]; then zs_note "$name: exit=$code; review this capture (optional sources may be unavailable)."; fi
    if [ "$(wc -c < "$ZS_OUT/$name.txt")" -ge "$ZS_CAP" ]; then zs_note "$name: OUTPUT CAPPED at $ZS_CAP bytes."; fi
}

zs_read_state() {
    zs_ctl show "$ZS_UNIT" -p LoadState -p UnitFileState -p ActiveState -p SubState \
        -p MainPID -p ControlPID -p Result -p ExecMainCode -p ExecMainStatus \
        -p NRestarts -p Restart -p InvocationID -p ControlGroup -p TasksCurrent \
        -p MemoryCurrent -p MemoryPeak -p CPUUsageNSec -p TimeoutStartUSec \
        -p TimeoutStopUSec -p FragmentPath -p DropInPaths > "$1" 2> "$1.error"
}

# Pure preflight checks; missing/duplicate fields cause refusal.
zs_state_allows_start() {
    local file=$1 state
    [ "$(zs_prop "$file" LoadState)" = loaded ] || return 1
    [ "$(zs_prop "$file" UnitFileState)" = disabled ] || return 1
    state=$(zs_prop "$file" ActiveState) || return 1
    case "$state" in inactive|failed) ;; *) return 1 ;; esac
    [ "$(zs_prop "$file" MainPID)" = 0 ] && [ "$(zs_prop "$file" ControlPID)" = 0 ]
}

zs_jobs_clear() { awk -v u="$ZS_UNIT" '$2==u {bad=1} END {exit bad}' "$1"; }

zs_preflight() {
    zs_read_state "$ZS_OUT/preflight-unit.txt" || { zs_log 'REFUSED: cannot read unit state.'; return 1; }
    zs_state_allows_start "$ZS_OUT/preflight-unit.txt" || { zs_log 'REFUSED: require loaded, disabled, inactive/failed, MainPID=0, ControlPID=0. No automatic unmask/disable.'; return 1; }
    zs_ctl list-jobs --no-legend --no-pager > "$ZS_OUT/preflight-jobs.txt" || return 1
    zs_jobs_clear "$ZS_OUT/preflight-jobs.txt" || { zs_log 'REFUSED: pending unit job.'; return 1; }
    timeout -k 3 10 ps -eo pid=,comm= > "$ZS_OUT/preflight-processes.txt" || return 1
    if awk '$2=="zabbix_server" {found=1} END {exit !found}' "$ZS_OUT/preflight-processes.txt"; then
        zs_log 'REFUSED: zabbix_server processes already exist.'; return 1
    fi
    timeout -k 3 10 ss -H -ltn 'sport = :10051' > "$ZS_OUT/preflight-port.txt" || return 1
    [ ! -s "$ZS_OUT/preflight-port.txt" ] || { zs_log 'REFUSED: TCP 10051 already has a listener.'; return 1; }
}

zs_install_dropin() {
    local dir=${ZS_DROPIN%/*}
    printf '# Created by zabbix_start_observe.sh; retain until review.\n[Service]\nRestart=no\n' > "$ZS_OUT/expected-dropin.conf" || return 1
    [ ! -L "$dir" ] && [ ! -L "$ZS_DROPIN" ] || { zs_log 'REFUSED: diagnostic drop-in path is a symlink.'; return 1; }
    mkdir -p "$dir" || return 1
    if [ -e "$ZS_DROPIN" ]; then
        cmp -s "$ZS_OUT/expected-dropin.conf" "$ZS_DROPIN" || { zs_log 'REFUSED: an unrelated drop-in already exists at the target path.'; return 1; }
    else
        (set -C; cat "$ZS_OUT/expected-dropin.conf" > "$ZS_DROPIN") || return 1
    fi
    chmod 644 "$ZS_DROPIN" || return 1
    zs_ctl daemon-reload || return 1
    zs_read_state "$ZS_OUT/dropin-unit.txt" || return 1
    [ "$(zs_prop "$ZS_OUT/dropin-unit.txt" Restart)" = no ] || { zs_log 'REFUSED: effective Restart is not no.'; return 1; }
    zs_log "Restart=no verified. Runtime drop-in retained: $ZS_DROPIN"
}

zs_start_once() {
    zs_preflight || return 2
    zs_install_dropin || return 2
    # Recheck after daemon-reload; do not start if an external actor changed state.
    zs_preflight || return 2
    zs_ctl reset-failed "$ZS_UNIT" > "$ZS_OUT/reset-failed.txt" 2>&1 || return 2
    zs_preflight || return 2
    ZS_SINCE=$(date '+%Y-%m-%d %H:%M:%S') || return 2
    ZS_MONO_START=$(zs_now) || return 2
    ZS_START_SENT=1
    zs_log 'Submitting ONE systemctl start --no-block; no retries will be made.'
    zs_ctl start --no-block "$ZS_UNIT" > "$ZS_OUT/start-command.txt" 2>&1
    local code=$?
    printf '%s\n' "$code" > "$ZS_OUT/start-command.exit-code"
    if [ "$code" != 0 ]; then zs_critical "Start request returned $code; state may be uncertain. No retry."; fi
    return 0
}

zs_baseline() {
    zs_capture clock 10 sh -c 'date --iso-8601=seconds; date -u --iso-8601=seconds; cat /proc/sys/kernel/random/boot_id; uptime'
    zs_capture versions 15 sh -c 'uname -a; cat /etc/os-release; systemctl --version; if command -v zabbix_server >/dev/null 2>&1; then zabbix_server -V; fi'
    zs_capture unit-definition 15 systemctl cat "$ZS_UNIT" --no-pager
    zs_capture unit-command 15 systemctl show "$ZS_UNIT" -p ExecStart -p EnvironmentFiles -p TriggeredBy -p Triggers -p OnFailure
    zs_capture config-filtered 10 awk '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*(ListenIP|ListenPort|SourceIP|LogType|LogFile|LogFileSize|PidFile|SocketDir|DBHost|DBPort|DBName|DBUser|User|Include|HANodeName|NodeAddress|Timeout|Start[A-Za-z]+|[A-Za-z]*CacheSize)[[:space:]]*=/ {print}
    ' "$ZS_CONFIG"
    printf 'Diagnostic config: %s\nDiagnostic log: %s\nInclude files are NOT expanded. Compare actual ExecStart/EnvironmentFile. HA is NOT changed. Port checks assume 10051. No SQL connection is made by this script.\n' "$ZS_CONFIG" "$ZS_LOG" > "$ZS_OUT/config-note.txt"
    zs_capture disk-before 10 df -lh
    zs_capture inodes-before 10 df -li
    zs_capture memory-before 10 free -h
    zs_capture vmstat-before 10 vmstat 1 3
    zs_capture boot-kernel-before 15 journalctl -b -k -n 150 --no-pager
    zs_capture log-before 10 tail -n 100 "$ZS_LOG"
}

zs_assess_state() {
    local file=$1 elapsed=$2 active sub pid restarts result ident
    active=$(zs_prop "$file" ActiveState) && sub=$(zs_prop "$file" SubState) &&
        pid=$(zs_prop "$file" MainPID) && restarts=$(zs_prop "$file" NRestarts) &&
        result=$(zs_prop "$file" Result) && ident=$(zs_prop "$file" InvocationID) || { zs_note "t=$elapsed: incomplete state properties."; return 1; }
    case "$pid:$restarts" in *[!0-9:]*|:*|*:) zs_note "t=$elapsed: invalid PID/restart counter."; return 1 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$elapsed" "$active" "$sub" "$pid" "$restarts" "$result" "$ident" >> "$ZS_OUT/timeline.tsv"
    if [ "$active" = failed ]; then zs_critical "t=$elapsed: unit FAILED, Result=$result, MainPID=$pid."; fi
    case "$result" in success|'') ;; *) zs_critical "t=$elapsed: Result=$result." ;; esac
    if [ "$restarts" != 0 ]; then zs_critical "t=$elapsed: automatic restarts recorded: $restarts."; fi
    if [ "$active" = active ] && [ "$sub" = running ] && [ "$pid" != 0 ]; then ZS_SEEN_RUNNING=1; fi
    if [ "$ZS_SEEN_RUNNING" = 1 ] && { [ "$active" != active ] || [ "$sub" != running ] || [ "$pid" = 0 ]; }; then
        zs_critical "t=$elapsed: service left the running state: $active/$sub PID=$pid."
    fi
    if [ "$pid" != 0 ]; then
        [ -z "$ZS_FIRST_PID" ] || [ "$ZS_FIRST_PID" = "$pid" ] || zs_critical "t=$elapsed: MainPID changed from $ZS_FIRST_PID to $pid."
        [ -n "$ZS_FIRST_PID" ] || ZS_FIRST_PID=$pid
    fi
    # A queued start may briefly expose the previous inactive invocation.
    # Pin identity only once this observation sees a nonzero MainPID.
    if [ -n "$ident" ] && [ "$pid" != 0 ]; then
        [ -z "$ZS_FIRST_ID" ] || [ "$ZS_FIRST_ID" = "$ident" ] || zs_critical "t=$elapsed: InvocationID changed."
        [ -n "$ZS_FIRST_ID" ] || ZS_FIRST_ID=$ident
    fi
}

zs_snapshot() {
    local tag=$1
    zs_capture "$tag-processes" 10 ps -C zabbix_server -o pid,ppid,stat,etime,pcpu,pmem,wchan:24,args
    zs_capture "$tag-memory" 10 free -h
    zs_capture "$tag-pressure" 10 sh -c 'for f in /proc/loadavg /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory; do if [ -r "$f" ]; then printf "\n%s\n" "$f"; cat "$f"; fi; done'
    zs_capture "$tag-cgroup" 10 sh -c '
        p=/sys/fs/cgroup/system.slice/zabbix-server.service
        if [ ! -d "$p" ]; then echo "Service cgroup v2 path unavailable (inactive unit or another layout/version)."; exit 0; fi
        for f in cgroup.events memory.events memory.current memory.max pids.current pids.max pids.events; do
            if [ -r "$p/$f" ]; then printf "\n%s\n" "$f"; cat "$p/$f"; fi
        done'
    zs_capture "$tag-log-tail" 10 tail -n 250 "$ZS_LOG"
}

zs_observe() {
    local now elapsed next_snapshot=0 next_report=0 pause
    printf 'elapsed_s\tActiveState\tSubState\tMainPID\tNRestarts\tResult\tInvocationID\n' > "$ZS_OUT/timeline.tsv"
    zs_log 'Observing for 300 seconds. Zabbix will be left in its resulting state.'
    while :; do
        now=$(zs_now) || return 1
        elapsed=$((now-ZS_MONO_START))
        if zs_read_state "$ZS_OUT/state-$elapsed.txt"; then
            zs_assess_state "$ZS_OUT/state-$elapsed.txt" "$elapsed" || :
        else
            zs_note "t=$elapsed: cannot query systemd."
        fi
        zs_capture "listeners-$elapsed" 8 ss -H -ltnp 'sport = :10051'
        if [ "$elapsed" -ge "$next_snapshot" ]; then zs_snapshot "sample-$elapsed"; next_snapshot=$((elapsed+60)); fi
        if [ "$elapsed" -ge "$next_report" ]; then zs_log "Observation: ${elapsed}s elapsed; critical findings=$ZS_CRITICAL; collection gaps=$ZS_INCOMPLETE"; next_report=$((elapsed+30)); fi
        now=$(zs_now) || return 1
        elapsed=$((now-ZS_MONO_START))
        [ "$elapsed" -lt 300 ] || break
        pause=$((300-elapsed)); [ "$pause" -le 10 ] || pause=10
        sleep "$pause"
    done
}

# Output matches with original source/line, without claiming that a text match is a diagnosis.
zs_classify() {
    awk '
        {s=tolower($0)
         if(s~/segmentation fault|segfault|core dumped|assertion.*failed|cannot allocate memory|out of memory|oom-kill|oom_kill|killed process|no space left on device|too many open files|database is down|connection to database.*failed|cannot connect to.*database|unsupported database|database version.*(mismatch|not supported)|please increase.*cache|cannot start|failed to start.*zabbix|one child process died|main process exited|failed with result|zabbix server stopped|address already in use|cannot open.*config|invalid.*(config|parameter)|unknown.*parameter/)
             print "CRITICAL_CANDIDATE " FILENAME ":" FNR ":" $0
         else if(s~/error|failed|cannot|unable|not supported|not monitored|not found|unreachable|refused|timed out|timeout|denied|does not match/)
             print "WARNING_CANDIDATE " FILENAME ":" FNR ":" $0
        }' "$@"
}

zs_collect_window() {
    local from to
    from=$(date -d "$ZS_SINCE" +%Y%m%d%H%M%S) || return 1
    to=$(date -d "$ZS_UNTIL" +%Y%m%d%H%M%S) || return 1
    zs_capture observation-unit-journal 30 journalctl -b -u "$ZS_UNIT" --since "$ZS_SINCE" --until "$ZS_UNTIL" -o short-iso-precise --no-pager
    zs_capture observation-kernel-journal 30 journalctl -b -k --since "$ZS_SINCE" --until "$ZS_UNTIL" -o short-iso-precise --no-pager
    zs_capture observation-zabbix-logs 90 sh -c '
        number=0; failed=0
        for f in "$1" "$1".[0-9]*; do
            [ -f "$f" ] || continue
            number=$((number+1)); printf "\nSOURCE %s\n" "$f"
            (case "$f" in *.gz) gzip -cd -- "$f" ;; *) cat -- "$f" ;; esac
             printf "%s\n" "$?" > "$4/log-source-$number.exit-code") |
            awk -v lo="$2" -v hi="$3" '\''{
                n=split($0,a,":")
                if(n>=3 && a[1]~/^[[:space:]]*[0-9]+$/ && a[2]~/^[0-9]+$/ && length(a[2])==8 && a[3]~/^[0-9][0-9][0-9][0-9][0-9][0-9]\./) {
                    stamp=a[2] substr(a[3],1,6); keep=(stamp>=lo && stamp<=hi)
                }
                if(keep) print
            }'\''
            code=unknown; [ ! -r "$4/log-source-$number.exit-code" ] || read -r code < "$4/log-source-$number.exit-code"
            [ "$code" = 0 ] || failed=1
        done
        [ "$number" -gt 0 ] || { echo "No readable matching log source" >&2; failed=1; }
        exit "$failed"
    ' sh "$ZS_LOG" "$from" "$to" "$ZS_OUT"
    zs_classify "$ZS_OUT/observation-unit-journal.txt" "$ZS_OUT/observation-kernel-journal.txt" "$ZS_OUT/observation-zabbix-logs.txt" > "$ZS_OUT/log-findings.txt" || zs_note 'Log classifier failed.'
    if grep -q '^CRITICAL_CANDIDATE ' "$ZS_OUT/log-findings.txt"; then zs_critical 'Potential critical log messages found; see log-findings.txt and original context.'; fi
}

zs_final_state() {
    local pid cg owners owner elapsed=final now
    zs_read_state "$ZS_OUT/final-unit.txt" || { zs_note 'Cannot read final unit state.'; return 1; }
    if [ -n "$ZS_MONO_START" ]; then
        now=$(zs_now) && elapsed=$((now-ZS_MONO_START))
    fi
    zs_assess_state "$ZS_OUT/final-unit.txt" "$elapsed" || :
    if [ "$(zs_prop "$ZS_OUT/final-unit.txt" ActiveState)" != active ] || [ "$(zs_prop "$ZS_OUT/final-unit.txt" SubState)" != running ]; then
        zs_critical 'At end: service is not active/running.'
    fi
    pid=$(zs_prop "$ZS_OUT/final-unit.txt" MainPID) || return 1
    case "$pid" in ''|*[!0-9]*|0) zs_critical 'At end: no valid MainPID.' ;; *)
        if [ ! -r "/proc/$pid/comm" ] || [ "$(cat "/proc/$pid/comm" 2>/dev/null)" != zabbix_server ]; then zs_critical 'At end: MainPID is absent or not zabbix_server.'; fi ;;
    esac
    zs_capture final-listeners 10 ss -H -ltnp 'sport = :10051'
    if [ ! -s "$ZS_OUT/final-listeners.txt" ]; then
        zs_critical 'At end: no TCP 10051 listener. If HA standby is still configured, inspect HA status before treating this as a crash.'
    elif [ "$(cat "$ZS_OUT/final-listeners.exit-code" 2>/dev/null)" = 0 ]; then
        cg=$(zs_prop "$ZS_OUT/final-unit.txt" ControlGroup) || return 1
        case "$cg" in /*) ;; *) zs_note 'Cannot verify listener ownership: no service cgroup.'; return 1 ;; esac
        owners=$(awk '{s=$0; while(match(s,/pid=[0-9]+/)){p=substr(s,RSTART+4,RLENGTH-4); if(!seen[p]++)print p; s=substr(s,RSTART+RLENGTH)}}' "$ZS_OUT/final-listeners.txt")
        if [ -z "$owners" ]; then zs_note 'Listener PID ownership unavailable.'; fi
        for owner in $owners; do
            if ! awk -F: -v p="$cg" '$3==p || index($3,p"/")==1 {ok=1} END {exit !ok}' "/proc/$owner/cgroup" 2>/dev/null; then
                zs_critical "Listener owner PID $owner is outside the service cgroup or disappeared; inspect final-listeners.txt."
            fi
        done
    fi
    zs_capture final-status 10 systemctl status "$ZS_UNIT" --no-pager --full --lines=40
    zs_capture final-db-connections 10 ss -H -tnp 'dport = :5432'
    zs_snapshot final
    zs_capture vmstat-after 10 vmstat 1 3
    zs_capture final-main-proc 10 sh -c '
        case "$1" in ""|*[!0-9]*|0) echo "No valid MainPID"; exit 0 ;; esac
        for f in limits status cgroup wchan; do printf "\n%s\n" "$f"; cat "/proc/$1/$f"; done
    ' sh "$pid"
    if command -v zabbix_server >/dev/null 2>&1 && [ "$pid" != 0 ]; then
        zs_capture final-ha-status 12 zabbix_server -c "$ZS_CONFIG" -R ha_status
    fi
    if [ -r "$ZS_OUT/final-cgroup.txt" ] && awk '$1=="oom_kill" && $2+0>0 {found=1} END {exit !found}' "$ZS_OUT/final-cgroup.txt"; then
        zs_critical 'Service cgroup reports oom_kill > 0; inspect kernel log and cgroup lifetime.'
    fi
}

zs_finish() {
    local result=$1 archive
    [ "$result" != 0 ] || { if [ "$ZS_CRITICAL" = 1 ]; then result=1; elif [ "$ZS_INCOMPLETE" = 1 ]; then result=3; fi; }
    {
        printf 'Mode: %s\nStart request submitted: %s\nObservation since: %s\nObservation until: %s\n' "$ZS_MODE" "$ZS_START_SENT" "$ZS_SINCE" "$ZS_UNTIL"
        printf 'Critical/suspected findings: %s\nCollection gaps: %s\nExit code: %s\n' "$ZS_CRITICAL" "$ZS_INCOMPLETE" "$result"
        printf 'Review critical-events.txt, log-findings.txt, timeline.tsv, final-unit.txt, collection-notes.txt and captures.txt.\n'
        printf 'Pattern matches are candidates, not a complete error detector. Fresh monitoring data and proxy backlog were NOT checked via SQL/API.\n'
        printf 'No automatic service stop/restart/enable, firewall or HA changes. Restart=no drop-in, if installed, remains: %s\n' "$ZS_DROPIN"
        printf 'Do not repeat --start if processes remain. Use --diagnose-only for another observation.\n'
    } > "$ZS_OUT/SUMMARY.txt"
    zs_log "Collection finished; result=$result. Report directory: $ZS_OUT"
    archive=$ZS_OUT.tar.gz
    if timeout -k 5 120 tar -C "${ZS_OUT%/*}" -czf "$archive" "${ZS_OUT##*/}"; then
        printf '\nSEND THIS ARCHIVE: %s\n' "$archive"
        if command -v sha256sum >/dev/null 2>&1; then sha256sum "$archive"; fi
    else
        printf '\nArchive failed/incomplete. Copy this DIRECTORY instead: %s\n' "$ZS_OUT" >&2
        result=3
    fi
    return "$result"
}

zs_interrupted() {
    trap - HUP INT TERM
    zs_note 'Operator/session signal interrupted collection. Zabbix was not stopped by this script.'
    zs_log 'Interrupted; attempting to archive the partial observation.'
    zs_final_state || :
    ZS_UNTIL=$(date '+%Y-%m-%d %H:%M:%S') || ZS_UNTIL=now
    zs_collect_window || :
    zs_finish 130
    exit 130
}

zs_main() {
    local tool result=0
    case "${1:-}" in --help|-h) zs_usage; return 0 ;; esac
    zs_parse "$@" || { zs_usage; return 2; }
    [ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ] || { echo 'Run as root on the Linux Zabbix VM.' >&2; return 2; }
    for tool in systemctl journalctl timeout flock ps ss awk grep date head wc cat tail gzip tar mkdir chmod sleep tee cmp; do
        command -v "$tool" >/dev/null 2>&1 || { printf 'Missing executable: %s\n' "$tool" >&2; return 2; }
    done
    exec 9>/run/zabbix-recovery.lock || return 2
    flock -n 9 || { echo 'Another Zabbix diagnostic/recovery is running.' >&2; return 2; }
    mkdir -p /var/log/zabbix-start-observe || return 2
    ZS_OUT=/var/log/zabbix-start-observe/$(date +%Y%m%d-%H%M%S)-$$
    mkdir -m 700 "$ZS_OUT" || return 2
    : > "$ZS_OUT/critical-events.txt"; : > "$ZS_OUT/collection-notes.txt"
    ZS_SINCE=$(date '+%Y-%m-%d %H:%M:%S') || return 2
    trap 'zs_interrupted' HUP INT TERM
    zs_log "Mode=$ZS_MODE; report=$ZS_OUT"
    zs_baseline
    if [ "$ZS_MODE" = start ]; then
        zs_start_once || result=2
    else
        ZS_MONO_START=$(zs_now) || result=2
        ZS_SINCE=$(date '+%Y-%m-%d %H:%M:%S') || result=2
    fi
    if [ "$result" = 0 ]; then zs_observe || { zs_note 'Observation interrupted by an internal collection error.'; result=3; }; fi
    zs_final_state || zs_note 'Final state verification was incomplete.'
    ZS_UNTIL=$(date '+%Y-%m-%d %H:%M:%S') || ZS_UNTIL=now
    zs_collect_window || zs_note 'Log window extraction was incomplete.'
    zs_finish "$result"
}

zs_main "$@"
