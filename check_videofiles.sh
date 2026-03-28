#!/bin/bash

# Check (using intel HW acceleration) that the first and last N seconds of every
# media file is OK (ffmpeg can read them without real errors).

SCRIPT_DIR="$(dirname "$0")"
DATESTAMP="$(date +%Y%m%d_%H%M%S)"

# ── Defaults (all overridable in the config file) ─────────────────────────────
# Format: 'grep_pattern|SHORT_CODE'

KNOWN_HARMLESS_ERRORS=(
    'Header missing|MP3_HDR'
    'low_delay flag set incorrectly|LOW_DELAY'
    'non monotonous|MONOTON'
    'DTS .*, resampling|DTS_RESAMP'
    'PTS .*, resampling|PTS_RESAMP'
    'last message repeated|REPEATED'
    'ac3.*header|AC3_HDR'
    'invalid data found when processing input|INV_DATA'
    'max_analyze_duration|MAX_ANALYZE'
    'Application provided invalid|APP_INVALID'
    'co located POCs unavailable|COPOC'
    'stream.*no video nor audio|NO_STREAMS'
)

KNOWN_ERROR_CODES=(
    'moov atom not found|NO_MOOV'
    'missing mandatory atom|NO_MOOV'
    'Error while decoding|DECODE_ERR'
    'Could not find codec|NO_CODEC'
    'Decoder.*not found|NO_CODEC'
    'end of file|TRUNCATED'
    'truncat|TRUNCATED'
    'corrupt|CORRUPT'
    'Invalid data found|CORRUPT'
    'no such file|NOT_FOUND'
    'Permission denied|PERM'
)

# Load config file — can override any variable or append to either array
[[ -f "$SCRIPT_DIR/check_videofiles.conf" ]] && source "$SCRIPT_DIR/check_videofiles.conf"

# Serialize arrays into newline-separated strings for export to subshells
# (bash arrays cannot be exported directly)
HARMLESS_SERIAL=$(printf '%s\n' "${KNOWN_HARMLESS_ERRORS[@]}")
ERROR_CODES_SERIAL=$(printf '%s\n' "${KNOWN_ERROR_CODES[@]}")

export HWACC_DEV="${HWACC_DEV:-/dev/dri/renderD128}"
export HWACC_TYPE="${HWACC_TYPE:-vaapi}"
export PARALLEL="${PARALLEL:-2}"
export CHECKSECONDS="${CHECKSECONDS:-60}"
export HARMLESS_SERIAL
export ERROR_CODES_SERIAL

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
mkdir -p "$(dirname "$LOGFILE")"

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
    harmless_grep=$(printf "%s\n" "$HARMLESS_SERIAL" | cut -d"|" -f1 | paste -sd"|"); \
    if [ -n "$harmless_grep" ]; then \
      real_err=$(printf "%s\n" "$err" | grep -ivE "$harmless_grep"); \
    else \
      real_err="$err"; \
    fi; \
    if [ -n "$real_err" ]; then \
      status="ERROR"; \
      codes=""; \
      while IFS="|" read -r pat code; do \
        [ -z "$pat" ] && continue; \
        if printf "%s\n" "$real_err" | grep -qiE "$pat"; then \
          printf "%s\n" "$codes" | grep -qF "$code" || codes="${codes:+$codes,}$code"; \
        fi; \
      done <<< "$ERROR_CODES_SERIAL"; \
      [ -z "$codes" ] && codes="UNKNOWN"; \
    elif [ -n "$err" ]; then \
      status="WARN "; \
      codes=""; \
      while IFS="|" read -r pat code; do \
        [ -z "$pat" ] && continue; \
        if printf "%s\n" "$err" | grep -qiE "$pat"; then \
          printf "%s\n" "$codes" | grep -qF "$code" || codes="${codes:+$codes,}$code"; \
        fi; \
      done <<< "$HARMLESS_SERIAL"; \
      [ -z "$codes" ] && codes="HARMLESS"; \
    else \
      status="OK   "; \
      codes=""; \
    fi; \
    if [ -n "$codes" ]; then \
      printf "%s [%s +%ds %03dms] [%s] %s\n" "$status" "$started_at" $((elapsed/1000)) $((elapsed%1000)) "$codes" "$1"; \
    else \
      printf "%s [%s +%ds %03dms] %s\n" "$status" "$started_at" $((elapsed/1000)) $((elapsed%1000)) "$1"; \
    fi; \
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
      esac; \
    fi' _ {} \
  | tee -a "$LOGFILE"

echo "Log saved to: $LOGFILE"