## BUG-2769 · Windows 触屏在 galgame 里点按不触发单击查词
- **报告**：2026-09-29（用户：W1ght；Windows 触屏，galgame 场景，同批报告 BUG-2768 / BUG-2770）
- **真实性**：✅ 真 bug（本条只在 Siglus 十参数/十六参数（采样型）家族上验证与修复；其它引擎的触屏单击见备注）。
  触摸点按被 Windows 提升成背靠背的 `WM_LBUTTONDOWN`/`WM_LBUTTONUP`。Siglus 采样型家族的查词提交**只**由
  精确 GetKeyState 采样器完成（`native/galgame_hook/hook/adapters/siglus_lookup_click_policy.inc`
  `FilterSiglusLookupLeftButtonSample` 的 `decision.submit`），它每帧只采样一次，两条消息落在两次采样之间，
  采样器永远看不到按下；而引擎 WM 汇点（同文件 `ConsumeSiglusLookupInputMessage`）在 down 命中字形时已经把
  点击吞掉并挂上过滤闩——于是一次触摸点按**既不查词、也不推进**，看起来就是「触屏点了没反应」。
  八参数家族早因同一原因改为在 WM 汇点内完成整次事务（`siglus_lookup_message_transaction.inc` 头注释），
  采样型家族一直没有。
  - **修复前对照（真机）**：修复前 DLL（点击代码与上游 develop 一致），读档停在台词，触摸点按「し」「う」两次 →
    probe `hits` 始终 0、`text_writes` 不变（被吞），悬停框随触点移到「し」上（几何已就绪）；同一台词鼠标点字 → `hits` +1。
- **[x] ① 已修复** — 采样型家族的 WM 汇点在 down 命中时记下冻结的载荷（`g_siglus_lookup_message_tap`，
  复用 `SiglusLookupMessageTransaction`）；采样器只要看到这次按压处于按下态就撤销它（`CancelSiglusLookupMessageTap`，
  由采样器照旧负责唯一一次提交）；只有采样器始终没看到的短按压，才在 WM up 时经与八参数事务同一套复核
  （纪元、线程、前台、窗口、实时视图、原生输入准入、`SiglusLookupPayloadMatchesPublishedTarget`）后提交。
  没有加延时/重试，鼠标长按路径与提交次数不变。提交：见 PR。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/siglus_lookup_message_transaction_test.cpp`
  `TestSampledFamilySubFrameTap`（十参数与十六参数：WM 单独 down/up 提交恰好一次、载荷身份正确、随后的 up 采样仍被遮蔽；
  未命中/弹窗/几何代数变化都不提交）与 `TestLostUpAndOtherFamilies`（采样器看到按下时仍只由采样器提交一次、WM up 不重复）；
  `tests/siglus_lookup_input_diagnostics_test.cpp` `TestMessageAndSurfaceBoundaries` 同步为新契约。
  x86 ctest 118/118、x64 ctest 114/114。
- **真机验证**（2026-09-29，CLANNAD Steam `SiglusEngine_Steam.exe` SHA-256 `116A1B6A…DEA2D`，x86，本分支 hook DLL
  SHA-256 `5386A56B…A624`；触摸用 `InjectTouchInput`（PT_TOUCH，按下→50ms→抬起）真实注入，系统自行提升为鼠标消息）：
  - 台词「こいつら、しつこいんだ」触摸点按 → `hits` 0→1，命中字序号 4，查词框画在被点的字上，`text_writes` 不变（不推进）。
  - 台词「てめぇら、うるせぇぞ」触摸点按「う」→ `hits` +1、字序号 6，不推进。
  - 选项画面触摸点按 → 按 BUG-2768 交给游戏选择（见该条）。
  - 真 Fushi 宿主（本分支 Debug 构建 + `gal_realgame_driver_itest.dart` 附着，hook 为本分支 dist SHA-256 `5D2814DF…48E8`，
    `attached=activeNative`）：触摸点「ら」→ 游戏内查词卡弹出、台词不推进；卡片的触摸滑关见 BUG-2770。
- **备注**：
  - 只改了 Siglus 采样型家族（引擎级，按调用约定家族判定，无 exe 哈希特判）。KiriKiri / SGRE / 通用覆盖层等其它引擎的
    触屏单击没有在本机真触摸下逐一验证；SGRE 只认物理 DirectInput（见 galgame 真机驱动台账），触摸大概率同样进不去，
    需各自按引擎开任务。
  - 本机 Fushi 宿主的 `WH_MOUSE_LL` 路径未改动。
