#!/usr/bin/env bash
set -eu
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "$ROOT/tests/cancel.XXXXXX")
COUNT=0
case_test() {
    local name=$1 body=$2
    (
        source "$ROOT/zabbix_cancel_stuck_restart.sh"
        ZRC_OUT=$WORK/$name; mkdir "$ZRC_OUT"
        EVENTS=$ZRC_OUT/events; : > "$EVENTS"
        state=deactivating; sub=stop-sigterm; main=0; id=4126
        invocation=75746af206224b30a9ebf8ff4521d53b
        job_type=restart; target=zabbix-server.service; reads=0
        zrc_ctl() { printf '%s\n' "$*" >> "$EVENTS"; return 0; }
        zrc_snapshot() {
            reads=$((reads+1))
            printf 'LoadState=loaded\nActiveState=%s\nSubState=%s\nMainPID=%s\nControlPID=0\nControlGroup=/system.slice/zabbix-server.service\nInvocationID=%s\n' "$state" "$sub" "$main" "$invocation" > "$ZRC_OUT/$1-state.txt"
            printf '2256 apt-daily-upgrade.service start running\n' > "$ZRC_OUT/$1-jobs.txt"
            if [[ $1 != after ]]; then printf '%s %s %s running\n' "$id" "$target" "$job_type" >> "$ZRC_OUT/$1-jobs.txt"; fi
        }
        ORIGINAL_SNAPSHOT=$(declare -f zrc_snapshot)
        expect() { local want=$1 got; zrc_cancel > "$ZRC_OUT/output" && got=0 || got=$?; [[ $want == "$got" ]]; }
        eval "$body"
    )
    COUNT=$((COUNT+1)); echo "PASS $name"
}
case_test cancels_only_target 'expect 0; [[ $(cat "$EVENTS") == "cancel 4126" ]]'
case_test uses_current_id 'id=9001; expect 0; [[ $(cat "$EVENTS") == "cancel 9001" ]]'
case_test refuses_running_main 'main=2105; expect 2; [[ ! -s $EVENTS ]]'
case_test refuses_active_service 'state=active; sub=running; expect 2; [[ ! -s $EVENTS ]]'
case_test refuses_other_unit 'target=postgresql.service; expect 2; [[ ! -s $EVENTS ]]'
case_test refuses_stop_job 'job_type=stop; expect 2; [[ ! -s $EVENTS ]]'
case_test refuses_changed_job '
    eval "${ORIGINAL_SNAPSHOT/zrc_snapshot/zrc_original_snapshot}"
    zrc_snapshot() { if [[ $1 == verified ]]; then id=9002; fi; zrc_original_snapshot "$1"; }
    expect 2; [[ ! -s $EVENTS ]]
'
case_test refuses_changed_invocation '
    eval "${ORIGINAL_SNAPSHOT/zrc_snapshot/zrc_original_snapshot}"
    zrc_snapshot() { if [[ $1 == verified ]]; then invocation=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi; zrc_original_snapshot "$1"; }
    expect 2; [[ ! -s $EVENTS ]]
'
case_test refuses_transport_failure 'zrc_snapshot() { return 1; }; expect 2; [[ ! -s $EVENTS ]]'
case_test no_retry_after_cancel_error 'zrc_ctl() { printf "%s\n" "$*" >> "$EVENTS"; return 1; }; expect 3; [[ $(wc -l < "$EVENTS") == 1 ]]'
echo "All $COUNT cancellation scenarios passed. Evidence: $WORK"
