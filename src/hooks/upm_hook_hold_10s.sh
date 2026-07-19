#!/bin/bash
# UPM Hook: upm_hook_hold_10s
# Add your custom scripts below.
# Software shutdown fallback for CM5.

echo "$(date '+%Y-%m-%d %H:%M:%S') [UPM-HOOK] 10s hold! Shutting down." \
  >> /var/log/upm.log
shutdown --halt --poweroff now
