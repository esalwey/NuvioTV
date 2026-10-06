#!/usr/bin/env bash
#
# hero-swap-sheets.sh — BUG-95 (beta.18, 2026-09-08) simulator repro rig.
#
# Companion to HeroFolderSwapTests.swift's test54FolderHeroSwapGeometry: that test drives a
# scripted walk across folder-to-folder and folder-to-title hero swaps on the FA87 fixture while
# this script (run against the resulting screen recording) finds the moments where a swap actually
# happened and produces a contact sheet of the ~1s around each one, so a human can eyeball whether
# the backdrop re-crops itself after it appears (Steven's report) rather than committing already
# cropped.
#
# Usage: scripts/dev/hero-swap-sheets.sh <video.mp4> <outdir>
#
# Step 1 (scene scan): runs ffmpeg's scene-change detector over just the hero artwork region —
# the right-aligned 1250x820-point box of the nominal 1920x1080-point Home layout — and prints
# every timestamp where the scene score exceeds 0.12 (a hero swap: hard crossfade cut, or the
# tail of one). The crop box is scaled proportionally to the actual video resolution, since a
# simulator screen recording is very unlikely to BE exactly 1920x1080.
#
# Step 2 (contact sheets): for each flagged timestamp t, emits a single 5x6 tile JPEG (30 frames,
# 30fps, i.e. 1.0s) covering [t-0.4, t+0.6) of that same crop — the window the fix's own doc
# comment says the re-crop unwound over (~35 frames at the video's native rate, comfortably
# inside this 1s window at 30fps). t-0.4 is clamped at 0 so a swap flagged near the very start of
# the clip doesn't push ffmpeg's -ss negative.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <video.mp4> <outdir>" >&2
    exit 1
fi

V="$1"
OUT="$2"

if [[ ! -f "$V" ]]; then
    echo "error: input video not found: $V" >&2
    exit 1
fi

for bin in ffmpeg ffprobe; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "error: $bin not found on PATH" >&2
        exit 1
    fi
done

mkdir -p "$OUT"

# --- Video dimensions (points-equivalent: the recording's own pixel size) ---------------------
WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$V")
HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$V")

if [[ -z "$WIDTH" || -z "$HEIGHT" ]]; then
    echo "error: could not read video dimensions via ffprobe" >&2
    exit 1
fi

# --- Hero artwork crop box: right-aligned 1250x820 box of the nominal 1920x1080 layout ---------
# sx = width/1920, sy = height/1080; w=1250*sx, h=820*sy, x=670*sx, y=0. All rounded to the
# nearest integer pixel via awk.
read -r CW CH CX CY <<EOF
$(awk -v w="$WIDTH" -v h="$HEIGHT" 'BEGIN {
    sx = w / 1920.0
    sy = h / 1080.0
    cw = int(1250 * sx + 0.5)
    ch = int(820 * sy + 0.5)
    cx = int(670 * sx + 0.5)
    cy = 0
    printf "%d %d %d %d", cw, ch, cx, cy
}')
EOF

echo "video: ${WIDTH}x${HEIGHT}  hero crop: w=${CW} h=${CH} x=${CX} y=${CY}" >&2

# --- Step 1: scene scan over the hero crop ------------------------------------------------------
SCAN_LOG="$(mktemp)"
trap 'rm -f "$SCAN_LOG"' EXIT

ffmpeg -hide_banner -loglevel info -i "$V" \
    -vf "crop=${CW}:${CH}:${CX}:${CY},scale=400:-1,select='gt(scene,0.12)',showinfo" \
    -f null - 2>"$SCAN_LOG" || true

# showinfo prints one line per SELECTED frame (only frames whose scene score cleared 0.12, thanks
# to the upstream select filter), each carrying a pts_time:<seconds> field.
TIMES=()
while IFS= read -r t; do
    [[ -n "$t" ]] && TIMES+=("$t")
done < <(grep -Eo 'pts_time:[0-9]+(\.[0-9]+)?' "$SCAN_LOG" | cut -d: -f2)

if [[ ${#TIMES[@]} -eq 0 ]]; then
    echo "no scene changes above threshold 0.12 found in the hero crop — nothing to sheet" >&2
    exit 0
fi

echo "flagged swap times (s): ${TIMES[*]}" >&2

# --- Step 2: one contact sheet per flagged time ---------------------------------------------------
for t in "${TIMES[@]}"; do
    START=$(awk -v t="$t" 'BEGIN { s = t - 0.4; if (s < 0) s = 0; printf "%.3f", s }')
    SHEET="$OUT/swap_${t}.jpg"
    ffmpeg -hide_banner -loglevel error -y \
        -ss "$START" -t 1.0 -i "$V" \
        -vf "crop=${CW}:${CH}:${CX}:${CY},fps=30,scale=500:-1,tile=5x6" \
        -frames:v 1 "$SHEET"
    echo "sheet: t=${t}s (window ${START}s..+1.0s) -> $SHEET" >&2
done

echo "done: ${#TIMES[@]} flagged time(s), sheets in $OUT" >&2
