#!/bin/bash
# ucs_hook_hold_10s.sh
# Triggered when the power button is held for exactly 10 seconds.
# Software shutdown fallback for CM5.

echo "$(date '+%Y-%m-%d %H:%M:%S') [UCS-HOOK] 10s hold! Shutting down." \
  >> /var/log/ucs.log
shutdown --halt --poweroff now
