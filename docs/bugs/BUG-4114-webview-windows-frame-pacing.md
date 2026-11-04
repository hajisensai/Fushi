## BUG-4114 · Windows WebView 纹理桥取帧相位抖动，歌词换句 / 滚轮看着掉帧
- **报告**：2026-11-04（用户：Windows 歌词模式换句滚动、滚轮滚动看着帧率低，怀疑 Impeller）
- **真实性**：✅ 真 bug，不是 Impeller，也不是页内掉帧。实测（同一套探针，下表）页内 rAF 稳定 60 Hz、WGC 实际交帧 ~57 帧/秒，但 Flutter 栅格回调只拿到 ~47 帧/秒、相邻两次取新帧间隔 p95 33.8 ms（每秒 ~10 次 >20 ms）。丢的是「WGC 帧 → Flutter 纹理」交接这一段：
  - `packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc:501`（旧 `StartPumpLocked`）+ `:784`（旧 `PumpFrameLocked`）：取帧挂在**平台线程的 `DispatcherQueueTimer`** 上（`:31` 请求 8.33 ms），平台线程与 Dart UI 线程合并（`flutter_windows_engine.cc` 默认 merged），tick 的相位与 DWM 帧无关、还随 Dart 负载漂移；`frame_available_()`（`:858`）落点在 Flutter 下一个 vsync 之前还是之后是随机的，于是一部分 Flutter 帧里两张 WGC 帧挤在一起（前一张被覆盖、丢掉），另一部分帧里没有新帧（重复上一张）——画面每秒约 10 次 33 ms 的顿挫。
  - `:23` `kNumBuffers = 1` + 旧 GPU 栅格回调直接从 WGC 帧缓冲本身拷（`texture_bridge_gpu.cc:421` `ProcessFrame(last_frame_, …)`，`last_frame_` 一直攥着帧池唯一的缓冲）。
  - BUG-3352 的 15.625 ms 取整在本机没有出现（tick p50 8.9 ms，系统计时精度已被其它进程抬到 1 ms），所以单把定时器周期 / 精度调好救不回来——E3 对照证实。
- **[x] ① 已修复** — 取帧从平台线程定时器搬到每个帧池自己的取帧线程（PR 见提交），按合成器时钟对齐 DWM 帧：
  - free-threaded 帧池（`CreateFreeThreadedCaptureFramePool`）、2 个缓冲；**不订阅 FrameArrived**（BUG-209 / BUG-163 的迟到事件 UAF 约束不变）。取帧线程 `RunFrameWorker` 用 `DCompositionWaitForCompositorClock`（Win11）同时等停止事件，没有该导出时退回按 DWM 刷新间隔重装的高精度可等待定时器；每次醒来排空帧池只留最新一帧。
  - 帧到即拷进 mailbox 的私有纹理（插件设备上、不共享句柄），拷完 `Flush` 后立刻释放 WGC 帧，缓冲当场还给 DWM。栅格线程的纹理回调持 mailbox 锁从私有纹理拷进**句柄固定**的共享纹理（BUG-3913 的容量纹理，句柄不变）。两次拷贝在同一立即上下文上，`GraphicsContext` 开 `ID3D11Multithread::SetMultithreadProtected(TRUE)`；取帧线程只发不依赖管线状态的 `CopySubresourceRegion` / `Flush`，不踩栅格线程 libplacebo 的管线状态。
  - 上报经 agile（FtmBase）`IDispatcherQueueHandler` `TryEnqueue` 回平台线程，`DeliverFrameLocked` 在平台线程上做全部原有判断：失活闸、`needs_update_` → `RecreateFramePoolLocked`、mailbox `seq` 去重、限帧 `ShouldDropFrame`、`IsProcessExiting` 总闸、`frame_available_()` → `MarkTextureFrameAvailable`。`post_pending` 合并投递，平台线程一忙也不会刷屏消息队列。
- **[x] ② 已加自动化测试** — 源码守卫按新不变式重写：`fushi/test/widgets/texture_bridge_stop_guard_test.dart`（禁旧定时器泵、要求 free-threaded 帧池 + 取帧线程 + join 顺序 + 平台线程上报）、`wgc_pump_tick_agile_guard_test.dart`（上报委托必须 agile、只捕获失活闸与 mailbox）、`wgc_pump_interval_guard_test.dart`（合成器时钟 / 高精度退回、`kNumBuffers >= 2`、等待必须超时）、`wgc_capture_logging_guard_test.dart` / `inappwebview_windows_native_guards_test.dart`（`worker-*` 生命周期日志、退役闭包序列 `worker-stop-start → worker-stop-joined → worker-stop-done → session-close → pool-close → retire-register`、退出总闸在 `DeliverFrameLocked`）、`fushi/test/media/video/web_video_shaders_test.dart`（栅格拷贝源改为私有纹理）。帧节奏本身没有可落地的自动化层（要 DWM 真合成 + 真 WebView2），靠下面的真 app 探针。
- **实测（Windows 真 app，`-Visible` 离屏 itest，Debug，歌词模式 300 句，换句 14 次 ×2 轮 + 合成滚轮 9 s ×2 轮；每格是两次独立运行）**

  | 指标 | 修复前 | E3 缓冲=2 | E3 缓冲=3 | E3 timeBeginPeriod(1) | 修复后 |
  |---|---|---|---|---|---|
  | E1 页内 rAF p50 / p95 / >20ms（滚轮） | 16.7 / 16.8 / 0～1 | 同 | 同 | 同 | 16.7 / 16.8～17.2 / 0 |
  | E2 取帧唤醒 p50 / p95 | 8.9 / 9.3 ms（UI 定时器） | 8.8 / 9.4 | 8.8 / 9.4 | 8.9 / 9.3 | 16.67 / 16.7～16.8 ms（合成器时钟） |
  | E2 WGC 交帧（滚轮） | 57.3 / 56.1 帧/秒 | 57.3 | 55.9 | 58.2 | 57.3 / 56.7 帧/秒 |
  | E2 一次唤醒排空 >1 帧 | 0 | 0 | 0 | 0 | 0～0.06 /秒 |
  | **E2 栅格取新帧（滚轮）** | **47.6 / 46.3 帧/秒** | 47.0 | 46.4 | 47.9 | **55.2 / 54.9 帧/秒** |
  | **栅格间隔 p95（滚轮）** | **33.8 / 33.8 ms** | 33.7 | 33.9 | 33.8 | **18.0 / 18.1 ms** |
  | **栅格 >20ms 次数（滚轮）** | **9.7 / 10.4 /秒** | 10.2 | 9.8 | 9.2 | **1.5 / 2.5 /秒** |
  | 栅格取新帧 / WGC 交帧（换句） | 23.7/27.9、24.6/28.0 | 24.6/28.7 | 23.5/27.4 | 24.2/28.3 | 27.9/28.2、27.7/28.0 |
  | 栅格 >20ms（换句） | 5.4 / 5.1 /秒 | 5.2 | 5.6 | 5.2 | 1.7 / 2.0 /秒 |

  E3 结论：取帧本身不缺帧（WGC 已 ~57 帧/秒、单缓冲也没有排队），加缓冲、提计时精度都不改变栅格侧；改变的只有「取帧相位与 DWM 对齐」。修复后剩下的 ~2 次/秒 >20ms 与 WGC 自己的 `cap_gt20`（~1～1.6 次/秒，DWM 那一帧没出新内容）同量级。
  - 探针：`packages/flutter_inappwebview_windows/windows/utils/wgc_pacing_probe.h`，**保留为默认关闭的诊断开关**（环境变量 `FUSHI_WGC_PACING_PROBE=1` 才采样，关闭时每个埋点只读一次静态 bool，无锁无分配），每秒向 `logs/native/wgc_capture.log` 写一行 `evt=pacing`。保留理由：帧节奏问题只能在真 DWM 合成下测，下次排查不用再临时埋点。E3 的缓冲数 / 计时精度旋钮与页内 rAF 探针 itest（需要往歌词页注入 JS 的临时 debug 钩子）**未提交**。
- **高刷新率（144 Hz 显示器，2026-11-05 用户改回 144 Hz 后复测，同一探针）**：
  - 只修取帧线程时：页内 rAF 144 帧/秒（6.9 ms）、取帧线程唤醒 6.94 ms 已跟上，但 **WGC 交帧恒为 20.83 ms**（每 3 个刷新周期一帧，滚轮 44～48 帧/秒），栅格随之 ~47 帧/秒。根因：WGC 会话默认把交帧节流在约 60 Hz，60 Hz 屏上节流线等于刷新率所以看不出来。
  - 修：`texture_bridge.cc` 建会话后、`StartCapture` 前 QI `IGraphicsCaptureSession5`（Win11 24H2+，IID `67c0ea62-1f85-5061-925a-239be0ac09cb`，取自系统 `Windows.Graphics.winmd`；编译 SDK 10.0.22621 没有该接口，手写 ABI 声明，SDK 升到 26100 后换头文件），`put_MinUpdateInterval(1 ms)`。没有该接口的系统保持默认节流，记 `min-update-interval-unsupported`。守卫 `wgc_pump_interval_guard_test.dart`。
  - 结果（`fp-144-minint-1`）：滚轮 WGC 交帧 130～144 帧/秒、栅格取新帧 122～137 帧/秒，栅格间隔 p50 7.0 ms / p95 8.3 ms，>20 ms 约 1 次/秒；换句时栅格 p50 7.0 ms / p95 8.6～9.1 ms。
  - 其它平台（同日核对）：Android WebView 是原生视图，`HighRefreshRate.java` 为主窗口 / 查词弹窗 / 悬浮窗请求最高刷新模式；iOS Release / Profile 构建时把 `CADisableMinimumFrameDurationOnPhone` 改成 true（Debug 保持 false，BUG-642），macOS WKWebView 原生合成；Linux WPE 按显示器刷新率设目标帧率（`flutter_inappwebview_linux/linux/in_app_webview/in_app_webview.cc:1291`）。都不经过本纹理桥。
- **浏览器滚动上报减负（同 PR，接手自 `pr/browser-scroll-smooth`，全平台）**：`fushi/lib/src/web_browser/tab_view/web_browser_page_scripts.dart` 的滚动脚本原来每帧过一次 JS 桥报 `(y, dy)`，滚动最忙时与绘制抢线程（Android Hybrid Composition 下尤甚）；改成只在收起状态机可能翻转时报（同向累计越过阈值一次、到顶一次，按下 / 换容器 / 停顿 250 ms 后重新允许）。测试 `fushi/test/web_browser/web_browser_scroll_report_test.dart` 用 node 真跑脚本，四条逐帧轨迹上「逐帧上报」与「新上报」每一帧的收起结果完全一致。
- **生命周期设计（逐条）**
  - **创建**：`CreateAndStartFramePoolLocked` 建 free-threaded 帧池 → 注册表 `Retain` → `CreateCaptureSession` → `StartCapture` → `StartFrameWorkerLocked`（建手动复位停止事件、失活闸 `WgcPumpCallbackState`、agile 上报委托，最后起 `std::thread`；`std::system_error` 记 `worker-start-fail` 并走 `RetireFramePoolLocked("worker-start-fail")`，不吞）。取帧线程只持有 `WgcFrameWorkerShared`（帧池 / DispatcherQueue / 上报委托 / mailbox / 设备与上下文的引用），**从不持有 TextureBridge**。
  - **尺寸变化**：`NotifySurfaceSizeChanged` 置 `needs_update_` 后 `PostDeliveryLocked` 投一次上报，让平台线程即使没有新帧也及时处理；`DeliverFrameLocked` 里 `RecreateFramePoolLocked` 放得下就不重建（BUG-3913 容量），放不下则先完整退役旧帧池（含 join 旧取帧线程）再建新的。mailbox 跨代沿用，私有纹理按帧纹理尺寸重建（不共享句柄，引用计数在插件设备上平衡，不是 BUG-3913 那类系统侧残留）。
  - **销毁 / 退役**（`RetireFramePoolLocked` → `StopFrameWorkerLocked`）：① `InvalidatePumpCallback` 失活上报（已排进 DispatcherQueue 的上报执行时 no-op，记一次 `deliver-late-noop`）→ ② `SetEvent(stop)` → ③ `join` 取帧线程（取帧线程等待时钟时同时等停止事件，一个节拍内返回；它只拿 mailbox 锁、不拿桥的 `mutex_`，所以持 `mutex_` 的 join 不会死锁）→ ④ 清 `worker_shared` / `pump_state` → `state-inactive` → `FinalizeFramePoolLifetime`（Close session → Close pool → 注册表 `MarkRetired`）。join 之后才 Close：取帧线程与 Close / 析构之间有确定先后。`WgcFramePoolLifetime` 析构里还有一道防漏 join（记 `worker-join-in-dtor`），正常路径永远走不到；实测日志里没有出现。
  - **BUG-209 / BUG-163 UAF**：不订阅 FrameArrived，没有任何 WinRT 事件委托挂在帧池上，迟到的 deferred FirePresentEvent 路径不存在；上报委托只捕获失活闸与本代投递标记（`shared_ptr`），桥析构后迟到的上报只看到失活闸。`~CustomPlatformView` 先 `SetOnFrameAvailable(nullptr)` 再 `Stop()` 再注销纹理的顺序不变。
  - **BUG-3913 实例复用 / 停放**：停放不动桥；复用时 `Start()` 先 `RetireFramePoolLocked("start")`（会 join 旧线程）再建新帧池，mailbox 的 `seq` 单调递增、`delivered_seq_` 只在平台线程读写，复用后的第一帧照常上报。
  - **进程退出**：`SetProcessExiting()` 置位后 `DeliverFrameLocked` 在 `frame_available_()` 前早返回；`prepareForProcessExit` 里 `webViews.clear()` 析构所有桥（逐个 join 取帧线程）之后才释放 `graphics_context_` / `compositor_` / DispatcherQueueController（BUG-255 顺序不变）；取帧线程自己持有设备 / 上下文引用，即使顺序被打乱也不会用到已释放的设备。
- **审查后补修（2026-11-05，合 develop 时）**
  - **投递合并标记按代持有**：`post_pending` 原挂在桥共用的 `WgcFrameMailbox` 上，而 `deliver_handler` 每代一个。旧一代 handler 已排进 DispatcherQueue、平台线程同一任务里 Stop→Start / 退役重建后，新一代首帧 `exchange` 见 true 不投递，旧 handler 随后清标记再在失活闸上 no-op——新帧 `seq` 已推进却没有 `frame_available_`，静态页要等别的原因重绘才显示。改为 `WgcFrameWorkerShared::post_pending`（`shared_ptr<atomic<bool>>`，handler 按值捕获同一份），`PostDeliveryLocked` 与取帧线程都用当前代的标记。
  - **取帧线程不静默退出**：`FrameClock::Wait` 退回定时器 / 纯 sleep 分支里等待失败（非停止事件）时记 `worker-clock-exit`（含返回值与 `GetLastError`），WebView 冻结在最后一帧时日志可查。
  - **COM 释放顺序**：`RunFrameWorker` 在 `CoUninitialize` 之前 `shared.reset()`，线程持有的帧池 / DispatcherQueue / 委托 / 设备引用在公寓仍有效时释放。
  - 守卫：`texture_bridge_stop_guard_test.dart` 第二条用例、`wgc_pump_tick_agile_guard_test.dart`（捕获列表改为 `[pump_state, post_pending]`）。
  - 滚动阈值 `kWebBrowserCollapseScrollThreshold` 移到 `fushi/lib/src/web_browser/web_browser_scroll_collapse.dart`，页内脚本不再反向 import pages 层。
- **备注**：
  - BUG-163 第四修（free-threaded 帧池 + FrameArrived）当年 Release 下 WebView 不出字，根因没留下。本修复与它的差别：不订阅事件、帧在取帧线程先拷进私有纹理、上报回平台线程、设备开多线程保护。Release 整包实测（2026-11-05，144 Hz，开发版数据根）：用户确认阅读器正文、歌词模式、查词弹窗、应用内浏览器都正常出字、滚动顺滑；同进程日志 27 次 `min-update-interval-set`、零 `frame-getfail` / `createSession-fail` / `worker-start-fail`，最忙的几秒 WGC 交帧 144～145 帧/秒、栅格取新帧 143～145 帧/秒、栅格间隔 p95 7.9～8.2 ms。
  - 实测在开发机 60 Hz 显示器上做；高刷新率显示器上合成器时钟按刷新率走，取帧线程唤醒频率随之升高（每次唤醒只是一次 `TryGetNextFrame`，无帧时不拷贝）。
  - 修复前后 itest 运行目录（不入库）：`fushi/.codex-test/windows-itest/fp-before-{1,2}`、`fp-e3-{buf2,buf3,timerres}`、`fp-after-{1,2}`。
