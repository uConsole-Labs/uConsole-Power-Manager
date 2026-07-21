# uConsole-Power-Manager AI Agent Guidelines

This document provides strict operational constraints and architectural rules
for AI agents interacting with this repository.

## 1. Project Overview

- **Purpose**: A lightweight, zero-polling background power management service
  specifically designed for the ClockworkPi uConsole Compute Module 5 (CM5)
  running Wayland.

## 2. Architecture & Boundaries (Strict Rules)

- **FHS Compliance**: The project strictly follows the Linux Filesystem
  Hierarchy Standard.
  - Core executables and hooks must reside in `/opt/upm/`.
  - Configuration files must reside in `/etc/upm/`.
- **Permissions Management**:
  - Do NOT apply executable (`+x`) permissions to any file in the `src/`
    directory.
  - The `install.sh` script is the single source of truth for applying
    `chmod +x` during deployment to target directories (e.g., `/opt/upm/` or
    `/usr/local/bin/`).
- **Complete Uninstallation**: Any file or directory generated or copied by
  `install.sh` MUST have a corresponding `rm` or `rm -rf` command in the
  `generate_uninstaller` function within `install.sh`.

## 3. Hardware Constraints & Flaws

- **The 10-Second Shutdown Flaw**: Due to architectural changes in the CM5 power
  control pins, the AXP228 PMIC's default 10-second hard power-off feature
  fails to cut power completely, freezing the system.
- **Software Takeover**: To bypass this hardware issue, the service sends an I2C
  command to disable the hardware's default 10-second shutdown. The background
  service (`upm_power_key_monitor.service`) uses `evtest` to listen for the
  power key event and safely forces a shutdown at the software level.
  **CRITICAL RISK**: By disabling the PMIC's hardware 10-second shutdown, the
  system lacks a hardware fallback. If the kernel panics or the user-space
  daemon crashes, the user cannot power off the device without a hard battery
  pull.

## 4. Mechanisms & GUI Injections

- **Zero Polling**: All scripts must be fully event-driven (using `evtest` or
  `inotifywait`). Do NOT use `sleep` loops to poll hardware states.
- **Wayland GUI Hooks**: Background services run as `root` but often need to
  display UI elements to the desktop user. Hook scripts (e.g.,
  `upm_hook_hold_2s.sh`) achieve this by dynamically fetching the desktop user's
  UID and injecting `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` via `sudo -u`.
  **SECURITY RULE**: The daemon MUST strictly validate the fetched UID against
  active `logind` sessions before executing the `sudo` injection to prevent
  privilege escalation.
- **Device Locks**: The `upm_power_key_monitor.service` holds an exclusive lock
  (`EVIOCGRAB`) on the power key. Before running tests or modifying the
  installation, you must stop this service to prevent `evtest` grab failures.
