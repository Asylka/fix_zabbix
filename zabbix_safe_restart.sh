#!/usr/bin/env bash
# Ubuntu 24.04 / systemd 255 / Zabbix 6.0. No network or extra packages required.
# Run with bash, NOT sh. Changes only this service's runtime systemd policy.
set -u
set -o pipefail
umask 077
export LC_ALL=C SYSTEMD_PAGER=cat SYSTEMD_COLORS=0

UNIT=zabbix-server.service
SCRIPT_VERSION=1.2
CG=/system.slice/zabbix-server.service
DROPIN=/run/systemd/system/zabbix-server.service.d/zzzzzz-safe-restart.conf
CONFIG=/etc/zabbix/zabbix_server.conf
LOG=/var/log/zabbix/zabbix_server.log
PORT=10051
MODE= FORCE=0 GRACE=300 OBSERVE=300
OUT= PHASE=prepare START_SENT=0 STOP_SENT=0 FORCE_SENT=0
CRITICAL=0 GAPS=0 LOG_OPEN=0 LOG_OFFSET=0 LOG_BYTES=0 LOG_CAPPED=0
LOG_LIMIT=33554432 CHUNK_LIMIT=2097152
FIRST_PID= FIRST_ID= STOP_ID= RUN_SEEN=0
declare -A S=()
ZCOUNT=0 OUTSIDE=0 CG_POP=0 DCOUNT=0 JOBS=0 LISTENERS=0
INSPECT_STAGE=unknown INSPECT_FAILURES=0

usage() {
    cat <<'EOF'
Usage: sudo bash zabbix_safe_restart.sh --restart [--force-after-timeout]
       sudo bash zabbix_safe_restart.sh --stop [--force-after-timeout]
       sudo bash zabbix_safe_restart.sh --start
       sudo bash zabbix_safe_restart.sh --diagnose
Options: --grace-seconds N (30..3600, default 300)
         --observe-seconds N (30..3600, default 300)
         --config /absolute/path --log-file /absolute/path --port N
Default stop: systemd stop, wait, SIGTERM to this unit, wait 60 seconds.
Optional force: SIGKILL to this unit ONLY, then wait up to 60 seconds.
No start while old processes, unit jobs, a populated cgroup or listener remain.
Processes outside the standard unit cgroup cause refusal; never killed by name.
No HA/DB/firewall/config edits, reboot, mask, enable/disable, or PID-file removal.
Config/log arguments are diagnostic sources; they DO NOT change ExecStart.
Runtime policy remains until review: Restart=no, SendSIGKILL=no,
KillMode=control-group, KillSignal=SIGTERM, TimeoutStopSec=infinity.
Exit: 0 service/listener stable (or fully stopped); 1 observed failure;
      2 operation refused / stop incomplete; 3 collection incomplete; 130 interrupted.
Exit 0 does not prove fresh metrics, DB writes or an empty proxy queue.
EOF
}

parse() {
    while (($#)); do
        case "$1" in
            --restart|--stop|--start|--diagnose)
                [[ -z $MODE ]] || return 2; MODE=${1#--}; shift ;;
            --force-after-timeout) FORCE=1; shift ;;
            --grace-seconds|--observe-seconds|--port)
                (($# >= 2)) && [[ $2 =~ ^[0-9]{1,5}$ ]] || return 2
                local n=$((10#$2))
                case "$1" in
                    --port) ((n>=1 && n<=65535)) || return 2; PORT=$n ;;
                    --grace-seconds) ((n>=30 && n<=3600)) || return 2; GRACE=$n ;;
                    *) ((n>=30 && n<=3600)) || return 2; OBSERVE=$n ;;
                esac; shift 2 ;;
            --config|--log-file)
                (($# >= 2)) && [[ $2 == /* ]] || return 2
                case "$1" in --config) CONFIG=$2 ;; *) LOG=$2 ;; esac; shift 2 ;;
            *) return 2 ;;
        esac
    done
    [[ -n $MODE ]] || return 2
    [[ $FORCE == 0 || $MODE == restart || $MODE == stop ]] || return 2
}

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*" | tee -a "$OUT/run.log"; }
warn() { printf '%s\n' "$*" >> "$OUT/warnings.txt"; log "WARNING: $*"; }
gap() { GAPS=1; printf '%s\n' "$*" >> "$OUT/collection-gaps.txt"; }
bad() { CRITICAL=1; printf '%s\n' "$*" >> "$OUT/critical.txt"; log "ERROR: $*"; }
redact() {
    tr -d '\000' | awk '{s=tolower($0); if(s~/password|passwd|secret|token|tlspsk|private.?key/) print "[REDACTED: potentially secret-bearing line]"; else print}'
}
ctl() { timeout -k 3 15 systemctl --no-ask-password "$@"; }
mono() { local t rest; read -r t rest < /proc/uptime; printf '%s\n' "${t%%.*}"; }

# Bounded diagnostic capture; preserve command and pipeline status.
capture() {
    local name=$1 seconds=$2; shift 2
    local -a codes
    timeout -k 3 "$seconds" "$@" 2>&1 | head -c 2097152 | redact > "$OUT/$name.txt"
    codes=("${PIPESTATUS[@]}")
    printf '%s\t%s\t%s\t%s\n' "$name" "${codes[0]}" "${codes[1]}" "${codes[2]}" >> "$OUT/captures.tsv"
    if ((codes[0] != 0 || codes[1] != 0 || codes[2] != 0)); then
        gap "$name: command=${codes[0]}, limiter=${codes[1]}, filter=${codes[2]}; see captures.tsv."
    fi
    if [[ $(wc -c < "$OUT/$name.txt") -ge 2097152 ]]; then gap "$name: output may be capped."; fi
    return 0
}

read_state() {
    local k v
    ctl show "$UNIT" -p LoadState -p UnitFileState -p ActiveState -p SubState \
        -p MainPID -p ControlPID -p Result -p InvocationID -p ControlGroup \
        -p ExecMainPID -p ExecMainCode -p ExecMainStatus -p ExecMainStartTimestamp -p ExecMainExitTimestamp \
        -p NRestarts -p Restart -p SendSIGKILL -p KillMode -p KillSignal \
        -p TimeoutStartUSec -p TimeoutStopUSec -p TasksCurrent -p TasksMax \
        -p MemoryCurrent -p MemoryMax -p LimitNOFILE -p FragmentPath -p DropInPaths \
        > "$OUT/current-unit.txt" 2> "$OUT/current-unit.error" || return 1
    S=()
    while IFS='=' read -r k v; do
        [[ $k =~ ^[A-Za-z]+$ && ! ${S[$k]+present} ]] || return 1
        S[$k]=$v
    done < "$OUT/current-unit.txt"
    for k in LoadState ActiveState SubState MainPID ControlPID Result InvocationID ControlGroup NRestarts; do
        [[ ${S[$k]+present} ]] || return 1
    done
    [[ ${S[MainPID]} =~ ^[0-9]+$ && ${S[ControlPID]} =~ ^[0-9]+$ && ${S[NRestarts]} =~ ^[0-9]+$ ]]
}

pid_group() {
    local line
    [[ -r /proc/$1/cgroup ]] || return 1
    while IFS= read -r line; do
        case "$line" in 0::*) printf '%s\n' "${line#0::}"; return 0 ;; esac
    done < /proc/"$1"/cgroup
    return 1
}
in_group() { [[ $1 == "$CG" || $1 == "$CG/"* ]]; }

# Do not infer shutdown from ActiveState or MainPID alone.
inspect() {
    local pid ppid state comm group key value populated=0
    INSPECT_STAGE=unit-state
    read_state || { gap 'Cannot read unit state.'; return 1; }
    [[ -z ${S[ControlGroup]} || ${S[ControlGroup]} == "$CG" ]] || {
        bad "Unexpected cgroup ${S[ControlGroup]}; only $CG is supported."; return 1;
    }
    INSPECT_STAGE=processes
    timeout -k 2 10 ps -eo pid=,ppid=,stat=,comm= > "$OUT/current-ps.txt" 2> "$OUT/current-ps.error" || return 1
    ZCOUNT=0 OUTSIDE=0 DCOUNT=0
    : > "$OUT/current-zabbix-processes.tsv"
    while read -r pid ppid state comm; do
        [[ $comm == zabbix_server ]] || continue
        [[ -d /proc/$pid ]] || continue
        group=$(pid_group "$pid") || {
            [[ -d /proc/$pid ]] || continue
            group=UNKNOWN
        }
        ((ZCOUNT+=1))
        in_group "$group" || ((OUTSIDE+=1))
        [[ $state != D* ]] || ((DCOUNT+=1))
        printf '%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$state" "$group" >> "$OUT/current-zabbix-processes.tsv"
    done < "$OUT/current-ps.txt"
    INSPECT_STAGE=cgroup
    CG_POP=0
    if [[ -d /sys/fs/cgroup$CG ]]; then
        [[ -r /sys/fs/cgroup$CG/cgroup.events ]] || return 1
        populated=unknown
        while read -r key value; do [[ $key != populated ]] || populated=$value; done < /sys/fs/cgroup"$CG"/cgroup.events
        [[ $populated == 0 || $populated == 1 ]] || return 1
        CG_POP=$populated
    fi
    INSPECT_STAGE=jobs
    ctl list-jobs --no-legend --no-pager > "$OUT/current-jobs.txt" 2> "$OUT/current-jobs.error" || return 1
    JOBS=$(awk -v u="$UNIT" '$2==u {n++} END {print n+0}' "$OUT/current-jobs.txt")
    INSPECT_STAGE=listeners
    timeout -k 2 10 ss -H -ltnp "sport = :$PORT" > "$OUT/current-listeners.txt" 2> "$OUT/current-listeners.error" || return 1
    LISTENERS=$(wc -l < "$OUT/current-listeners.txt")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date --iso-8601=seconds)" "$PHASE" "${S[ActiveState]}" "${S[SubState]}" \
        "${S[MainPID]}" "$ZCOUNT" "$OUTSIDE" "$CG_POP" "$DCOUNT" "$JOBS" "$LISTENERS" >> "$OUT/timeline.tsv"
}

# Retry reads only. A partial/failed snapshot must never authorize a signal/start.
inspect_reliably() {
    local attempt rc file prefix
    for attempt in 1 2 3; do
        if inspect; then
            if ((attempt>1)); then log "State inspection recovered on attempt $attempt/3."; fi
            return 0
        else
            rc=$?
        fi
        INSPECT_FAILURES=$((INSPECT_FAILURES+1))
        prefix=$OUT/inspection-failure-$INSPECT_FAILURES
        printf '%s phase=%s attempt=%s/3 stage=%s exit=%s\n' \
            "$(date --iso-8601=seconds)" "$PHASE" "$attempt" "$INSPECT_STAGE" "$rc" >> "$OUT/inspection-errors.log"
        for file in "$OUT"/current-*; do
            [[ -f $file ]] || continue
            cp -- "$file" "$prefix-${file##*/}" || gap 'Could not preserve a failed inspection snapshot.'
            if [[ $file == *.error && -s $file ]]; then
                printf '%s\n' "${file##*/}:" >> "$OUT/inspection-errors.log"
                redact < "$file" >> "$OUT/inspection-errors.log"
            fi
        done
        warn "State inspection failed at $INSPECT_STAGE (attempt $attempt/3); details: inspection-errors.log. No action authorized by this snapshot."
        # A known structural mismatch is not a transient transport failure.
        [[ -z ${S[ControlGroup]:-} || ${S[ControlGroup]} == "$CG" ]] || return 1
        ((attempt==3)) || sleep 5
    done
    gap 'Three consecutive state inspections failed; no signals/start permitted from unknown state.'
    return 1
}
clean() {
    [[ ${S[LoadState]} == loaded && ( ${S[ActiveState]} == inactive || ${S[ActiveState]} == failed ) &&
       ${S[MainPID]} == 0 && ${S[ControlPID]} == 0 && $ZCOUNT == 0 && $CG_POP == 0 && $JOBS == 0 && $LISTENERS == 0 ]]
}

resources() {
    local tag=$1 pid ppid state group n=0 file
    cp "$OUT/current-unit.txt" "$OUT/$tag-unit.txt"
    cp "$OUT/current-zabbix-processes.tsv" "$OUT/$tag-processes.tsv"
    cp "$OUT/current-listeners.txt" "$OUT/$tag-listeners.txt"
    capture "$tag-process-details" 10 ps -eo pid,ppid,stat,etime,pcpu,pmem,wchan:28,args
    capture "$tag-memory" 10 free -m
    capture "$tag-disk" 10 df -lP
    capture "$tag-inodes" 10 df -liP
    capture "$tag-vmstat" 8 vmstat 1 2
    capture "$tag-pressure" 5 sh -c 'for f in /proc/pressure/*; do echo "$f"; cat "$f"; done'
    : > "$OUT/$tag-cgroup.txt"
    for file in cgroup.events memory.events memory.current memory.max pids.current pids.max pids.events; do
        if [[ -r /sys/fs/cgroup$CG/$file ]]; then
            printf '\n%s\n' "$file" >> "$OUT/$tag-cgroup.txt"
            cat /sys/fs/cgroup"$CG"/"$file" >> "$OUT/$tag-cgroup.txt"
        fi
    done
    # A D-state task may survive even SIGKILL; collect wait locations, never retry forever.
    while IFS=$'\t' read -r pid ppid state group; do
        [[ $state == D* ]] || continue
        ((n+=1)); ((n<=20)) || break
        capture "$tag-D-$pid" 5 sh -c 'for f in status wchan stack; do echo "$f"; cat "/proc/$1/$f"; done' sh "$pid"
    done < "$OUT/current-zabbix-processes.tsv"
}

# Follow an open inode and collect bounded byte ranges, never scan old giant rotations.
open_log() {
    if [[ -f $LOG && -r $LOG ]] && exec 8< "$LOG"; then
        LOG_OPEN=1
        LOG_OFFSET=$(stat -Lc %s /proc/$$/fd/8) || { LOG_OPEN=0; gap 'Cannot stat initial log.'; }
    else
        gap "File log unavailable: $LOG. Journald is collected separately."
    fi
}
log_chunk() {
    local size count available
    size=$(stat -Lc %s /proc/$$/fd/8) || { gap 'Cannot stat open log inode.'; return; }
    if ((size<LOG_OFFSET)); then gap 'Log truncated; reset byte offset; some records may be missing.'; LOG_OFFSET=0; fi
    count=$((size-LOG_OFFSET)); ((count>0)) || return 0
    available=$((LOG_LIMIT-LOG_BYTES))
    if ((count>CHUNK_LIMIT)); then gap 'Log rate exceeded per-sample cap; records skipped.'; count=$CHUNK_LIMIT; fi
    if ((count>available)); then count=$available; fi
    if ((count>0)); then
        timeout -k 2 8 dd if=/proc/$$/fd/8 iflag=skip_bytes,count_bytes \
            skip="$LOG_OFFSET" count="$count" status=none 2> "$OUT/log-read.error" | redact >> "$OUT/$PHASE-new-log.txt" || gap 'Log byte-range read failed.'
        LOG_BYTES=$((LOG_BYTES+count))
    fi
    if ((LOG_BYTES>=LOG_LIMIT && LOG_CAPPED==0)); then LOG_CAPPED=1; gap 'New log collection reached 32 MiB total cap.'; fi
    LOG_OFFSET=$size
}
log_delta() {
    local old new
    if ((LOG_OPEN)); then
        log_chunk
        old=$(stat -Lc '%d:%i' /proc/$$/fd/8) || return 0
        new=$(stat -Lc '%d:%i' -- "$LOG" 2>/dev/null) || return 0
        [[ $old != "$new" ]] || return 0
        gap 'Log inode rotated; followed old and new inode. Multiple rapid rotations may leave gaps.'
        exec 8<&-; LOG_OPEN=0
    fi
    if [[ -f $LOG && -r $LOG ]] && exec 8< "$LOG"; then
        LOG_OPEN=1; LOG_OFFSET=0; log_chunk
    fi
}

install_policy() {
    local dir=${DROPIN%/*}
    cat > "$OUT/expected-policy.conf" <<'EOF'
# Owned by zabbix_safe_restart.sh v1; retained for operator review.
[Service]
Restart=no
SendSIGKILL=no
KillMode=control-group
KillSignal=SIGTERM
TimeoutStopSec=infinity
EOF
    [[ ! -L $dir && ! -L $DROPIN ]] || { bad 'Runtime drop-in path is a symlink.'; return 1; }
    mkdir -p "$dir" || return 1
    if [[ -e $DROPIN ]]; then
        cmp -s "$OUT/expected-policy.conf" "$DROPIN" || { bad "Unrelated file exists at $DROPIN."; return 1; }
    else
        (set -o noclobber; cat "$OUT/expected-policy.conf" > "$DROPIN") || return 1
    fi
    chmod 644 "$DROPIN" || return 1
    ctl daemon-reload || return 1
    read_state || return 1
    policy_ok || { bad 'Effective runtime policy differs from requested policy.'; return 1; }
    log "Runtime policy installed and retained: $DROPIN"
}
policy_ok() {
    [[ ${S[Restart]:-} == no && ${S[SendSIGKILL]:-} == no &&
       ${S[KillMode]:-} == control-group && ${S[KillSignal]:-} == 15 && ${S[TimeoutStopUSec]:-} == infinity ]]
}
# The observed failed run overlapped unattended-upgrade and a systemd reexec.
# Never stop package management; refuse new service mutations until it is idle.
package_guard() {
    local active
    timeout -k 2 10 ps -eo pid=,ppid=,comm=,args= > "$OUT/package-processes.txt" 2> "$OUT/package-processes.error" || {
        bad 'Cannot check package-manager processes; service action refused.'; return 1;
    }
    awk '$3=="dpkg" || $3=="apt" || $3=="apt-get" ||
         $0 ~ /\/(unattended-upgrade|dpkg|apt|apt-get)([[:space:]]|$)/ {print}' \
        "$OUT/package-processes.txt" > "$OUT/package-active.txt"
    if [[ -s $OUT/package-active.txt ]]; then
        bad 'Package installation/upgrade is running. Wait for it to finish; do not kill apt/dpkg. See package-active.txt.'
        return 1
    fi
    ctl show apt-daily-upgrade.service -p ActiveState --value > "$OUT/package-unit.txt" 2> "$OUT/package-unit.error" || {
        bad 'Cannot check apt-daily-upgrade state; service action refused.'; return 1;
    }
    read -r active < "$OUT/package-unit.txt" || return 1
    case "$active" in
        inactive|failed) return 0 ;;
        active|activating|deactivating|reloading)
            bad "apt-daily-upgrade.service is $active. Retry after the update finishes; it is not stopped by this script."; return 1 ;;
        *) bad "Unknown package-update unit state: $active. Service action refused."; return 1 ;;
    esac
}

stop_identity_ok() {
    [[ -z ${S[InvocationID]} || ${S[InvocationID]} == "$STOP_ID" ]] &&
    [[ ${S[ActiveState]} != active && ${S[ActiveState]} != activating && $OUTSIDE == 0 ]]
}

wait_clean() {
    local limit=$1 begin now report=0
    begin=$(mono)
    while :; do
        inspect_reliably || { bad 'Cannot verify stopped state after three read attempts; no further signals/start.'; return 2; }
        log_delta
        clean && return 0
        if ((OUTSIDE>0)); then bad 'Zabbix processes exist outside this unit; no signals/start permitted.'; return 2; fi
        if [[ -n ${S[InvocationID]} && ${S[InvocationID]} != "$STOP_ID" ]]; then
            bad 'Invocation changed during shutdown; external service management suspected.'; return 2
        fi
        now=$(mono)
        if ((now>=report)); then
            log "Stopping: ${S[ActiveState]}/${S[SubState]}, processes=$ZCOUNT, D=$DCOUNT, cgroup=$CG_POP, jobs=$JOBS, listeners=$LISTENERS"
            report=$((now+30))
        fi
        ((now-begin<limit)) || return 1
        sleep 5
    done
}
signal_unit() {
    local sig=$1
    package_guard || return 1
    inspect_reliably && policy_ok && stop_identity_ok || { bad "Refusing $sig: unit identity/state/policy changed or could not be read."; return 1; }
    ((CG_POP==1)) || { bad "Refusing $sig: no populated service cgroup; inspect jobs/listener owners."; return 1; }
    log "Sending $sig through systemd to $UNIT only."
    ctl kill --kill-whom=all --signal="$sig" "$UNIT" >> "$OUT/signals.txt" 2>&1
}
stop_service() {
    local rc
    PHASE=stop
    inspect_reliably || return 2
    clean && { log 'Service already fully stopped.'; return 0; }
    ((OUTSIDE==0)) || { bad 'Unmanaged Zabbix processes found; refusing stop/start.'; return 2; }
    STOP_ID=${S[InvocationID]}
    STOP_SENT=1
    log 'Submitting systemctl stop --no-block.'
    ctl stop --no-block "$UNIT" > "$OUT/stop-command.txt" 2>&1 || { bad 'Stop request failed or timed out; no start.'; return 2; }
    wait_clean "$GRACE"; rc=$?
    ((rc==0)) && return 0
    ((rc==1)) || return 2
    resources stop-timeout
    warn "Graceful stop exceeded ${GRACE}s; collecting evidence and requesting SIGTERM for remaining unit processes."
    signal_unit SIGTERM || return 2
    wait_clean 60; rc=$?
    ((rc==0)) && return 0
    ((rc==1)) || return 2
    resources after-term
    if ((FORCE==0)); then
        bad 'Processes/stop job remain. No new start. Review archive; --force-after-timeout is an explicit separate option.'
        return 2
    fi
    warn 'Forced shutdown authorized by flag; unflushed monitoring data may be lost.'
    FORCE_SENT=1
    signal_unit SIGKILL || return 2
    wait_clean 60; rc=$?
    if ((rc!=0)); then
        bad 'Still not fully stopped after SIGKILL. Possible D-state I/O wait or stuck systemd job; no start.'
        resources after-kill
        return 2
    fi
}

listener_owned() {
    local pid group owners
    ((LISTENERS>0)) || return 1
    # Enumerate every PID, including multiple owners on a single socket line.
    owners=$(grep -oE 'pid=[0-9]+' "$OUT/current-listeners.txt" | cut -d= -f2 | sort -u) || return 1
    [[ -n $owners ]] || return 1
    while read -r pid; do group=$(pid_group "$pid") && in_group "$group" || return 1; done <<< "$owners"
}
running() {
    local name group
    [[ ${S[ActiveState]} == active && ${S[SubState]} == running && ${S[MainPID]} != 0 && $OUTSIDE == 0 && $CG_POP == 1 ]] || return 1
    read -r name < /proc/"${S[MainPID]}"/comm 2>/dev/null || return 1
    [[ $name == zabbix_server ]] || return 1
    group=$(pid_group "${S[MainPID]}") && in_group "$group" && listener_owned
}
observe() {
    local begin=$1 now report=0 snapshot=0
    while :; do
        inspect_reliably || { bad 'Observation cannot read service/process state.'; return 1; }
        log_delta
        if [[ ${S[MainPID]} != 0 ]]; then
            if [[ -n $FIRST_PID && $FIRST_PID != "${S[MainPID]}" ]]; then bad 'MainPID changed during observation.'; fi
            if [[ -n $FIRST_ID && $FIRST_ID != "${S[InvocationID]}" ]]; then bad 'InvocationID changed during observation.'; fi
            [[ -n $FIRST_PID ]] || FIRST_PID=${S[MainPID]}
            [[ -n $FIRST_ID ]] || FIRST_ID=${S[InvocationID]}
        fi
        [[ ${S[NRestarts]} == 0 ]] || bad "Automatic restarts recorded: ${S[NRestarts]}."
        [[ ${S[ActiveState]} != failed ]] || { bad "Service failed: ${S[Result]}."; return 1; }
        ((OUTSIDE==0)) || { bad 'Zabbix processes outside service appeared.'; return 1; }
        if running; then RUN_SEEN=1
        elif ((RUN_SEEN)); then bad 'Service lost its running state or owned TCP listener.'; return 1
        fi
        now=$(mono)
        if ((now>=report)); then
            log "Observing $((now-begin))/${OBSERVE}s: ${S[ActiveState]}/${S[SubState]}, PID=${S[MainPID]}, processes=$ZCOUNT, listeners=$LISTENERS"
            report=$((now+30))
        fi
        if ((now>=snapshot)); then resources "sample-$((now-begin))"; snapshot=$((now+60)); fi
        ((now-begin<OBSERVE)) || break
        sleep 10
    done
    inspect_reliably && running || { bad 'At end: service/main process/owned listener is not ready. For HA, inspect final-ha-status before concluding a crash.'; return 1; }
}
start_service() {
    local begin
    PHASE=prestart
    package_guard || return 2
    inspect_reliably && clean || { bad 'Start refused: old processes/cgroup/jobs/listener remain or state is unknown.'; return 2; }
    # Fix for the previous script: inactive units do not require reset-failed.
    if [[ ${S[ActiveState]} == failed ]]; then
        ctl reset-failed "$UNIT" > "$OUT/reset-failed.txt" 2>&1 || {
            inspect_reliably && clean && [[ ${S[ActiveState]} == inactive ]] || { bad 'reset-failed failed and a safe inactive state was not verified.'; return 2; }
            warn 'reset-failed returned an error, but unit was reverified inactive and fully stopped.'
        }
    fi
    log_delta
    inspect_reliably && clean && policy_ok || { bad 'Final pre-start checks failed.'; return 2; }
    PHASE=start
    START_WALL=$(date '+%Y-%m-%d %H:%M:%S')
    begin=$(mono)
    START_SENT=1
    log 'Submitting ONE systemctl start --no-block; no automatic retries.'
    ctl start --no-block "$UNIT" > "$OUT/start-command.txt" 2>&1 || { bad 'Start request failed or timed out; no retry.'; return 1; }
    observe "$begin"
}

classify() {
    local f
    : > "$OUT/log-findings.txt"
    for f in "$OUT/start-new-log.txt" "$OUT/diagnose-new-log.txt" "$OUT/start-journal.txt" "$OUT/kernel-journal.txt"; do
        [[ -f $f ]] || continue
        awk '{s=tolower($0)
          if(s~/segfault|segmentation fault|core dumped|assertion.*failed|out of memory|oom-kill|killed process|cannot allocate memory|one child process died|database is down|cannot connect.*database|connection to database.*failed|no space left on device|too many open files|please increase.*cache|failed to start|failed with result|main process exited|address already in use|cannot open.*config|unknown.*parameter|invalid.*parameter|cannot start|unsupported database|database version.*not supported|zabbix server stopped/)
            print "CRITICAL_CANDIDATE " FILENAME ":" FNR ":" $0
          else if(s~/not found|not monitored|unknown request|preprocessing failed|error|failed|cannot|denied|timed out|unreachable|refused/)
            print "WARNING_CANDIDATE " FILENAME ":" FNR ":" $0
        }' "$f" >> "$OUT/log-findings.txt"
    done
    if grep -q '^CRITICAL_CANDIDATE' "$OUT/log-findings.txt"; then bad 'Potential critical messages found; inspect log-findings.txt with source context.'; fi
    if grep -q '^WARNING_CANDIDATE' "$OUT/log-findings.txt"; then warn 'Monitoring/log warnings found; see log-findings.txt.'; fi
}

finish() {
    local result=$1 until archive
    trap - INT TERM HUP
    log_delta
    if inspect_reliably; then resources final; else gap 'Final state inspection failed.'; fi
    until=$(date '+%Y-%m-%d %H:%M:%S')
    capture unit-journal 15 journalctl -b -u "$UNIT" --since "$SINCE" --until "$until" -n 4000 --no-pager -o short-iso-precise
    capture kernel-journal 15 journalctl -b -k --since "$SINCE" --until "$until" -n 2000 --no-pager -o short-iso-precise
    capture systemd-manager-journal 15 journalctl -b _PID=1 --since "$SINCE" --until "$until" -n 1000 --no-pager -o short-iso-precise
    capture dbus-journal 15 journalctl -b -u dbus.service -u dbus-broker.service --since "$SINCE" --until "$until" -n 1000 --no-pager -o short-iso-precise
    if ((START_SENT)); then
        capture start-journal 15 journalctl -b -u "$UNIT" --since "$START_WALL" --until "$until" -n 4000 --no-pager -o short-iso-precise
    fi
    if [[ ${S[MainPID]:-0} != 0 ]] && command -v zabbix_server >/dev/null; then
        capture final-ha-status 12 zabbix_server -c "$CONFIG" -R ha_status
    fi
    capture final-db-connections 10 ss -H -tnp 'dport = :5432'
    log_delta
    classify
    if ! inspect_reliably; then
        gap 'Cannot verify state at report completion.'
        ((result!=0)) || result=3
    elif ((result==0)); then
        if [[ $MODE == stop ]]; then
            clean || { bad 'Service no longer fully stopped at report completion.'; result=1; }
        else
            running || { bad 'Service/listener not ready at report completion.'; result=1; }
        fi
    fi
    if ((result==0)); then
        if ((CRITICAL)); then result=1; elif ((GAPS)); then result=3; fi
    fi
    {
        printf 'Script version: %s\nInspection failures: %s\n' "$SCRIPT_VERSION" "$INSPECT_FAILURES"
        printf 'Mode: %s\nExit code: %s\nStop submitted: %s\nStart submitted: %s\nForced SIGKILL requested: %s\n' "$MODE" "$result" "$STOP_SENT" "$START_SENT" "$FORCE_SENT"
        printf 'State: %s/%s; MainPID=%s; Zabbix processes=%s; outside cgroup=%s; D-state=%s\n' "${S[ActiveState]:-unknown}" "${S[SubState]:-unknown}" "${S[MainPID]:-unknown}" "$ZCOUNT" "$OUTSIDE" "$DCOUNT"
        printf 'Critical findings: %s\nCollection gaps: %s\nRuntime policy retained if installed: %s\n' "$CRITICAL" "$GAPS" "$DROPIN"
        printf 'Effective Restart=%s; UnitFileState=%s\n' "${S[Restart]:-unknown}" "${S[UnitFileState]:-unknown}"
        printf 'Review critical.txt, warnings.txt, collection-gaps.txt, timeline.tsv, log-findings.txt and final-* files.\n'
        printf 'Fresh metrics, DB writes, proxy backlog and remote HA peers were NOT verified. Pattern matches are candidates.\n'
        printf 'Journals limited to last 4000 unit / 2000 kernel entries; process captures limited to 2 MiB. Secret redaction is partial.\n'
        printf 'No HA/DB/firewall/config/autostart edits. No PID-file removal. No start is permitted with surviving old processes.\n'
    } > "$OUT/SUMMARY.txt"
    log "Finished: exit=$result; report=$OUT"
    archive=$OUT.tar.gz
    if timeout -k 5 60 tar -C "${OUT%/*}" -czf "$archive" "${OUT##*/}"; then
        printf '\nSEND THIS ARCHIVE: %s\n' "$archive"
        sha256sum "$archive"
    else
        printf '\nARCHIVE FAILED: copy report directory %s instead.\n' "$OUT" >&2
        result=3
    fi
    return "$result"
}
interrupted() { gap 'Interrupted by signal; no additional service management will be performed.'; finish 130; exit 130; }

main() {
    local tool rc=0 base=/var/log/zabbix-safe-restart
    case "${1:-}" in -h|--help) usage; return 0 ;; esac
    parse "$@" || { usage; return 2; }
    [[ $(uname -s) == Linux && $EUID == 0 && -f /sys/fs/cgroup/cgroup.controllers ]] || {
        echo 'Requires root on Linux with systemd and cgroup v2 (target: Ubuntu 24.04).' >&2; return 2;
    }
    for tool in systemctl journalctl timeout flock ps ss awk grep cut sort head tail tr date stat dd free df vmstat tar sha256sum mktemp tee cmp chmod cp wc sleep mkdir cat; do
        command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; return 2; }
    done
    [[ ! -L /run/zabbix-recovery.lock && ! -L $base ]] || { echo 'Refusing symlink lock/report root.' >&2; return 2; }
    exec 9>/run/zabbix-recovery.lock || return 2
    flock -n 9 || { echo 'Another Zabbix recovery/observation is running.' >&2; return 2; }
    mkdir -p "$base" && chmod 700 "$base" || return 2
    OUT=$(mktemp -d "$base/$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 2
    SINCE=$(date '+%Y-%m-%d %H:%M:%S')
    START_WALL=$SINCE
    : > "$OUT/critical.txt"; : > "$OUT/warnings.txt"; : > "$OUT/collection-gaps.txt"
    printf 'time\tphase\tactive\tsub\tmain_pid\tzabbix_processes\toutside\tcgroup_populated\tD_state\tjobs\tlisteners\n' > "$OUT/timeline.tsv"
    trap interrupted INT TERM HUP
    log "Version=$SCRIPT_VERSION; Mode=$MODE; force=$FORCE; report=$OUT"
    capture versions 10 sh -c 'uname -a; systemctl --version; zabbix_server -V'
    capture unit-definition 10 systemctl cat "$UNIT" --no-pager
    capture before-unit-journal 15 journalctl -b -u "$UNIT" -n 3000 --no-pager -o short-iso-precise
    capture unit-command 10 systemctl show "$UNIT" -p ExecStart -p EnvironmentFiles -p TriggeredBy -p OnFailure
    capture config-filtered 8 awk '/^[[:space:]]*#/ {next} /^[[:space:]]*(Include|HANodeName|NodeAddress|LogType|LogFile|LogFileSize|ListenIP|ListenPort|DBHost|DBPort|DBName|DBUser|Timeout|Start[A-Za-z]+|[A-Za-z]*CacheSize)[[:space:]]*=/ {print}' "$CONFIG"
    capture previous-log-tail 8 tail -c 65536 -- "$LOG"
    printf 'Diagnostic config=%s\nDiagnostic log=%s\nInclude files are not expanded; compare actual ExecStart and EnvironmentFile.\nPrevious-log-tail is historical and is not classified as a new startup failure.\n' "$CONFIG" "$LOG" > "$OUT/config-note.txt"
    if grep -Eq '^[[:space:]]*HANodeName[[:space:]]*=[[:space:]]*[^[:space:]]' "$OUT/config-filtered.txt"; then
        warn 'HANodeName is set: HA configuration is retained. Standby may have no listener. Remote HA peers are not checked.'
    fi
    if ! inspect_reliably; then bad 'Initial state cannot be verified.'; finish 2; return $?; fi
    resources before
    open_log
    if [[ $MODE == diagnose ]]; then
        PHASE=diagnose
        observe "$(mono)"; rc=$?
    elif [[ ${S[LoadState]} != loaded ]]; then
        bad 'Unit not loaded or masked. No automatic unmask/installation.'; rc=2
    elif ((OUTSIDE>0)); then
        bad 'Zabbix processes outside the standard unit cgroup. Refusing management, including forced signals.'; rc=2
    elif [[ $MODE == start ]] && ! clean; then
        bad 'Use --restart for an existing/stopping instance; --start requires a complete stop.'; rc=2
    elif ! package_guard; then
        rc=2
    elif ! install_policy; then
        bad 'Cannot install/verify runtime policy.'; rc=2
    else
        case "$MODE" in
            stop) stop_service; rc=$? ;;
            restart) stop_service; rc=$?; if ((rc==0)); then start_service; rc=$?; fi ;;
            start) start_service; rc=$? ;;
        esac
    fi
    finish "$rc"
}

# Sourcing defines functions only, for isolated local regression tests.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; exit $?; fi
