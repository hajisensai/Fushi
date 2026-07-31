## BUG-1267 · 捕获窗口(attach)模式硬编码不装 LunaHook PC hooks，Unity 游戏中途对接抓不到文本
- **报告**：2026-07-31（用户：helper 本身支持中途注入，但 hibiki 客户端没法中途对接；
  只能自己用 LE 启动后在 hibiki 里捕获窗口。用户手动跑 `hibiki_voice_injector.exe --pid 42504`
  的输出为 `[session] reusing live hook mapping pid=42504 text=0 audioBytes=0` /
  `[unity-audio] resource extractor runtime missing` / `OK hooked pid=42504 hooked=1`）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/mining/gal_hook_session_controller.dart`
  attach 两个调用点（`startAttachedCapture` 与 `_retryEngineAttach`）修复前均写死
  `lunaPcHooks: false`
- **[x] ① 已修复** — `hibiki/lib/src/mining/gal_hook_session_controller.dart`

  用户的判断需要更正一半：能力在 native 侧是齐的（injector 的 `--pid` 中途注入存在，
  用户手动跑也确实 `hooked=1`），客户端也**有** attach 模式（`buildEngineHookInjectorArguments`
  会发 `--pid`）。真正缺的是 `--luna-pchooks`。

  `shouldUseLunaPcHooksForExecutable`（`hibiki/lib/src/mining/galgame_audio_source.dart:729`）
  的判据只认 exe 路径：basename 白名单（manosaba / siglusengine），或同目录有
  `UnityPlayer.dll` **且**有 IL2CPP（`GameAssembly.dll` / `global-metadata.dat`）或 Mono
  证据。launch 路径有 exe 路径可喂，attach 路径没有——于是两个调用点直接写死 `false`，
  把**「判据取不到」实现成了「判为否」**。后果：Unity/IL2CPP 与 Siglus 目标只要不是由
  Hibiki 亲自拉起，就永远不补装 LunaHook 通用 PC hooks，文本线程一条都建不起来，
  injector 报 `text=0`——正是用户看到的「捕获上了但什么都不出」。用户截图里的
  `[unity-audio] resource extractor runtime missing` 也印证目标就是 Unity 游戏。

  修法：exe 路径本来就能从 PID 拿到。新增 `GalTargetImagePathProbe`（默认实现复用既有的
  `GalgameWindowsProcessProbe.processImagePath`，即 `QueryFullProcessImageNameW`，不再写
  第四份 FFI 封装），attach 两处改走 `_lunaPcHooksForPid(pid)`，与 launch **共用同一套
  判据**。查不到路径时返回 false，与修复前行为一致——探测失败不会比旧版更糟。

  `GalgameWindowsProcessProbe` 会 `DynamicLibrary.open`，故默认实现懒实例化并缓存，非
  Windows 直接返回 null，不影响 Linux CI。

- **[x] ② 已加自动化测试** — `hibiki/test/mining/gal_attach_pchooks_loopback_settle_test.dart`

  四条，全部经 attach 真实入口 `startAttachedCapture`，断言工厂实际收到的 `lunaPcHooks`：
  Unity/IL2CPP 目录 → true；非 Unity → false；只有 `UnityPlayer.dll` 而无 IL2CPP/Mono
  证据 → false（判据两者缺一不可）；PID 查不到 exe → false 且不崩。

  变异实测已做：把 attach 调用点改回 `lunaPcHooks: false` → Unity 那条如期变红。

- **备注**：本轮只修了「中途对接抓不到文本」。用户同时报告的「hibiki 里一键启动会报
  fatal error」**未处理**——尚未拿到报错原文，无法确认是否即
  `native/galgame_hook/hook/il2cpp_thread_scope.h` 记录的 Unity IL2CPP
  `"Fatal error in GC: Collecting from unknown thread"`（该守卫代码已存在，但 helper 是
  单独发布的，用户侧版本可能落后于主包）。需要用户提供报错文本后另开 BUG。
