# Media-collection-tools

This is a collection of media tools.  
`check_videofiles.sh` is a basic bash script attempting to detecte and/or fix unplayable video files.  
It should not be considered "good code" or "stable" in any way, simply a personal script I decided to make available for others to use.  

## Config file
To not use the script defaults, here is an example `check_videofiles.conf`: 

```
# Hardware acceleration
HWACC_DEV='/dev/dri/renderD128'   # Intel/AMD VAAPI device
HWACC_TYPE='vaapi'                # vaapi (Intel/AMD) or cuda (NVIDIA)

# How many files to check in parallel
PARALLEL=2

# How many seconds to check at the start and end of each file
CHECKSECONDS=60

# File extensions to scan (pipe-separated)
EXTENSIONS="avi|mkv|mp4|ts|m4v"

# Action to take on files that fail the check:
#   none    — just log it (default, safe)
#   remux   — attempt to fix by remuxing into a new file (non-destructive)
#   move    — move to QUARANTINE_FOLDER
#   delete  — permanently delete the file (destructive!)
ACTION='none'

# Where to move files when ACTION=move
# Defaults to a timestamped subfolder in the script directory if not set
QUARANTINE_FOLDER='/data/_corrupted'

```
