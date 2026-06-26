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
