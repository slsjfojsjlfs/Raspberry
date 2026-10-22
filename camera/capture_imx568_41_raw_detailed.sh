#!/usr/bin/env bash

set -Eeuo pipefail

readonly VIDEO_DEVICE="/dev/video0"
readonly CONTROL_DEVICE="/dev/v4l-subdev2"
readonly RESULT_DIR="/home/r/Raspberry/Image/image_temp_result"
FRAME_COUNT=41
INTERVAL_MS="0"
readonly WARMUP_FRAMES=1
readonly WIDTH=2464
readonly HEIGHT=2064
readonly PIXEL_FORMAT="GREY"
readonly FRAME_BYTES=$((WIDTH * HEIGHT))
readonly BURST_FILE="${RESULT_DIR}/.imx568_frames.raw"
readonly V4L2_LOG="${RESULT_DIR}/.v4l2_capture.log"
readonly LOCK_FILE="/tmp/imx568_capture_41.lock"
RESTORE_FRAME_RATE=0

usage() {
    cat <<'EOF'
Usage: capture_imx568_41_raw_detailed.sh [options]

Options:
  -n, --count N          Number of RAW frames to save (default: 41)
  -i, --interval-ms MS   Target frame interval in milliseconds; 0 uses the
                         camera's automatic/maximum frame rate (default: 0)
  -h, --help             Show this help

Examples:
  capture_imx568_41_raw_detailed.sh
  capture_imx568_41_raw_detailed.sh --count 100 --interval-ms 50
EOF
}

while (( $# > 0 )); do
    case "$1" in
        -n|--count)
            (( $# >= 2 )) || { usage >&2; exit 2; }
            FRAME_COUNT="$2"
            shift 2
            ;;
        -i|--interval-ms)
            (( $# >= 2 )) || { usage >&2; exit 2; }
            INTERVAL_MS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$FRAME_COUNT" =~ ^[1-9][0-9]*$ ]] \
    || { printf 'Frame count must be a positive integer.\n' >&2; exit 2; }
(( FRAME_COUNT <= 100000 )) \
    || { printf 'Frame count must not exceed 100000.\n' >&2; exit 2; }
INTERVAL_MS=$(python3 - "$INTERVAL_MS" <<'PY'
import math
import sys

try:
    value = float(sys.argv[1])
except ValueError:
    raise SystemExit("Interval must be a non-negative number.")
if not math.isfinite(value) or value < 0:
    raise SystemExit("Interval must be a finite non-negative number.")
print(f"{value:.12g}")
PY
 ) || exit 2

readonly FRAME_COUNT INTERVAL_MS
readonly EXPECTED_BYTES=$((FRAME_BYTES * FRAME_COUNT))

log() {
    printf '[%(%F %T)T] %s\n' -1 "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

cleanup() {
    rm -f -- "$BURST_FILE" "$V4L2_LOG"
    if (( RESTORE_FRAME_RATE == 1 )) && [[ -c "$CONTROL_DEVICE" ]]; then
        v4l2-ctl -d "$CONTROL_DEVICE" -c frame_rate=0 >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

for command_name in v4l2-ctl timeout python3 flock find stat df awk tr; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "Required command not found: $command_name"
done

[[ -c "$VIDEO_DEVICE" ]] || fail "Capture device not found: $VIDEO_DEVICE"
[[ -c "$CONTROL_DEVICE" ]] || fail "Control device not found: $CONTROL_DEVICE"

exec 9>"$LOCK_FILE"
flock -n 9 || fail "Another IMX568 capture job is already running."

mkdir -p -- "$RESULT_DIR"
[[ "$RESULT_DIR" == "/home/r/Raspberry/Image/image_temp_result" ]] \
    || fail "Refusing to clear an unexpected result directory: $RESULT_DIR"
find "$RESULT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

available_kib=$(df -Pk "$RESULT_DIR" | awk 'NR == 2 {print $4}')
required_kib=$(((EXPECTED_BYTES * 2 + 16 * 1024 * 1024 + 1023) / 1024))
(( available_kib >= required_kib )) \
    || fail "Not enough free space: need at least ${required_kib} KiB."

SCRIPT_START_WALL_NS=$(python3 -c 'import time; print(time.time_ns())')
CLOCK_SYNC_STATUS="unknown"
if command -v timedatectl >/dev/null 2>&1; then
    CLOCK_SYNC_STATUS=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    [[ -n "$CLOCK_SYNC_STATUS" ]] || CLOCK_SYNC_STATUS="unknown"
fi
if [[ "$CLOCK_SYNC_STATUS" != "yes" ]]; then
    log "WARNING: system clock is not reported as NTP-synchronized (${CLOCK_SYNC_STATUS}); absolute timestamps depend on the board clock."
fi

log "Configuring IMX568 for continuous RAW8 capture."
v4l2-ctl -d "$CONTROL_DEVICE" -c trigger_mode=0
v4l2-ctl -d "$VIDEO_DEVICE" \
    --set-fmt-video="width=${WIDTH},height=${HEIGHT},pixelformat=${PIXEL_FORMAT}"

DESIRED_FRAME_RATE_MHZ=0
if [[ "$INTERVAL_MS" != "0" ]]; then
    DESIRED_FRAME_RATE_MHZ=$(python3 - "$INTERVAL_MS" <<'PY'
import sys

interval_ms = float(sys.argv[1])
rate_millihz = round(1_000_000 / interval_ms)
if rate_millihz < 1:
    raise SystemExit("Requested interval is too large for the frame_rate control.")
print(rate_millihz)
PY
    )
    v4l2-ctl -d "$CONTROL_DEVICE" -c "frame_rate=${DESIRED_FRAME_RATE_MHZ}" \
        || fail "The camera rejected interval ${INTERVAL_MS} ms (frame_rate=${DESIRED_FRAME_RATE_MHZ} mHz)."
    RESTORE_FRAME_RATE=1
else
    v4l2-ctl -d "$CONTROL_DEVICE" -c frame_rate=0
fi

frame_rate_output=$(v4l2-ctl -d "$CONTROL_DEVICE" -C frame_rate)
ACTUAL_FRAME_RATE_MHZ=$(printf '%s' "$frame_rate_output" | tr -cd '0-9')
[[ -n "$ACTUAL_FRAME_RATE_MHZ" ]] || fail "Could not read the configured frame_rate."
CAPTURE_TIMEOUT_SECONDS=$(python3 - "$FRAME_COUNT" "$ACTUAL_FRAME_RATE_MHZ" <<'PY'
import math
import sys

count = int(sys.argv[1])
rate_millihz = int(sys.argv[2])
# When frame_rate=0 the driver selects its automatic rate. Allow a conservative
# 100 ms per frame for timeout calculation without changing camera timing.
interval_ms = 1_000_000 / rate_millihz if rate_millihz > 0 else 100.0
print(max(30, math.ceil(count * interval_ms / 1000) + 15))
PY
)

log "Requested count=${FRAME_COUNT}, interval_ms=${INTERVAL_MS}, configured_frame_rate_millihz=${ACTUAL_FRAME_RATE_MHZ}."

read -r CAPTURE_START_WALL_NS CAPTURE_START_MONO_NS < <(
    python3 -c 'import time; print(time.time_ns(), time.monotonic_ns())'
)

log "Capturing ${FRAME_COUNT} RAW frames after ${WARMUP_FRAMES} warm-up frame."
if ! timeout "${CAPTURE_TIMEOUT_SECONDS}s" v4l2-ctl -d "$VIDEO_DEVICE" \
    --stream-mmap=4 \
    --stream-skip="$WARMUP_FRAMES" \
    --stream-count="$FRAME_COUNT" \
    --stream-to="$BURST_FILE" \
    --stream-show-delta-now \
    --verbose >"$V4L2_LOG" 2>&1; then
    sed -n '1,200p' "$V4L2_LOG" >&2 || true
    fail "V4L2 capture failed or timed out."
fi

CAPTURE_END_WALL_NS=$(python3 -c 'import time; print(time.time_ns())')
actual_bytes=$(stat -c '%s' "$BURST_FILE")
[[ "$actual_bytes" -eq "$EXPECTED_BYTES" ]] \
    || fail "Burst size is ${actual_bytes} bytes; expected ${EXPECTED_BYTES}."

log "Splitting the burst into ${FRAME_COUNT} individual RAW files and writing reports."
python3 - \
    "$BURST_FILE" "$V4L2_LOG" "$RESULT_DIR" \
    "$WIDTH" "$HEIGHT" "$FRAME_COUNT" "$WARMUP_FRAMES" \
    "$SCRIPT_START_WALL_NS" "$CAPTURE_START_WALL_NS" \
    "$CAPTURE_START_MONO_NS" "$CAPTURE_END_WALL_NS" \
    "$VIDEO_DEVICE" "$CONTROL_DEVICE" "$PIXEL_FORMAT" "$CLOCK_SYNC_STATUS" \
    "$INTERVAL_MS" "$ACTUAL_FRAME_RATE_MHZ" <<'PY'
from __future__ import annotations

import csv
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import sys
import time


(
    burst_name,
    v4l2_log_name,
    result_name,
    width_text,
    height_text,
    count_text,
    warmup_text,
    script_start_text,
    capture_start_wall_text,
    capture_start_mono_text,
    capture_end_wall_text,
    video_device,
    control_device,
    pixel_format,
    clock_sync_status,
    requested_interval_text,
    configured_frame_rate_text,
) = sys.argv[1:]

burst_path = Path(burst_name)
v4l2_log_path = Path(v4l2_log_name)
result_dir = Path(result_name)
width = int(width_text)
height = int(height_text)
frame_count = int(count_text)
warmup_frames = int(warmup_text)
script_start_wall_ns = int(script_start_text)
capture_start_wall_ns = int(capture_start_wall_text)
capture_start_mono_ns = int(capture_start_mono_text)
capture_end_wall_ns = int(capture_end_wall_text)
frame_bytes = width * height
requested_interval_ms = float(requested_interval_text)
configured_frame_rate_millihz = int(configured_frame_rate_text)
configured_interval_ms = (
    1_000_000 / configured_frame_rate_millihz
    if configured_frame_rate_millihz > 0
    else None
)

pattern = re.compile(
    r"cap dqbuf:\s*(?P<buffer>\d+)\s+"
    r"seq:\s*(?P<sequence>\d+)\s+"
    r"bytesused:\s*(?P<bytes>\d+)\s+"
    r"ts:\s*(?P<timestamp>\d+\.\d+)"
)
buffers = []
for line in v4l2_log_path.read_text(encoding="utf-8", errors="replace").splitlines():
    match = pattern.search(line)
    if match:
        buffers.append(
            {
                "buffer_index": int(match.group("buffer")),
                "sequence": int(match.group("sequence")),
                "raw_bytes": int(match.group("bytes")),
                "monotonic_ns": round(float(match.group("timestamp")) * 1_000_000_000),
            }
        )

expected_timestamp_count = frame_count + warmup_frames
if len(buffers) != expected_timestamp_count:
    raise RuntimeError(
        f"Parsed {len(buffers)} V4L2 timestamps; expected "
        f"{expected_timestamp_count} including warm-up frames"
    )
discarded_buffers = buffers[:warmup_frames]
buffers = buffers[warmup_frames:]
if any(item["raw_bytes"] != frame_bytes for item in buffers):
    raise RuntimeError("At least one V4L2 buffer has an unexpected byte count")
if any(
    buffers[index]["sequence"] != buffers[index - 1]["sequence"] + 1
    for index in range(1, frame_count)
):
    raise RuntimeError("Non-contiguous V4L2 sequence numbers indicate dropped frames")

local_timezone = datetime.now().astimezone().tzinfo
records = []
with burst_path.open("rb") as source:
    for index, buffer in enumerate(buffers, start=1):
        payload = source.read(frame_bytes)
        if len(payload) != frame_bytes:
            raise RuntimeError(
                f"Frame {index} has {len(payload)} bytes; expected {frame_bytes}"
            )
        output_path = result_dir / f"imx568_{index:03d}.raw"
        output_path.write_bytes(payload)
        actual_size = output_path.stat().st_size
        if actual_size != frame_bytes:
            raise RuntimeError(
                f"{output_path} has {actual_size} bytes; expected {frame_bytes}"
            )

        timestamp_ns = capture_start_wall_ns + (
            buffer["monotonic_ns"] - capture_start_mono_ns
        )
        timestamp = datetime.fromtimestamp(
            timestamp_ns / 1_000_000_000, tz=local_timezone
        ).isoformat(timespec="microseconds")
        previous_ns = buffers[index - 2]["monotonic_ns"] if index > 1 else None
        interval_ms = (
            (buffer["monotonic_ns"] - previous_ns) / 1_000_000
            if previous_ns is not None
            else None
        )
        records.append(
            {
                "frame_index": index,
                "sequence": buffer["sequence"],
                "buffer_index": buffer["buffer_index"],
                "timestamp": timestamp,
                "timestamp_epoch_ns": timestamp_ns,
                "kernel_monotonic_ns": buffer["monotonic_ns"],
                "interval_from_previous_ms": interval_ms,
                "raw_file": output_path.name,
                "raw_bytes": actual_size,
                "raw_sha256": hashlib.sha256(payload).hexdigest(),
            }
        )
    if source.read(1):
        raise RuntimeError("RAW burst contains trailing data")

intervals = [record["interval_from_previous_ms"] for record in records[1:]]
interval_statistics = {
    "count": len(intervals),
    "average": sum(intervals) / len(intervals) if intervals else None,
    "minimum": min(intervals) if intervals else None,
    "maximum": max(intervals) if intervals else None,
}
script_end_wall_ns = time.time_ns()
summary = {
    "status": "success",
    "storage_format": "RAW8 GREY, one byte per pixel, no file header",
    "timestamp_source": "V4L2 buffer timestamp, CLOCK_MONOTONIC, end of frame",
    "system_clock_ntp_synchronized": clock_sync_status,
    "started_at": datetime.fromtimestamp(
        script_start_wall_ns / 1_000_000_000, tz=local_timezone
    ).isoformat(timespec="microseconds"),
    "completed_at": datetime.fromtimestamp(
        script_end_wall_ns / 1_000_000_000, tz=local_timezone
    ).isoformat(timespec="microseconds"),
    "video_device": video_device,
    "control_device": control_device,
    "frame_count": frame_count,
    "requested_interval_ms": requested_interval_ms,
    "configured_frame_rate_millihz": configured_frame_rate_millihz,
    "configured_interval_ms": configured_interval_ms,
    "discarded_warmup_frames": warmup_frames,
    "discarded_warmup_sequences": [item["sequence"] for item in discarded_buffers],
    "width": width,
    "height": height,
    "pixel_format": pixel_format,
    "expected_raw_bytes_per_frame": frame_bytes,
    "capture_command_elapsed_ms": (
        capture_end_wall_ns - capture_start_wall_ns
    ) / 1_000_000,
    "first_to_last_frame_ms": (
        buffers[-1]["monotonic_ns"] - buffers[0]["monotonic_ns"]
    ) / 1_000_000,
    "total_script_elapsed_ms": (script_end_wall_ns - script_start_wall_ns) / 1_000_000,
    "frame_interval_ms": interval_statistics,
    "total_raw_bytes": sum(record["raw_bytes"] for record in records),
    "frames": records,
}

with (result_dir / "capture_report.json").open("w", encoding="utf-8") as target:
    json.dump(summary, target, ensure_ascii=False, indent=2)
    target.write("\n")

with (result_dir / "frames.csv").open("w", encoding="utf-8", newline="") as target:
    writer = csv.DictWriter(target, fieldnames=list(records[0].keys()))
    writer.writeheader()
    writer.writerows(records)

def format_optional(value: float | None) -> str:
    return "N/A" if value is None else f"{value:.6f}"


with (result_dir / "capture_detailed.log").open("w", encoding="utf-8") as target:
    target.write(f"IMX568 {frame_count}-frame RAW detailed capture log\n")
    target.write("=" * 72 + "\n")
    target.write(f"status: {summary['status']}\n")
    target.write(f"storage_format: {summary['storage_format']}\n")
    target.write(f"started_at: {summary['started_at']}\n")
    target.write(f"completed_at: {summary['completed_at']}\n")
    target.write(f"timestamp_source: {summary['timestamp_source']}\n")
    target.write(f"system_clock_ntp_synchronized: {clock_sync_status}\n")
    target.write(f"video_device: {video_device}\n")
    target.write(f"control_device: {control_device}\n")
    target.write(f"format: {pixel_format} {width}x{height}\n")
    target.write(f"frame_count: {frame_count}\n")
    target.write(f"requested_interval_ms: {requested_interval_ms:.6f}\n")
    target.write(f"configured_frame_rate_millihz: {configured_frame_rate_millihz}\n")
    target.write(f"configured_interval_ms: {format_optional(configured_interval_ms)}\n")
    target.write(f"discarded_warmup_frames: {warmup_frames}\n")
    target.write(f"capture_command_elapsed_ms: {summary['capture_command_elapsed_ms']:.6f}\n")
    target.write(f"first_to_last_frame_ms: {summary['first_to_last_frame_ms']:.6f}\n")
    target.write(f"total_script_elapsed_ms: {summary['total_script_elapsed_ms']:.6f}\n")
    target.write(f"average_interval_ms: {format_optional(interval_statistics['average'])}\n")
    target.write(f"minimum_interval_ms: {format_optional(interval_statistics['minimum'])}\n")
    target.write(f"maximum_interval_ms: {format_optional(interval_statistics['maximum'])}\n")
    target.write(f"total_raw_bytes: {summary['total_raw_bytes']}\n")
    target.write("\nPer-frame records\n")
    target.write("-" * 72 + "\n")
    for record in records:
        interval = record["interval_from_previous_ms"]
        interval_text = "N/A" if interval is None else f"{interval:.6f}"
        target.write(
            f"frame={record['frame_index']:03d} "
            f"sequence={record['sequence']} "
            f"timestamp={record['timestamp']} "
            f"interval_ms={interval_text} "
            f"raw_bytes={record['raw_bytes']} "
            f"file={record['raw_file']} "
            f"sha256={record['raw_sha256']}\n"
        )

with (result_dir / "capture_info.txt").open("w", encoding="utf-8") as target:
    target.write(f"captured_at={summary['completed_at']}\n")
    target.write(f"video_device={video_device}\n")
    target.write(f"control_device={control_device}\n")
    target.write(f"frame_count={frame_count}\n")
    target.write(f"requested_interval_ms={requested_interval_ms:.6f}\n")
    target.write(f"configured_frame_rate_millihz={configured_frame_rate_millihz}\n")
    target.write(f"configured_interval_ms={format_optional(configured_interval_ms)}\n")
    target.write(f"discarded_warmup_frames={warmup_frames}\n")
    target.write(f"width={width}\n")
    target.write(f"height={height}\n")
    target.write(f"pixel_format={pixel_format}\n")
    target.write(f"frame_bytes={frame_bytes}\n")
    target.write(f"system_clock_ntp_synchronized={clock_sync_status}\n")
    target.write(f"capture_command_elapsed_ms={summary['capture_command_elapsed_ms']:.6f}\n")
    target.write(f"average_interval_ms={format_optional(interval_statistics['average'])}\n")
PY

rm -f -- "$BURST_FILE" "$V4L2_LOG"

raw_count=$(find "$RESULT_DIR" -maxdepth 1 -type f -name 'imx568_*.raw' | wc -l)
[[ "$raw_count" -eq "$FRAME_COUNT" ]] \
    || fail "Generated ${raw_count} RAW files; expected ${FRAME_COUNT}."

for report in capture_detailed.log capture_report.json frames.csv capture_info.txt; do
    [[ -s "${RESULT_DIR}/${report}" ]] || fail "Missing report: ${report}"
done

log "Capture completed: ${raw_count} RAW files and detailed logs in ${RESULT_DIR}"
