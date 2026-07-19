#!/bin/bash
# UPM Hook: upm_hook_hold_2s
# Add your custom scripts below.
echo "$(date '+%Y-%m-%d %H:%M:%S') [UPM-HOOK] 2s hold triggered." \
  >> /var/log/upm.log

POWER_DEV="/dev/input/by-path/platform-pwr_button-event"

if pgrep -x "pishutdown" > /dev/null; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') [UPM-HOOK] pishutdown is already running. Ignoring." >> /var/log/upm.log
else
  if [ -e "$POWER_DEV" ]; then
    evemu-event "$POWER_DEV" --sync --type 1 --code 116 --value 1
    sleep 0.1
    evemu-event "$POWER_DEV" --sync --type 1 --code 116 --value 0
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [UPM-HOOK] Warning: Power button input device not found." >> /var/log/upm.log
  fi
fi
