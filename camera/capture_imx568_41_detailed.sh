#!/usr/bin/env bash

set -Eeuo pipefail

readonly VIDEO_DEVICE="/dev/video0"
readonly CONTROL_DEVICE="/dev/v4l-subdev2"
readonly RESULT_DIR="/home/r/Raspberry/Image/image_temp_result"
readonly FRAME_COUNT=41
readonly WARMUP_FRAMES=1
readonly WIDTH=2464
readonly HEIGHT=2064
readonly PIXEL_FORMAT="GREY"
readonly FRAME_BYTES=$((WIDTH * HEIGHT))
readonly EXPECTED_BYTES=$((FRAME_BYTES * FRAME_COUNT))
readonly BURST_FILE="${RESULT_DIR}/.imx568_41_frames.raw"
readonly V4L2_LOG="${RESULT_DIR}/.v4l2_capture.log"
readonly LOCK_FILE="/tmp/imx568_capture_41.lock"

log() {
    printf '[%(%F %T)T] %s\n' -1 "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

cleanup() {
    rm -f -- "$BURST_FILE" "$V4L2_LOG"
}
trap cleanup EXIT

for command_name in v4l2-ctl timeout python3 flock find stat df awk; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "Required command not found: $command_name"
done

[[ -c "$VIDEO_DEVICE" ]] || fail "Capture device not found: $VIDEO_DEVICE"
[[ -c "$CONTROL_DEVICE" ]] || fail "Control device not found: $CONTROL_DEVICE"
python3 -c 'import cv2, numpy' >/dev/null 2>&1 \
    || fail "Python packages OpenCV (cv2) and NumPy are required."

exec 9>"$LOCK_FILE"
flock -n 9 || fail "Another IMX568 capture job is already running."

mkdir -p -- "$RESULT_DIR"
[[ "$RESULT_DIR" == "/home/r/Raspberry/Image/image_temp_result" ]] \
    || fail "Refusing to clear an unexpected result directory: $RESULT_DIR"
find "$RESULT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

available_kib=$(df -Pk "$RESULT_DIR" | awk 'NR == 2 {print $4}')
required_kib=$(((EXPECTED_BYTES * 3 + 1023) / 1024))
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

# Capture an epoch/monotonic clock anchor immediately before streaming. V4L2
# buffer timestamps use CLOCK_MONOTONIC and are converted to local wall time by
# the reporting code below.
read -r CAPTURE_START_WALL_NS CAPTURE_START_MONO_NS < <(
    python3 -c 'import time; print(time.time_ns(), time.monotonic_ns())'
)

log "Capturing ${FRAME_COUNT} consecutive frames and kernel timestamps."
if ! timeout 30s v4l2-ctl -d "$VIDEO_DEVICE" \
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

log "Converting RAW8 frames and writing detailed reports."
python3 - \
    "$BURST_FILE" "$V4L2_LOG" "$RESULT_DIR" \
    "$WIDTH" "$HEIGHT" "$FRAME_COUNT" "$WARMUP_FRAMES" \
    "$SCRIPT_START_WALL_NS" "$CAPTURE_START_WALL_NS" \
    "$CAPTURE_START_MONO_NS" "$CAPTURE_END_WALL_NS" \
    "$VIDEO_DEVICE" "$CONTROL_DEVICE" "$PIXEL_FORMAT" "$CLOCK_SYNC_STATUS" <<'PY'
from __future__ import annotations

import csv
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import sys
import time

import cv2
import numpy as np


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
        f"Parsed {len(buffers)} V4L2 frame timestamps; expected "
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
        image = np.frombuffer(payload, dtype=np.uint8).reshape(height, width)
        output_path = result_dir / f"imx568_{index:03d}.png"
        if not cv2.imwrite(str(output_path), image):
            raise RuntimeError(f"Failed to write {output_path}")

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
                "raw_bytes": buffer["raw_bytes"],
                "png_file": output_path.name,
                "png_bytes": output_path.stat().st_size,
                "png_sha256": hashlib.sha256(output_path.read_bytes()).hexdigest(),
            }
        )
    if source.read(1):
        raise RuntimeError("RAW burst contains trailing data")

intervals = [record["interval_from_previous_ms"] for record in records[1:]]
script_end_wall_ns = time.time_ns()
summary = {
    "status": "success",
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
    "frame_interval_ms": {
        "count": len(intervals),
        "average": sum(intervals) / len(intervals),
        "minimum": min(intervals),
        "maximum": max(intervals),
    },
    "total_png_bytes": sum(record["png_bytes"] for record in records),
    "frames": records,
}

with (result_dir / "capture_report.json").open("w", encoding="utf-8") as target:
    json.dump(summary, target, ensure_ascii=False, indent=2)
    target.write("\n")

csv_fields = list(records[0].keys())
with (result_dir / "frames.csv").open("w", encoding="utf-8", newline="") as target:
    writer = csv.DictWriter(target, fieldnames=csv_fields)
    writer.writeheader()
    writer.writerows(records)

with (result_dir / "capture_detailed.log").open("w", encoding="utf-8") as target:
    target.write("IMX568 41-frame detailed capture log\n")
    target.write("=" * 72 + "\n")
    target.write(f"status: {summary['status']}\n")
    target.write(f"started_at: {summary['started_at']}\n")
    target.write(f"completed_at: {summary['completed_at']}\n")
    target.write(f"timestamp_source: {summary['timestamp_source']}\n")
    target.write(f"system_clock_ntp_synchronized: {clock_sync_status}\n")
    target.write(f"video_device: {video_device}\n")
    target.write(f"control_device: {control_device}\n")
    target.write(f"format: {pixel_format} {width}x{height}\n")
    target.write(f"frame_count: {frame_count}\n")
    target.write(f"discarded_warmup_frames: {warmup_frames}\n")
    target.write(
        f"capture_command_elapsed_ms: {summary['capture_command_elapsed_ms']:.6f}\n"
    )
    target.write(f"first_to_last_frame_ms: {summary['first_to_last_frame_ms']:.6f}\n")
    target.write(f"total_script_elapsed_ms: {summary['total_script_elapsed_ms']:.6f}\n")
    target.write(f"average_interval_ms: {summary['frame_interval_ms']['average']:.6f}\n")
    target.write(f"minimum_interval_ms: {summary['frame_interval_ms']['minimum']:.6f}\n")
    target.write(f"maximum_interval_ms: {summary['frame_interval_ms']['maximum']:.6f}\n")
    target.write(f"total_png_bytes: {summary['total_png_bytes']}\n")
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
            f"png_bytes={record['png_bytes']} "
            f"file={record['png_file']} "
            f"sha256={record['png_sha256']}\n"
        )

# Keep the old summary filename for compatibility with existing download tools.
with (result_dir / "capture_info.txt").open("w", encoding="utf-8") as target:
    target.write(f"captured_at={summary['completed_at']}\n")
    target.write(f"video_device={video_device}\n")
    target.write(f"control_device={control_device}\n")
    target.write(f"frame_count={frame_count}\n")
    target.write(f"discarded_warmup_frames={warmup_frames}\n")
    target.write(f"width={width}\n")
    target.write(f"height={height}\n")
    target.write(f"pixel_format={pixel_format}\n")
    target.write(f"system_clock_ntp_synchronized={clock_sync_status}\n")
    target.write(f"frame_bytes={frame_bytes}\n")
    target.write(f"capture_command_elapsed_ms={summary['capture_command_elapsed_ms']:.6f}\n")
    target.write(f"average_interval_ms={summary['frame_interval_ms']['average']:.6f}\n")
PY

rm -f -- "$BURST_FILE" "$V4L2_LOG"

png_count=$(find "$RESULT_DIR" -maxdepth 1 -type f -name 'imx568_*.png' | wc -l)
[[ "$png_count" -eq "$FRAME_COUNT" ]] \
    || fail "Generated ${png_count} PNG files; expected ${FRAME_COUNT}."

for report in capture_detailed.log capture_report.json frames.csv capture_info.txt; do
    [[ -s "${RESULT_DIR}/${report}" ]] || fail "Missing report: ${report}"
done

log "Capture completed: ${png_count} PNG files and detailed logs in ${RESULT_DIR}"
