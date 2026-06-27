#!/bin/bash

# Configuration and Paths
CONF_FILE="/etc/ucs.conf"
VERSION_FILE="/etc/ucs.version"
SERVICE_POWER="ucs_power_key_monitor.service"
SERVICE_BATT="ucs_batt_monitor.service"
LOCK_FILE_POWER="/tmp/ucs_power_key.lock"

# Default Hook Paths (Can be overridden in conf)
HOOK_SHORT_PRESS="/etc/ucs/hooks/ucs_hook_short_press.sh"
HOOK_HOLD_2S="/etc/ucs/hooks/ucs_hook_hold_2s.sh"
HOOK_HOLD_5S="/etc/ucs/hooks/ucs_hook_hold_5s.sh"
HOOK_HOLD_10S="/etc/ucs/hooks/ucs_hook_hold_10s.sh"
HOOK_FREQ_POWERSAVE="/etc/ucs/hooks/ucs_hook_freq_powersave.sh"
HOOK_FREQ_RESTORE="/etc/ucs/hooks/ucs_hook_freq_restore.sh"

# Load Configuration
LONG_PRESS_SEC=10
if [ -f "$CONF_FILE" ]; then
  source "$CONF_FILE"
fi

if ! [[ "$LONG_PRESS_SEC" =~ ^[0-9]+$ ]]; then
  LONG_PRESS_SEC=10
elif [ "$LONG_PRESS_SEC" -lt 10 ]; then
  LONG_PRESS_SEC=10
elif [ "$LONG_PRESS_SEC" -gt 30 ]; then
  LONG_PRESS_SEC=30
fi

# Interval for the 5-second power key warning backlight flash
BACKLIGHT_FLASH_INTERVAL_SEC="0.5"

BATT_FREQ_MODE_NORMAL="normal"
BATT_FREQ_MODE_POWER_SAVE="powersave"

ucs_decide_target_state() {
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

log_msg() {
  local type="$1"
  local msg="$2"
  if [ "$type" = "DEBUG" ] && [ "${ENABLE_DEBUG:-false}" != "true" ]; then
    return
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') [UCS] [$type] $msg"
}

check_root() {
  if [ "$EUID" -ne 0 ]; then
    log_msg "ERROR" "This command requires root privileges. Please use sudo."
    exit 1
  fi
}

ucs_notify_user() {
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

ucs_enable() {
  sudo systemctl enable "$SERVICE_POWER" "$SERVICE_BATT" >/dev/null 2>&1
  log_msg "INFO" "Services enabled for auto-start."
  log_msg "INFO" "Note: It is NOT started yet. Run 'ucs start' to run it."
}

ucs_disable() {
  sudo systemctl stop "$SERVICE_POWER" "$SERVICE_BATT" >/dev/null 2>&1
  sudo systemctl disable "$SERVICE_POWER" "$SERVICE_BATT" >/dev/null 2>&1
  log_msg "INFO" "Services disabled and stopped."
}

ucs_start() {
  sudo systemctl start "$SERVICE_POWER" "$SERVICE_BATT"
  log_msg "INFO" "Services started."
}

ucs_stop() {
  sudo systemctl stop "$SERVICE_POWER" "$SERVICE_BATT"
  log_msg "INFO" "Services stopped."
}

ucs_restart() {
  sudo systemctl restart "$SERVICE_POWER" "$SERVICE_BATT"
  log_msg "INFO" "Services restarted."
}

ucs_enable_debug_msg() {
  sudo sed -i 's/^ENABLE_DEBUG=.*/ENABLE_DEBUG="true"/' "$CONF_FILE"
  log_msg "INFO" "Debug messages enabled."
}

ucs_disable_debug_msg() {
  sudo sed -i 's/^ENABLE_DEBUG=.*/ENABLE_DEBUG="false"/' "$CONF_FILE"
  log_msg "INFO" "Debug messages disabled."
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
  elif [ "$new_time" -gt 30 ]; then
    log_msg "WARN" "Maximum time is 30 seconds. Setting to 30."
    new_time=30
  fi
  sudo sed -i "s/^LONG_PRESS_SEC=.*/LONG_PRESS_SEC=$new_time/" "$CONF_FILE"
  log_msg "INFO" "Long press time set to $new_time seconds."

  if sudo systemctl is-active --quiet "$SERVICE_POWER" || \
     sudo systemctl is-active --quiet "$SERVICE_BATT"; then
    sudo systemctl restart "$SERVICE_POWER" "$SERVICE_BATT"
    log_msg "INFO" "Services restarted to apply new time."
  fi
}

ucs_status() {
  log_msg "INFO" "Current Configuration ($CONF_FILE):"
  while read -r line; do log_msg "INFO" "  $line"; done < "$CONF_FILE"
  echo ""
  log_msg "INFO" "Systemd Service Status:"
  sudo systemctl status "$SERVICE_POWER" "$SERVICE_BATT" --no-pager
}

ucs_version() {
  if [ -f "$VERSION_FILE" ]; then
    local ver
    ver=$(cat "$VERSION_FILE")
    echo "uConsole-shutdown version $ver"
  else
    echo "uConsole-shutdown version (unknown)"
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

ucs_backlight_flash() {
  local FB_PATH
  local BL_PATH
  FB_PATH=$(find /sys/class/graphics -name "fb0" 2>/dev/null | head -n 1)
  BL_PATH=$(find /sys/class/backlight -maxdepth 1 -mindepth 1 \
    2>/dev/null | head -n 1)

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
  for i in {1..3}; do
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
  rm -f "$LOCK_FILE_POWER"
  log_msg "INFO" "Cleanup complete."
}

ucs_monitor_power_key() {
  local IS_DRY_RUN="${1:-false}"

  if [ -f "$LOCK_FILE_POWER" ]; then
    local lock_pid
    lock_pid=$(cat "$LOCK_FILE_POWER")
    if kill -0 "$lock_pid" 2>/dev/null; then
      log_msg "ERROR" "Monitor is already running (PID: $lock_pid)."
      log_msg "ERROR" "Please stop the background service first (ucs stop)."
      exit 1
    fi
  fi
  echo $$ > "$LOCK_FILE_POWER"

  if [ "$IS_DRY_RUN" = true ]; then
    ENABLE_DEBUG="true"
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


ucs_monitor_battery() {
  local IS_DRY_RUN="${1:-false}"
  local LOCK_FILE_BATT="/tmp/ucs_battery.lock"

  if [ -f "$LOCK_FILE_BATT" ]; then
    local lock_pid
    lock_pid=$(cat "$LOCK_FILE_BATT")
    if kill -0 "$lock_pid" 2>/dev/null; then
      log_msg "ERROR" "Battery monitor is already running (PID: $lock_pid)."
      exit 1
    fi
  fi
  echo $$ > "$LOCK_FILE_BATT"

  if [ "$IS_DRY_RUN" = true ]; then
    ENABLE_DEBUG="true"
    log_msg "WARN" "=== DRY RUN MODE ENABLED (Battery Monitor) ==="
  else
    log_msg "INFO" "Starting battery monitor..."
  fi

  local CPU_POLICY_DIR="/sys/devices/system/cpu/cpufreq/policy0"
  local CPU_BAK_FILE="/tmp/ucs_cpu_freq.bak"

  local CURRENT_TARGET="$BATT_FREQ_MODE_NORMAL"
  local LAST_TARGET=""
  local TIMER_PID=""
  local LAST_BATT_LEVEL=""
  local UDEV_PID=""
  local INOTIFY_PID=""
  local TMP_PIPE="/tmp/ucs_events_$$"

  mkfifo "$TMP_PIPE"

  trap '
    rm -f "$LOCK_FILE_BATT" "$TMP_PIPE"
    [ -n "$UDEV_PID" ] && kill "$UDEV_PID" 2>/dev/null
    [ -n "$INOTIFY_PID" ] && kill "$INOTIFY_PID" 2>/dev/null
    [ -n "$TIMER_PID" ] && kill "$TIMER_PID" 2>/dev/null
    log_msg "INFO" "Battery monitor cleanup complete."
    exit 0
  ' EXIT SIGINT SIGTERM

  evaluate_system_state() {
    local bl_power_val="0"
    local bl_path
    bl_path=$(find /sys/class/backlight -maxdepth 1 -mindepth 1 \
      2>/dev/null | head -n 1)
    if [ -n "$bl_path" ] && [ -f "$bl_path/bl_power" ]; then
      bl_power_val=$(cat "$bl_path/bl_power" 2>/dev/null || echo "0")
    fi

    local has_ext="false"
    for drm_status in /sys/class/drm/card*-HDMI-*/status; do
      if [ -f "$drm_status" ]; then
        if grep -q "^connected$" "$drm_status" 2>/dev/null; then
          has_ext="true"
          break
        fi
      fi
    done

    local batt_cap="100"
    local batt_status="Discharging"
    local batt_path="/sys/class/power_supply/axp20x-battery"
    if [ ! -d "$batt_path" ]; then
      batt_path=$(find /sys/class/power_supply -name "BAT*" \
        2>/dev/null | head -n 1)
    fi
    if [ -n "$batt_path" ] && [ -f "$batt_path/capacity" ]; then
      batt_cap=$(cat "$batt_path/capacity" 2>/dev/null || echo "100")
      batt_status=$(cat "$batt_path/status" 2>/dev/null || echo "Discharging")
    fi

    local is_charging="false"
    if [ "$batt_status" = "Charging" ] || [ "$batt_status" = "Full" ]; then
      is_charging="true"
    fi

    local d_msg="[Eval] BL=$bl_power_val, Ext=$has_ext, "
    d_msg="${d_msg}Batt=${batt_cap}%, Chg=$is_charging"
    log_msg "DEBUG" "$d_msg"

    if [ -n "$LAST_BATT_LEVEL" ] && [ "$batt_cap" -ne "$LAST_BATT_LEVEL" ]; then
      log_msg "DEBUG" \
        "[Eval] Batt changed: $LAST_BATT_LEVEL -> $batt_cap"
      for th in 50 20 10 5; do
        if [ "$LAST_BATT_LEVEL" -gt "$th" ] && [ "$batt_cap" -le "$th" ]; then
          local hook_script="/etc/ucs/hooks/ucs_hook_batt_below_${th}.sh"
          if [ -f "$hook_script" ]; then
            log_msg "INFO" "Triggering hook: batt_below_${th}"
            bash "$hook_script" &
          fi
        elif [ "$LAST_BATT_LEVEL" -le "$th" ] && [ "$batt_cap" -gt "$th" ]; then
          local hook_script="/etc/ucs/hooks/ucs_hook_batt_above_${th}.sh"
          if [ -f "$hook_script" ]; then
            log_msg "INFO" "Triggering hook: batt_above_${th}"
            bash "$hook_script" &
          fi
        fi
      done
    fi
    LAST_BATT_LEVEL="$batt_cap"

    local new_target
    new_target=$(ucs_decide_target_state \
      "$bl_power_val" "$has_ext" "$batt_cap" "$is_charging")

    if [ "$new_target" != "none" ]; then
      CURRENT_TARGET="$new_target"
    fi

    local l_msg="[Eval] new_target=$new_target -> Tgt=$CURRENT_TARGET"
    log_msg "DEBUG" "$l_msg"

    if [ "$CURRENT_TARGET" != "$LAST_TARGET" ]; then
      if [ -n "$TIMER_PID" ]; then
        kill "$TIMER_PID" 2>/dev/null
        TIMER_PID=""
      fi

      if [ "$CURRENT_TARGET" != "$BATT_FREQ_MODE_NORMAL" ]; then
        (
          sleep 5
          if [ "$IS_DRY_RUN" = true ]; then
            log_msg "WARN" "(DRY RUN) Applying CPU state: $CURRENT_TARGET"
            if [ "$CURRENT_TARGET" = "$BATT_FREQ_MODE_POWER_SAVE" ]; then
              ucs_notify_user "(DRY RUN) Powersave mode (CPU minimum freq)"
            elif [ "$CURRENT_TARGET" = "$BATT_FREQ_MODE_NORMAL" ]; then
              ucs_notify_user "(DRY RUN) Normal mode (CPU dynamic freq)"
            fi
            exit 0
          fi

          if [ "$CURRENT_TARGET" = "$BATT_FREQ_MODE_POWER_SAVE" ]; then
            log_msg "INFO" "Adjusting to most power saving..."
            if [ ! -f "$CPU_BAK_FILE" ]; then
              local c_max=$(cat "$CPU_POLICY_DIR/scaling_max_freq" 2>/dev/null)
              local c_min=$(cat "$CPU_POLICY_DIR/scaling_min_freq" 2>/dev/null)
              if [ -n "$c_max" ] && [ -n "$c_min" ]; then
                echo "${c_max},${c_min}" > "$CPU_BAK_FILE"
              fi
            fi
            local hw_min=$(cat "$CPU_POLICY_DIR/cpuinfo_min_freq" 2>/dev/null)
            if [ -n "$hw_min" ]; then
              echo "$hw_min" > "$CPU_POLICY_DIR/scaling_min_freq" 2>/dev/null
              echo "$hw_min" > "$CPU_POLICY_DIR/scaling_max_freq" 2>/dev/null
            fi
            bash "$HOOK_FREQ_POWERSAVE" &
            ucs_notify_user "Powersave mode (CPU minimum freq)"
          elif [ "$CURRENT_TARGET" = "$BATT_FREQ_MODE_NORMAL" ]; then
            log_msg "INFO" "Adjusting to restore..."
            if [ -f "$CPU_BAK_FILE" ]; then
              IFS=',' read -r b_max b_min < "$CPU_BAK_FILE"
              echo "$b_max" > "$CPU_POLICY_DIR/scaling_max_freq" 2>/dev/null
              echo "$b_min" > "$CPU_POLICY_DIR/scaling_min_freq" 2>/dev/null
              rm -f "$CPU_BAK_FILE"
            else
              local h_max=$(cat "$CPU_POLICY_DIR/cpuinfo_max_freq" 2>/dev/null)
              local h_min=$(cat "$CPU_POLICY_DIR/cpuinfo_min_freq" 2>/dev/null)
              if [ -n "$h_max" ] && [ -n "$h_min" ]; then
                echo "$h_max" > "$CPU_POLICY_DIR/scaling_max_freq" 2>/dev/null
                echo "$h_min" > "$CPU_POLICY_DIR/scaling_min_freq" 2>/dev/null
              fi
            fi
            bash "$HOOK_FREQ_RESTORE" &
            ucs_notify_user "Normal mode (CPU dynamic freq)"
          fi
        ) &
        TIMER_PID=$!
      fi
      LAST_TARGET="$CURRENT_TARGET"
    fi
  }

  evaluate_system_state

  stdbuf -oL udevadm monitor --subsystem-match=power_supply \
    --subsystem-match=drm > "$TMP_PIPE" 2>/dev/null &
  UDEV_PID=$!

  local bl_path
  bl_path=$(find /sys/class/backlight -maxdepth 1 -mindepth 1 \
    2>/dev/null | head -n 1)
  if [ -n "$bl_path" ] && command -v inotifywait >/dev/null 2>&1; then
    inotifywait -m -e modify "$bl_path/bl_power" > "$TMP_PIPE" 2>/dev/null &
    INOTIFY_PID=$!
  fi

  while read -r line; do
    evaluate_system_state
  done < "$TMP_PIPE"
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

case "$1" in
  enable) check_root; ucs_enable ;;
  disable) check_root; ucs_disable ;;
  start) check_root; ucs_start ;;
  stop) check_root; ucs_stop ;;
  restart) check_root; ucs_restart ;;
  device_sleep_or_resume) check_root; ucs_device_sleep_or_resume ;;
  backlight_flash) check_root; ucs_backlight_flash ;;
  flash_test) check_root; ucs_backlight_flash ;;
  enable_debug_msg) check_root; ucs_enable_debug_msg ;;
  disable_debug_msg) check_root; ucs_disable_debug_msg ;;
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
  monitor_power_key) check_root; ucs_monitor_power_key false ;;
  dry_run_monitor_power_key) check_root; ucs_monitor_power_key true ;;
  monitor_battery) check_root; ucs_monitor_battery false ;;
  dry_run_monitor_battery) check_root; ucs_monitor_battery true ;;
  flash_test) check_root; ucs_backlight_flash ;;
  test_logic)
    if [ -z "$5" ]; then
      echo "Usage: ucs test_logic <bl_power> <has_ext> <batt_cap> <is_charging>"
      exit 1
    fi
    ucs_decide_target_state "$2" "$3" "$4" "$5"
    ;;
  *) print_help ;;
esac
