#!/bin/bash

# Check (using intel HW acceleration) that the first and last w seconds of every media file is OK (ffmpeg can read them)
# It took too long to check the entire file.

SCRIPT_DIR="$(dirname "$0")"
DATESTAMP="$(date +%Y%m%d_%H%M%S)"

# Load config file if it exists (overrides defaults below)
[[ -f "$SCRIPT_DIR/check_videofiles.conf" ]] && source "$SCRIPT_DIR/check_videofiles.conf"

# These need to be exported to the xargs subshell
export HWACC_DEV="${HWACC_DEV:-/dev/dri/renderD128}" #Intel
export HWACC_TYPE="${HWACC_TYPE:-vaapi}" #Intel
export PARALLEL="${PARALLEL:-2}"
export CHECKSECONDS="${CHECKSECONDS:-60}"

# ACTION on error:
#   none    — just log it (default)
#   remux   — attempt to fix by remuxing into a new file (safe, non-destructive)
#   delete  — permanently delete the file (destructive!)
#   move    — move to QUARANTINE_FOLDER
export ACTION="${ACTION:-none}"
export QUARANTINE_FOLDER="${QUARANTINE_FOLDER:-$SCRIPT_DIR/quarantine_$DATESTAMP}"

# These are always determined by the script — never taken from the config file
EXTENSIONS="${EXTENSIONS:-avi|mkv|mp4|ts|m4v}"
PARENTFOLDER="$1"
LOGFILE="$SCRIPT_DIR/check_videofiles_logs/${DATESTAMP}.log"

find "$PARENTFOLDER" -type f -regextype posix-extended -regex ".*\.(${EXTENSIONS})" -print0 \
  | xargs -0 -P $PARALLEL -I{} bash -c \
    'start=$(date +%s%3N); \
     started_at=$(date +%H:%M:%S); \
     err=$( \
       ffmpeg -v error -hwaccel $HWACC_TYPE -hwaccel_device $HWACC_DEV -hwaccel_output_format $HWACC_TYPE -threads 1 -t $CHECKSECONDS -i "$1" -map 0:a -f null - 2>&1; \
       ffmpeg -v error -hwaccel $HWACC_TYPE -hwaccel_device $HWACC_DEV -hwaccel_output_format $HWACC_TYPE -threads 1 -sseof -$CHECKSECONDS -i "$1" -map 0:a -f null - 2>&1 \
     ); \
     elapsed=$(( $(date +%s%3N) - start )); \
     if [ -n "$err" ]; then \
       printf "ERROR [%s +%ds %03dms] %s\n" "$started_at" $((elapsed/1000)) $((elapsed%1000)) "$1"; \
       case "$ACTION" in \
         remux) \
           fixed="${1%.*}_fixed.${1##*.}"; \
           ffmpeg -v error -i "$1" -c copy "$fixed" 2>&1 \
             && printf "  ↳ REMUXED  OK : %s\n" "$fixed" \
             || printf "  ↳ REMUX FAILED: %s\n" "$1" \
           ;; \
         delete) \
           rm -f "$1" \
             && printf "  ↳ DELETED     : %s\n" "$1" \
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
     else \
       printf "OK    [%s +%ds %03dms] %s\n" "$started_at" $((elapsed/1000)) $((elapsed%1000)) "$1"; \
     fi' _ {} \
  | tee -a "$LOGFILE"

echo "Log saved to: $LOGFILE"
