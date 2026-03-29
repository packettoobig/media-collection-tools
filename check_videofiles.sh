#!/bin/bash

# Checks the first and last N seconds of every media file using:
#   Stage 1 — ffprobe container probe     (fast, no decode)
#   Stage 2 — ffmpeg remux-to-null        (fast, no decode — structural integrity)
#   Stage 3 — ffmpeg HW-decode start+end  (decode check)
#
# Terminal output : one summary line per file  (OK / ERROR)
# Log file        : summary + full ffmpeg stderr, labelled by stage

SCRIPT_DIR="$(dirname "$0")"
DATESTAMP="$(date +%Y%m%d_%H%M%S)"

# ── Defaults (overridable in check_videofiles.conf) ───────────────────────────
HWACC_DEV="${HWACC_DEV:-/dev/dri/renderD128}"
HWACC_TYPE="${HWACC_TYPE:-vaapi}"
PARALLEL="${PARALLEL:-4}"
CHECKSECONDS="${CHECKSECONDS:-60}"
ACTION="${ACTION:-none}"
QUARANTINE_FOLDER="${QUARANTINE_FOLDER:-$SCRIPT_DIR/quarantine_$DATESTAMP}"

[[ -f "$SCRIPT_DIR/check_videofiles.conf" ]] && source "$SCRIPT_DIR/check_videofiles.conf"

# Re-export after config (config may have overridden values)
export HWACC_DEV HWACC_TYPE PARALLEL CHECKSECONDS ACTION QUARANTINE_FOLDER

EXTENSIONS="${EXTENSIONS:-avi|mkv|mp4|ts|m4v}"
PARENTFOLDER="${1:?Usage: $0 <folder>}"
export LOGFILE="$SCRIPT_DIR/logs_check_videofiles/${DATESTAMP}.log"
mkdir -p "$(dirname "$LOGFILE")"

find "$PARENTFOLDER" -type f -regextype posix-extended -regex ".*\.(${EXTENSIONS})" -print0 \
  | xargs -0 -P "$PARALLEL" -I{} bash -c '
    f="$1"
    start=$(date +%s%3N)
    ts=$(date +%H:%M:%S)
    tmplog=$(mktemp)
    has_error=0

    # Stage 1: container probe (fast — no decode)
    out=$(ffprobe -v error -show_format -show_streams -i "$f" 2>&1 >/dev/null)
    if [ -n "$out" ]; then
      has_error=1
      { printf "[PROBE]\n"; printf "%s\n" "$out"; } | sed "s/^/  | /" >> "$tmplog"
    fi

    # Stage 2: structural remux-to-null (fast — no decode)
    if [ $has_error -eq 0 ]; then
      out=$(ffmpeg -v error -i "$f" -map 0 -map_metadata -1 -c copy -f null - 2>&1)
      if [ -n "$out" ]; then
        has_error=1
        { printf "[STRUCT]\n"; printf "%s\n" "$out"; } | sed "s/^/  | /" >> "$tmplog"
      fi
    fi

    # Stage 3: HW-accelerated decode of first + last N seconds
    if [ $has_error -eq 0 ]; then
      out=$(
        ffmpeg -v error \
          -hwaccel "$HWACC_TYPE" -hwaccel_device "$HWACC_DEV" -hwaccel_output_format "$HWACC_TYPE" \
          -threads 1 -t "$CHECKSECONDS" -i "$f" -map 0:v? -map 0:a? -f null - 2>&1
        ffmpeg -v error \
          -hwaccel "$HWACC_TYPE" -hwaccel_device "$HWACC_DEV" -hwaccel_output_format "$HWACC_TYPE" \
          -threads 1 -sseof "-$CHECKSECONDS" -i "$f" -map 0:v? -map 0:a? -f null - 2>&1
      )
      if [ -n "$out" ]; then
        has_error=1
        { printf "[DECODE]\n"; printf "%s\n" "$out"; } | sed "s/^/  | /" >> "$tmplog"
      fi
    fi

    elapsed=$(( $(date +%s%3N) - start ))
    [ $has_error -eq 1 ] && status="ERROR" || status="OK   "
    summary="${status} [${ts} +$((elapsed/1000))s $((elapsed%1000))ms] ${f}"

    # Terminal: one line only
    echo "$summary"

    # Log: summary + full detail — flock prevents parallel processes from interleaving
    (
      flock 9
      echo "$summary" >&9
      [ -s "$tmplog" ] && cat "$tmplog" >&9
    ) 9>>"$LOGFILE"
    rm -f "$tmplog"

    # Optional action on error
    if [ $has_error -eq 1 ] && [ "$ACTION" != "none" ]; then
      ext="${f##*.}"; base=$(basename "$f" ".$ext"); dir=$(dirname "$f")
      base_clean="${base%%_fixed*}"
      case "$ACTION" in
        remux)
          fixed="${dir}/${base_clean}_fixed.${ext}"
          if ffmpeg -y -v error -i "$f" -map 0 -c copy "$fixed" 2>/dev/null; then
            msg="  ↳ REMUXED  OK : $fixed"
          else
            rm -f "$fixed"; msg="  ↳ REMUX FAILED: $f"
          fi ;;
        delete)
          rm -f "$f" \
            && msg="  ↳ DELETED      : $f" \
            || msg="  ↳ DELETE FAILED: $f" ;;
        move)
          mkdir -p "$QUARANTINE_FOLDER"
          mv "$f" "$QUARANTINE_FOLDER/" \
            && msg="  ↳ MOVED TO     : $QUARANTINE_FOLDER" \
            || msg="  ↳ MOVE FAILED  : $f" ;;
      esac
      echo "$msg"
      (flock 9; echo "$msg" >&9) 9>>"$LOGFILE"
    fi
  ' _ {}

echo "Log saved to: $LOGFILE"
