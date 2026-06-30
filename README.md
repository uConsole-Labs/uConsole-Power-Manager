# uConsole-PowerManager

A lightweight, event-driven background service for ClockworkPi uConsole. It
fixes the power button long-press freeze issue.

[點擊此處跳轉至中文版說明](#中文版說明-traditional-chinese)

## ✨ Features

*   **For CM5 Only**: Built specifically for the ClockworkPi uConsole CM5.
*   **CPU Frequency Scaling**: Auto downclocks CPU when battery is low or
    screen is off to save power.
*   **Safe Screen Control**: Hardware-level screen sleep that prevents Wayland
    desktop freezes.
*   **Zero CPU Polling**: Event-driven design uses 0% CPU in the background.
*   **Visual Warning**: Flashes the backlight before a forced shutdown to
    prevent accidental data loss.

## 🛠️ Installation and Removal

**System Requirements:** Debian/Ubuntu with root access.
The install script will automatically install required packages (`evtest`,
`i2c-tools`, `inotify-tools`, `mako-notifier`, `libnotify-bin`).

*   **Quick Install:**
    ```bash
    sudo bash install.sh
    ```
    After installation, two background services will start automatically:
    1.  `upm_power_key_monitor.service`: Handles the power button events.
    2.  `upm_batt_monitor.service`: Handles battery monitoring and CPU scaling.

*   **Complete Removal:**
    ```bash
    sudo upm-uninstall
    ```

## 💻 CLI Commands

You can use the `upm` command in your terminal to control the system.

### Service Management
*   `upm enable` / `upm disable`: Turn auto-start on boot on or off.
*   `upm start` / `upm stop`: Start or stop the background services now.
*   `upm restart`: Restart the services (run this after changing settings).
*   `upm status`: Show the current status of the services.

### Development and Testing
*   `upm time <seconds>`: Set the long-press shutdown time (10 to 30 seconds).
*   `upm flash_test`: Test the screen backlight warning flash.
*   `upm dry_run_monitor_power_key`: Test power key monitor without shutdown.
*   `upm dry_run_monitor_battery`: Run battery monitor without real CPU changes.
    It will send desktop notifications to show what it is doing.
*   `upm test_logic <bl_power> <ext> <batt> <chg>`: Test the power save logic.
    You can use this to quickly test the rules without waiting for 5 seconds.

## ⚙️ Configuration

The main configuration file is `/etc/upm.conf`.
You can edit it with a text editor.

*   **`LONG_PRESS_SEC`**: The time to hold the power button before shutdown.
*   **Hook Paths**: You can change the file paths for the custom scripts here.

> Warning: Always run `sudo upm restart` after you edit `/etc/upm.conf`.

## 🪝 Hook Scripts

The system uses Hook scripts so you can easily run your own code.
The default scripts are in the `/etc/upm/hooks/` folder.

### Power Key Hooks
*   `upm_hook_short_press.sh`: Runs when you press the power button shortly.
*   `upm_hook_hold_2s.sh`: Runs when you hold the power button for 2 seconds.
*   `upm_hook_hold_5s.sh`: Runs when you hold the button for 5 seconds.
*   `upm_hook_hold_10s.sh`: Runs when you hold the button for 10 seconds.

### Performance Hooks
*   `upm_hook_freq_powersave.sh`: Runs when the system enters power save mode.
*   `upm_hook_freq_restore.sh`: Runs when the system returns to normal mode.

### Battery Level Hooks
If you create a script with a specific name in the hooks folder, it will run
when the battery reaches that level (supports 50%, 20%, 10%, 5%):
*   `upm_hook_batt_below_20.sh`: Runs once when battery drops below 20%.
*   `upm_hook_batt_above_50.sh`: Runs once when battery goes above 50%.

## 🐛 Debugging

If you need to fix problems, you can use these commands:

1.  **Enable Debug Logs**:
    Run `sudo upm enable_debug_msg`. The system will log all hardware status.
2.  **View Live Logs**:
    Use `journalctl` to see the background system logs:
    *   For the power key: `sudo journalctl -u upm_power_key_monitor.service -f`
    *   For the battery: `sudo journalctl -u upm_batt_monitor.service -f`
3.  **Disable Debug Logs**:
    Run `sudo upm disable_debug_msg` to turn off the detailed logs.

---

# 中文版說明 (Traditional Chinese)

專為 ClockworkPi uConsole 設計的輕量級、事件驅動背景服務。它解決了長按電源鍵
會造成系統當機的問題。

## ✨ 核心特色

*   **CM5 專屬架構**：專為搭載 CM5 核心的 ClockworkPi uConsole 開發。
*   **動態降頻省電**：在低電量或螢幕關閉時自動調降 CPU 頻率，延長續航。
*   **安全螢幕控制**：硬體層級的螢幕休眠切換，徹底避免 Wayland 圖形崩潰。
*   **零輪詢佔用**：全事件驅動設計，背景服務監聽時維持 0% CPU 效能消耗。
*   **視覺防呆警告**：強制關機前會閃爍背光，防止誤觸造成未存檔資料遺失。

## 🛠️ 安裝與移除

**系統需求：** Debian/Ubuntu，需要 root 權限。
安裝腳本會自動安裝需要的套件 (`evtest`, `i2c-tools`, `inotify-tools`,
`mako-notifier`, `libnotify-bin`)。

*   **快速安裝：**
    ```bash
    sudo bash install.sh
    ```
    安裝完成後，系統會自動啟動兩個背景服務：
    1.  `upm_power_key_monitor.service`：負責處理電源鍵事件。
    2.  `upm_batt_monitor.service`：負責監控電池與調整 CPU 頻率。

*   **完整移除：**
    ```bash
    sudo upm-uninstall
    ```

## 💻 CLI 指令操作

您可以在終端機輸入 `upm` 指令來控制系統。

### 服務管理
*   `upm enable` / `upm disable`：開啟或關閉開機自動啟動。
*   `upm start` / `upm stop`：立刻啟動或停止背景服務。
*   `upm restart`：重新啟動服務（更改設定後請執行這個指令）。
*   `upm status`：顯示服務目前的狀態。

### 開發與測試
*   `upm time <seconds>`：設定長按強制關機的時間（10 到 30 秒）。
*   `upm flash_test`：測試螢幕背光閃爍的警告效果。
*   `upm dry_run_monitor_power_key`：測試按鍵監控，但不會真的關機。
*   `upm dry_run_monitor_battery`：測試電池監控，但不會真的改變 CPU 頻率。
    它會傳送桌面通知來顯示它正在做什麼。
*   `upm test_logic <bl_power> <ext> <batt> <chg>`：測試省電邏輯。
    您可以使用這個指令快速測試規則，不需要等待 5 秒鐘。

## ⚙️ 設定檔

主要的設定檔在 `/etc/upm.conf`。
您可以使用文字編輯器來修改它。

*   **`LONG_PRESS_SEC`**：長按電源鍵觸發關機的秒數。
*   **Hook 路徑**：您可以在這裡更改自訂腳本的檔案路徑。

> 警告：修改 `/etc/upm.conf` 後，請務必執行 `sudo upm restart`。

## 🪝 Hook 腳本

系統使用 Hook 腳本機制，讓您可以輕鬆執行自己的程式碼。
預設的腳本放在 `/etc/upm/hooks/` 資料夾中。

### 電源鍵 Hooks
*   `upm_hook_short_press.sh`：短按電源鍵時執行。
*   `upm_hook_hold_2s.sh`：按住電源鍵 2 秒時執行。
*   `upm_hook_hold_5s.sh`：按住電源鍵 5 秒時執行。
*   `upm_hook_hold_10s.sh`：按住電源鍵 10 秒時執行。

### 效能 Hooks
*   `upm_hook_freq_powersave.sh`：系統進入省電模式時執行。
*   `upm_hook_freq_restore.sh`：系統回到正常模式時執行。

### 電池電量 Hooks
如果您在 hooks 資料夾中建立特定名稱的腳本，當電池達到該電量時就會執行它
（支援 50%, 20%, 10%, 5%）：
*   `upm_hook_batt_below_20.sh`：電池電量低於 20% 時執行一次。
*   `upm_hook_batt_above_50.sh`：電池電量高於 50% 時執行一次。

## 🐛 除錯

如果您需要解決問題，可以使用以下指令：

1.  **開啟詳細日誌**：
    執行 `sudo upm enable_debug_msg`。系統會記錄所有的硬體狀態。
2.  **查看即時日誌**：
    使用 `journalctl` 來查看背景系統日誌：
    *   電源鍵日誌：`sudo journalctl -u upm_power_key_monitor.service -f`
    *   電池日誌：`sudo journalctl -u upm_batt_monitor.service -f`
3.  **關閉詳細日誌**：
    執行 `sudo upm disable_debug_msg` 來關閉詳細的日誌輸出。
