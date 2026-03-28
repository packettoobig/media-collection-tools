#!/bin/bash

# Check (using intel HW acceleration) that the first and last X seconds of every media file is OK (ffmpeg can read them)
# It took too long to check the entire file.

# These need to be exported to the xargs subshell
export HWACC_DEV='/dev/dri/renderD128' #Intel
export HWACC_TYPE='vaapi' #Intel
export PARALLEL=2
export CHECKSECONDS=60

# ACTION on error:
#   none    — just log it (default)
#   remux   — attempt to fix by remuxing into a new file (safe, non-destructive)
#   delete  — permanently delete the file (destructive!)
#   move    — move to QUARANTINE_FOLDER
export ACTION='none'
export QUARANTINE_FOLDER='/nasraid/DATA/_corrupted'

# These don't need export
PARENTFOLDER=$1
EXTENSIONS="avi|mkv|mp4|ts|m4v"
LOGFILE="$(dirname "$0")/check_videofiles_$(date +%Y%m%d_%H%M%S).log"

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
