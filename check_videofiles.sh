#!/bin/bash

# Checks the first and last N seconds of every media file using three stages:
#   Stage 1 — ffprobe container probe      (fast, no decode)
#   Stage 2 — ffmpeg remux-to-null         (fast, no decode — structural integrity)
#   Stage 3 — ffmpeg HW-decode start+end   (parallel, keyframes only by default)
#
# Terminal output : one summary line per file  (OK / ERROR)
# Log file        : summary + full ffmpeg stderr per stage

SCRIPT_DIR="$(dirname "$0")"
DATESTAMP="$(date +%Y%m%d_%H%M%S)"

# ── Defaults (all overridable in check_videofiles.conf) ───────────────────────
HWACC_DEV="${HWACC_DEV:-/dev/dri/renderD128}"
HWACC_TYPE="${HWACC_TYPE:-vaapi}"
PARALLEL="${PARALLEL:-4}"
CHECKSECONDS="${CHECKSECONDS:-30}"
ACTION="${ACTION:-none}"
QUARANTINE_FOLDER="${QUARANTINE_FOLDER:-$SCRIPT_DIR/quarantine_$DATESTAMP}"

# SKIP_NONREF=true  → decode keyframes only (-skip_frame noref) — fast, default
# SKIP_NONREF=false → full decode of every frame — thorough but slow
SKIP_NONREF="${SKIP_NONREF:-true}"

# Load user config (may override any variable above)
[[ -f "$SCRIPT_DIR/check_videofiles.conf" ]] && source "$SCRIPT_DIR/check_videofiles.conf"

# Re-export after config sourcing
export HWACC_DEV HWACC_TYPE PARALLEL CHECKSECONDS ACTION QUARANTINE_FOLDER SKIP_NONREF

EXTENSIONS="${EXTENSIONS:-avi|mkv|mp4|ts|m4v}"
PARENTFOLDER="${1:?Usage: $0 <folder>}"
export LOGFILE="$SCRIPT_DIR/logs_check_videofiles/${DATESTAMP}.log"
mkdir -p "$(dirname "$LOGFILE")"

# Print effective settings at startup
printf 'Starting check — %s\n' "$DATESTAMP"
printf '  Folder      : %s\n' "$PARENTFOLDER"
printf '  Parallel    : %s\n' "$PARALLEL"
printf '  CheckSeconds: %s\n' "$CHECKSECONDS"
printf '  SkipNonRef  : %s\n' "$SKIP_NONREF"
printf '  Action      : %s\n' "$ACTION"
printf '  Log         : %s\n' "$LOGFILE"
printf '\n'

find "$PARENTFOLDER" -type f -regextype posix-extended -regex ".*\.(${EXTENSIONS})" -print0 \
  | xargs -0 -P "$PARALLEL" -I{} bash -c '
    f="$1"
    start=$(date +%s%3N)
    ts=$(date +%H:%M:%S)
    tmplog=$(mktemp)
    has_error=0

    # ── Stage 1: container probe (no decode) ──────────────────────────────────
    out=$(ffprobe -v error -show_format -show_streams -nostdin -i "$f" 2>&1 >/dev/null)
    if [ -n "$out" ]; then
      has_error=1
      { printf "[PROBE]\n"; printf "%s\n" "$out"; } | sed "s/^/  | /" >> "$tmplog"
    fi

    # ── Stage 2: structural remux-to-null (no decode) ─────────────────────────
    if [ $has_error -eq 0 ]; then
      out=$(ffmpeg -v error -nostdin -i "$f" -map 0 -map_metadata -1 -c copy -f null - 2>&1)
      if [ -n "$out" ]; then
        has_error=1
        { printf "[STRUCT]\n"; printf "%s\n" "$out"; } | sed "s/^/  | /" >> "$tmplog"
      fi
    fi

    # ── Stage 3: decode start + end in parallel ───────────────────────────────
    if [ $has_error -eq 0 ]; then

      # Build skip-nonref flag
      [ "$SKIP_NONREF" = "true" ] && skip_flag="-skip_frame noref" || skip_flag=""

      hw_flags="-hwaccel $HWACC_TYPE -hwaccel_device $HWACC_DEV -hwaccel_output_format $HWACC_TYPE"

      # Run start and end decode simultaneously, capture output to temp files
      tmp_start=$(mktemp)
      tmp_end=$(mktemp)

      eval ffmpeg -v error $skip_flag $hw_flags \
        -nostdin -threads 1 -t "$CHECKSECONDS" -i \""$f"\" \
        -map 0:v? -map 0:a? -f null - \
        > "$tmp_start" 2>&1 &
      pid_start=$!

      eval ffmpeg -v error $skip_flag $hw_flags \
        -nostdin -threads 1 -sseof "-$CHECKSECONDS" -i \""$f"\" \
        -map 0:v? -map 0:a? -f null - \
        > "$tmp_end" 2>&1 &
      pid_end=$!

      wait $pid_start $pid_end

      out_start=$(cat "$tmp_start")
      out_end=$(cat "$tmp_end")
      rm -f "$tmp_start" "$tmp_end"

      out="${out_start}${out_end}"
      if [ -n "$out" ]; then
        has_error=1
        { printf "[DECODE]\n"; printf "%s\n" "$out"; } | sed "s/^/  | /" >> "$tmplog"
      fi
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    elapsed=$(( $(date +%s%3N) - start ))
    [ $has_error -eq 1 ] && status="ERROR" || status="OK   "
    summary="${status} [${ts} +$((elapsed/1000))s $((elapsed%1000))ms] ${f}"

    # Terminal: one line
    echo "$summary"

    # Log: summary + detail (flock prevents parallel interleaving)
    (
      flock 9
      echo "$summary" >&9
      [ -s "$tmplog" ] && cat "$tmplog" >&9
    ) 9>>"$LOGFILE"
    rm -f "$tmplog"

    # ── Action on error ───────────────────────────────────────────────────────
    if [ $has_error -eq 1 ] && [ "$ACTION" != "none" ]; then
      ext="${f##*.}"
      base=$(basename "$f" ".$ext")
      dir=$(dirname "$f")
      base_clean="${base%%_fixed*}"
      case "$ACTION" in
        remux)
          fixed="${dir}/${base_clean}_fixed.${ext}"
          if ffmpeg -y -v error -nostdin -i "$f" -map 0 -c copy "$fixed" 2>/dev/null; then
            msg="  ↳ REMUXED  OK : $fixed"
          else
            rm -f "$fixed"
            msg="  ↳ REMUX FAILED: $f"
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

echo ""
echo "Log saved to: $LOGFILE"
