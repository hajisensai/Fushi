## BUG-2746 · KiriKiri 查词弹窗上滚动滚轮会让游戏翻到下一句
- **报告**：2026-09-27（用户：《王様恋愛》Ver1.00 / KiriKiri Z，打开游戏内查词后想用滚轮往下看词典，游戏直接翻到下一句）。补充（2026-09-28）：点一下弹窗也仍会翻页；同社（ASa Project）另一作同样复现，其它厂商的 KiriKiri 游戏不复现。直连卡片与 attachedOnly 贴附层 + 桌面弹窗两种呈现都复现。
- **真实性**：✅ 真 bug，路径已由此前运行时诊断确认。2026-09-30 核对作者 `upstream/develop` 至 `2f08d46106cf224a9106c752ae347bb29db9a77a`：PR #1721 已合并，但只包含按钮 / 启动捕获修复，本条仍未修。
  - 宿主侧：`low_level_mouse_hook.cpp` 在光标压在查词卡片上时吞掉 `WM_MOUSEWHEEL` 并转交给 `GlobalLookupWindow::HandleGlobalWheel`。临时加的有界日志证实每一格都被吞下并转交（`showing=1`），窗口消息没有漏给游戏。
  - 游戏侧：exe 内含 `tTVPWheelDirectInputDevice`，`-wheel` 选项 `"value":"dinput"` 标 `"default":true`，`.cf` 与用户 `.cfu` 均未改写，即按引擎缺省经 **DirectInput** 读滚轮；WH_MOUSE_LL 挡不住这条路。临时 hook 日志显示游戏有一台 `GetCapabilities` 为鼠标的 DirectInput 设备每 ~60 ms 调一次 `GetDeviceState`，**`bytes=4`**：KiriKiri 为滚轮单建了只含 Z 轴的 4 字节自定义格式设备。
  - 通用输入护盾（`generic_input_shield.inc`）的 DirectInput detour 只处理左键；即便加滚轮过滤，也不能按 16/20 字节的标准 DIMOUSESTATE 布局去找 lZ，必须按设备**当前**数据格式定位 Z 轴。另外附着前游戏自建的设备没有经过工厂 hook，未登记。
  - 「只有该社复现」尚未解释，可能只是该社把滚轮向下映射为「下一句」，别家映射为回看或不处理；不作为根因证据。
- **[ ] ① 候选已实现，待实机验收** — `codex/gal-popup-wheel-20260930`，2026-09-30：
  1. 仅处理已确认 KiriKiri exporter、`GUID_SysMouse`、相对模式、`bytes=4` 且当前格式 offset 0 为 `GUID_ZAxis` 的即时状态路径。对已存在的设备，探测 DirectInput A/W 与 Device2/7 实现；过滤在通用设备登记门之前，接口别名按 canonical IUnknown 共用消费游标。标准 16/20 字节与 buffered 路径保持原行为。
  2. 宿主在 WH_MOUSE_LL **真正返回 1 的滚轮分支**确认归属；未消费且前台为对应游戏的物理垂直滚轮累计到独立 48 字节 mapping。注入侧仍调用原 GetDeviceState 排空 DI，但返回宿主累计量的增量。因此移出 / 关闭后的延迟读取不会泄漏，卡内外相反方向在 DI 中抵消也不丢游戏输入。按读取位置、短时间窗口或从原 DI 减预算都不足以保证该行为。
  3. 首次真实合格调用同步标记 source requirement；宿主等待 HHOOK 与真实消费游标 generation acknowledgement 后才上屏。失败不得降级为仍可消费滚轮的卡片。producer 保留至对应游戏退出，关卡片 / 关捕获 / 切目标不退休旧游戏 source；HHOOK 重装期间先暂停 source 并换 generation。
  4. 原 voice/lookup SharedHeader ABI 不变。新增 `lookup_wheel_source.h` 契约；滚轮诊断只排队元数据，由 worker 写出，单进程最多 64 条。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/direct_input_wheel_test.cpp` 直接调用生产过滤函数，覆盖混合反向增量、延迟发布、关闭后的 owned tail、接口别名、失焦与模式变化、source 丢失 / 重连、缓存淘汰、诊断预算、其他设备与标准格式负向情况。x86/x64 新测试与原 `generic_input_shield_test` 均通过；两个修改的宿主 CPP 定向编译通过。
- **备注**：尚未完整构建应用、执行宿主 LL Hook / 窗口上屏链或在真实游戏复测，① 保持未验收。需验证直连卡片、贴附层旁桌面卡片、滚后立即移出 / 关闭、游戏画面正常滚轮、关闭捕获与宿主重连。注入 DLL 有改动，测试前须重启游戏并重新附着。
- **故障限制**：source 已映射后若宿主退出或崩溃，目标相对 4 字节滚轮保持 0，直到宿主重新建立 ready source 或游戏重启；原 DI 的一次 0 读取不是先前物理事件已退休的证明，不能据此放回可能属于卡片的残留滚轮。
