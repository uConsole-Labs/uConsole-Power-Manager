#!/bin/bash
# UPM Hook: upm_hook_freq_restore
# Add your custom scripts below.
echo "$(date '+%Y-%m-%d %H:%M:%S') [UPM-HOOK] Device resumed." \
  >> /var/log/upm.log
