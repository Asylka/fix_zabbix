#!/usr/bin/env bash
# Local tests only. Linux/systemd operations are replaced by shell functions.
set -eu
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "$ROOT/tests/run.XXXXXX")
COUNT=0

test_case() {
    local name=$1 body=$2
    (
        source "$ROOT/zabbix_safe_restart.sh"
        ORIG_OBSERVE=$(declare -f observe)
        ORIG_WAIT=$(declare -f wait_clean)
        ORIG_PACKAGE_GUARD=$(declare -f package_guard)
        # No main(), systemctl, kill, /run or /etc operations are executed.
        OUT=$WORK/$name; mkdir "$OUT"
        EVENTS=$OUT/events; : > "$EVENTS"
        log() { printf '%s\n' "$*" >> "$OUT/run.log"; }
        resources() { printf 'snapshot %s\n' "$1" >> "$EVENTS"; }
        log_delta() { :; }
        mono() { printf '100\n'; }
        sleep() { :; }
        clean_state() {
            S=([LoadState]=loaded [ActiveState]=inactive [SubState]=dead [MainPID]=0 [ControlPID]=0
               [InvocationID]='' [ControlGroup]='' [NRestarts]=0 [Result]=success
               [Restart]=no [SendSIGKILL]=no [KillMode]=control-group [KillSignal]=15 [TimeoutStopUSec]=infinity)
            ZCOUNT=0 OUTSIDE=0 CG_POP=0 DCOUNT=0 JOBS=0 LISTENERS=0
        }
        clean_state
        inspect() { return 0; }
        ctl() { printf '%s\n' "$*" >> "$EVENTS"; return 0; }
        package_guard() { return 0; }
        observe() { printf 'observe\n' >> "$EVENTS"; return 0; }
        expect_code() {
            local want=$1 got; shift
            "$@" && got=0 || got=$?
            [[ $got == "$want" ]] || { echo "Expected $want; got $got: $*" >&2; exit 1; }
        }
        eval "$body"
    )
    COUNT=$((COUNT+1)); echo "PASS $name"
}

test_case inactive_start_skips_reset '
    expect_code 0 start_service
    [[ $START_SENT == 1 ]]
    ! grep -q reset-failed "$EVENTS"
    [[ $(grep -c "^start --no-block" "$EVENTS") == 1 ]]
'
test_case failed_reset_success '
    S[ActiveState]=failed
    ctl() { printf "%s\n" "$*" >> "$EVENTS"; [[ $1 != reset-failed ]] || S[ActiveState]=inactive; return 0; }
    expect_code 0 start_service
    grep -q "^reset-failed" "$EVENTS"
'
test_case reset_error_reverified_inactive '
    S[ActiveState]=failed
    ctl() { printf "%s\n" "$*" >> "$EVENTS"; if [[ $1 == reset-failed ]]; then S[ActiveState]=inactive; return 1; fi; }
    expect_code 0 start_service
    [[ $START_SENT == 1 ]]
'
test_case reset_error_still_failed '
    S[ActiveState]=failed
    ctl() { printf "%s\n" "$*" >> "$EVENTS"; return 1; }
    expect_code 2 start_service
    [[ $START_SENT == 0 ]]
'
test_case leftover_process_refuses_start '
    ZCOUNT=1
    expect_code 2 start_service
    [[ ! -s $EVENTS && $START_SENT == 0 ]]
'
test_case populated_cgroup_refuses_start '
    CG_POP=1
    expect_code 2 start_service
    [[ ! -s $EVENTS ]]
'
test_case remaining_job_refuses_start '
    JOBS=1
    expect_code 2 start_service
    [[ ! -s $EVENTS ]]
'
test_case occupied_port_refuses_start '
    LISTENERS=1
    expect_code 2 start_service
    [[ ! -s $EVENTS ]]
'
test_case external_change_before_start '
    calls=0
    inspect() { calls=$((calls+1)); if ((calls>=2)); then ZCOUNT=1; fi; }
    expect_code 2 start_service
    [[ $START_SENT == 0 ]]
'
test_case failed_start_no_retry '
    ctl() { printf "%s\n" "$*" >> "$EVENTS"; return 1; }
    expect_code 1 start_service
    [[ $(grep -c "^start --no-block" "$EVENTS") == 1 ]]
    ! grep -q observe "$EVENTS"
'
test_case stop_already_clean '
    expect_code 0 stop_service
    [[ ! -s $EVENTS && $STOP_SENT == 0 ]]
'
test_case graceful_stop '
    S[ActiveState]=active; S[InvocationID]=old; CG_POP=1; ZCOUNT=5
    wait_clean() { clean_state; return 0; }
    expect_code 0 stop_service
    grep -q "^stop --no-block" "$EVENTS"
    ! grep -q "^kill" "$EVENTS"
'
test_case stop_error_blocks_restart '
    S[ActiveState]=active; CG_POP=1; ZCOUNT=5
    ctl() { printf "%s\n" "$*" >> "$EVENTS"; return 1; }
    expect_code 2 stop_service
    [[ $START_SENT == 0 ]]
'
test_case outside_processes_never_signaled '
    OUTSIDE=1; ZCOUNT=1
    expect_code 2 stop_service
    [[ ! -s $EVENTS ]]
'
test_case timeout_default_no_kill '
    S[ActiveState]=deactivating; S[InvocationID]=old; CG_POP=1; ZCOUNT=5
    wait_clean() { return 1; }
    expect_code 2 stop_service
    grep -q "signal=SIGTERM" "$EVENTS"
    ! grep -q "signal=SIGKILL" "$EVENTS"
    [[ $START_SENT == 0 ]]
'
test_case force_only_after_grace_and_term '
    FORCE=1; S[ActiveState]=deactivating; S[InvocationID]=old; CG_POP=1; ZCOUNT=5
    waits=0
    wait_clean() { waits=$((waits+1)); printf "wait %s\n" "$1" >> "$EVENTS"; if ((waits==3)); then clean_state; return 0; fi; return 1; }
    expect_code 0 stop_service
    [[ $FORCE_SENT == 1 && $waits == 3 ]]
    grep -q "kill --kill-whom=all --signal=SIGKILL zabbix-server.service" "$EVENTS"
'
test_case d_state_after_kill_blocks_start '
    FORCE=1; S[ActiveState]=deactivating; S[InvocationID]=old; CG_POP=1; ZCOUNT=1; DCOUNT=1
    wait_clean() { return 1; }
    expect_code 2 stop_service
    [[ $FORCE_SENT == 1 && $START_SENT == 0 ]]
'
test_case signal_refuses_new_invocation '
    STOP_ID=old; S[InvocationID]=new; S[ActiveState]=deactivating; CG_POP=1
    expect_code 1 signal_unit SIGKILL
    [[ ! -s $EVENTS ]]
'
test_case signal_refuses_active_unit '
    STOP_ID=old; S[InvocationID]=old; S[ActiveState]=active; CG_POP=1
    expect_code 1 signal_unit SIGKILL
    [[ ! -s $EVENTS ]]
'
test_case signal_refuses_changed_policy '
    STOP_ID=old; S[InvocationID]=old; S[ActiveState]=deactivating; CG_POP=1; S[Restart]=always
    expect_code 1 signal_unit SIGKILL
    [[ ! -s $EVENTS ]]
'
test_case input_validation '
    expect_code 0 parse --restart --force-after-timeout --grace-seconds 030 --port 10051
    [[ $MODE == restart && $GRACE == 30 ]]
    MODE=; FORCE=0
    expect_code 2 parse --start --force-after-timeout
    MODE=; FORCE=0
    expect_code 2 parse --restart --port 70000
    MODE=; FORCE=0
    expect_code 2 parse --start --restart
'
test_case classify_only_new_errors '
    printf "zabbix server stopped\n" > "$OUT/stop-new-log.txt"
    printf "out of memory\n" > "$OUT/previous-log-tail.txt"
    printf "host [x] not found\n" > "$OUT/start-new-log.txt"
    classify
    [[ $CRITICAL == 0 ]]
    printf "database is down\n" >> "$OUT/start-new-log.txt"
    classify
    [[ $CRITICAL == 1 ]]
'
test_case redaction_and_nul '
    printf "DBPassword=secret\nnormal\000text\n" | redact > "$OUT/redacted"
    ! grep -q secret "$OUT/redacted"
    grep -q normaltext "$OUT/redacted"
'
test_case read_state_rejects_missing_properties '
    ctl() { printf "LoadState=loaded\nActiveState=inactive\n"; }
    expect_code 1 read_state
'
test_case read_state_rejects_duplicate_properties '
    ctl() { printf "LoadState=loaded\nLoadState=loaded\n"; }
    expect_code 1 read_state
'
test_case listener_checks_every_owner '
    LISTENERS=1
    printf "LISTEN 0 128 *:10051 *:* users:((x,pid=11,fd=3),(x,pid=22,fd=3))\n" > "$OUT/current-listeners.txt"
    pid_group() { if [[ $1 == 11 ]]; then printf "%s\n" "$CG"; else printf "/other.service\n"; fi; }
    expect_code 1 listener_owned
    pid_group() { printf "%s\n" "$CG"; }
    expect_code 0 listener_owned
'
test_case wait_timeout_is_bounded '
    eval "$ORIG_WAIT"
    ZCOUNT=1; CG_POP=1; S[ActiveState]=deactivating; S[InvocationID]=old; STOP_ID=old
    T=100; mono() { printf "%s\n" "$T"; }; sleep() { T=$((T+5)); }
    expect_code 1 wait_clean 30
    [[ $T == 130 ]]
'
test_case wait_external_restart_aborts '
    eval "$ORIG_WAIT"
    ZCOUNT=1; S[ActiveState]=active; S[InvocationID]=new; STOP_ID=old
    expect_code 2 wait_clean 300
'
test_case observation_stable_for_full_window '
    eval "$ORIG_OBSERVE"
    S[ActiveState]=active; S[SubState]=running; S[MainPID]=11; S[InvocationID]=one; OBSERVE=30
    T=100; mono() { printf "%s\n" "$T"; }; sleep() { T=$((T+10)); }
    running() { return 0; }
    expect_code 0 observe 100
    [[ $T == 130 && $RUN_SEEN == 1 && $CRITICAL == 0 ]]
'
test_case observation_detects_service_loss '
    eval "$ORIG_OBSERVE"
    S[ActiveState]=active; S[SubState]=running; S[MainPID]=11; S[InvocationID]=one; OBSERVE=30
    T=100; mono() { printf "%s\n" "$T"; }; sleep() { T=$((T+10)); }
    running() { [[ $T == 100 ]]; }
    expect_code 1 observe 100
    [[ $CRITICAL == 1 ]]
'
test_case observation_detects_pid_change '
    eval "$ORIG_OBSERVE"
    S[ActiveState]=active; S[SubState]=running; S[MainPID]=11; S[InvocationID]=one; OBSERVE=30
    T=100; mono() { printf "%s\n" "$T"; }; sleep() { T=$((T+10)); S[MainPID]=22; }
    running() { return 0; }
    expect_code 0 observe 100
    [[ $CRITICAL == 1 ]]
'
test_case incremental_log_byte_caps '
    PHASE=start; FAKE_SIZE=10; LOG_OFFSET=0; CHUNK_LIMIT=4; LOG_LIMIT=6
    stat() { printf "%s\n" "$FAKE_SIZE"; }
    timeout() { shift 3; "$@"; }
    dd() { printf "%s\n" "$*" >> "$EVENTS"; printf "test\n"; }
    log_chunk
    [[ $LOG_OFFSET == 10 && $LOG_BYTES == 4 && $GAPS == 1 ]]
    grep -q "skip=0 count=4" "$EVENTS"
    FAKE_SIZE=14
    log_chunk
    [[ $LOG_OFFSET == 14 && $LOG_BYTES == 6 && $LOG_CAPPED == 1 ]]
    grep -q "skip=10 count=2" "$EVENTS"
'
test_case incremental_log_detects_truncation '
    PHASE=start; LOG_OFFSET=500; FAKE_SIZE=10
    stat() { printf "%s\n" "$FAKE_SIZE"; }
    timeout() { shift 3; "$@"; }
    dd() { printf "%s\n" "$*" >> "$EVENTS"; printf "test\n"; }
    log_chunk
    [[ $LOG_OFFSET == 10 && $LOG_BYTES == 10 && $GAPS == 1 ]]
    grep -q "skip=0 count=10" "$EVENTS"
'
test_case inspection_recovers_and_preserves_error '
    reads=0
    inspect() {
        reads=$((reads+1)); INSPECT_STAGE=jobs
        if ((reads==1)); then
            printf "Failed to list jobs: Message recipient disconnected from message bus without replying\n" > "$OUT/current-jobs.error"
            return 1
        fi
        return 0
    }
    expect_code 0 inspect_reliably
    [[ $reads == 2 && $INSPECT_FAILURES == 1 && ! -s $EVENTS ]]
    grep -q "Message recipient disconnected" "$OUT/inspection-errors.log"
    test -f "$OUT/inspection-failure-1-current-jobs.error"
'
test_case inspection_persistent_error_is_bounded '
    reads=0
    inspect() { reads=$((reads+1)); INSPECT_STAGE=jobs; return 1; }
    expect_code 1 inspect_reliably
    [[ $reads == 3 && $GAPS == 1 && ! -s $EVENTS ]]
'
test_case stale_clean_state_never_authorizes_start '
    inspect() { return 1; }
    expect_code 2 start_service
    [[ $START_SENT == 0 && ! -s $EVENTS ]]
'
test_case recovered_read_still_checks_leftovers '
    reads=0
    inspect() { reads=$((reads+1)); if ((reads==1)); then return 1; fi; ZCOUNT=10; return 0; }
    expect_code 2 start_service
    [[ $reads == 2 && $START_SENT == 0 && ! -s $EVENTS ]]
'
test_case bus_failure_during_stop_never_authorizes_force '
    eval "$ORIG_WAIT"
    FORCE=1; S[ActiveState]=deactivating; S[InvocationID]=old; ZCOUNT=1227; CG_POP=1
    reads=0
    inspect() { reads=$((reads+1)); if ((reads==1)); then return 0; fi; INSPECT_STAGE=jobs; return 1; }
    expect_code 2 stop_service
    [[ $STOP_SENT == 1 && $FORCE_SENT == 0 && $START_SENT == 0 ]]
    [[ $(grep -c "^stop --no-block" "$EVENTS") == 1 ]]
    ! grep -q "^kill" "$EVENTS"
'
test_case bus_failure_never_authorizes_signal '
    S[ActiveState]=deactivating; STOP_ID=old; S[InvocationID]=old; CG_POP=1
    inspect() { return 1; }
    expect_code 1 signal_unit SIGKILL
    [[ ! -s $EVENTS ]]
'
test_case package_upgrade_blocks_start '
    package_guard() { return 1; }
    expect_code 2 start_service
    [[ $START_SENT == 0 && ! -s $EVENTS ]]
'
test_case package_upgrade_blocks_force '
    S[ActiveState]=deactivating; STOP_ID=old; S[InvocationID]=old; CG_POP=1
    package_guard() { return 1; }
    expect_code 1 signal_unit SIGKILL
    [[ ! -s $EVENTS ]]
'
test_case guard_detects_unattended_upgrade '
    eval "$ORIG_PACKAGE_GUARD"
    timeout() { printf "18401 18371 unattended-upgr /usr/bin/python3 /usr/bin/unattended-upgrade\n"; }
    expect_code 1 package_guard
    grep -q unattended-upgrade "$OUT/package-active.txt"
    [[ ! -s $EVENTS ]]
'
test_case guard_ignores_idle_shutdown_helper '
    eval "$ORIG_PACKAGE_GUARD"
    timeout() { printf "1145 1 unattended-upgr /usr/bin/python3 /usr/share/unattended-upgrades/unattended-upgrade-shutdown --wait-for-signal\n"; }
    ctl() { printf "inactive\n"; }
    expect_code 0 package_guard
    [[ ! -s $OUT/package-active.txt ]]
'
test_case guard_detects_active_update_unit '
    eval "$ORIG_PACKAGE_GUARD"
    timeout() { printf "1 0 systemd /usr/lib/systemd/systemd\n"; }
    ctl() { printf "active\n"; }
    expect_code 1 package_guard
'
test_case guard_fails_closed_on_transport_error '
    eval "$ORIG_PACKAGE_GUARD"
    timeout() { printf "1 0 systemd /usr/lib/systemd/systemd\n"; }
    ctl() { return 1; }
    expect_code 1 package_guard
'
echo "All $COUNT local regression scenarios passed. Evidence: $WORK"
