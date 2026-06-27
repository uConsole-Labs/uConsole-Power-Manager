#!/bin/bash

# Configuration and Paths
CONF_FILE="/etc/ucs.conf"
VERSION_FILE="/etc/ucs.version"
SERVICE_NAME="ucs.service"
LOCK_FILE="/tmp/ucs_monitor.lock"

# Default Hook Paths (Can be overridden in conf)
HOOK_SHORT_PRESS="/etc/ucs/hooks/ucs_hook_short_press.sh"
HOOK_HOLD_2S="/etc/ucs/hooks/ucs_hook_hold_2s.sh"
HOOK_HOLD_5S="/etc/ucs/hooks/ucs_hook_hold_5s.sh"
HOOK_HOLD_10S="/etc/ucs/hooks/ucs_hook_hold_10s.sh"

# Load Configuration
LONG_PRESS_SEC=10
if [ -f "$CONF_FILE" ]; then
  source "$CONF_FILE"
fi

log_msg() {
  local type="$1"
  local msg="$2"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [UCS] [$type] $msg"
}

check_root() {
  if [ "$EUID" -ne 0 ]; then
    log_msg "ERROR" "This command requires root privileges. Please use sudo."
    exit 1
  fi
}

ucs_enable() {
  sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  log_msg "INFO" "Service enabled for auto-start."
  log_msg "INFO" "Note: It is NOT started yet. Run 'ucs start' to run it."
}

ucs_disable() {
  sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
  sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
  log_msg "INFO" "Service disabled and stopped."
}

ucs_start() {
  sudo systemctl start "$SERVICE_NAME"
  log_msg "INFO" "Service started."
}

ucs_stop() {
  sudo systemctl stop "$SERVICE_NAME"
  log_msg "INFO" "Service stopped."
}

ucs_restart() {
  sudo systemctl restart "$SERVICE_NAME"
  log_msg "INFO" "Service restarted."
}

ucs_set_time() {
  local new_time="$1"
  if ! [[ "$new_time" =~ ^[0-9]+$ ]]; then
    log_msg "ERROR" "Invalid time format. Must be a number."
    exit 1
  fi
  if [ "$new_time" -lt 10 ]; then
    log_msg "WARN" "Minimum time is 10 seconds. Setting to 10."
    new_time=10
  fi
  sudo sed -i "s/^LONG_PRESS_SEC=.*/LONG_PRESS_SEC=$new_time/" "$CONF_FILE"
  log_msg "INFO" "Long press time set to $new_time seconds."

  if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
    sudo systemctl restart "$SERVICE_NAME"
    log_msg "INFO" "Service restarted to apply new time."
  fi
}

ucs_status() {
  log_msg "INFO" "Current Configuration ($CONF_FILE):"
  while read -r line; do log_msg "INFO" "  $line"; done < "$CONF_FILE"
  echo ""
  log_msg "INFO" "Systemd Service Status:"
  sudo systemctl status "$SERVICE_NAME" --no-pager
}

ucs_version() {
  if [ -f "$VERSION_FILE" ]; then
    local ver
    ver=$(cat "$VERSION_FILE")
    log_msg "INFO" "Version: $ver"
  else
    log_msg "WARN" "Version file not found."
  fi
}

ucs_device_sleep_or_resume() {
  local FB_PATH
  local BL_PATH
  FB_PATH=$(find /sys/class/graphics -name "fb0" | head -n 1)
  BL_PATH=$(find /sys/class/backlight -maxdepth 1 -mindepth 1 | head -n 1)

  if [ -n "$BL_PATH" ] && [ -n "$FB_PATH" ]; then
    local STATE
    STATE=$(cat "$BL_PATH/bl_power" 2>/dev/null)
    if [ "$STATE" = "4" ]; then
      echo "0" > "$FB_PATH/blank" 2>/dev/null
      echo "0" > "$BL_PATH/bl_power" 2>/dev/null
      log_msg "INFO" "Device resumed."
    else
      echo "1" > "$FB_PATH/blank" 2>/dev/null
      echo "4" > "$BL_PATH/bl_power" 2>/dev/null
      log_msg "INFO" "Device sleeping."
    fi
  else
    log_msg "WARN" "Cannot find backlight or framebuffer paths."
  fi
}

ucs_backlight_flash() {
  local bl_dev=""
  for d in /sys/class/backlight/*; do
    if [ -d "$d" ]; then
      bl_dev="$d"
      break
    fi
  done

  if [ -z "$bl_dev" ] || [ ! -f "$bl_dev/brightness" ]; then
    log_msg "WARN" "No backlight device found."
    return
  fi

  local orig_val
  orig_val=$(cat "$bl_dev/brightness")

  trap 'echo "$orig_val" > "$bl_dev/brightness"; exit 0' SIGTERM

  log_msg "INFO" "Flashing backlight..."
  for i in {1..3}; do
    echo 0 > "$bl_dev/brightness" 2>/dev/null
    sleep 0.15
    echo "$orig_val" > "$bl_dev/brightness" 2>/dev/null
    sleep 0.15
  done
}

# Global variables for cleanup
ORIG_I2C_VAL=""
TIMER_PID=""
IS_CM5=false

ucs_cleanup() {
  log_msg "INFO" "Caught exit signal, running cleanup..."
  if [ -n "$TIMER_PID" ]; then
    log_msg "DEBUG" "Killing active timer subshell (PID: $TIMER_PID)"
    kill "$TIMER_PID" 2>/dev/null
  fi
  if [ "$IS_CM5" = true ] && [ -n "$ORIG_I2C_VAL" ]; then
    log_msg "INFO" "Restoring AXP228 register 0x36 to: $ORIG_I2C_VAL"
    i2cset -f -y 3 0x34 0x36 "$ORIG_I2C_VAL"
  fi
  rm -f "$LOCK_FILE"
  log_msg "INFO" "Cleanup complete."
}

ucs_monitor() {
  local IS_DRY_RUN="${1:-false}"

  if [ -f "$LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(cat "$LOCK_FILE")
    if kill -0 "$lock_pid" 2>/dev/null; then
      log_msg "ERROR" "Monitor is already running (PID: $lock_pid)."
      log_msg "ERROR" "Please stop the background service first (ucs stop)."
      exit 1
    fi
  fi
  echo $$ > "$LOCK_FILE"

  if [ "$IS_DRY_RUN" = true ]; then
    log_msg "WARN" "=== DRY RUN MODE ENABLED ==="
    log_msg "WARN" "System will NOT actually shut down."
  else
    log_msg "INFO" "Starting monitor..."
  fi

  trap 'ucs_cleanup' EXIT
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

  local LAST_DOWN=0
  local LAST_SHORT_PRESS=0

  evtest --grab "$ev_dev" | while read -r line; do
    if [[ "$line" == *"type 1 (EV_KEY), code 116 (KEY_POWER), value 1"* ]]; then
      log_msg "DEBUG" "Power key DOWN detected."
      LAST_DOWN=$(date +%s.%N)

      (
        log_msg "DEBUG" "[Timer] Waiting 2s for HOOK_HOLD_2S..."
        sleep 2
        log_msg "DEBUG" "[Timer] 2s reached! Executing 2s hook."
        if [ "$IS_DRY_RUN" = true ]; then
          log_msg "WARN" "(DRY RUN) 2s hold hook triggered."
        else
          bash "$HOOK_HOLD_2S" &
        fi

        log_msg "DEBUG" "[Timer] Waiting 3s for HOOK_HOLD_5S..."
        sleep 3
        log_msg "DEBUG" "[Timer] 5s reached! Executing 5s hook."
        if [ "$IS_DRY_RUN" = true ]; then
          log_msg "WARN" "(DRY RUN) 5s hold hook triggered."
        else
          bash "$HOOK_HOLD_5S" &
        fi

        local remaining=$((LONG_PRESS_SEC - 5))
        log_msg "INFO" "[Timer] Waiting remaining $remaining seconds..."
        sleep $remaining

        log_msg "DEBUG" "[Timer] ${LONG_PRESS_SEC}s reached!"
        if [ "$IS_DRY_RUN" = true ]; then
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
      local NOW=$(date +%s.%N)
      log_msg "DEBUG" "Power key UP detected."
      if [ -n "$TIMER_PID" ]; then
        kill "$TIMER_PID" 2>/dev/null
        TIMER_PID=""
      fi

      local DURATION=$(awk "BEGIN {print $NOW - $LAST_DOWN}")

      if ( awk "BEGIN {exit !($DURATION > 0.05 && $DURATION < 0.7)}" ); then
        local CD=$(awk "BEGIN {print $NOW - $LAST_SHORT_PRESS}")
        if ( awk "BEGIN {exit !($CD > 1.0)}" ); then
          if [ "$IS_DRY_RUN" = true ]; then
            log_msg "WARN" "(DRY RUN) Short press hook triggered."
          else
            log_msg "INFO" "Short press detected. Triggering hook."
            bash "$HOOK_SHORT_PRESS" &
          fi
          LAST_SHORT_PRESS=$NOW
        else
          log_msg "DEBUG" "Short press ignored (Cooldown)."
        fi
      fi
    fi
  done
}

print_help() {
  ucs_version
  echo ""
  echo "Usage: ucs <command> [args]"
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
  echo "  status                  Display configuration and status."
  echo "  version                 Print version."
  echo ""
  echo "Testing Commands:"
  echo "  monitor                 Run monitor in foreground."
  echo "  dry_run_monitor         Run safely without shutdown."
  echo ""
}

case "$1" in
  enable) check_root; ucs_enable ;;
  disable) check_root; ucs_disable ;;
  start) check_root; ucs_start ;;
  stop) check_root; ucs_stop ;;
  restart) check_root; ucs_restart ;;
  device_sleep_or_resume) check_root; ucs_device_sleep_or_resume ;;
  backlight_flash) check_root; ucs_backlight_flash ;;
  time)
    check_root
    if [ -z "$2" ]; then
      log_msg "ERROR" "Missing time parameter. Usage: ucs time <seconds>"
    else
      ucs_set_time "$2"
    fi
    ;;
  status) ucs_status ;;
  version) ucs_version ;;
  monitor) check_root; ucs_monitor false ;;
  dry_run_monitor) check_root; ucs_monitor true ;;
  *) print_help ;;
esac
