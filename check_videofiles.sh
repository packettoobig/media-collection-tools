#!/bin/bash

# Check (using intel HW acceleration) that the first and last N seconds of every
# media file is OK (ffmpeg can read them without real errors).

SCRIPT_DIR="$(dirname "$0")"
DATESTAMP="$(date +%Y%m%d_%H%M%S)"

# ── Defaults (all overridable in the config file) ─────────────────────────────

KNOWN_HARMLESS_ERRORS=(
    'Header missing'
    'low_delay flag set incorrectly'
    'non monotonous'
    'DTS .*, resampling'
    'PTS .*, resampling'
    'last message repeated'
    'ac3.*header'
    'invalid data found when processing input'
    'max_analyze_duration'
    'Application provided invalid'
    'co located POCs unavailable'
    'stream.*no video nor audio'
)

# Load config file — can override any variable or append to KNOWN_HARMLESS_ERRORS
[[ -f "$SCRIPT_DIR/check_videofiles.conf" ]] && source "$SCRIPT_DIR/check_videofiles.conf"

# Serialize the array into a grep-compatible alternation pattern.
# Must be done AFTER config is sourced so user additions are included.
# bash arrays cannot be exported directly, so we export the compiled string.
HARMLESS_PATTERN=$(printf '%s\n' "${KNOWN_HARMLESS_ERRORS[@]}" | paste -sd '|')

export HWACC_DEV="${HWACC_DEV:-/dev/dri/renderD128}"
export HWACC_TYPE="${HWACC_TYPE:-vaapi}"
export PARALLEL="${PARALLEL:-2}"
export CHECKSECONDS="${CHECKSECONDS:-60}"
export HARMLESS_PATTERN

# ACTION on error:
#   none    — just log it (default)
#   remux   — attempt to fix by remuxing into a new file (safe, non-destructive)
#   delete  — permanently delete the file (destructive!)
#   move    — move to QUARANTINE_FOLDER
export ACTION="${ACTION:-none}"
export QUARANTINE_FOLDER="${QUARANTINE_FOLDER:-$SCRIPT_DIR/quarantine_$DATESTAMP}"

# Always determined by the script — never taken from the config file
EXTENSIONS="${EXTENSIONS:-avi|mkv|mp4|ts|m4v}"
PARENTFOLDER="$1"
LOGFILE="$SCRIPT_DIR/logs_check_videofiles/${DATESTAMP}.log"

find "$PARENTFOLDER" -type f -regextype posix-extended -regex ".*\.(${EXTENSIONS})" -print0 \
  | xargs -0 -P $PARALLEL -I{} bash -c \
    'start=$(date +%s%3N); \
    started_at=$(date +%H:%M:%S); \
    err=$( \
      ffmpeg -v error -hwaccel $HWACC_TYPE -hwaccel_device $HWACC_DEV -hwaccel_output_format $HWACC_TYPE -threads 1 -t $CHECKSECONDS -i "$1" -map 0:a -f null - 2>&1; \
      ffmpeg -v error -hwaccel $HWACC_TYPE -hwaccel_device $HWACC_DEV -hwaccel_output_format $HWACC_TYPE -threads 1 -sseof -$CHECKSECONDS -i "$1" -map 0:a -f null - 2>&1 \
    ); \
    if [ -n "$err" ]; then \
      sw_err=$( \
        ffmpeg -v error -threads 1 -t $CHECKSECONDS -i "$1" -map 0 -f null - 2>&1; \
        ffmpeg -v error -threads 1 -sseof -$CHECKSECONDS -i "$1" -map 0 -f null - 2>&1 \
      ); \
      err="$sw_err"; \
    fi; \
    elapsed=$(( $(date +%s%3N) - start )); \
    if [ -n "$HARMLESS_PATTERN" ]; then \
      real_err=$(printf "%s\n" "$err" | grep -ivE "$HARMLESS_PATTERN"); \
    else \
      real_err="$err"; \
    fi; \
    if [ -n "$real_err" ]; then \
      status="ERROR"; \
    elif [ -n "$err" ]; then \
      status="WARN "; \
    else \
      status="OK   "; \
    fi; \
    printf "%s [%s +%ds %03dms] %s\n" "$status" "$started_at" $((elapsed/1000)) $((elapsed%1000)) "$1"; \
    if [ "$status" = "ERROR" ]; then \
      case "$ACTION" in \
        remux) \
          ext="${1##*.}"; \
          base=$(basename "$1" ".$ext"); \
          dir=$(dirname "$1"); \
          base_clean="${base%%_fixed*}"; \
          fixed="${dir}/${base_clean}_fixed.${ext}"; \
          if ffmpeg -y -v error -i "$1" -map 0 -c copy "$fixed" 2>/dev/null; then \
            printf "  ↳ REMUXED  OK : %s\n" "$fixed"; \
          else \
            printf "  ↳ REMUX FAILED: %s\n" "$1"; \
            rm -f "$fixed"; \
          fi \
          ;; \
        delete) \
          rm -f "$1" \
            && printf "  ↳ DELETED      : %s\n" "$1" \
            || printf "  ↳ DELETE FAILED: %s\n" "$1" \
          ;; \
        move) \
          mkdir -p "$QUARANTINE_FOLDER"; \
          mv "$1" "$QUARANTINE_FOLDER/" \
            && printf "  ↳ MOVED TO    : %s\n" "$QUARANTINE_FOLDER" \
            || printf "  ↳ MOVE FAILED : %s\n" "$1" \
          ;; \
        *) ;; \
      esac \
    fi' _ {} \
  | tee -a "$LOGFILE"

echo "Log saved to: $LOGFILE"
