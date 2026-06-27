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

### 服務管理指令 (Service Management)

*   `ucs enable`
    將服務註冊為開機自動啟動，但「不會」立刻執行。

*   `ucs disable`
    停止並徹底停用背景服務，讓系統還原為原廠的電源鍵邏輯。

*   `ucs start`
    立即啟動背景監控服務。若目前狀態為 disable，此指令將會失敗並印出提示。

*   `ucs stop`
    立即停止背景監控服務。若目前狀態為 disable，此指令將會失敗。

*   `ucs restart`
    重新啟動背景監控服務，用於套用設定檔或重置狀態。

### 設定與測試指令 (Config & Testing)

*   `ucs time <seconds>`
    設定長按觸發關機的秒數。為了避免誤觸，此數值**最低限制為 10 秒**。
    範例：`ucs time 12`（將長按觸發時間改為 12 秒）。

*   `ucs status`
    顯示當前的設定檔參數，以及 Systemd 守護行程的運作狀態。

*   `ucs dry_run_monitor`
    於終端機前景執行安全測試。此模式「不會」修改硬體暫存器，也「不會」真的
    執行關機，適合開發者觀察按鍵攔截與計時器邏輯。

*   `ucs flash_test`
    單純測試螢幕背光閃爍的視覺效果。
