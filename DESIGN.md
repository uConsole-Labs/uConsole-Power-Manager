# uConsole-Power-Manager Design and Architecture

[點擊此處跳轉至中文版說明](#中文版說明-traditional-chinese)

## 1. Dual-Service Architecture

This project solves the power button freezing issue on the ClockworkPi uConsole
(especially with the CM5 module). To keep the system very stable, the project is
divided into two separate background services:

1.  **Power Key Monitor (`upm_power_key_monitor.service`)**: Handles the power
    button hardware events, warning flashes, and safe shutdown.
2.  **Battery Monitor (`upm_batt_monitor.service`)**: Handles battery saving,
    external screen detection, and CPU frequency changes.

Both services are designed to be lightweight and use zero CPU polling.

---

## Part 1: Power Key Monitor

### 1.1 Design Concept and 0% CPU Usage
Old monitor tools often use a `sleep` loop to check the hardware. This wastes
CPU power. This service uses the `evtest` tool to read the `axp221-pek` input
directly. It waits without using the CPU. When you are not pressing the button,
the service sleeps completely and uses 0% CPU.

For the CM5 hardware, the service sends an I2C command to disable the hardware's
default 10-second shutdown. This allows the software to take full control.

### 1.2 Logic Flow Chart

```text
[ Hardware Power Button ]
           |
  ( Waiting, 0% CPU )
           |
    +------+------+
    |             |
[ Key DOWN ]  [ Key UP ]
    |             |
Start 5s timer  +-+--------------------+
    |           | (Stop timer)         |
    v           v                      v
[ Run Hook ]    | < 0.05s              | > 0.05s and < 0.7s
                v                      v
           Invalid (Ignore)      Check cooldown time
                                       |
                                       v
                                [ Run Short Press Hook ]
```

### 1.3 Warning and Safe Recovery
To prevent data loss from accidental presses, the system has visual warnings:
1.  **Press 0 to 5 seconds**: You can release the button anytime to cancel.
2.  **Press for 5 seconds**: The screen will turn black and back on 3 times.
    This means the system will force restart soon. Let go if it is a mistake.
3.  **Press for 10-30 seconds**: The software forces a shutdown.

**Safe Trap Mechanism**:
Flashing the screen takes some time. If you release the button while it is
flashing, the system will stop the timer. The code uses a `trap` to make sure
the screen power is always turned back on. You will not get stuck with a black
screen.

---

## Part 2: Battery and Power Saving Monitor

The goal is to save battery when the power is low or the screen is off. It also
prevents the system from slowing down unexpectedly.

This service also uses zero CPU polling. It uses `udevadm` and `inotifywait` to
listen for events.

### 1. Frequency Adjustment

The system listens for three events:
*   **a. Internal screen brightness changes**
*   **b. Charger plugged or unplugged**
*   **c. Battery level changes**

#### 1.1 When to enter Power Save
When these rules are true, and **stay true for 5 seconds**:
*   **a.** (Screen is off `AND` no external screen) `OR` (Battery < 30%)
*   **b.** `AND` (Not charging)

#### 1.2 When to enter Normal Mode
When any of these rules are true, and **stay true for 5 seconds**:
*   **a.** (Screen is on `OR` has external screen) `AND` (Battery >= 30%)
*   **b.** `OR` (Charging)

#### 1.3 Power Save Actions
*   **1.3.1 Record Settings**: Save the current CPU max and min frequency.
*   **1.3.2 Set to Power Save**: Change the CPU frequency to the lowest hardware
    limit. Then run the `$HOOK_FREQ_POWERSAVE` script.

#### 1.4 Normal Mode Actions
*   **1.4.1 Check Records**: Check if there are saved frequency records.
*   **1.4.2 Restore Settings**:
    *   **Yes**: Restore the saved frequency.
    *   **No**: Read the default hardware frequency and apply it.
    *   Finally, run the `$HOOK_FREQ_RESTORE` script.

### Logic Flow Chart

```text
 [ udevadm ]                [ inotifywait ]
(Batt/Charger)             (Screen Brightness)
       \                        /
        +---> [ Named Pipe ] <-+
                     |
                     v
             [ Read Events ]
                     |
                     v
   +-----------------+-----------------+
   |                                   |
[ 1.1 Power Save ]               [ 1.2 Normal Mode ]
((Screen=0 and No Ext)           ((Screen!=0 or Has Ext)
         or                               and
   Battery < 30%)                   Battery >= 30%)
        and                               or
  (Not Charging)                     (Charging)
   |                                   |
   +-----------------+-----------------+
                     |
            [ Did state change? ]
                     | (Yes)
             ( Start 5s timer )
                     | (No changes for 5s)
                     v
   +-----------------+-----------------+
   |                                   |
[ 1.3 Power Save Action ]        [ 1.4 Normal Action ]
1.3.1 Record frequency           1.4.1 Check records
1.3.2 Set to lowest limit        1.4.2 Has records?
                                   - Yes: Restore record
                                   - No: Restore default
```

### 1.5 Decoupling and Testability
To test the rules easily without real hardware, the logic is put into a pure
function named `upm_decide_target_state`.
This function does not read any files. It only uses the input values (backlight,
external screen, battery, charger) to calculate the result. You can use the CLI
(`upm test_logic`) to test all situations in milliseconds. This makes the system
very strong and reliable.

### 1.6 System to User Notifications
The background services run as `root` and cannot easily talk to your desktop.
To show desktop notifications (like in dry-run mode), the system uses a special
method (`upm_notify_user`). It finds your user ID and the Wayland DBUS address,
and uses `sudo -u` to send the notification to your screen safely.

---

# 中文版說明 (Traditional Chinese)

## 1. 雙服務架構 (Dual-Service Architecture)

本專案解決了 ClockworkPi uConsole（特別是 CM5）長按電源鍵會當機的問題。為
了讓系統非常穩定，我們將程式分成兩個獨立的背景服務：

1.  **電源鍵監控 (`upm_power_key_monitor.service`)**：處理實體按鍵、螢幕警
    告與安全關機。
2.  **電池監控 (`upm_batt_monitor.service`)**：處理電池省電、外接螢幕檢查
    與 CPU 頻率調整。

兩個服務都很輕量，並且不使用 CPU 輪詢 (Zero Polling)。

---

## 第一部分：電源鍵監控服務

### 1.1 設計概念與 0% CPU 耗損
舊的工具通常會用 `sleep` 迴圈來檢查硬體，這會浪費 CPU 電力。本服務使用
`evtest` 工具直接讀取硬體訊號。當你沒有按按鈕時，程式會完全休眠，使用 0%
的 CPU。

對於 CM5 硬體，服務會自動發送 I2C 指令，關閉硬體預設的 10 秒斷電功能，讓軟
體可以完全接管。

### 1.2 邏輯流程圖

```text
[ 硬體電源鍵 ]
      |
 ( 休眠等待，0% CPU )
      |
  +---+---+
  |       |
[ 按下 ] [ 放開 ]
  |       |
開始 5s計時 +----------------------+
  |       | (停止計時)             |
  v       v                        v
[ 執行 ]  | < 0.05s                | > 0.05s 且 < 0.7s
          v                        v
      無效操作 (忽略)         檢查冷卻時間
                                   |
                                   v
                             [ 執行短按 Hook ]
```

### 1.3 警告與安全恢復
為了防止你不小心按到而遺失資料，系統有視覺警告功能：
1.  **按壓 0 到 5 秒**：你可以隨時放開按鍵取消。
2.  **按壓滿 5 秒**：螢幕會變黑再變亮 3 次。這表示系統快要強制重啟了，如果
    是誤按請馬上放開。
3.  **按壓 10 到 30 秒**：軟體會強制關機。

**安全 Trap 機制**：
讓螢幕閃爍需要一點時間。如果你在閃爍的時候放開按鍵，程式會停止計時。這裡使
用了 `trap` 機制來確保螢幕電源一定會被重新打開，你不會遇到螢幕一直黑掉的狀
況。

---

## 第二部分：電池與省電監控服務

這個服務的目標是在電量低或螢幕關閉時節省電力，並且防止系統在運作時突然變慢。
它同樣不使用 CPU 輪詢，而是透過 `udevadm` 和 `inotifywait` 來接收事件。

### 1. 調整頻率

系統會監控三個事件：
*   **a. 內建螢幕亮度改變**
*   **b. 充電線插拔**
*   **c. 電池電量改變**

#### 1.1 何時進入省電模式
當以下規則成立，並且**維持 5 秒沒有改變**：
*   **a.** (螢幕關閉 `AND` 沒有外接螢幕) `OR` (電量 < 30%)
*   **b.** `AND` (沒有在充電)

#### 1.2 何時回到正常模式
當以下任何規則成立，並且**維持 5 秒沒有改變**：
*   **a.** (螢幕開啟 `OR` 有外接螢幕) `AND` (電量 >= 30%)
*   **b.** `OR` (正在充電)

#### 1.3 省電模式動作
*   **1.3.1 紀錄設定**：儲存目前的 CPU 最高與最低頻率。
*   **1.3.2 設定為省電**：將 CPU 頻率限制在硬體的最低值。然後執行
    `$HOOK_FREQ_POWERSAVE` 腳本。

#### 1.4 正常模式動作
*   **1.4.1 檢查紀錄**：檢查是否有之前儲存的頻率紀錄。
*   **1.4.2 恢復設定**：
    *   **有**：恢復儲存的頻率。
    *   **沒有**：讀取硬體的預設頻率並套用。
    *   最後，執行 `$HOOK_FREQ_RESTORE` 腳本。

### 邏輯流程圖

```text
 [ udevadm ]                [ inotifywait ]
(電池/充電器)                 (螢幕亮度)
       \                        /
        +---> [ Named Pipe ] <-+
                     |
                     v
             [ 讀取事件 ]
                     |
                     v
   +-----------------+-----------------+
   |                                   |
[ 1.1 省電模式 ]                 [ 1.2 正常模式 ]
((螢幕關閉 且 無外接)            ((螢幕開啟 或 有外接)
         或                               且
    電量 < 30%)                      電量 >= 30%)
         且                               或
    (無充電)                           (充電中)
   |                                   |
   +-----------------+-----------------+
                     |
             [ 狀態有改變嗎? ]
                     | (有)
             ( 開始 5 秒計時 )
                     | (5 秒內沒有改變)
                     v
   +-----------------+-----------------+
   |                                   |
[ 1.3 省電動作 ]                 [ 1.4 正常動作 ]
1.3.1 紀錄頻率                   1.4.1 檢查紀錄
1.3.2 設定為最低限制             1.4.2 有紀錄嗎?
                                   - 有: 恢復紀錄
                                   - 無: 恢復預設
```

### 1.5 程式解耦與測試
為了解決硬體測試的困難，判斷邏輯被獨立成一個叫做 `upm_decide_target_state`
的純函式。這個函式不會讀取任何檔案，只會根據輸入的數值來計算結果。你可以使
用 CLI (`upm test_logic`) 在毫秒內測試所有的情況。這讓系統變得非常可靠。

### 1.6 系統與使用者的桌面通知
背景服務是使用 `root` 權限執行的，通常無法直接與你的桌面溝通。為了顯示桌面
通知，系統使用了一個特別的方法 (`upm_notify_user`)。它會找出你的使用者 ID
與 Wayland 的 DBUS 位址，並安全地傳送通知到你的螢幕上。
