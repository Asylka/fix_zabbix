#!/usr/bin/env bash
# No real systemctl, dpkg, processes or sleep: all external control is mocked.
set -eu
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "$ROOT/tests/drain.XXXXXX")
COUNT=0
case_test() {
    local name=$1 body=$2
    (
        source "$ROOT/zabbix_cancel_stuck_restart.sh"
        ZRC_OUT=$WORK/$name; mkdir "$ZRC_OUT"; CASE_OUT=$ZRC_OUT
        EVENTS=$ZRC_OUT/events; : > "$EVENTS"
        CLOCK=0; CANCELS=0; NEED_CANCELS=2; AUDITS=0
        FIXTURE_INVOCATION=75746af206224b30a9ebf8ff4521d53b
        state=deactivating; sub=stop-sigterm; main=0; job_type=restart
        ACTIVITY_ERROR=0; UNVERIFIED=0; STUCK_BUSY=0; SAME_JOB=0
        CHANGED_INVOCATION=0; LATE_MAIN=0; CANCEL_ERROR=0
        AUDIT_ERROR=0; AUDIT_BUSY=0; FINAL_JOB=0; IMMEDIATE_JOB=0; DEADLINE_IN_CANCEL=0; CLOCK_FAILURE=0
        zrc_now() {
            if ((CLOCK_FAILURE)) && [[ $ZRC_OUT == */cancel-* ]]; then return 1; fi
            printf '%s\n' "$CLOCK"
        }
        zrc_sleep() { CLOCK=$((CLOCK+$1)); }
        zrc_ctl() {
            [[ $1 == cancel && $# == 2 && $2 =~ ^[0-9]+$ ]] || return 98
            printf '%s\n' "$*" >> "$EVENTS"
            CANCELS=$((CANCELS+1))
            ((CANCEL_ERROR==0))
        }
        zrc_snapshot() {
            local tag=$1 id
            if ((CHANGED_INVOCATION && CANCELS>0)); then FIXTURE_INVOCATION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi
            if ((LATE_MAIN && CLOCK>=5)); then main=90000; state=active; sub=running; fi
            printf 'LoadState=loaded\nActiveState=%s\nSubState=%s\nMainPID=%s\nControlPID=0\nControlGroup=/system.slice/zabbix-server.service\nInvocationID=%s\n' "$state" "$sub" "$main" "$FIXTURE_INVOCATION" > "$ZRC_OUT/$tag-state.txt"
            printf '999 ssh.service restart running\n' > "$ZRC_OUT/$tag-jobs.txt"
            if { [[ $tag != after ]] || ((IMMEDIATE_JOB)); } && { ((CANCELS<NEED_CANCELS)) || { [[ $tag == final ]] && ((FINAL_JOB)); }; }; then
                id=$((7155+CANCELS)); ((SAME_JOB==0)) || id=7155
                printf '%s zabbix-server.service %s running\n' "$id" "$job_type" >> "$ZRC_OUT/$tag-jobs.txt"
            fi
        }
        zrc_activity() {
            ((ACTIVITY_ERROR==0)) || return 1
            ZRC_BUSY=0; ZRC_WAITER=1
            if ((CANCELS<NEED_CANCELS || STUCK_BUSY || (AUDIT_BUSY && AUDITS>0))); then ZRC_BUSY=1; fi
            ((UNVERIFIED==0)) || ZRC_WAITER=0
            if ((DEADLINE_IN_CANCEL)) && [[ $1 == */cancel-* ]]; then CLOCK=300; fi
            return 0
        }
        zrc_audit() { AUDITS=$((AUDITS+1)); ((AUDIT_ERROR==0)); }
        expect() {
            local want=$1 got
            if zrc_drain > "$CASE_OUT/output"; then got=0; else got=$?; fi
            if [[ $got != "$want" ]]; then cat "$CASE_OUT/output"; echo "wanted $want got $got"; return 1; fi
        }
        eval "$body"
    )
    COUNT=$((COUNT+1)); echo "PASS $name"
}
case_test releases_repeated_jobs 'expect 0; [[ $(cat "$EVENTS") == $'"'"'cancel 7155\ncancel 7156'"'"' ]]; ((CLOCK>=40 && AUDITS==1))'
case_test immediate_new_job_revalidated 'IMMEDIATE_JOB=1; expect 0; ((CANCELS==2 && AUDITS==1))'
case_test deadline_before_mutation 'DEADLINE_IN_CANCEL=1; expect 2; [[ ! -s $EVENTS ]]'
case_test clock_failure_before_mutation 'CLOCK_FAILURE=1; expect 2; [[ ! -s $EVENTS ]]'
case_test idle_requires_observation 'NEED_CANCELS=0; expect 0; ((CLOCK>=30 && AUDITS==1)); [[ ! -s $EVENTS ]]'
case_test active_main_refused 'main=2105; expect 2; [[ ! -s $EVENTS ]]'
case_test changed_invocation_stops 'CHANGED_INVOCATION=1; expect 2; ((CANCELS==1))'
case_test new_main_during_observation 'NEED_CANCELS=0; LATE_MAIN=1; expect 2; [[ ! -s $EVENTS ]]'
case_test no_waiter_no_cancel 'UNVERIFIED=1; expect 2; [[ ! -s $EVENTS ]]'
case_test timer_or_read_failure_no_cancel 'ACTIVITY_ERROR=1; expect 2; [[ ! -s $EVENTS ]]'
case_test stop_job_never_cancelled 'job_type=stop; expect 2; [[ ! -s $EVENTS ]]'
case_test same_job_not_retried 'SAME_JOB=1; expect 3; ((CANCELS==1))'
case_test cancel_transport_error_no_retry 'CANCEL_ERROR=1; expect 3; ((CANCELS==1))'
case_test cancellation_limit 'NEED_CANCELS=20; ZRC_MAX_CANCELS=2; expect 2; ((CANCELS==2))'
case_test bounded_busy_wait 'NEED_CANCELS=0; STUCK_BUSY=1; ZRC_LIMIT=20; expect 2; ((CLOCK==20 && AUDITS==0)); [[ ! -s $EVENTS ]]'
case_test audit_findings_refused 'NEED_CANCELS=0; AUDIT_ERROR=1; expect 2; ((AUDITS==1))'
case_test activity_during_audit_refused 'NEED_CANCELS=0; AUDIT_BUSY=1; expect 2; ((AUDITS==1))'
case_test job_during_audit_refused 'NEED_CANCELS=0; FINAL_JOB=1; expect 2; [[ ! -s $EVENTS ]]'

# Exercise actual process parsing against the ancestry seen in the user's archive.
(
    source "$ROOT/zabbix_cancel_stuck_restart.sh"
    cat > "$WORK/processes.txt" <<'EOF'
1145 1 unattended-upgr /usr/bin/python3 /usr/share/unattended-upgrades/unattended-upgrade-shutdown --wait-for-signal
18371 1 apt.systemd.dai /bin/sh /usr/lib/apt/apt.systemd.daily lock_is_held install
18401 18371 unattended-upgr /usr/bin/python3 /usr/bin/unattended-upgrade
115993 18401 unattended-upgr /usr/bin/python3 /usr/bin/unattended-upgrade
116078 115993 unattended-upgr /usr/bin/python3 /usr/bin/unattended-upgrade
116087 116078 sh sh -c -- test -x /usr/lib/needrestart/apt-pinvoke && /usr/lib/needrestart/apt-pinvoke -m u || true
116088 116087 frontend /usr/bin/perl /usr/share/debconf/frontend /usr/sbin/needrestart -m u
116100 116088 needrestart /usr/bin/perl /usr/sbin/needrestart -m u
116132 116100 systemctl systemctl restart cron.service zabbix-server.service
200000 1 bash bash
200001 200000 systemctl systemctl restart zabbix-server.service
200002 116100 systemctl systemctl restart postgresql.service
EOF
    [[ $(zrc_find_waiter "$WORK/processes.txt") == 116132 ]]
    zrc_filter_packages "$WORK/processes.txt" > "$WORK/packages.txt"
    ! grep -q '^1145 ' "$WORK/packages.txt"
    grep -q '^18401 ' "$WORK/packages.txt"
    grep -q '^18371 ' "$WORK/packages.txt"
    awk '$3!="unattended-upgr"' "$WORK/processes.txt" > "$WORK/no-upgrade.txt"
    if zrc_find_waiter "$WORK/no-upgrade.txt"; then exit 1; fi
    echo 'PASS ancestry_attribution_and_shutdown_exclusion'

    # Real activity checker with a failed update unit and its orphaned children.
    mkdir "$WORK/activity"
    timer_active=inactive; timer_enabled=disabled
    zrc_ctl() {
        if [[ $2 == apt-daily-upgrade.timer ]]; then
            printf 'LoadState=loaded\nActiveState=%s\nUnitFileState=%s\n' "$timer_active" "$timer_enabled"
        else printf 'ActiveState=failed\nSubState=failed\nMainPID=0\nResult=signal\n'
        fi
    }
    timeout() { cat "$WORK/processes.txt"; }
    zrc_activity "$WORK/activity"
    ((ZRC_BUSY==1 && ZRC_WAITER==1))
    timer_active=active
    if zrc_activity "$WORK/activity" > "$WORK/timer-refusal.txt"; then exit 1; fi
    timer_active=inactive; timer_enabled=enabled
    if zrc_activity "$WORK/activity" >> "$WORK/timer-refusal.txt"; then exit 1; fi
    echo 'PASS failed_unit_does_not_hide_orphans_and_timer_is_required'
)
(
    source "$ROOT/zabbix_cancel_stuck_restart.sh"
    JOURNAL_RC=0; TAR_RC=0
    timeout() {
        case "$4" in
            journalctl) printf 'diagnostic journal\n'; return "$JOURNAL_RC" ;;
            tar) return "$TAR_RC" ;;
            *) return 99 ;;
        esac
    }
    ZRC_OUT=$WORK/report-journal-error; mkdir "$ZRC_OUT"
    JOURNAL_RC=1
    if zrc_report 0 > "$ZRC_OUT/output"; then rc=0; else rc=$?; fi
    [[ $rc == 3 ]]; grep -q 'Exit code: 3' "$ZRC_OUT/SUMMARY.txt"
    ZRC_OUT=$WORK/report-archive-error; mkdir "$ZRC_OUT"
    JOURNAL_RC=0; TAR_RC=1
    if zrc_report 0 > "$ZRC_OUT/output"; then rc=0; else rc=$?; fi
    [[ $rc == 3 ]]; grep -q 'Exit code: 3' "$ZRC_OUT/SUMMARY.txt"
    ! grep -q 'Exit code: 0' "$ZRC_OUT/output"
    echo 'PASS report_failures_prevent_success_exit'
)
echo "All $((COUNT+3)) drain scenarios passed. Evidence: $WORK"
