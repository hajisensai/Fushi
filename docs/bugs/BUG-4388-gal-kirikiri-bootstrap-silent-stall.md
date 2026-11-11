## BUG-4388 · KiriKiri 查词 / KAG 文本道 bootstrap 静默停住：addHook 一个钩子名被拒即整个传感器作废，安装链各出口无诊断
- **报告**：2026-11-12（用户：志愿者机真机两例，经协调会话转来）
  - 出会って5分は俺のもの！時間停止と不可避な運命（KiriKiri Z 1.3.3.7 x86，TVPMainWindow 全屏，windowEx / KAGParserEx）：KAG 文本道与查词传感器都没装上，日志里没有 `[FushiKagText] bootstrap installed=`，readiness 停在 `lookup_diag=0xb0000040 diag2=0xa584000c`。
  - ひこうき雲の向こう側（经典 KiriKiri2 x86，TTVPWindowForm，Locale Emulator 启动）：文本道正常（installed=127），查词传感器从不建立，`diag2` 最终是 `0x1d96000c`（kag 与 kag.addHook 都在、TJS bootstrap 函数仍挂着），点击未被认领、剧情推进。
- **真实性**：✅ 真 bug（两层）
  1. **结构缺陷（已修）**：查词 bootstrap 的 KAGEX 输入接缝把四个 `kag.addHook(...)` 连成一串、没有各自的 try（原 `native/galgame_hook/hook/adapters/kirikiri_adapter.inc:4184` 起，`fushiLookupInstallKagSeams`）。`addHook` 是各 KAG 衍生框架自加的扩展点，钩子表各不相同（`onMouseWheelHook` 只在 KAGEX 系里有），任何一个名字不被接受就抛到 bootstrap 的 catch：整个传感器连同已装好的 TextRender / 消息层包装一起作废。
  2. **可观测性缺陷（已修）**：安装链上每个出口都与「一行都没有」同形——catch 把 `fushiLookupNotify` 撤成 void（原 `:5499`），DLL 再也不会读 `fushiLookupLastError`；前置条件探测只量前 8 轮（原 `:6014` `kLookupTjsPreconditionProbes`），kag 晚于这 240 帧出现就永远量不到；文本道回调丢掉 `TVPExecuteScript` 的结果（原 `:7589`）；文本道装完零接缝时写回 `fushiKagTextInstalled = seams`（=0，原 `:5876`），与「还没装」同形；接缝 / 主线程 id / host 函数 / 脚本登记都没有日志。
  - ひこうき雲 一例是否正是第 1 条（addHook 拒名）**尚未真机证实**：现有位只能证明 kag 与 addHook 存在、bootstrap 函数仍挂着，分不出「在等 TextRender 半就绪」与「安装体抛了」。新诊断行会直接给出答案。時間停止 一例从代码读不出必然失败点，交给新诊断定位。
- **[x] ① 已修复** — `fushiLookupInstallKagSeams` 逐个 try 挂 addHook，被拒的那一路单独退回 kag 实例方法包装（同一路不两边挂），被拒位记进 `fushiLookupKagSeamsRejected`；安装链加有界阶段诊断 `[FushiKiriBoot]`（`native/galgame_hook/hook/adapters/kirikiri_bootstrap_diag.h`，worker 侧 `LogKirikiriBootstrapPhases` `kirikiri_adapter.inc:8038`；TJS 阶段码 `fushiLookupBootstrapStage` / `fushiKagTextStage`，catch 写 `100 + installStage` `:5559`；零接缝写 -3 `:5972`；文本道回调记 execute-faulted `:7723`）。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/kirikiri_bootstrap_diag_test.cpp`（阶段码解码、变化才写、每阶段上限）；`native/galgame_hook/tests/kirikiri_lookup_source_guard_test.py::BootstrapStageDiagGuardTest`（每个提前 return 先写阶段码、catch 带出 installStage、addHook 逐个 try 且不重复挂、零接缝不写 0、回调不丢执行结果、落行只在 HookWorker，各带变异实测）。
- **备注**：真机复测待协调会话在志愿者机上做（本会话无真机权限）；两款游戏各需一份带 `[FushiKiriBoot]` 行的日志。
