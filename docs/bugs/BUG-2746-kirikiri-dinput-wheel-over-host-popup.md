## BUG-2746 · KiriKiri 查词弹窗上滚动滚轮会让游戏翻到下一句
- **报告**：2026-09-27（用户：《王様恋愛》Ver1.00 / KiriKiri Z，打开游戏内查词后想用滚轮往下看词典，游戏直接翻到下一句）。补充（2026-09-28）：点一下弹窗也仍会翻页；同社（ASa Project）另一作同样复现，其它厂商的 KiriKiri 游戏不复现。直连卡片与 attachedOnly 贴附层 + 桌面弹窗两种呈现都复现。
- **真实性**：✅ 真 bug，路径已由运行时诊断确认；本 PR **不修**（用户决定交作者处理，下列为已查明事实）。
  - 宿主侧：`low_level_mouse_hook.cpp` 在光标压在查词卡片上时吞掉 `WM_MOUSEWHEEL` 并转交给 `GlobalLookupWindow::HandleGlobalWheel`。临时加的有界日志证实每一格都被吞下并转交（`showing=1`），窗口消息没有漏给游戏。
  - 游戏侧：exe 内含 `tTVPWheelDirectInputDevice`，`-wheel` 选项 `"value":"dinput"` 标 `"default":true`，`.cf` 与用户 `.cfu` 均未改写，即按引擎缺省经 **DirectInput** 读滚轮；WH_MOUSE_LL 挡不住这条路。临时 hook 日志显示游戏有一台 `GetCapabilities` 为鼠标的 DirectInput 设备每 ~60 ms 调一次 `GetDeviceState`，**`bytes=4`**：KiriKiri 为滚轮单建了只含 Z 轴的 4 字节自定义格式设备。
  - 通用输入护盾（`generic_input_shield.inc`）的 DirectInput detour 只处理左键；即便加滚轮过滤，也不能按 16/20 字节的标准 DIMOUSESTATE 布局去找 lZ，必须按设备**当前**数据格式定位 Z 轴。另外附着前游戏自建的设备没有经过工厂 hook，未登记。
  - 「只有该社复现」尚未解释，可能只是该社把滚轮向下映射为「下一句」，别家映射为回看或不处理；不作为根因证据。
- **[ ] ① 未修复** — 调查中验证过的方向（原型实现与诊断未随本 PR 提交，需要时可另行提供），供作者取舍：
  1. 源头过滤：在通用护盾 DirectInput `GetDeviceState` / `GetDeviceData` detour 的登记门之前，对鼠标设备用 `GetObjectInfo(DIPH_BYOFFSET)` 按当前格式反查 `GUID_ZAxis` 的偏移（`EnumObjects` 给的是原生格式偏移，对自定义格式不成立），在滚轮属于宿主时清掉该轴 / 删掉该偏移的缓冲事件；附着前已建的设备可经已 hook 的工厂自建一个系统鼠标设备，触发实现级 inline hook 覆盖。
  2. 判定「这一格属于宿主」：窗口归属判据（光标下是别的进程、owner 属于游戏的窗）只覆盖直连卡片，贴附层旁的桌面弹窗不以游戏窗为 owner；更精确的是由宿主 WH_MOUSE_LL 在吞下滚轮时经共享内存发布一个时间戳（如复用 `lookup_shield_reserved` / `lookup_shield_reserved2`，布局不变），注入侧在其后一个短窗口内去掉 DirectInput 读到的 Z。这是 IPC 契约变更，需两侧同 PR。
  3. 只在 kag `onMouseWheel` 接缝消费不够：引擎原生层还会把滚轮派给焦点图层，且贴附层模式下 KiriKiri 游戏内传感器并未安装。
- **[ ] ② 未加自动化测试** — 随修复一起补（纯数据部分可单测：按偏移清轴、按偏移删缓冲事件并保序）。
- **备注**：上文引用的临时诊断（`global wheel`、`dinput.call`、`dinput.probe`、`wheel.dinput`）只用于定位，本 PR 不含。
