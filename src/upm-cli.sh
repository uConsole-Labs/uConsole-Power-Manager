#!/bin/bash
# CLI tool and core logic for UPM features.

# --- 1. Configuration and Paths ---
readonly FILE_PATH_CONF="/etc/upm/upm.conf"
readonly FILE_PATH_VERSION="/opt/upm/upm.version"
readonly SERVICE_POWER="upm_power_key_monitor.service"
readonly SERVICE_BATT="upm_batt_monitor.service"
readonly FILE_PATH_POWER_KEY_LOCK="/run/upm/upm_power_key.lock"
readonly FILE_PATH_BATTERY_LOCK="/run/upm/upm_battery.lock"
readonly DIR_PATH_CPU_POLICY="/sys/devices/system/cpu/cpufreq/policy0"
readonly FILE_PATH_CPU_FREQ_BACKUP="/run/upm/upm_cpu_freq.bak"

# --- 2. Hook Paths ---
readonly HOOK_SHORT_PRESS="/opt/upm/hooks/upm_hook_short_press.sh"
readonly HOOK_HOLD_2S="/opt/upm/hooks/upm_hook_hold_2s.sh"
readonly HOOK_HOLD_5S="/opt/upm/hooks/upm_hook_hold_5s.sh"
readonly HOOK_HOLD_10S="/opt/upm/hooks/upm_hook_hold_10s.sh"
readonly HOOK_FREQ_POWERSAVE="/opt/upm/hooks/upm_hook_freq_powersave.sh"
readonly HOOK_FREQ_RESTORE="/opt/upm/hooks/upm_hook_freq_restore.sh"

# --- 3. Timing & Modes ---

# Interval for the 5-second power key warning backlight flash
readonly BACKLIGHT_FLASH_INTERVAL_SEC="0.5"

readonly BATT_FREQ_MODE_NORMAL="normal"
readonly BATT_FREQ_MODE_POWER_SAVE="powersave"

# --- 4. Mutable Globals & Init ---

# Global variables for cleanup
ORIG_I2C_VAL=""
TIMER_PID=""
IS_CM5=false
POWER_KEY_EVTEST_PID=""
POWER_KEY_FIFO_PATH=""
BATT_UDEV_PID=""
BATT_INOTIFY_PID=""
BATT_FIFO_PATH=""

SYS_PATH_BACKLIGHT=""
SYS_PATH_FB0=""
SYS_PATH_BATT=""


################################################################################
# 1. Basic Utilities
################################################################################


# ==============================================================================
# upm_decide_target_state
#
# Decides the target battery frequency mode based on system state.
#
# Globals:
#   BATT_FREQ_MODE_POWER_SAVE
#   BATT_FREQ_MODE_NORMAL
# Arguments:
#   bl_power_val: The current backlight power value.
#   has_ext: True if an external monitor is connected.
#   batt_cap: The current battery capacity percentage.
#   is_charging: True if the battery is charging.
# Outputs:
#   Writes the target mode to stdout ("powersave", "normal", or "none").
# Returns:
#   0 on success.
# ==============================================================================
upm_decide_target_state() {
  local bl_power_val="$1"
  local has_ext="$2"
  local batt_cap="$3"
  local is_charging="$4"

  local cond_powersave="false"
  if { { [ "$bl_power_val" = "4" ] && [ "$has_ext" = "false" ]; } || \
       [ "$batt_cap" -lt 30 ]; } && [ "$is_charging" = "false" ]; then
    cond_powersave="true"
  fi

  local cond_restore="false"
  if { { [ "$bl_power_val" != "4" ] || [ "$has_ext" = "true" ]; } && \
       [ "$batt_cap" -ge 30 ]; } || [ "$is_charging" = "true" ]; then
    cond_restore="true"
  fi

  if [ "$cond_powersave" = "true" ]; then
    echo "$BATT_FREQ_MODE_POWER_SAVE"
  elif [ "$cond_restore" = "true" ]; then
    echo "$BATT_FREQ_MODE_NORMAL"
  else
    echo "none"
  fi
}

# ==============================================================================
# log_msg
#
# Logs a message to stdout with timestamp and type.
#
# Globals:
#   UPM_ENABLE_DEBUG
# Arguments:
#   type: The log level (e.g., INFO, WARN, ERROR, DEBUG).
#   msg: The message to log.
# Outputs:
#   Writes the formatted log message to stdout.
# Returns:
#   0 on success.
# ==============================================================================
log_msg() {
  local type="$1"
  local msg="$2"
  if [ "$type" = "DEBUG" ] && [ "${UPM_ENABLE_DEBUG:-false}" != "true" ]; then
    return
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') [UPM] [$type] $msg"
}

# ==============================================================================
# check_root
#
# Verifies if the script is running with root privileges.
#
# Globals:
#   EUID
# Arguments:
#   None
# Outputs:
#   Writes an error message to stdout if not root.
# Returns:
#   Exits with 1 if not root, otherwise returns 0.
# ==============================================================================
check_root() {
  if [ "$EUID" -ne 0 ]; then
    log_msg "ERROR" "This command requires root privileges. Please use sudo."
    exit 1
  fi
}


# ==============================================================================
# upm_kill_timer_safely
#
# Securely kills the timer subshell, avoiding reused PID targets.
#
# Globals:
#   TIMER_PID
# Arguments:
#   None
# Outputs:
#   Writes debug messages to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_kill_timer_safely() {
  if [ -n "$TIMER_PID" ]; then
    # Verify PID is our direct child to prevent reused PID kills (CWE-829)
    local ppid
    ppid=$(ps -o ppid= -p "$TIMER_PID" 2>/dev/null | tr -d ' ')
    if [ "$ppid" = "$$" ]; then
      log_msg "DEBUG" "Killing active timer subshell (PID: $TIMER_PID)"
      kill "$TIMER_PID" 2>/dev/null
    fi
    TIMER_PID=""
  fi
}


# ==============================================================================
# _get_backlight_path
#
# Retrieves and caches the path to the backlight device.
#
# Globals:
#   SYS_PATH_BACKLIGHT
# Arguments:
#   None
# Outputs:
#   None (updates global SYS_PATH_BACKLIGHT)
# Returns:
#   0 on success.
# ==============================================================================
_get_backlight_path() {
  if [ -z "$SYS_PATH_BACKLIGHT" ] || [ ! -d "$SYS_PATH_BACKLIGHT" ]; then
    SYS_PATH_BACKLIGHT=$(find /sys/class/backlight -maxdepth 1 -mindepth 1 \
      2>/dev/null | head -n 1)
  fi
}


# ==============================================================================
# _get_fb_path
#
# Retrieves and caches the path to the framebuffer device.
#
# Globals:
#   SYS_PATH_FB0
# Arguments:
#   None
# Outputs:
#   None (updates global SYS_PATH_FB0)
# Returns:
#   0 on success.
# ==============================================================================
_get_fb_path() {
  if [ -z "$SYS_PATH_FB0" ] || [ ! -d "$SYS_PATH_FB0" ]; then
    SYS_PATH_FB0=$(find /sys/class/graphics -name "fb0" 2>/dev/null | head -n 1)
  fi
}


# ==============================================================================
# _get_batt_path
#
# Retrieves and caches the path to the battery power supply device.
#
# Globals:
#   SYS_PATH_BATT
# Arguments:
#   None
# Outputs:
#   None (updates global SYS_PATH_BATT)
# Returns:
#   0 on success.
# ==============================================================================
_get_batt_path() {
  if [ -z "$SYS_PATH_BATT" ] || [ ! -d "$SYS_PATH_BATT" ]; then
    SYS_PATH_BATT="/sys/class/power_supply/axp20x-battery"
    if [ ! -d "$SYS_PATH_BATT" ]; then
      SYS_PATH_BATT=$(find /sys/class/power_supply -name "BAT*" \
        2>/dev/null | head -n 1)
    fi
  fi
}

# ==============================================================================
# upm_notify_user
#
# Sends a desktop notification to the current active user.
#
# Globals:
#   None
# Arguments:
#   msg: The notification message.
# Outputs:
#   Writes errors to stderr if dbus or notify-send fails.
# Returns:
#   0 on success.
# ==============================================================================
upm_notify_user() {
  local msg="$1"
  local user
  user=$(who | awk '{print $1}' | head -n 1)
  [ -z "$user" ] && return
  local uid
  uid=$(id -u "$user" 2>/dev/null)
  [ -z "$uid" ] && return

  local dbus_addr="unix:path=/run/user/$uid/bus"
  if [ -S "/run/user/$uid/bus" ]; then
    sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
      notify-send -a "uConsole" "System Performance" "$msg" 2>/dev/null &
  fi
}


################################################################################
# 2. Service Management
################################################################################


# ==============================================================================
# upm_enable
#
# Enables systemd services for automatic startup on boot.
#
# Globals:
#   SERVICE_POWER
#   SERVICE_BATT
# Arguments:
#   None
# Outputs:
#   Writes info messages to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_enable() {
  sudo systemctl enable "$SERVICE_POWER" "$SERVICE_BATT" >/dev/null 2>&1
  log_msg "INFO" "Services enabled for auto-start."
  log_msg "INFO" "Note: It is NOT started yet. Run 'upm start' to run it."
}

# ==============================================================================
# upm_disable
#
# Disables and stops the systemd services.
#
# Globals:
#   SERVICE_POWER
#   SERVICE_BATT
# Arguments:
#   None
# Outputs:
#   Writes info messages to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_disable() {
  sudo systemctl stop "$SERVICE_POWER" "$SERVICE_BATT" >/dev/null 2>&1
  sudo systemctl disable "$SERVICE_POWER" "$SERVICE_BATT" >/dev/null 2>&1
  log_msg "INFO" "Services disabled and stopped."
}

# ==============================================================================
# upm_start
#
# Starts the systemd services.
#
# Globals:
#   SERVICE_POWER
#   SERVICE_BATT
# Arguments:
#   None
# Outputs:
#   Writes info messages to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_start() {
  sudo systemctl start "$SERVICE_POWER" "$SERVICE_BATT"
  log_msg "INFO" "Services started."
}

# ==============================================================================
# upm_stop
#
# Stops the systemd services.
#
# Globals:
#   SERVICE_POWER
#   SERVICE_BATT
# Arguments:
#   None
# Outputs:
#   Writes info messages to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_stop() {
  sudo systemctl stop "$SERVICE_POWER" "$SERVICE_BATT"
  log_msg "INFO" "Services stopped."
}

# ==============================================================================
# upm_restart
#
# Restarts the systemd services.
#
# Globals:
#   SERVICE_POWER
#   SERVICE_BATT
# Arguments:
#   None
# Outputs:
#   Writes info messages to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_restart() {
  sudo systemctl restart "$SERVICE_POWER" "$SERVICE_BATT"
  log_msg "INFO" "Services restarted."
}

# ==============================================================================
# upm_enable_debug_msg
#
# Enables debug messages in the configuration file.
#
# Globals:
#   FILE_PATH_CONF
# Arguments:
#   None
# Outputs:
#   Writes info messages to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_enable_debug_msg() {
  sudo sed -i 's/^UPM_ENABLE_DEBUG=.*/UPM_ENABLE_DEBUG="true"/' "$FILE_PATH_CONF"
  log_msg "INFO" "Debug messages enabled."
}

# ==============================================================================
# upm_disable_debug_msg
#
# Disables debug messages in the configuration file.
#
# Globals:
#   FILE_PATH_CONF
# Arguments:
#   None
# Outputs:
#   Writes info messages to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_disable_debug_msg() {
  sudo sed -i 's/^UPM_ENABLE_DEBUG=.*/UPM_ENABLE_DEBUG="false"/' "$FILE_PATH_CONF"
  log_msg "INFO" "Debug messages disabled."
}


################################################################################
# 3. Configuration Commands
################################################################################


# ==============================================================================
# upm_set_time
#
# Sets the long press duration in the configuration file.
#
# Globals:
#   FILE_PATH_CONF
#   SERVICE_POWER
#   SERVICE_BATT
# Arguments:
#   new_time: The new duration in seconds (10 to 30).
# Outputs:
#   Writes info or error messages to stdout.
# Returns:
#   Exits with 1 on invalid format, otherwise returns 0.
# ==============================================================================
upm_set_time() {
  local new_time="$1"
  if ! [[ "$new_time" =~ ^[0-9]+$ ]]; then
    log_msg "ERROR" "Invalid time format. Must be a number."
    exit 1
  fi
  if [ "$new_time" -lt 10 ]; then
    log_msg "WARN" "Minimum time is 10 seconds. Setting to 10."
    new_time=10
  elif [ "$new_time" -gt 30 ]; then
    log_msg "WARN" "Maximum time is 30 seconds. Setting to 30."
    new_time=30
  fi
  sudo sed -i "s/^UPM_LONG_PRESS_SEC=.*/UPM_LONG_PRESS_SEC=$new_time/" "$FILE_PATH_CONF"
  log_msg "INFO" "Long press time set to $new_time seconds."

  if sudo systemctl is-active --quiet "$SERVICE_POWER" || \
     sudo systemctl is-active --quiet "$SERVICE_BATT"; then
    sudo systemctl restart "$SERVICE_POWER" "$SERVICE_BATT"
    log_msg "INFO" "Services restarted to apply new time."
  fi
}

# ==============================================================================
# upm_status
#
# Displays current configuration and systemd service status.
#
# Globals:
#   FILE_PATH_CONF
#   SERVICE_POWER
#   SERVICE_BATT
# Arguments:
#   None
# Outputs:
#   Writes configuration and service status to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_status() {
  log_msg "INFO" "Current Configuration ($FILE_PATH_CONF):"
  while read -r line; do log_msg "INFO" "  $line"; done < "$FILE_PATH_CONF"
  echo ""
  log_msg "INFO" "Systemd Service Status:"
  sudo systemctl status "$SERVICE_POWER" "$SERVICE_BATT" --no-pager
}

# ==============================================================================
# upm_version
#
# Prints the version of the uConsole Power Manager.
#
# Globals:
#   FILE_PATH_VERSION
# Arguments:
#   None
# Outputs:
#   Writes version information to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_version() {
  if [ -f "$FILE_PATH_VERSION" ]; then
    local ver
    ver=$(cat "$FILE_PATH_VERSION")
    echo "uConsole-PowerManager version $ver"
  else
    echo "uConsole-PowerManager version (unknown)"
  fi
}


################################################################################
# 4. Device Control
################################################################################


# ==============================================================================
# upm_device_sleep_or_resume
#
# Toggles the deep sleep state of the framebuffer and backlight.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes status info or warnings to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_device_sleep_or_resume() {
  local FB_PATH
  local BL_PATH
  _get_fb_path
  FB_PATH="$SYS_PATH_FB0"
  _get_backlight_path
  BL_PATH="$SYS_PATH_BACKLIGHT"

  if [ -n "$BL_PATH" ] && [ -n "$FB_PATH" ]; then
    local STATE
    STATE=$(cat "$BL_PATH/bl_power" 2>/dev/null)
    if [ "$STATE" = "4" ]; then
      echo "0" > "$FB_PATH/blank" 2>/dev/null
      echo "0" > "$BL_PATH/bl_power" 2>/dev/null
      log_msg "INFO" "Screen turned on."
    else
      echo "1" > "$FB_PATH/blank" 2>/dev/null
      echo "4" > "$BL_PATH/bl_power" 2>/dev/null
      log_msg "INFO" "Screen turned off."
    fi
  else
    log_msg "WARN" "Cannot find backlight or framebuffer paths."
  fi
}

# ==============================================================================
# upm_backlight_flash
#
# Flashes the screen backlight 3 times for a visual warning.
#
# Globals:
#   BACKLIGHT_FLASH_INTERVAL_SEC
# Arguments:
#   None
# Outputs:
#   Writes debug, info, and warning messages to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_backlight_flash() {
  local FB_PATH
  local BL_PATH
  _get_fb_path
  FB_PATH="$SYS_PATH_FB0"
  _get_backlight_path
  BL_PATH="$SYS_PATH_BACKLIGHT"

  if [ -z "$BL_PATH" ] || [ -z "$FB_PATH" ]; then
    log_msg "WARN" "Cannot find backlight or framebuffer paths for flash."
    return
  fi

  local orig_bl
  local orig_fb
  orig_bl=$(cat "$BL_PATH/bl_power" 2>/dev/null || echo "0")
  orig_fb=$(cat "$FB_PATH/blank" 2>/dev/null || echo "0")
  log_msg "DEBUG" "Read original state: fb0=$orig_fb, bl_power=$orig_bl"

  trap '
    log_msg "DEBUG" "Trap triggered, restoring: fb0=$orig_fb, bl_power=$orig_bl"
    echo "$orig_fb" > "$FB_PATH/blank" 2>/dev/null
    echo "$orig_bl" > "$BL_PATH/bl_power" 2>/dev/null
    exit 0
  ' SIGTERM

  log_msg "INFO" "Flashing backlight via blank & bl_power..."
  for _ in {1..3}; do
    log_msg "DEBUG" "Writing 1 to blank, 4 to bl_power"
    echo 1 > "$FB_PATH/blank" 2>/dev/null
    echo 4 > "$BL_PATH/bl_power" 2>/dev/null
    sleep "$BACKLIGHT_FLASH_INTERVAL_SEC"

    log_msg "DEBUG" "Writing 0 to blank, 0 to bl_power"
    echo 0 > "$FB_PATH/blank" 2>/dev/null
    echo 0 > "$BL_PATH/bl_power" 2>/dev/null
    sleep "$BACKLIGHT_FLASH_INTERVAL_SEC"
  done

  log_msg "DEBUG" "Restoring: fb0=$orig_fb, bl_power=$orig_bl"
  echo "$orig_fb" > "$FB_PATH/blank" 2>/dev/null
  echo "$orig_bl" > "$BL_PATH/bl_power" 2>/dev/null
}


################################################################################
# 5. Cleanup & Traps
################################################################################


# ==============================================================================
# upm_power_key_cleanup
#
# Cleans up resources when the power key monitor exits or receives a signal.
#
# Globals:
#   TIMER_PID
#   IS_CM5
#   ORIG_I2C_VAL
#   FILE_PATH_POWER_KEY_LOCK
#   POWER_KEY_EVTEST_PID
#   POWER_KEY_FIFO_PATH
# Arguments:
#   None
# Outputs:
#   Writes info and debug messages to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_power_key_cleanup() {
  log_msg "INFO" "Caught exit signal, running power key monitor cleanup..."
  upm_kill_timer_safely
  if [ -n "$POWER_KEY_EVTEST_PID" ]; then
    log_msg "DEBUG" "Killing evtest (PID: $POWER_KEY_EVTEST_PID)"
    kill "$POWER_KEY_EVTEST_PID" 2>/dev/null
  fi
  if [ "$IS_CM5" = true ] && [ -n "$ORIG_I2C_VAL" ]; then
    log_msg "INFO" "Restoring AXP228 register 0x36 to: $ORIG_I2C_VAL"
    i2cset -f -y 3 0x34 0x36 "$ORIG_I2C_VAL"
  fi
  rm -f "$FILE_PATH_POWER_KEY_LOCK"
  [ -n "$POWER_KEY_FIFO_PATH" ] && rm -f "$POWER_KEY_FIFO_PATH"
  log_msg "INFO" "Power key monitor cleanup complete."
}

# ==============================================================================
# upm_batt_cleanup
#
# Cleans up resources when the battery monitor exits or receives a signal.
#
# Globals:
#   TIMER_PID
#   BATT_UDEV_PID
#   BATT_INOTIFY_PID
#   FILE_PATH_BATTERY_LOCK
#   BATT_FIFO_PATH
# Arguments:
#   None
# Outputs:
#   Writes info and debug messages to stdout.
# Returns:
#   0 on success.
# ==============================================================================
upm_batt_cleanup() {
  log_msg "INFO" "Caught exit signal, running battery monitor cleanup..."
  upm_kill_timer_safely
  if [ -n "$BATT_UDEV_PID" ]; then
    kill "$BATT_UDEV_PID" 2>/dev/null
  fi
  if [ -n "$BATT_INOTIFY_PID" ]; then
    kill "$BATT_INOTIFY_PID" 2>/dev/null
  fi
  rm -f "$FILE_PATH_BATTERY_LOCK"
  [ -n "$BATT_FIFO_PATH" ] && rm -f "$BATT_FIFO_PATH"
  log_msg "INFO" "Battery monitor cleanup complete."
}


################################################################################
# 6. Event Monitors
################################################################################


# ==============================================================================
# upm_monitor_power_key
#
# Monitors the power key for short, hold, and long press events.
#
# Globals:
#   FILE_PATH_POWER_KEY_LOCK
#   UPM_ENABLE_DEBUG
#   IS_CM5
#   ORIG_I2C_VAL
#   UPM_LONG_PRESS_SEC
#   TIMER_PID
# Arguments:
#   IS_DRY_RUN: True to simulate events without shutting down.
# Outputs:
#   Writes log messages to stdout.
# Returns:
#   Exits with 1 on errors, otherwise runs continuously.
# ==============================================================================
upm_monitor_power_key() {
  local is_dry_run="${1:-false}"

  mkdir -p /run/upm
  chmod 755 /run/upm 2>/dev/null

  if [ -f "$FILE_PATH_POWER_KEY_LOCK" ]; then
    local lock_pid
    lock_pid=$(cat "$FILE_PATH_POWER_KEY_LOCK")
    if kill -0 "$lock_pid" 2>/dev/null; then
      log_msg "ERROR" "Monitor is already running (PID: $lock_pid)."
      log_msg "ERROR" "Please stop the background service first (upm stop)."
      exit 1
    fi
  fi
  echo $$ > "$FILE_PATH_POWER_KEY_LOCK"

  if [ "$is_dry_run" = true ]; then
    UPM_ENABLE_DEBUG="true"
    log_msg "WARN" "=== DRY RUN MODE ENABLED ==="
    log_msg "WARN" "System will NOT actually shut down."
  else
    log_msg "INFO" "Starting monitor..."
  fi

  trap 'upm_power_key_cleanup' EXIT
  trap 'exit 0' SIGINT SIGTERM

  local model_path="/proc/device-tree/model"
  if [ -f "$model_path" ]; then
    local model_name
    model_name=$(tr -d '\0' < "$model_path")
    log_msg "INFO" "Detected Hardware: $model_name"
    if [[ "$model_name" == *"Compute Module 5"* ]]; then
      IS_CM5=true
      log_msg "INFO" "CM5 detected. Disabling AXP228 hardware power-off..."
      ORIG_I2C_VAL=$(i2cget -f -y 3 0x34 0x36)
      log_msg "DEBUG" "Original REG 0x36 value backed up: $ORIG_I2C_VAL"
      i2cset -f -y 3 0x34 0x36 0x53
      log_msg "INFO" "AXP228 hardware power-off disabled."
    else
      log_msg "ERROR" "This tool is exclusively for CM5! Exiting."
      exit 1
    fi
  else
    log_msg "WARN" "Cannot read device tree model."
  fi

  local ev_dev=""
  for dev in /dev/input/by-path/*; do
    if [[ "$dev" == *"axp221-pek"* ]]; then
      ev_dev="$dev"
      break
    fi
  done

  if [ -z "$ev_dev" ]; then
    log_msg "ERROR" "Could not find axp221-pek event device."
    exit 1
  fi

  out=$(timeout 0.1 evtest --grab "$ev_dev" 2>&1)
  if [[ "$out" == *"grabbed by another process"* ]]; then
    log_msg "ERROR" "Input device is locked by another program (EVIOCGRAB)."
    exit 1
  fi

  log_msg "INFO" "Listening to events on $ev_dev"

  local last_down=0
  local last_short_press=0

  POWER_KEY_FIFO_PATH="/run/upm/power_events_$$.fifo"
  rm -f "$POWER_KEY_FIFO_PATH" 2>/dev/null
  if ! mkfifo "$POWER_KEY_FIFO_PATH"; then
    log_msg "ERROR" "Failed to create FIFO at $POWER_KEY_FIFO_PATH"
    exit 1
  fi

  evtest --grab "$ev_dev" > "$POWER_KEY_FIFO_PATH" 2>/dev/null &
  POWER_KEY_EVTEST_PID=$!

  while read -r line; do
    if [[ "$line" == *"type 1 (EV_KEY), code 116 (KEY_POWER), value 1"* ]]; then
      log_msg "DEBUG" "Power key DOWN detected."
      last_down=$(date +%s.%N)

      (
        log_msg "DEBUG" "[Timer] Waiting 2s for HOOK_HOLD_2S..."
        sleep 2
        log_msg "DEBUG" "[Timer] 2s reached! Executing 2s hook."
        if [ "$is_dry_run" = true ]; then
          log_msg "WARN" "(DRY RUN) 2s hold hook triggered."
        else
          bash "$HOOK_HOLD_2S" &
        fi

        log_msg "DEBUG" "[Timer] Waiting 3s for HOOK_HOLD_5S..."
        sleep 3
        log_msg "DEBUG" "[Timer] 5s reached! Executing 5s hook."
        if [ "$is_dry_run" = true ]; then
          log_msg "WARN" "(DRY RUN) 5s hold hook triggered."
        else
          bash "$HOOK_HOLD_5S" &
        fi

        local remaining=$((UPM_LONG_PRESS_SEC - 5))
        log_msg "INFO" "[Timer] Waiting remaining $remaining seconds..."
        sleep $remaining

        log_msg "DEBUG" "[Timer] ${UPM_LONG_PRESS_SEC}s reached!"
        if [ "$is_dry_run" = true ]; then
          log_msg "WARN" "(DRY RUN) Mocking shutdown!"
        else
          log_msg "WARN" "Triggering software shutdown hook!"
          bash "$HOOK_HOLD_10S" &
        fi
      ) &
      TIMER_PID=$!
      log_msg "DEBUG" "Started timer subshell (PID: $TIMER_PID)."

    elif [[ "$line" == *"type 1 (EV_KEY), code 116 (KEY_POWER), value 0"* ]]
    then
      local now
      now=$(date +%s.%N)
      log_msg "DEBUG" "Power key UP detected."
      upm_kill_timer_safely

      local duration
      duration=$(awk "BEGIN {print $now - $last_down}")

      if ( awk "BEGIN {exit !($duration > 0.05 && $duration < 0.7)}" ); then
        local cd_time
        cd_time=$(awk "BEGIN {print $now - $last_short_press}")
        if ( awk "BEGIN {exit !($cd_time > 1.0)}" ); then
          if [ "$is_dry_run" = true ]; then
            log_msg "WARN" "(DRY RUN) Short press hook triggered."
          else
            log_msg "INFO" "Short press detected. Triggering hook."
            bash "$HOOK_SHORT_PRESS" &
          fi
          last_short_press=$now
        else
          log_msg "DEBUG" "Short press ignored (Cooldown)."
        fi
      fi
    fi
  done < "$POWER_KEY_FIFO_PATH"

  log_msg "ERROR" "evtest monitor loop unexpectedly closed (EOF). Exiting..."
  exit 1
}

# ==============================================================================
# upm_read_hardware_sensors
#
# Reads hardware states and updates global HW_* variables.
#
# Globals:
#   HW_BL_POWER
#   HW_HAS_EXT
#   HW_BATT_CAP
#   HW_IS_CHARGING
#   SYS_PATH_BACKLIGHT
#   SYS_PATH_BATT
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0 on success.
# ==============================================================================
upm_read_hardware_sensors() {
  HW_BL_POWER="0"
  local bl_path
  _get_backlight_path
  bl_path="$SYS_PATH_BACKLIGHT"
  if [ -n "$bl_path" ] && [ -f "$bl_path/bl_power" ]; then
    HW_BL_POWER=$(cat "$bl_path/bl_power" 2>/dev/null || echo "0")
  fi

  HW_HAS_EXT="false"
  for drm_status in /sys/class/drm/card*-HDMI-*/status; do
    if [ -f "$drm_status" ]; then
      if grep -q "^connected$" "$drm_status" 2>/dev/null; then
        HW_HAS_EXT="true"
        break
      fi
    fi
  done

  HW_BATT_CAP="100"
  local batt_status="Discharging"
  local batt_path
  _get_batt_path
  batt_path="$SYS_PATH_BATT"
  if [ -n "$batt_path" ] && [ -f "$batt_path/capacity" ]; then
    HW_BATT_CAP=$(cat "$batt_path/capacity" 2>/dev/null || echo "100")
    batt_status=$(cat "$batt_path/status" 2>/dev/null || echo "Discharging")
  fi

  HW_IS_CHARGING="false"
  if [ "$batt_status" = "Charging" ] || [ "$batt_status" = "Full" ]; then
    HW_IS_CHARGING="true"
  fi

  local d_msg="[Eval] BL=$HW_BL_POWER, Ext=$HW_HAS_EXT, "
  d_msg="${d_msg}Batt=${HW_BATT_CAP}%, Chg=$HW_IS_CHARGING"
  log_msg "DEBUG" "$d_msg"
}

# ==============================================================================
# upm_check_and_fire_battery_hooks
#
# Fires battery threshold hooks when battery level crosses defined limits.
#
# Globals:
#   HW_BATT_CAP
#   LAST_BATT_LEVEL
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0 on success.
# ==============================================================================
upm_check_and_fire_battery_hooks() {
  if [ -n "$LAST_BATT_LEVEL" ] && [ "$HW_BATT_CAP" -ne "$LAST_BATT_LEVEL" ]; then
    log_msg "DEBUG" "[Eval] Batt changed: $LAST_BATT_LEVEL -> $HW_BATT_CAP"
    for th in 50 20 10 5; do
      if [ "$LAST_BATT_LEVEL" -gt "$th" ] && [ "$HW_BATT_CAP" -le "$th" ]; then
        local hook_script="/opt/upm/hooks/upm_hook_batt_below_${th}.sh"
        if [ -f "$hook_script" ]; then
          log_msg "INFO" "Triggering hook: batt_below_${th}"
          bash "$hook_script" &
        fi
      elif [ "$LAST_BATT_LEVEL" -le "$th" ] && [ "$HW_BATT_CAP" -gt "$th" ]; then
        local hook_script="/opt/upm/hooks/upm_hook_batt_above_${th}.sh"
        if [ -f "$hook_script" ]; then
          log_msg "INFO" "Triggering hook: batt_above_${th}"
          bash "$hook_script" &
        fi
      fi
    done
  fi
  LAST_BATT_LEVEL="$HW_BATT_CAP"
}

# ==============================================================================
# upm_evaluate_system_state
#
# Evaluates if target state has changed based on hardware sensors.
#
# Globals:
#   HW_BL_POWER
#   HW_HAS_EXT
#   HW_BATT_CAP
#   HW_IS_CHARGING
# Arguments:
#   $1 - current_target: The current applied CPU frequency mode.
# Outputs:
#   Writes the new target state to stdout if changed, otherwise "none".
# Returns:
#   0 on success.
# ==============================================================================
upm_evaluate_system_state() {
  local curr_tgt="$1"
  local calc_tgt
  calc_tgt=$(upm_decide_target_state \
    "$HW_BL_POWER" "$HW_HAS_EXT" "$HW_BATT_CAP" "$HW_IS_CHARGING")

  if [ "$calc_tgt" != "none" ] && [ "$calc_tgt" != "$curr_tgt" ]; then
    echo "$calc_tgt"
  else
    echo "none"
  fi
}

# ==============================================================================
# upm_apply_powersave
#
# Applies hardware limits and hooks for powersave mode.
#
# Globals:
#   FILE_PATH_CPU_FREQ_BACKUP
#   DIR_PATH_CPU_POLICY
#   HOOK_FREQ_POWERSAVE
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0 on success.
# ==============================================================================
upm_apply_powersave() {
  log_msg "INFO" "Adjusting to most power saving..."
  if [ ! -f "$FILE_PATH_CPU_FREQ_BACKUP" ]; then
    local c_max
    c_max=$(cat "$DIR_PATH_CPU_POLICY/scaling_max_freq" 2>/dev/null)
    local c_min
    c_min=$(cat "$DIR_PATH_CPU_POLICY/scaling_min_freq" 2>/dev/null)
    if [ -n "$c_max" ] && [ -n "$c_min" ]; then
      echo "${c_max},${c_min}" > "$FILE_PATH_CPU_FREQ_BACKUP"
    fi
  fi
  local hw_min
  hw_min=$(cat "$DIR_PATH_CPU_POLICY/cpuinfo_min_freq" 2>/dev/null)
  if [ -n "$hw_min" ]; then
    echo "$hw_min" > "$DIR_PATH_CPU_POLICY/scaling_min_freq" 2>/dev/null
    echo "$hw_min" > "$DIR_PATH_CPU_POLICY/scaling_max_freq" 2>/dev/null
  fi
  bash "$HOOK_FREQ_POWERSAVE" &
  upm_notify_user "Powersave mode (CPU minimum freq)"
}

# ==============================================================================
# upm_apply_normal
#
# Restores hardware limits and hooks for normal mode.
#
# Globals:
#   FILE_PATH_CPU_FREQ_BACKUP
#   DIR_PATH_CPU_POLICY
#   HOOK_FREQ_RESTORE
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0 on success.
# ==============================================================================
upm_apply_normal() {
  log_msg "INFO" "Adjusting to restore..."
  if [ -f "$FILE_PATH_CPU_FREQ_BACKUP" ]; then
    IFS=',' read -r b_max b_min < "$FILE_PATH_CPU_FREQ_BACKUP"
    echo "$b_max" > "$DIR_PATH_CPU_POLICY/scaling_max_freq" 2>/dev/null
    echo "$b_min" > "$DIR_PATH_CPU_POLICY/scaling_min_freq" 2>/dev/null
    rm -f "$FILE_PATH_CPU_FREQ_BACKUP"
  else
    local h_max
    h_max=$(cat "$DIR_PATH_CPU_POLICY/cpuinfo_max_freq" 2>/dev/null)
    local h_min
    h_min=$(cat "$DIR_PATH_CPU_POLICY/cpuinfo_min_freq" 2>/dev/null)
    if [ -n "$h_max" ] && [ -n "$h_min" ]; then
      echo "$h_max" > "$DIR_PATH_CPU_POLICY/scaling_max_freq" 2>/dev/null
      echo "$h_min" > "$DIR_PATH_CPU_POLICY/scaling_min_freq" 2>/dev/null
    fi
  fi
  bash "$HOOK_FREQ_RESTORE" &
  upm_notify_user "Normal mode (CPU dynamic freq)"
}

# ==============================================================================
# upm_apply_system_state
#
# Applies the target system state in a delayed background process.
#
# Globals:
#   TIMER_PID
#   BATT_FREQ_MODE_POWER_SAVE
#   BATT_FREQ_MODE_NORMAL
# Arguments:
#   $1 - target: The target state to apply.
#   $2 - is_dry_run: If true, skips hardware modification.
# Outputs:
#   None
# Returns:
#   0 on success.
# ==============================================================================
upm_apply_system_state() {
  local target="$1"
  local is_dry_run="$2"

  upm_kill_timer_safely

  (
    # Debounce: Wait before applying to prevent thrashing from rapid
    # state changes (e.g. plugging/unplugging).
    local d_sec="$UPM_BATT_STATE_DEBOUNCE_SEC"
    log_msg "INFO" "[Debounce] Delaying state ($target) for ${d_sec}s..."
    sleep "$d_sec"
    log_msg "DEBUG" "[Debounce] Delay completed. Applying state."

    if [ "$is_dry_run" = true ]; then
      log_msg "WARN" "(DRY RUN) Applying CPU state: $target"
      if [ "$target" = "$BATT_FREQ_MODE_POWER_SAVE" ]; then
        upm_notify_user "(DRY RUN) Powersave mode (CPU minimum freq)"
      elif [ "$target" = "$BATT_FREQ_MODE_NORMAL" ]; then
        upm_notify_user "(DRY RUN) Normal mode (CPU dynamic freq)"
      fi
      exit 0
    fi

    if [ "$target" = "$BATT_FREQ_MODE_POWER_SAVE" ]; then
      upm_apply_powersave
    elif [ "$target" = "$BATT_FREQ_MODE_NORMAL" ]; then
      upm_apply_normal
    fi
  ) &
  TIMER_PID=$!
}

# ==============================================================================
# upm_monitor_battery
#
# Monitors battery state and adjusts CPU frequency.
#
# Globals:
#   BATT_FREQ_MODE_NORMAL
#   UPM_ENABLE_DEBUG
#   FILE_PATH_BATTERY_LOCK
# Arguments:
#   $1 - is_dry_run: True to simulate CPU frequency adjustments.
# Outputs:
#   Writes log messages to stdout.
# Returns:
#   Exits with 1 on errors, otherwise runs continuously.
# ==============================================================================
upm_monitor_battery() {
  local is_dry_run="${1:-false}"

  mkdir -p /run/upm
  chmod 755 /run/upm 2>/dev/null

  if [ -f "$FILE_PATH_BATTERY_LOCK" ]; then
    local lock_pid
    lock_pid=$(cat "$FILE_PATH_BATTERY_LOCK")
    if kill -0 "$lock_pid" 2>/dev/null; then
      log_msg "ERROR" "Battery monitor is already running (PID: $lock_pid)."
      exit 1
    fi
  fi
  echo $$ > "$FILE_PATH_BATTERY_LOCK"

  if [ "$is_dry_run" = true ]; then
    UPM_ENABLE_DEBUG="true"
    log_msg "WARN" "=== DRY RUN MODE ENABLED (Battery Monitor) ==="
  else
    log_msg "INFO" "Starting battery monitor..."
  fi

  local current_target="$BATT_FREQ_MODE_NORMAL"
  BATT_FIFO_PATH="/run/upm/upm_events_$$.fifo"

  LAST_BATT_LEVEL=""
  HW_BL_POWER="0"
  HW_HAS_EXT="false"
  HW_BATT_CAP="100"
  HW_IS_CHARGING="false"

  rm -f "$BATT_FIFO_PATH" 2>/dev/null
  if ! mkfifo "$BATT_FIFO_PATH"; then
    log_msg "ERROR" "Failed to create FIFO at $BATT_FIFO_PATH"
    exit 1
  fi

  trap 'upm_batt_cleanup' EXIT
  trap 'exit 0' SIGINT SIGTERM

  upm_read_hardware_sensors
  upm_check_and_fire_battery_hooks

  local init_target
  init_target=$(upm_evaluate_system_state "$current_target")
  if [ "$init_target" != "none" ]; then
    upm_apply_system_state "$init_target" "$is_dry_run"
    current_target="$init_target"
  fi

  stdbuf -oL udevadm monitor --subsystem-match=power_supply \
    --subsystem-match=drm > "$BATT_FIFO_PATH" 2>/dev/null &
  BATT_UDEV_PID=$!

  local bl_path
  _get_backlight_path
  bl_path="$SYS_PATH_BACKLIGHT"
  if [ -n "$bl_path" ] && command -v inotifywait >/dev/null 2>&1; then
    inotifywait -m -e modify "$bl_path/bl_power" > "$BATT_FIFO_PATH" 2>/dev/null &
    BATT_INOTIFY_PID=$!
  fi

  while read -r line; do
    upm_read_hardware_sensors
    upm_check_and_fire_battery_hooks

    local new_target
    new_target=$(upm_evaluate_system_state "$current_target")

    if [ "$new_target" != "none" ]; then
      upm_apply_system_state "$new_target" "$is_dry_run"
      current_target="$new_target"
    fi
  done < "$BATT_FIFO_PATH"

  log_msg "ERROR" "Battery monitor loop unexpectedly closed (EOF). Exiting..."
  exit 1
}


################################################################################
# 7. CLI & Main Entrypoint
################################################################################


# ==============================================================================
# print_help
#
# Prints the help message showing usage and available commands.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes help text to stdout.
# Returns:
#   0 on success.
# ==============================================================================
print_help() {

  upm_version
  echo ""
  echo "Usage: upm <command> [args]"
  echo ""
  echo "Service Management Commands:"
  echo "  enable                  Enable auto-start on boot."
  echo "  disable                 Stop and disable auto-start."
  echo "  start                   Start background monitoring."
  echo "  stop                    Stop background monitoring."
  echo "  restart                 Restart background monitoring."
  echo ""
  echo "Device Control Commands:"
  echo "  device_sleep_or_resume  Toggle deep sleep state (FB and Backlight)."
  echo "  backlight_flash         Flash backlight for warning."
  echo ""
  echo "Configuration Commands:"
  echo "  time <seconds>          Set long-press trigger time."
  echo "  enable_debug_msg        Enable debug output in logs."
  echo "  disable_debug_msg       Disable debug output in logs."
  echo "  status                  Display configuration and status."
  echo "  version                 Print version."
  echo ""
  echo "Testing Commands:"
  echo "  monitor_power_key       Run power key monitor in foreground."
  echo "  dry_run_monitor_power_key Run safely without shutdown."
  echo "  monitor_battery         Run battery monitor in foreground."
  echo "  dry_run_monitor_battery Run safely without shutdown."
  echo "  flash_test              Flash backlight for warning."
  echo ""
}

# ==============================================================================
# main
#
# Main entry point for the script.
#
# Globals:
#   FILE_PATH_CONF
#   UPM_LONG_PRESS_SEC
# Arguments:
#   $@ - All arguments passed to the script.
# Outputs:
#   Depends on the command executed.
# Returns:
#   0 on success.
# ==============================================================================
main() {
  # Load Configuration
  UPM_LONG_PRESS_SEC=10
  UPM_BATT_STATE_DEBOUNCE_SEC=5
  if [ -f "$FILE_PATH_CONF" ]; then
    # shellcheck disable=SC1090
    source "$FILE_PATH_CONF"

    # Backward compatibility for old configs
    UPM_ENABLE_DEBUG="${UPM_ENABLE_DEBUG:-${ENABLE_DEBUG:-}}"
    UPM_LONG_PRESS_SEC="${UPM_LONG_PRESS_SEC:-${LONG_PRESS_SEC:-}}"
    UPM_BATT_STATE_DEBOUNCE_SEC="${UPM_BATT_STATE_DEBOUNCE_SEC:-${BATT_STATE_DEBOUNCE_SEC:-}}"
  fi

  if ! [[ "$UPM_LONG_PRESS_SEC" =~ ^[0-9]+$ ]]; then
    UPM_LONG_PRESS_SEC=10
  elif [ "$UPM_LONG_PRESS_SEC" -lt 10 ]; then
    UPM_LONG_PRESS_SEC=10
  elif [ "$UPM_LONG_PRESS_SEC" -gt 30 ]; then
    UPM_LONG_PRESS_SEC=30
  fi

  if ! [[ "$UPM_BATT_STATE_DEBOUNCE_SEC" =~ ^[0-9]+$ ]]; then
    UPM_BATT_STATE_DEBOUNCE_SEC=5
  elif [ "$UPM_BATT_STATE_DEBOUNCE_SEC" -lt 1 ] || \
       [ "$UPM_BATT_STATE_DEBOUNCE_SEC" -gt 60 ]; then
    UPM_BATT_STATE_DEBOUNCE_SEC=5
  fi

  case "$1" in
    enable) check_root; upm_enable ;;
    disable) check_root; upm_disable ;;
    start) check_root; upm_start ;;
    stop) check_root; upm_stop ;;
    restart) check_root; upm_restart ;;
    device_sleep_or_resume) check_root; upm_device_sleep_or_resume ;;
    backlight_flash) check_root; upm_backlight_flash ;;
    flash_test) check_root; upm_backlight_flash ;;
    enable_debug_msg) check_root; upm_enable_debug_msg ;;
    disable_debug_msg) check_root; upm_disable_debug_msg ;;
    time)
      check_root
      if [ -z "$2" ]; then
        log_msg "ERROR" "Missing time parameter. Usage: upm time <seconds>"
      else
        upm_set_time "$2"
      fi
      ;;
    status) upm_status ;;
    version) upm_version ;;
    monitor_power_key) check_root; upm_monitor_power_key false ;;
    dry_run_monitor_power_key) check_root; upm_monitor_power_key true ;;
    monitor_battery) check_root; upm_monitor_battery false ;;
    dry_run_monitor_battery) check_root; upm_monitor_battery true ;;
    test_logic)
      if [ -z "$5" ]; then
        echo "Usage: upm test_logic <bl_power> <has_ext> <batt_cap>" \
          "<is_charging>"
        exit 1
      fi
      upm_decide_target_state "$2" "$3" "$4" "$5"
      ;;
    *) print_help ;;
  esac
}

main "$@"
