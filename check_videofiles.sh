#!/bin/bash

# Check (using intel HW acceleration) that the first and last w seconds of every media file is OK (ffmpeg can read them)
# It took too long to check the entire file.

# These need to be exported the the xarg subshell
export HWACC_DEV='/dev/dri/renderD128' #Intel
export HWACC_TYPE='vaapi' #Intel
export PARALLEL=2
export CHECKSECONDS=60

# These don't
PARENTFOLDER=$1
EXTENSIONS="avi|mkv|mp4|ts|m4v"


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
     else \
       printf "OK    [%s +%ds %03dms] %s\n" "$started_at" $((elapsed/1000)) $((elapsed%1000)) "$1"; \
     fi' _ {}


