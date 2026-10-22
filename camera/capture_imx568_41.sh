#!/usr/bin/env bash

set -Eeuo pipefail

readonly VIDEO_DEVICE="/dev/video0"
readonly CONTROL_DEVICE="/dev/v4l-subdev2"
readonly RESULT_DIR="/home/r/Raspberry/Image/image_temp_result"
readonly FRAME_COUNT=41
readonly WIDTH=2464
readonly HEIGHT=2064
readonly PIXEL_FORMAT="GREY"
readonly FRAME_BYTES=$((WIDTH * HEIGHT))
readonly EXPECTED_BYTES=$((FRAME_BYTES * FRAME_COUNT))
readonly BURST_FILE="${RESULT_DIR}/.imx568_41_frames.raw"
readonly LOCK_FILE="/tmp/imx568_capture_41.lock"

log() {
    printf '[%(%F %T)T] %s\n' -1 "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

cleanup() {
    rm -f -- "$BURST_FILE"
}
trap cleanup EXIT

for command_name in v4l2-ctl timeout python3 flock find; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "Required command not found: $command_name"
done

[[ -c "$VIDEO_DEVICE" ]] || fail "Capture device not found: $VIDEO_DEVICE"
[[ -c "$CONTROL_DEVICE" ]] || fail "Control device not found: $CONTROL_DEVICE"

python3 -c 'import cv2, numpy' >/dev/null 2>&1 \
    || fail "Python packages OpenCV (cv2) and NumPy are required."

# Do not allow two capture jobs to use the same camera or result directory.
exec 9>"$LOCK_FILE"
flock -n 9 || fail "Another IMX568 capture job is already running."

mkdir -p -- "$RESULT_DIR"

# This is intentionally restricted to the fixed result directory. Each run
# removes only the previous capture result, never other Image subdirectories.
[[ "$RESULT_DIR" == "/home/r/Raspberry/Image/image_temp_result" ]] \
    || fail "Refusing to clear an unexpected result directory: $RESULT_DIR"
find "$RESULT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

available_kib=$(df -Pk "$RESULT_DIR" | awk 'NR == 2 {print $4}')
required_kib=$(((EXPECTED_BYTES * 3 + 1023) / 1024))
(( available_kib >= required_kib )) \
    || fail "Not enough free space: need at least ${required_kib} KiB."

log "Configuring IMX568 for continuous RAW8 capture."
v4l2-ctl -d "$CONTROL_DEVICE" -c trigger_mode=0
v4l2-ctl -d "$VIDEO_DEVICE" \
    --set-fmt-video="width=${WIDTH},height=${HEIGHT},pixelformat=${PIXEL_FORMAT}"

log "Capturing ${FRAME_COUNT} consecutive frames to a temporary RAW burst."
timeout 30s v4l2-ctl -d "$VIDEO_DEVICE" \
    --stream-mmap=4 \
    --stream-count="$FRAME_COUNT" \
    --stream-to="$BURST_FILE" \
    --verbose

actual_bytes=$(stat -c '%s' "$BURST_FILE")
[[ "$actual_bytes" -eq "$EXPECTED_BYTES" ]] \
    || fail "Burst size is ${actual_bytes} bytes; expected ${EXPECTED_BYTES}."

log "Converting the RAW8 burst into 41 PNG images."
python3 - "$BURST_FILE" "$RESULT_DIR" "$WIDTH" "$HEIGHT" "$FRAME_COUNT" <<'PY'
from pathlib import Path
import sys

import cv2
import numpy as np

burst_path = Path(sys.argv[1])
result_dir = Path(sys.argv[2])
width = int(sys.argv[3])
height = int(sys.argv[4])
frame_count = int(sys.argv[5])
frame_bytes = width * height

with burst_path.open("rb") as source:
    for index in range(1, frame_count + 1):
        payload = source.read(frame_bytes)
        if len(payload) != frame_bytes:
            raise RuntimeError(
                f"Frame {index} has {len(payload)} bytes; expected {frame_bytes}"
            )

        image = np.frombuffer(payload, dtype=np.uint8).reshape(height, width)
        output_path = result_dir / f"imx568_{index:03d}.png"
        if not cv2.imwrite(str(output_path), image):
            raise RuntimeError(f"Failed to write {output_path}")

    if source.read(1):
        raise RuntimeError("RAW burst contains trailing data")
PY

rm -f -- "$BURST_FILE"

png_count=$(find "$RESULT_DIR" -maxdepth 1 -type f -name 'imx568_*.png' | wc -l)
[[ "$png_count" -eq "$FRAME_COUNT" ]] \
    || fail "Generated ${png_count} PNG files; expected ${FRAME_COUNT}."

{
    printf 'captured_at=%(%FT%T%z)T\n' -1
    printf 'video_device=%s\n' "$VIDEO_DEVICE"
    printf 'control_device=%s\n' "$CONTROL_DEVICE"
    printf 'frame_count=%s\n' "$FRAME_COUNT"
    printf 'width=%s\n' "$WIDTH"
    printf 'height=%s\n' "$HEIGHT"
    printf 'pixel_format=%s\n' "$PIXEL_FORMAT"
    printf 'frame_bytes=%s\n' "$FRAME_BYTES"
    v4l2-ctl -d "$CONTROL_DEVICE" \
        -C exposure,analogue_gain,trigger_mode,io_mode,frame_rate
} >"${RESULT_DIR}/capture_info.txt"

log "Capture completed: ${png_count} PNG files in ${RESULT_DIR}"
