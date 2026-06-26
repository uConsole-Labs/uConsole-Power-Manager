# uConsole-shutdown

### English
A lightweight, event-driven background service that resolves power button
long-press shutdown issues on the ClockworkPi uConsole. It automatically detects
the core module (CM4 or CM5) and applies the appropriate shutdown strategy,
bypassing the hardware power-off limitations specific to the CM5. It features a
5-second screen-flash visual warning and a command-line interface ( ucs ) for
configuration, all while maintaining 0% CPU usage during standby.

### 繁體中文
一個極輕量的事件驅動背景服務，用於解決 ClockworkPi uConsole 長按電源鍵關機的
相容性問題。它會自動偵測核心模組（CM4 或 CM5）並套用對應的關機策略，繞過 CM5
在硬體斷電上的限制。本專案包含長按 5 秒的螢幕閃爍視覺警告，以及一個用於管理
設定的指令列工具（ ucs ），且在待機監控時維持 0% 的 CPU 資源耗損。

## CLI Usage (ucs 指令操作說明)

安裝完成後，您可以使用全域指令 `ucs`（代表 uConsole-shutdown）來管理服務與修
改設定。所有的設定修改都會自動重啟背景服務以即時生效。

### 常用指令：

*   `ucs enable`
    啟用腳本與自訂的電源鍵監控功能。

*   `ucs disable`
    停用功能。此操作會安全地關閉背景服務，讓系統還原為原廠的電源鍵邏輯。

*   `ucs time <seconds>`
    設定長按觸發關機的秒數。為了避免與正常的螢幕開關衝突，此數值**最低限制為
    10 秒**。
    範例：`ucs time 12`（將長按觸發時間改為 12 秒）。

*   `ucs status`
    顯示當前的設定檔參數，以及 Systemd 守護行程的運作狀態。
