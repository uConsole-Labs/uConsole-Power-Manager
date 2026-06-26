#!/bin/bash

# Configuration and Paths
CONF_FILE="/etc/ucs.conf"
VERSION_FILE="/etc/ucs.version"
SERVICE_NAME="ucs.service"

# Load Configuration
ENABLE="true"
LONG_PRESS_SEC=10
if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
fi

# Ensure minimum 10 seconds
if [ "$LONG_PRESS_SEC" -lt 10 ] 2>/dev/null; then
    LONG_PRESS_SEC=10
fi

log_msg() {
    local type="$1"
    local msg="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [UCS] [$type] $msg"
}

do_enable() {
    sudo sed -i 's/^ENABLE=.*/ENABLE=true/' "$CONF_FILE"
    sudo systemctl restart "$SERVICE_NAME"
    log_msg "INFO" "Service enabled and restarted."
}

do_disable() {
    sudo sed -i 's/^ENABLE=.*/ENABLE=false/' "$CONF_FILE"
    sudo systemctl stop "$SERVICE_NAME"
    log_msg "INFO" "Service disabled and stopped."
}

do_set_time() {
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
    sudo systemctl restart "$SERVICE_NAME"
    log_msg "INFO" "Long press time set to $new_time seconds and service restarted."
}

do_status() {
    log_msg "INFO" "Current Configuration ($CONF_FILE):"
    cat "$CONF_FILE" | while read line; do log_msg "INFO" "  $line"; done
    echo ""
    log_msg "INFO" "Systemd Service Status:"
    sudo systemctl status "$SERVICE_NAME" --no-pager
}

do_version() {
    if [ -f "$VERSION_FILE" ]; then
        local ver=$(cat "$VERSION_FILE")
        log_msg "INFO" "Version: $ver"
    else
        log_msg "WARN" "Version file not found."
    fi
}

do_flash_screen() {
    local bl_dev=""
    for d in /sys/class/backlight/*; do
        if [ -d "$d" ]; then
            bl_dev="$d"
            break
        fi
    done
    if [ -z "$bl_dev" ] || [ ! -f "$bl_dev/brightness" ]; then
        log_msg "WARN" "No backlight device found."
        sleep 5
        return
    fi

    local orig_val=$(cat "$bl_dev/brightness")
    
    # Trap SIGTERM to ensure brightness is restored
    trap 'echo "$orig_val" > "$bl_dev/brightness"; exit 0' SIGTERM

    log_msg "INFO" "Flashing screen (Warning Phase)..."
    for i in {1..3}; do
        echo 0 > "$bl_dev/brightness"
        sleep 0.15
        echo "$orig_val" > "$bl_dev/brightness"
        sleep 0.15
    done

    # Wait remaining time (e.g., 5 more seconds for 10s total)
    local remaining=$((LONG_PRESS_SEC - 5))
    log_msg "INFO" "Waiting remaining $remaining seconds..."
    sleep $remaining
}

do_monitor() {
    if [ "$ENABLE" != "true" ]; then
        log_msg "INFO" "Service is disabled in config. Exiting."
        exit 0
    fi

    log_msg "INFO" "Starting uConsole shutdown monitor..."
    
    local model_path="/proc/device-tree/model"
    local is_cm5=false

    if [ -f "$model_path" ]; then
        local model_name=$(cat "$model_path" | tr -d '\0')
        log_msg "INFO" "Detected Hardware: $model_name"
        if [[ "$model_name" == *"Compute Module 5"* ]]; then
            is_cm5=true
            log_msg "INFO" "CM5 detected. Disabling AXP228 hardware 10s power-off..."
            # Write 0x53 to AXP228 REG 0x36 to disable auto shutdown
            i2cset -f -y 3 0x34 0x36 0x53
            log_msg "INFO" "AXP228 hardware power-off disabled."
        elif [[ "$model_name" == *"Compute Module 4"* ]]; then
            log_msg "INFO" "CM4 detected. Retaining original AXP228 hardware power-off."
        else
            log_msg "WARN" "Unknown core module. Assuming default CM4 behavior."
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

    log_msg "INFO" "Listening to events on $ev_dev"
    
    local timer_pid=""

    evtest "$ev_dev" | while read -r line; do
        # Look for KEY_POWER down (value 1)
        if [[ "$line" == *"type 1 (EV_KEY), code 116 (KEY_POWER), value 1"* ]]; then
            log_msg "DEBUG" "Power key DOWN detected."
            
            # Start background timer
            (
                # Wait 5 seconds
                sleep 5
                
                # Do visual flash and wait the rest of the time
                do_flash_screen
                
                # Time is up
                if [ "$is_cm5" = true ]; then
                    log_msg "WARN" "10 seconds reached (CM5). Triggering software shutdown!"
                    shutdown --halt --poweroff now
                else
                    log_msg "WARN" "10 seconds reached (CM4). Hardware will power off immediately."
                fi
            ) &
            timer_pid=$!
            log_msg "DEBUG" "Started timer subshell (PID: $timer_pid)."
            
        # Look for KEY_POWER up (value 0)
        elif [[ "$line" == *"type 1 (EV_KEY), code 116 (KEY_POWER), value 0"* ]]; then
            log_msg "DEBUG" "Power key UP detected."
            if [ -n "$timer_pid" ]; then
                log_msg "DEBUG" "Canceling timer subshell (PID: $timer_pid)."
                kill "$timer_pid" 2>/dev/null
                timer_pid=""
            fi
        fi
    done
}

# CLI Argument parsing
case "$1" in
    enable)
        do_enable
        ;;
    disable)
        do_disable
        ;;
    time)
        if [ -z "$2" ]; then
            log_msg "ERROR" "Missing time parameter. Usage: ucs time <seconds>"
        else
            do_set_time "$2"
        fi
        ;;
    status)
        do_status
        ;;
    version)
        do_version
        ;;
    monitor)
        do_monitor
        ;;
    *)
        do_version
        echo "Usage: ucs {enable|disable|time <seconds>|status|version|monitor}"
        ;;
esac
