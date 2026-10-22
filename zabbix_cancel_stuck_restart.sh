#!/usr/bin/env bash
# Cancel verified restart jobs for an already stuck Zabbix instance.
# No signals, package-manager termination, service start/stop or config edits.
set -u
set -o pipefail
umask 077
export LC_ALL=C SYSTEMD_PAGER=cat SYSTEMD_COLORS=0
ZRC_UNIT=zabbix-server.service
ZRC_OUT=
ZRC_VERSION=1.1
ZRC_EXPECTED_INVOCATION=
ZRC_DRAIN=0
ZRC_LAST_CANCELLED=
ZRC_BUSY=1
ZRC_WAITER=0
ZRC_LIMIT=300
ZRC_MAX_CANCELS=6
ZRC_QUIET=30
ZRC_DEADLINE=0

zrc_ctl() { timeout -k 3 15 systemctl --no-ask-password "$@"; }
zrc_prop() {
    awk -F= -v key="$2" '$1==key {n++;v=substr($0,length(key)+2)} END {if(n!=1)exit 1;print v}' "$1"
}
zrc_validate_state() {
    [[ $(zrc_prop "$1" LoadState) == loaded &&
       $(zrc_prop "$1" ActiveState) == deactivating &&
       $(zrc_prop "$1" SubState) == stop-sigterm &&
       $(zrc_prop "$1" MainPID) == 0 &&
       $(zrc_prop "$1" ControlPID) == 0 &&
       $(zrc_prop "$1" ControlGroup) == /system.slice/zabbix-server.service &&
       $(zrc_prop "$1" InvocationID) =~ ^[a-fA-F0-9]{32}$ ]]
}
zrc_job() {
    awk -v unit="$ZRC_UNIT" '$2==unit {n++; if($1~/^[0-9]+$/ && $3=="restart" && $4=="running") id=$1}
        END {if(n!=1 || id=="")exit 1;print id}' "$1"
}
zrc_snapshot() {
    zrc_ctl show "$ZRC_UNIT" -p LoadState -p ActiveState -p SubState -p MainPID \
        -p ControlPID -p ControlGroup -p InvocationID > "$ZRC_OUT/$1-state.txt" 2> "$ZRC_OUT/$1-state.error" || return 1
    zrc_ctl list-jobs --no-legend --no-pager > "$ZRC_OUT/$1-jobs.txt" 2> "$ZRC_OUT/$1-jobs.error"
}
zrc_cancel() {
    local id1 id2 invocation1 invocation2 next_id now
    zrc_snapshot before && zrc_validate_state "$ZRC_OUT/before-state.txt" || {
        echo 'REFUSED: expected a verified stop-sigterm state with MainPID=0. No job cancelled.'; return 2;
    }
    id1=$(zrc_job "$ZRC_OUT/before-jobs.txt") || {
        echo 'REFUSED: expected exactly one running restart job for Zabbix. No job cancelled.'; return 2;
    }
    invocation1=$(zrc_prop "$ZRC_OUT/before-state.txt" InvocationID) || return 2
    [[ -z $ZRC_EXPECTED_INVOCATION || $invocation1 == "$ZRC_EXPECTED_INVOCATION" ]] || {
        echo 'REFUSED: Zabbix invocation changed since monitoring began.'; return 2;
    }
    [[ $id1 != "$ZRC_LAST_CANCELLED" ]] || {
        echo 'REFUSED: the previously cancelled job is still present. No retry.'; return 3;
    }
    # Revalidate identity and current job; never use the ID from an old archive.
    zrc_snapshot verified && zrc_validate_state "$ZRC_OUT/verified-state.txt" || {
        echo 'REFUSED: state changed or could not be re-read. No job cancelled.'; return 2;
    }
    id2=$(zrc_job "$ZRC_OUT/verified-jobs.txt") || return 2
    invocation2=$(zrc_prop "$ZRC_OUT/verified-state.txt" InvocationID) || return 2
    [[ $id1 == "$id2" && $invocation1 == "$invocation2" ]] || {
        echo 'REFUSED: job/instance changed. No job cancelled.'; return 2;
    }
    if ((ZRC_DRAIN)); then
        zrc_activity "$ZRC_OUT" || return 2
        ((ZRC_WAITER==1)) || {
            echo 'REFUSED: no verified unattended-upgrade -> needrestart -> systemctl restart waiter.'; return 2;
        }
        now=$(zrc_now) && [[ $now =~ ^[0-9]+$ ]] || { echo 'REFUSED: cannot read cancellation deadline clock.'; return 2; }
        ((now<ZRC_DEADLINE)) || { echo 'REFUSED: cancellation deadline reached.'; return 2; }
    fi
    printf 'Cancelling job %s for %s only.\n' "$id2" "$ZRC_UNIT"
    # A numeric argument is mandatory: bare systemctl cancel would cancel ALL jobs.
    zrc_ctl cancel "$id2" > "$ZRC_OUT/cancel.txt" 2>&1 || {
        echo 'Cancellation returned an error/timeout; outcome uncertain. No automatic retry.'; return 3;
    }
    ZRC_LAST_CANCELLED=$id2
    zrc_snapshot after || { echo 'Cancellation submitted, but final verification failed.'; return 3; }
    if awk -v unit="$ZRC_UNIT" '$2==unit && $3=="restart" {found=1} END {exit !found}' "$ZRC_OUT/after-jobs.txt"; then
        if ((ZRC_DRAIN)) && next_id=$(zrc_job "$ZRC_OUT/after-jobs.txt") && [[ $next_id != "$id2" ]] &&
            zrc_validate_state "$ZRC_OUT/after-state.txt" && [[ $(zrc_prop "$ZRC_OUT/after-state.txt" InvocationID) == "$invocation1" ]]; then
            echo 'A different restart job appeared; the next iteration must revalidate its identity and requester.'
            return 0
        fi
        echo 'A Zabbix restart job is still present or was recreated. No further cancellation performed.'; return 3
    fi
    echo 'No Zabbix restart job in this snapshot. Existing Zabbix processes have NOT been killed.'
    if ((ZRC_DRAIN==0)); then
        echo 'This does not confirm update completion: a later restart job may appear.'
        echo 'Check package processes and jobs before using zabbix_safe_restart.sh.'
    fi
}

zrc_now() { local value rest; read -r value rest < /proc/uptime || return 1; printf '%s\n' "${value%%.*}"; }
zrc_sleep() { sleep "$1"; }

# Input: ps -eo pid=,ppid=,comm=,args=. Do not mistake the idle shutdown helper
# for an installation. A failed systemd unit can still have live descendants.
zrc_filter_packages() {
    awk '$3=="dpkg" || $3=="apt" || $3=="apt-get" || $3=="needrestart" ||
        $0 ~ /\/(unattended-upgrade|dpkg|apt|apt-get|needrestart|apt\.systemd\.daily)([[:space:]]|$)/ {print}' "$1"
}
zrc_find_waiter() {
    awk -v unit="$ZRC_UNIT" '
      {parent[$1]=$2; command[$1]=$3
       for(i=4;i<=NF;i++) {
         if($i=="restart") restart[$1]=1
         if($i==unit) target[$1]=1
         if($i=="/usr/bin/unattended-upgrade") upgrade[$1]=1
         if($i=="/usr/sbin/needrestart") need[$1]=1
       }
      }
      END {
        found=0
        for(pid in parent) if(command[pid]=="systemctl" && restart[pid] && target[pid]) {
          p=parent[pid]; saw_need=0; saw_upgrade=0
          for(n=0;n<32 && p>1 && (p in parent);n++) {
            if(need[p]) saw_need=1
            if(upgrade[p] && saw_need) saw_upgrade=1
            p=parent[p]
          }
          if(saw_need && saw_upgrade) {print pid;found=1}
        }
        if(!found) exit 1
      }' "$1"
}
zrc_activity() {
    local dir=$1 active enabled package_state
    ZRC_BUSY=1 ZRC_WAITER=0
    zrc_ctl show apt-daily-upgrade.timer -p LoadState -p ActiveState -p UnitFileState \
        > "$dir/timer.txt" 2> "$dir/timer.error" || return 1
    active=$(zrc_prop "$dir/timer.txt" ActiveState) || return 1
    enabled=$(zrc_prop "$dir/timer.txt" UnitFileState) || return 1
    [[ $active == inactive && ( $enabled == disabled || $enabled == masked || $enabled == masked-runtime ) ]] || {
        echo 'REFUSED: apt-daily-upgrade.timer must already be inactive and disabled/masked.'; return 1;
    }
    zrc_ctl show apt-daily-upgrade.service -p ActiveState -p SubState -p MainPID -p Result \
        > "$dir/upgrade-unit.txt" 2> "$dir/upgrade-unit.error" || return 1
    package_state=$(zrc_prop "$dir/upgrade-unit.txt" ActiveState) || return 1
    case "$package_state" in
        inactive|failed|active|activating|deactivating|reloading) ;;
        *) echo 'REFUSED: unknown update service state.'; return 1 ;;
    esac
    timeout -k 2 10 ps -ww -eo pid=,ppid=,comm=,args= > "$dir/processes.txt" 2> "$dir/processes.error" || return 1
    zrc_filter_packages "$dir/processes.txt" > "$dir/package-active.txt" || return 1
    if zrc_find_waiter "$dir/processes.txt" > "$dir/restart-waiters.txt"; then ZRC_WAITER=1; fi
    if [[ ! -s $dir/package-active.txt && ( $package_state == inactive || $package_state == failed ) ]]; then ZRC_BUSY=0; fi
}
zrc_audit() { timeout -k 3 30 dpkg --audit > "$1/dpkg-audit.txt" 2>&1 && [[ ! -s $1/dpkg-audit.txt ]]; }

zrc_monitor() {
    local tag=$1 invocation
    zrc_snapshot "$tag" && zrc_validate_state "$ZRC_OUT/$tag-state.txt" || {
        echo 'REFUSED: Zabbix is no longer the verified stuck instance, or state read failed.'; return 2;
    }
    invocation=$(zrc_prop "$ZRC_OUT/$tag-state.txt" InvocationID) || return 2
    [[ -z $ZRC_EXPECTED_INVOCATION || $invocation == "$ZRC_EXPECTED_INVOCATION" ]] || {
        echo 'REFUSED: Zabbix invocation changed. No further cancellation.'; return 2;
    }
    ZRC_EXPECTED_INVOCATION=$invocation
}

zrc_drain() {
    local root=$ZRC_OUT begin now quiet=-1 count=0 step=0 jobs rc
    ZRC_DRAIN=1
    begin=$(zrc_now) || return 2
    ZRC_DEADLINE=$((begin+ZRC_LIMIT))
    zrc_monitor initial || return 2
    while :; do
        now=$(zrc_now) || return 2
        ((now-begin<ZRC_LIMIT)) || { echo 'REFUSED: bounded wait expired; update still not verified idle.'; return 2; }
        step=$((step+1))
        zrc_monitor "sample-$step" || return 2
        zrc_activity "$root" || { echo 'REFUSED: cannot verify update activity/timer.'; return 2; }
        jobs=$(awk -v unit="$ZRC_UNIT" '$2==unit {n++} END {print n+0}' "$root/sample-$step-jobs.txt") || return 2
        printf 'elapsed=%ss package_busy=%s zabbix_jobs=%s cancellations=%s/%s\n' \
            "$((now-begin))" "$ZRC_BUSY" "$jobs" "$count" "$ZRC_MAX_CANCELS"
        if ((jobs>0)); then
            quiet=-1
            ((count<ZRC_MAX_CANCELS)) || { echo 'REFUSED: cancellation limit reached.'; return 2; }
            ((ZRC_WAITER==1)) || { echo 'REFUSED: restart requester is not a verified upgrade/needrestart chain.'; return 2; }
            now=$(zrc_now) || return 2
            ((now-begin<ZRC_LIMIT)) || return 2
            count=$((count+1))
            ZRC_OUT=$root/cancel-$count
            mkdir "$ZRC_OUT" || { ZRC_OUT=$root; return 2; }
            if zrc_cancel; then rc=0; else rc=$?; fi
            ZRC_OUT=$root
            ((rc==0)) || return "$rc"
        elif ((ZRC_BUSY==0)); then
            ((quiet>=0)) || quiet=$now
            if ((now-quiet>=ZRC_QUIET)); then
                zrc_audit "$root" || { echo 'REFUSED: dpkg audit returned findings/error; see dpkg-audit.txt.'; return 2; }
                zrc_monitor final && zrc_activity "$root" || return 2
                jobs=$(awk -v unit="$ZRC_UNIT" '$2==unit {n++} END {print n+0}' "$root/final-jobs.txt") || return 2
                ((ZRC_BUSY==0 && jobs==0)) || { echo 'REFUSED: package activity or Zabbix job reappeared during final check.'; return 2; }
                echo 'UPGRADE RELEASED: package processes absent for the observation window; no Zabbix job; dpkg audit clear.'
                echo 'This does NOT prove all updates installed successfully. Review the update journal.'
                echo 'Zabbix has NOT been restarted. Now use zabbix_safe_restart.sh --restart --force-after-timeout --grace-seconds 60.'
                return 0
            fi
        else
            quiet=-1
        fi
        zrc_sleep 5
    done
}

zrc_report() {
    local result=$1 file temp archive status
    # Reports contain internal names/addresses; redact common secret-bearing lines.
    for file in apt-daily-upgrade.service "$ZRC_UNIT"; do
        if timeout -k 3 15 journalctl -b -u "$file" -n 250 --no-pager -o short-iso-precise > "$ZRC_OUT/$file-journal.txt" 2>&1; then status=0; else status=$?; fi
        printf '%s journal exit=%s\n' "$file" "$status" >> "$ZRC_OUT/collection-status.txt"
        if ((status!=0 && result==0)); then result=3; fi
    done
    for file in "$ZRC_OUT"/*.txt "$ZRC_OUT"/cancel-*/*.txt; do
        [[ -f $file ]] || continue
        temp=$file.redacted
        if awk '{s=tolower($0); if(s~/password|passwd|secret|token|tlspsk|private.?key/) print "[REDACTED: potentially secret-bearing line]"; else print}' "$file" > "$temp"; then
            mv -- "$temp" "$file" || result=3
        else result=3
        fi
    done
    printf 'Version: %s\nMode: %s\nExit code: %s\nReport: %s\n' "$ZRC_VERSION" "$ZRC_DRAIN" "$result" "$ZRC_OUT" > "$ZRC_OUT/SUMMARY.txt"
    archive=$ZRC_OUT.tar.gz
    if timeout -k 3 45 tar -C "${ZRC_OUT%/*}" -czf "$archive" "${ZRC_OUT##*/}"; then
        printf 'SEND THIS ARCHIVE: %s\n' "$archive"
    else
        echo 'Archive failed; copy the report directory.'; result=3
        printf 'Version: %s\nMode: %s\nExit code: %s\nReport: %s\n' "$ZRC_VERSION" "$ZRC_DRAIN" "$result" "$ZRC_OUT" > "$ZRC_OUT/SUMMARY.txt"
    fi
    cat "$ZRC_OUT/SUMMARY.txt"
    return "$result"
}
zrc_main() {
    local tool result base=/var/log/zabbix-restart-job-cancel
    local -a pipe_codes
    if [[ ${1:-} == --help ]]; then
        echo 'Usage: sudo bash zabbix_cancel_stuck_restart.sh [--drain-upgrade]'
        echo 'Cancels only the current Zabbix restart job after verifying a stuck stop with MainPID=0.'
        echo '--drain-upgrade: up to 6 verified jobs / 300s wait, then 30s idle observation and dpkg audit.'
        echo 'Requires disabled/inactive upgrade timer; each cancellation requires an upgrade/needrestart waiter.'
        return 0
    fi
    if (($#==1)) && [[ $1 == --drain-upgrade ]]; then ZRC_DRAIN=1; shift; fi
    (($#==0)) && [[ $EUID == 0 && $(uname -s) == Linux ]] || { echo 'Run as root on the Linux Zabbix VM; optional flag: --drain-upgrade.'; return 2; }
    for tool in timeout systemctl awk flock mktemp date tee mkdir chmod ps dpkg sleep journalctl tar mv cat; do
        command -v "$tool" >/dev/null || { echo "Missing: $tool"; return 2; }
    done
    [[ ! -L /run/zabbix-recovery.lock && ! -L $base ]] || { echo 'Refusing symlink path.'; return 2; }
    exec 9>/run/zabbix-recovery.lock || return 2
    flock -n 9 || { echo 'Another Zabbix recovery is running.'; return 2; }
    mkdir -p "$base" && chmod 700 "$base" || return 2
    ZRC_OUT=$(mktemp -d "$base/$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 2
    if ((ZRC_DRAIN)); then
        zrc_drain 2>&1 | tee "$ZRC_OUT/run.log"
        pipe_codes=("${PIPESTATUS[@]}")
    else
        zrc_cancel 2>&1 | tee "$ZRC_OUT/run.log"
        pipe_codes=("${PIPESTATUS[@]}")
    fi
    result=${pipe_codes[0]}
    if ((pipe_codes[1]!=0)); then result=3; fi
    zrc_report "$result"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then zrc_main "$@"; exit $?; fi
