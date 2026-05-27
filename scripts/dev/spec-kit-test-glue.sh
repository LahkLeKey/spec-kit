#!/usr/bin/env bash
# Spec Kit local test wrapper — parallel chunked FIFO over pytest-xdist.
#
# Design — "FIFO for our FIFO":
#   Outer FIFO  : an ordered queue of chunks; OUTER_JOBS consumers pop in
#                 dispatch order. `xargs -P` provides FIFO dispatch with
#                 parallel consumers — workers may finish out of order but
#                 chunks start in queue order.
#   Inner FIFO  : within each chunk, pytest-xdist `--dist=load` hands tests
#                 to INNER_JOBS workers one at a time (natural FIFO).
#   Cursor      : `.pytest_cache/fast-test/completed-chunks` holds one
#                 chunk index per line. `--resume` re-queues only the
#                 chunks not in that set (no off-by-one if the test set
#                 changes — unknown indices are simply skipped).
#
# Usage:
#   scripts/dev/spec-kit-test-glue.sh                          # parallel chunked run
#   scripts/dev/spec-kit-test-glue.sh --outer 4 --inner 4
#   scripts/dev/spec-kit-test-glue.sh --chunk-size 100
#   scripts/dev/spec-kit-test-glue.sh --resume                 # skip completed chunks
#   scripts/dev/spec-kit-test-glue.sh --reset                  # clear cursor + logs
#   scripts/dev/spec-kit-test-glue.sh -- tests/test_merge.py   # pass-through to pytest

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_DIR="$REPO_ROOT/.pytest_cache/fast-test"
CURSOR_FILE="$CACHE_DIR/completed-chunks"
NODES_FILE="$CACHE_DIR/nodes.txt"
LOG_DIR="$CACHE_DIR/logs"
LOCK_FILE="$CACHE_DIR/print.lock"

NPROC="$(nproc 2>/dev/null || echo 4)"
CHUNK_SIZE=200
OUTER_JOBS=2
INNER_JOBS=$(( NPROC / OUTER_JOBS )); (( INNER_JOBS < 2 )) && INNER_JOBS=2
RESUME=0
RESET=0
PASSTHROUGH=()

while (( $# )); do
    case "$1" in
        --chunk-size) CHUNK_SIZE="$2"; shift 2 ;;
        --outer)      OUTER_JOBS="$2"; shift 2 ;;
        --inner)      INNER_JOBS="$2"; shift 2 ;;
        --resume)     RESUME=1; shift ;;
        --reset)      RESET=1;  shift ;;
        --)           shift; PASSTHROUGH+=("$@"); break ;;
        -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
        *)            PASSTHROUGH+=("$1"); shift ;;
    esac
done

if (( RESET )); then
    rm -rf "$CACHE_DIR"
    echo "[fast-test] cache cleared ($CACHE_DIR)"
    exit 0
fi

cd "$REPO_ROOT"
mkdir -p "$LOG_DIR"
: > "$LOCK_FILE"

# flock isn't shipped in MSYS/Git Bash — fall back to a no-op when missing.
# Output collisions are rare because each status line is a single short
# printf well under PIPE_BUF.
if command -v flock >/dev/null 2>&1; then
    HAVE_FLOCK=1
else
    HAVE_FLOCK=0
fi

# stdbuf forces line-buffering through the pipeline so each PASSED/FAILED
# line appears in the console as soon as pytest emits it (otherwise `tee`
# and `sed` block-buffer when stdout is a pipe). MSYS/Git Bash lacks
# stdbuf, so we degrade to plain tee/sed (still mostly live because the
# downstream is a terminal).
if command -v stdbuf >/dev/null 2>&1; then
    STDBUF_LB="stdbuf -oL -eL"
    SED_BIN="stdbuf -oL -eL sed"
    TEE_BIN="stdbuf -oL -eL tee"
else
    STDBUF_LB=""
    SED_BIN="sed"
    TEE_BIN="tee"
fi

# ---------- 1. Collect node ids -------------------------------------------
printf '[fast-test] collecting tests '
COLLECT_ERR="$CACHE_DIR/collect.err"
# Heartbeat so the user sees activity during pytest's silent collection.
(
    t=0
    while sleep 2; do
        t=$(( t + 2 ))
        printf '.'
        (( t % 10 == 0 )) && printf '(%ds)' "$t"
    done
) &
COLLECT_HB=$!
trap 'kill $COLLECT_HB 2>/dev/null || true' EXIT
if ! uv run pytest -o addopts= --collect-only -q "${PASSTHROUGH[@]}" \
        2>"$COLLECT_ERR" | grep -E '::' > "$NODES_FILE.tmp"; then
    # grep returning 1 (no matches) is the only acceptable failure path;
    # any pytest failure leaves stderr in $COLLECT_ERR for diagnosis.
    if [[ ! -s "$NODES_FILE.tmp" ]]; then
        kill $COLLECT_HB 2>/dev/null || true
        printf '\n'
        echo "[fast-test] no tests collected" >&2
        [[ -s "$COLLECT_ERR" ]] && { echo "--- collection stderr ---"; cat "$COLLECT_ERR"; } >&2
        exit 1
    fi
fi
kill $COLLECT_HB 2>/dev/null || true
trap - EXIT
printf ' done\n'
mv "$NODES_FILE.tmp" "$NODES_FILE"
TOTAL="$(wc -l < "$NODES_FILE" | tr -d ' ')"
NUM_CHUNKS=$(( (TOTAL + CHUNK_SIZE - 1) / CHUNK_SIZE ))

# ---------- 2. Build pending chunk queue ----------------------------------
declare -A DONE=()
if (( RESUME )) && [[ -f "$CURSOR_FILE" ]]; then
    while read -r d; do [[ -n "$d" ]] && DONE[$d]=1; done < "$CURSOR_FILE"
fi
PENDING=()
for ((i=1; i<=NUM_CHUNKS; i++)); do
    [[ -z "${DONE[$i]:-}" ]] && PENDING+=("$i")
done
PENDING_COUNT="${#PENDING[@]}"
SKIPPED=$(( NUM_CHUNKS - PENDING_COUNT ))

(( OUTER_JOBS > PENDING_COUNT && PENDING_COUNT > 0 )) && OUTER_JOBS="$PENDING_COUNT"

printf '[fast-test] %d tests · %d chunks (size %d) · outer=%d inner=%d' \
    "$TOTAL" "$NUM_CHUNKS" "$CHUNK_SIZE" "$OUTER_JOBS" "$INNER_JOBS"
(( SKIPPED > 0 )) && printf ' · resume skips %d done' "$SKIPPED"
printf '\n'

if (( PENDING_COUNT == 0 )); then
    echo "[fast-test] nothing to run"
    rm -f "$CURSOR_FILE"
    exit 0
fi

# ---------- 3. Per-chunk runner (executed by xargs workers) ---------------
run_chunk() {
    local idx="$1"
    local start=$(( (idx - 1) * CHUNK_SIZE ))
    local end=$(( start + CHUNK_SIZE ))
    (( end > TOTAL )) && end=$TOTAL
    local count=$(( end - start ))
    local log="$LOG_DIR/chunk-$idx.log"
    local t0 dt status summary
    t0=$(date +%s)
    # Mark this chunk active so the heartbeat watcher can list in-flight
    # work even when no test lines are being emitted.
    : > "$ACTIVE_DIR/$idx"

    if (( HAVE_FLOCK )); then
        { flock 9
          printf '  > chunk %3d/%-3d  START   %4d tests (#%d..#%d)\n' \
              "$idx" "$NUM_CHUNKS" "$count" "$((start+1))" "$end"
        } 9>"$LOCK_FILE"
    else
        printf '  > chunk %3d/%-3d  START   %4d tests (#%d..#%d)\n' \
            "$idx" "$NUM_CHUNKS" "$count" "$((start+1))" "$end"
    fi

    # Stream pytest output live so the user sees per-test feedback as it
    # happens. We tee to a per-chunk log for post-run inspection and prefix
    # each line on stdout with [cNN] so interleaved chunks stay readable.
    # `-v` gives one line per test (line-buffered), so prefix injection
    # works without a pty.
    local prefix
    prefix="$(printf '[c%02d] ' "$idx")"
    set +e
    PYTHONUNBUFFERED=1 \
        sed -n "$((start+1)),${end}p" "$NODES_FILE" \
        | xargs -d '\n' -r uv run pytest -o addopts= \
            -n "$INNER_JOBS" --dist=load --tb=short -v \
            2>&1 \
        | $TEE_BIN "$log" \
        | $SED_BIN -e "s|^|$prefix|"
    status="${PIPESTATUS[1]}"
    set -e
    dt=$(( $(date +%s) - t0 ))
    # Prefer pytest's final '=== N passed[, M failed] in Xs ===' banner;
    # fall back to any '[counts] passed/failed/...' line if banner is absent.
    summary="$(grep -E '^=+ .*(passed|failed|error|skipped).* in [0-9.]+s =+$' "$log" \
              | tail -1 | sed -E 's/^=+ *//; s/ *=+$//; s/ in [0-9.]+s$//')"
    if [[ -z "$summary" ]]; then
        summary="$(grep -E '[0-9]+ (passed|failed|error|skipped)' "$log" \
                  | tail -1 | sed -E 's/^=+ *//; s/ *=+$//; s/ in [0-9.]+s$//')"
    fi
    [[ -z "$summary" ]] && summary="(no summary in log)"

    _emit() {
        if (( status == 0 )); then
            printf '  + chunk %3d/%-3d  PASS    %-40s  %3ds\n' \
                "$idx" "$NUM_CHUNKS" "$summary" "$dt"
            echo "$idx" >> "$CURSOR_FILE"
        else
            printf '  X chunk %3d/%-3d  FAIL    %-40s  %3ds  -> %s\n' \
                "$idx" "$NUM_CHUNKS" "$summary" "$dt" "$log"
        fi
    }
    if (( HAVE_FLOCK )); then
        { flock 9; _emit; } 9>"$LOCK_FILE"
    else
        _emit
    fi
    rm -f "$ACTIVE_DIR/$idx"

    return "$status"
}
export -f run_chunk
ACTIVE_DIR="$CACHE_DIR/active"
rm -rf "$ACTIVE_DIR"; mkdir -p "$ACTIVE_DIR"
export REPO_ROOT CACHE_DIR CURSOR_FILE NODES_FILE LOG_DIR LOCK_FILE ACTIVE_DIR \
       CHUNK_SIZE NUM_CHUNKS TOTAL INNER_JOBS HAVE_FLOCK SED_BIN TEE_BIN STDBUF_LB

# ---------- 4. Parallel FIFO dispatch -------------------------------------
WALL_START=$(date +%s)
DISPATCH_RC=0

# In-flight heartbeat: every 5s, print which chunks are still running
# and for how long. Keeps the console alive during slow chunks that
# aren't currently emitting test lines (worker spinup, setup/teardown,
# a long single test). Short interval so users never wonder if it froze.
(
    while sleep 5; do
        active=( "$ACTIVE_DIR"/* )
        [[ -e "${active[0]}" ]] || continue
        now=$(date +%s)
        parts=()
        for f in "${active[@]}"; do
            idx="$(basename "$f")"
            started=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
            parts+=("c${idx}=$((now - started))s")
        done
        printf '  ~ in-flight (%d): %s\n' "${#parts[@]}" "${parts[*]}"
    done
) &
HEARTBEAT_PID=$!
trap 'kill $HEARTBEAT_PID 2>/dev/null || true' EXIT

printf '%s\n' "${PENDING[@]}" \
    | xargs -P "$OUTER_JOBS" -I{} bash -c 'run_chunk "$@"' _ {} \
    || DISPATCH_RC=$?
kill $HEARTBEAT_PID 2>/dev/null || true
trap - EXIT
WALL=$(( $(date +%s) - WALL_START ))

# ---------- 5. Tally ------------------------------------------------------
COMPLETED=0
[[ -f "$CURSOR_FILE" ]] && COMPLETED="$(sort -u "$CURSOR_FILE" | wc -l | tr -d ' ')"
FAILED=$(( PENDING_COUNT - (COMPLETED - SKIPPED) ))

printf '\n[fast-test] '
if (( DISPATCH_RC == 0 && FAILED == 0 )); then
    printf 'all %d chunks passed · wall %ds\n' "$NUM_CHUNKS" "$WALL"
    rm -f "$CURSOR_FILE"
    exit 0
else
    printf '%d/%d chunks passed · %d failed · wall %ds\n' \
        "$COMPLETED" "$NUM_CHUNKS" "$FAILED" "$WALL"
    echo "[fast-test] failing chunk logs:"
    for log in "$LOG_DIR"/chunk-*.log; do
        idx="$(basename "$log" .log | sed 's/^chunk-//')"
        if [[ -z "${DONE[$idx]:-}" ]] && ! grep -qx "$idx" "$CURSOR_FILE" 2>/dev/null; then
            echo "  - $log"
        fi
    done
    echo "[fast-test] re-run with --resume to retry failed chunks only"
    exit 1
fi
