#!/usr/bin/env bash
set -euo pipefail

# Cross-host physical NVMe HMLM migration.
#
# Usage:
#   sudo ./migrate-v4.sh <DEST_HOST_IP>
#
# Ordering:
#   1. Synchronize ROOT first (unrelated to NVMe/CDQ).
#   2. Arm CDQ.
#   3. Start the full physical-NVMe baseline mirror.
#   4. Start QEMU RAM/VFIO migration immediately.
#   5. When NVMe baseline reaches READY, cancel that mirror normally.
#   6. HMLM takes over through its independent delta NBD connection.
#   7. Final suspend drains CDQ, finishes delta copy, flushes, and transfers
#      VFIO/controller state.

DEST_IP="${1:?Usage: sudo $0 <DEST_HOST_IP>}"

SOURCE_QMP="${SOURCE_QMP:-/tmp/uvp-hmlm-src.qmp}"

HMLM_CTRL="${HMLM_CTRL:-/dev/nvme0}"
HMLM_SRC="${HMLM_SRC:-/dev/nvme0n1}"
HMLM_MCID="${HMLM_MCID:-1}"
HMLM_NSID="${HMLM_NSID:-1}"
HMLM_CDQ_SIZE="${HMLM_CDQ_SIZE:-131072}"
HMLM_DELTA_GRANULARITY="${HMLM_DELTA_GRANULARITY:-65536}"
HMLM_CUTOVER_BYTES="${HMLM_CUTOVER_BYTES:-67108864}"
HMLM_FINAL_TIMEOUT_MS="${HMLM_FINAL_TIMEOUT_MS:-120000}"
HMLM_FULL_RAM_FINAL="${HMLM_FULL_RAM_FINAL:-on}"
HMLM_DELTA_SETTLE_MS="${HMLM_DELTA_SETTLE_MS:-200}"
HMLM_ARM_SETTLE_SEC="${HMLM_ARM_SETTLE_SEC:-1}"

READY_GRACE_POLLS="${READY_GRACE_POLLS:-2}"
HANDOFF_TIMEOUT_SEC="${HANDOFF_TIMEOUT_SEC:-60}"

NVME_NBD_PORT="${NVME_NBD_PORT:-10809}"
NVME_NBD_EXPORT="${NVME_NBD_EXPORT:-uvp-nvme}"
ROOT_NBD_PORT="${ROOT_NBD_PORT:-10810}"
MIGRATION_PORT="${MIGRATION_PORT:-4444}"

MIRROR_JOB_ID="${MIRROR_JOB_ID:-nvme-hmlm-mirror}"
ROOT_MIRROR_JOB_ID="${ROOT_MIRROR_JOB_ID:-root-mirror}"
MIRROR_SPEED="${MIRROR_SPEED:-0}"
MIRROR_GRANULARITY="${MIRROR_GRANULARITY:-65536}"
MIRROR_BUF_SIZE="${MIRROR_BUF_SIZE:-268435456}"
QMP_EVENT_LOG="${QMP_EVENT_LOG:-/tmp/uvp-hmlm-qmp-events.log}"

BASELINE_NBD_NODE="hmlm-dst"
DELTA_NBD_NODE="hmlm-delta-dst"
SOURCE_HMLM_NODE="hmlm-src"

die() { echo "ERROR: $*" >&2; exit 1; }

for c in jq socat blockdev; do
    command -v "$c" >/dev/null || die "$c is required"
done

[[ -S "$SOURCE_QMP" ]] || die "Source QMP socket not found: $SOURCE_QMP"
[[ -b "$HMLM_SRC" ]] || die "Source namespace not found: $HMLM_SRC"
[[ -e "$HMLM_CTRL" ]] || die "Source NVMe controller not found: $HMLM_CTRL"

NAMESPACE_BYTES="$(blockdev --getsize64 "$HMLM_SRC")"
LBA_SIZE="$(blockdev --getss "$HMLM_SRC")"

echo "Source namespace bytes : $NAMESPACE_BYTES"
echo "Source LBA size        : $LBA_SIZE"

QMP_SEQ=0
QMP_RETURN=''
QMP_ERROR=''
NVME_MIRROR_STARTED=false
NVME_MIRROR_CANCEL_SENT=false
NVME_READY_POLLS=0
HANDOFF_START_SEC=0
HMLM_STARTED=false
MIGRATION_COMPLETED=false
SOURCE_NODE_ADDED=false
BASELINE_NBD_ADDED=false
DELTA_NBD_ADDED=false

: > "$QMP_EVENT_LOG"

coproc QMPPROC { exec socat - "UNIX-CONNECT:${SOURCE_QMP}"; }
QMP_IN=${QMPPROC[1]}
QMP_OUT=${QMPPROC[0]}

qmp_read_for_id()
{
    local want=$1 line got
    local deadline=$((SECONDS + 60))

    while (( SECONDS < deadline )); do
        if ! IFS= read -r -t 1 line <&"$QMP_OUT"; then
            continue
        fi
        [[ -n "$line" ]] || continue
        got="$(jq -r 'if has("id") then (.id|tostring) else "" end' \
               <<<"$line" 2>/dev/null || true)"

        if [[ "$got" != "$want" ]]; then
            if jq -e 'has("event")' >/dev/null 2>&1 <<<"$line"; then
                printf '%s\n' "$line" >> "$QMP_EVENT_LOG"
            fi
            continue
        fi

        if jq -e 'has("error")' >/dev/null <<<"$line"; then
            QMP_ERROR="$(jq -r '.error.desc // .error.class // "QMP error"' <<<"$line")"
            return 1
        fi

        QMP_RETURN="$(jq -c '.return' <<<"$line")"
        QMP_ERROR=''
        return 0
    done

    QMP_ERROR='QMP read timed out/disconnected'
    return 1
}

qmp_cmd()
{
    local name=$1
    local args=${2:-}

    QMP_SEQ=$((QMP_SEQ + 1))

    if [[ -n "$args" ]]; then
        jq -cn --arg name "$name" --argjson args "$args" --argjson id "$QMP_SEQ" \
            '{execute:$name,arguments:$args,id:$id}' >&"$QMP_IN"
    else
        jq -cn --arg name "$name" --argjson id "$QMP_SEQ" \
            '{execute:$name,id:$id}' >&"$QMP_IN"
    fi

    qmp_read_for_id "$QMP_SEQ"
}

delete_node_best_effort()
{
    local node=$1

    qmp_cmd blockdev-del "$(jq -cn --arg n "$node" '{"node-name":$n}')" \
        >/dev/null 2>&1 || true
}

cleanup()
{
    local rc=$?
    set +e

    if [[ "$rc" -ne 0 && "$HMLM_STARTED" == true ]]; then
        qmp_cmd x-nvme-hmlm-stop '{}' >/dev/null 2>&1 || true
    fi

    if [[ "$rc" -ne 0 && "$NVME_MIRROR_STARTED" == true &&
          "$NVME_MIRROR_CANCEL_SENT" == false ]]; then
        qmp_cmd block-job-cancel \
            "$(jq -cn --arg j "$MIRROR_JOB_ID" '{device:$j,force:true}')" \
            >/dev/null 2>&1 || true
    fi

    if [[ "$MIGRATION_COMPLETED" == true || "$rc" -ne 0 ]]; then
        [[ "$DELTA_NBD_ADDED" == true ]] && delete_node_best_effort "$DELTA_NBD_NODE"
        [[ "$BASELINE_NBD_ADDED" == true ]] && delete_node_best_effort "$BASELINE_NBD_NODE"
        [[ "$SOURCE_NODE_ADDED" == true ]] && \
            delete_node_best_effort "$SOURCE_HMLM_NODE"
    fi

    if [[ -n "${QMPPROC_PID:-}" ]]; then
        kill "$QMPPROC_PID" >/dev/null 2>&1 || true
        wait "$QMPPROC_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

IFS= read -r -t 5 greeting <&"$QMP_OUT" || die "No QMP greeting"
jq -e 'has("QMP")' >/dev/null <<<"$greeting" || die "Bad QMP greeting"
qmp_cmd qmp_capabilities || die "$QMP_ERROR"

# A previous run must not leave an active HMLM session in this QEMU.
qmp_cmd query-nvme-hmlm || die "query-nvme-hmlm failed: $QMP_ERROR"
if [[ "$(jq -r '.active // false' <<<"$QMP_RETURN")" == true ]]; then
    echo "Stale HMLM session found; requesting explicit teardown..."
    qmp_cmd x-nvme-hmlm-stop '{}' ||
        die "stale HMLM teardown failed: $QMP_ERROR"
    qmp_cmd query-nvme-hmlm || die "query-nvme-hmlm failed: $QMP_ERROR"
    [[ "$(jq -r '.active // true' <<<"$QMP_RETURN")" == false ]] ||
        die "HMLM remains active after teardown"
fi

# Discover optional x-nvme-hmlm-start fields.  Different HMLM patch
# revisions do not expose the same optional arguments.
qmp_cmd query-qmp-schema || die "query-qmp-schema failed: $QMP_ERROR"
HMLM_FIELDS="$(jq -c '. as $schema |
  ([$schema[] | select(.name=="x-nvme-hmlm-start" and ."meta-type"=="command")][0]."arg-type") as $name |
  [$schema[] | select(.name==$name) | .members[]?.name]' <<<"$QMP_RETURN")"
for required in mirror-job source-node target-node ctrl mcid nsid lba-size namespace-bytes cdq-size; do
    jq -e --arg name "$required" 'index($name) != null' <<<"$HMLM_FIELDS" >/dev/null ||
        die "x-nvme-hmlm-start lacks required parameter: $required"
done

# ---------------------------------------------------------------------------
# 1. Root storage first.  No CDQ is needed during this unrelated copy.
# ---------------------------------------------------------------------------
echo
echo "Starting root-disk mirror first..."
ROOT_TARGET="nbd:${DEST_IP}:${ROOT_NBD_PORT}:exportname=root"
ROOT_ARGS="$(jq -cn \
    --arg target "$ROOT_TARGET" \
    --arg job "$ROOT_MIRROR_JOB_ID" \
    '{device:"root",target:$target,sync:"full",mode:"existing",
      "copy-mode":"write-blocking"} + {"job-id":$job}')"

qmp_cmd drive-mirror "$ROOT_ARGS" ||
    die "root drive-mirror failed: $QMP_ERROR"

echo "Waiting for root mirror READY..."
while true; do
    qmp_cmd query-block-jobs || die "query-block-jobs: $QMP_ERROR"
    JOBS="$QMP_RETURN"

    ROOT_READY="$(jq -r --arg j "$ROOT_MIRROR_JOB_ID" \
        '[.[] | select((."job-id" // .device) == $j) |
          (.ready // false)] | first // false' <<<"$JOBS")"

    ROOT_OFF="$(jq -r --arg j "$ROOT_MIRROR_JOB_ID" \
        '[.[] | select((."job-id" // .device) == $j) |
          (.offset // 0)] | first // 0' <<<"$JOBS")"

    ROOT_LEN="$(jq -r --arg j "$ROOT_MIRROR_JOB_ID" \
        '[.[] | select((."job-id" // .device) == $j) |
          (.len // 0)] | first // 0' <<<"$JOBS")"

    if [[ "$ROOT_LEN" =~ ^[0-9]+$ ]] && (( ROOT_LEN > 0 )); then
        ROOT_PCT="$(awk -v o="$ROOT_OFF" -v l="$ROOT_LEN" \
            'BEGIN {printf "%.2f",100*o/l}')"
    else
        ROOT_PCT="0.00"
    fi

    printf 'ROOT mirror=%6s%% ready=%s\n' "$ROOT_PCT" "$ROOT_READY"

    [[ "$ROOT_READY" == "true" ]] && break
    sleep 1
done

echo "ROOT is READY. It remains as a live/write-blocking mirror."

# ---------------------------------------------------------------------------
# 2. Create source node and TWO independent NBD clients to physical NVMe.
# ---------------------------------------------------------------------------
echo
echo "Flushing source namespace host cache..."
blockdev --flushbufs "$HMLM_SRC"

echo "Creating O_DIRECT HMLM source block node..."
# x-nvme-hmlm-start validates BDRV_O_NOCACHE on source-node itself.
# Therefore SOURCE_HMLM_NODE must be the host_device node opened with
# cache.direct=true; do not place a buffered raw wrapper above it.
qmp_cmd blockdev-add "$(jq -cn \
    --arg f "$HMLM_SRC" \
    --arg node "$SOURCE_HMLM_NODE" \
    '{driver:"host_device",filename:$f,"node-name":$node,
      "read-only":true,"cache":{"direct":true}}')" ||
    die "O_DIRECT source blockdev-add failed: $QMP_ERROR"
SOURCE_NODE_ADDED=true

echo "Adding independent baseline NBD client..."
qmp_cmd blockdev-add "$(jq -cn \
    --arg host "$DEST_IP" \
    --arg port "$NVME_NBD_PORT" \
    --arg export "$NVME_NBD_EXPORT" \
    --arg node "$BASELINE_NBD_NODE" \
    '{driver:"nbd","node-name":$node,
      server:{type:"inet",host:$host,port:$port},
      export:$export,"open-timeout":10}')" ||
    die "baseline NBD blockdev-add: $QMP_ERROR"
BASELINE_NBD_ADDED=true

echo "Adding independent HMLM delta NBD client..."
qmp_cmd blockdev-add "$(jq -cn \
    --arg host "$DEST_IP" \
    --arg port "$NVME_NBD_PORT" \
    --arg export "$NVME_NBD_EXPORT" \
    --arg node "$DELTA_NBD_NODE" \
    '{driver:"nbd","node-name":$node,
      server:{type:"inet",host:$host,port:$port},
      export:$export,"open-timeout":10}')" ||
    die "delta NBD blockdev-add: $QMP_ERROR"
DELTA_NBD_ADDED=true

# ---------------------------------------------------------------------------
# 3. Arm CDQ BEFORE starting the physical NVMe baseline.
# ---------------------------------------------------------------------------
echo
echo "Arming HMLM/CDQ..."
FULL=false
case "${HMLM_FULL_RAM_FINAL,,}" in
    1|yes|true|on) FULL=true ;;
esac

HARGS="$(jq -cn \
    --argjson fields "$HMLM_FIELDS" \
    --arg job "$MIRROR_JOB_ID" \
    --arg src "$SOURCE_HMLM_NODE" \
    --arg dst "$DELTA_NBD_NODE" \
    --arg ctrl "$HMLM_CTRL" \
    --argjson mcid "$HMLM_MCID" \
    --argjson nsid "$HMLM_NSID" \
    --argjson lba "$LBA_SIZE" \
    --argjson bytes "$NAMESPACE_BYTES" \
    --argjson cdq "$HMLM_CDQ_SIZE" \
    --argjson gran "$HMLM_DELTA_GRANULARITY" \
    --argjson cut "$HMLM_CUTOVER_BYTES" \
    --argjson timeout "$HMLM_FINAL_TIMEOUT_MS" \
    --argjson settle "$HMLM_DELTA_SETTLE_MS" \
    --argjson full "$FULL" \
    '{"mirror-job":$job,
      "source-node":$src,
      "target-node":$dst,
      ctrl:$ctrl,mcid:$mcid,nsid:$nsid,
      "lba-size":$lba,
      "namespace-bytes":$bytes,
      "cdq-size":$cdq}
      + (if ($fields|index("delta-granularity")) then
           {"delta-granularity":$gran} else {} end)
      + (if ($fields|index("cutover-bytes")) then
           {"cutover-bytes":$cut} else {} end)
      + (if ($fields|index("full-ram-final")) then
           {"full-ram-final":$full} else {} end)
      + (if ($fields|index("final-timeout-ms")) then
           {"final-timeout-ms":$timeout} else {} end)
      + (if ($fields|index("delta-settle-ms")) then
           {"delta-settle-ms":$settle} else {} end)')"

qmp_cmd x-nvme-hmlm-start "$HARGS" ||
    die "x-nvme-hmlm-start failed: $QMP_ERROR"
HMLM_STARTED=true

echo "Waiting ${HMLM_ARM_SETTLE_SEC}s after CDQ arm before baseline..."
sleep "$HMLM_ARM_SETTLE_SEC"

# ---------------------------------------------------------------------------
# 4. Start full NVMe baseline mirror.
# ---------------------------------------------------------------------------
echo "Starting physical NVMe baseline mirror..."

NVME_ARGS="$(jq -cn \
    --arg job "$MIRROR_JOB_ID" \
    --arg source "$SOURCE_HMLM_NODE" \
    --arg target "$BASELINE_NBD_NODE" \
    --argjson speed "$MIRROR_SPEED" \
    --argjson gran "$MIRROR_GRANULARITY" \
    --argjson buf "$MIRROR_BUF_SIZE" \
    '{device:$source,
      target:$target,
      sync:"full",
      speed:$speed,
      granularity:$gran,
      "buf-size":$buf,
      "copy-mode":"background",
      "on-source-error":"report",
      "on-target-error":"report",
      "job-id":$job}')"

qmp_cmd blockdev-mirror "$NVME_ARGS" ||
    die "NVMe blockdev-mirror failed: $QMP_ERROR"
NVME_MIRROR_STARTED=true

# Wait only until the NVMe mirror job is visible.  Do NOT wait for READY.
# query-block-jobs reports the job identifier in the legacy "device" field.
deadline=$((SECONDS + 30))
while true; do
    qmp_cmd query-block-jobs || die "query-block-jobs: $QMP_ERROR"
    JOBS="$QMP_RETURN"

    NVME_JOB="$(jq -c --arg j "$MIRROR_JOB_ID" \
        '[.[] | select(.device == $j)] | first // empty' <<<"$JOBS")"

    if [[ -n "$NVME_JOB" ]]; then
        JOB_STATUS="$(jq -r '.status // "unknown"' <<<"$NVME_JOB")"
        JOB_IO_STATUS="$(jq -r '."io-status" // "unknown"' <<<"$NVME_JOB")"
        JOB_ERROR="$(jq -r '.error // ""' <<<"$NVME_JOB")"

        echo "NVMe mirror job visible: id=$MIRROR_JOB_ID status=$JOB_STATUS io-status=$JOB_IO_STATUS"

        if [[ -n "$JOB_ERROR" && "$JOB_ERROR" != "null" ]]; then
            die "NVMe mirror I/O error: $JOB_ERROR"
        fi
        break
    fi

    # Generic job status may expose an asynchronous initialization failure.
    qmp_cmd query-jobs || die "query-jobs: $QMP_ERROR"
    GENERIC_JOBS="$QMP_RETURN"
    GENERIC_STATUS="$(jq -r --arg j "$MIRROR_JOB_ID" \
        '[.[] | select(.id == $j) | .status] | first // ""' <<<"$GENERIC_JOBS")"

    if [[ "$GENERIC_STATUS" == "concluded" || "$GENERIC_STATUS" == "aborting" ]]; then
        echo "NVMe mirror job terminated during initialization: status=$GENERIC_STATUS" >&2
        echo "Recent QMP events:" >&2
        tail -n 20 "$QMP_EVENT_LOG" >&2 || true
        die "NVMe mirror terminated asynchronously"
    fi

    if (( SECONDS >= deadline )); then
        echo "query-block-jobs:" >&2
        jq . <<<"$JOBS" >&2 || true
        echo "query-jobs:" >&2
        jq . <<<"$GENERIC_JOBS" >&2 || true
        echo "Recent QMP events:" >&2
        tail -n 20 "$QMP_EVENT_LOG" >&2 || true
        die "NVMe mirror did not become visible within 30 seconds"
    fi
    sleep 0.1
done

# ---------------------------------------------------------------------------
# 5. Start RAM/VFIO migration while NVMe baseline + CDQ are active.
#    HMLM itself gates final switchover.
# ---------------------------------------------------------------------------
echo
echo "Starting RAM/VFIO/controller-state migration..."
MIG_ARGS="$(jq -cn --arg uri "tcp:${DEST_IP}:${MIGRATION_PORT}" '{uri:$uri}')"
qmp_cmd migrate "$MIG_ARGS" || die "migrate failed to start: $QMP_ERROR"

echo
echo "Live status:"
echo "  NVMe mirror -> READY -> normal cancel -> HMLM delta takeover"
echo "  'entries' is cumulative; 'bitmap-dirty-bytes' is outstanding work."
echo

while true; do
    qmp_cmd query-migrate || die "query-migrate: $QMP_ERROR"
    M="$QMP_RETURN"
    STATUS="$(jq -r '.status // "unknown"' <<<"$M")"

    qmp_cmd query-nvme-hmlm || die "query-nvme-hmlm: $QMP_ERROR"
    H="$QMP_RETURN"

    ERR="$(jq -r '.error // ""' <<<"$H")"
    [[ -z "$ERR" || "$ERR" == "null" ]] || die "HMLM error: $ERR"

    BASELINE_READY="$(jq -r '."baseline-ready" // false' <<<"$H")"
    ENTRIES="$(jq -r '.entries // 0' <<<"$H")"
    MARKS="$(jq -r '."bitmap-marks" // 0' <<<"$H")"
    DIRTY_NOW="$(jq -r '."bitmap-dirty-bytes" // 0' <<<"$H")"
    DELTA_RANGES="$(jq -r '."delta-copied-ranges" // 0' <<<"$H")"
    DELTA_BYTES="$(jq -r '."delta-copied-bytes" // 0' <<<"$H")"
    DELTA_PASSES="$(jq -r '."delta-passes" // 0' <<<"$H")"
    SUSPENDED="$(jq -r '."controller-suspended" // false' <<<"$H")"
    DELETED="$(jq -r '."cdq-deleted" // false' <<<"$H")"

    qmp_cmd query-block-jobs || die "query-block-jobs: $QMP_ERROR"
    JOBS="$QMP_RETURN"

    NVME_PRESENT="$(jq -r --arg j "$MIRROR_JOB_ID" \
        '[.[] | select((."job-id" // .device) == $j)] | length' <<<"$JOBS")"

    NVME_READY="$(jq -r --arg j "$MIRROR_JOB_ID" \
        '[.[] | select((."job-id" // .device) == $j) |
          (.ready // false)] | first // false' <<<"$JOBS")"

    NVME_OFF="$(jq -r --arg j "$MIRROR_JOB_ID" \
        '[.[] | select((."job-id" // .device) == $j) |
          (.offset // 0)] | first // 0' <<<"$JOBS")"

    NVME_LEN="$(jq -r --arg j "$MIRROR_JOB_ID" \
        '[.[] | select((."job-id" // .device) == $j) |
          (.len // 0)] | first // 0' <<<"$JOBS")"

    if [[ "$NVME_LEN" =~ ^[0-9]+$ ]] && (( NVME_LEN > 0 )); then
        NVME_PCT="$(awk -v o="$NVME_OFF" -v l="$NVME_LEN" \
            'BEGIN {printf "%.2f",100*o/l}')"
    elif (( NVME_PRESENT == 0 )); then
        NVME_PCT="handoff"
    else
        NVME_PCT="0.00"
    fi

    # Six-patch handoff:
    #  - observe READY for more than one poll so HMLM also sees the stable state;
    #  - issue a normal non-force cancel;
    #  - allow QEMU's default auto-dismiss to remove the job and release the
    #    baseline NBD node so HMLM can activate its independent delta writer.
    if [[ "$NVME_MIRROR_CANCEL_SENT" == false ]]; then
        if [[ "$NVME_PRESENT" == "0" ]]; then
            die "NVMe baseline mirror disappeared before READY handoff"
        fi

        if [[ "$NVME_READY" == "true" ]]; then
            NVME_READY_POLLS=$((NVME_READY_POLLS + 1))
            if (( NVME_READY_POLLS >= READY_GRACE_POLLS )); then
                echo
                echo "NVMe baseline READY for ${NVME_READY_POLLS} polls: cancelling baseline mirror for HMLM handoff..."
                qmp_cmd block-job-cancel \
                    "$(jq -cn --arg j "$MIRROR_JOB_ID" '{device:$j,force:false}')" ||
                    die "NVMe baseline cancel failed: $QMP_ERROR"
                NVME_MIRROR_CANCEL_SENT=true
                HANDOFF_START_SEC=$SECONDS
            fi
        else
            NVME_READY_POLLS=0
        fi
    else
        if [[ "$BASELINE_READY" == "true" ]]; then
            :
        elif (( HANDOFF_START_SEC > 0 &&
                SECONDS - HANDOFF_START_SEC >= HANDOFF_TIMEOUT_SEC )); then
            if qmp_cmd query-jobs >/dev/null 2>&1; then
                echo "query-jobs at handoff timeout:" >&2
                jq . <<<"$QMP_RETURN" >&2 || true
            fi
            echo "Recent QMP events:" >&2
            tail -n 20 "$QMP_EVENT_LOG" >&2 || true
            die "HMLM baseline handoff did not complete within ${HANDOFF_TIMEOUT_SEC}s"
        fi
    fi

    printf 'migration=%-10s | NVMe=%-8s ready=%-5s baseline=%-5s | CDQ entries=%-9s marks=%-9s dirty-now=%-12s | delta ranges=%-8s bytes=%-12s passes=%-5s | suspended=%s deleted=%s\n' \
        "$STATUS" "$NVME_PCT" "$NVME_READY" "$BASELINE_READY" \
        "$ENTRIES" "$MARKS" "$DIRTY_NOW" \
        "$DELTA_RANGES" "$DELTA_BYTES" "$DELTA_PASSES" \
        "$SUSPENDED" "$DELETED"

    case "$STATUS" in
        completed)
            echo
            echo "============================================================"
            echo " MIGRATION COMPLETED"
            echo " final dirty-now      : $DIRTY_NOW"
            echo " CDQ entries consumed : $ENTRIES"
            echo " delta bytes copied   : $DELTA_BYTES"
            echo " delta passes         : $DELTA_PASSES"
            echo " controller suspended : $SUSPENDED"
            echo " CDQ deleted          : $DELETED"
            echo "============================================================"

            # Finalization deletes the controller-side CDQ.  This explicit
            # stop releases QEMU's remaining fd/eventfd/bitmap state and
            # prevents the next migration from inheriting a live session.
            qmp_cmd x-nvme-hmlm-stop '{}' ||
                die "post-migration HMLM stop failed: $QMP_ERROR"
            HMLM_STARTED=false
            qmp_cmd query-nvme-hmlm ||
                die "post-migration HMLM query failed: $QMP_ERROR"
            [[ "$(jq -r '.active // true' <<<"$QMP_RETURN")" == false ]] ||
                die "HMLM remains active after successful migration"

            MIGRATION_COMPLETED=true
            exit 0
            ;;
        failed|cancelled)
            echo "$M" | jq .
            die "migration $STATUS"
            ;;
    esac

    sleep 1
done
