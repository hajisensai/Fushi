## BUG-2121 · FindGameMainWindow 排除所有有 owner 的窗口：BCB VCL 窗体被隐藏 TApplication own，KiriKiri2 查词安装 / exe 直取门 / overlay owner 整局静默失败
- **报告**：2026-09-04（用户：ceshi 批量适配。Fate/stay night[Realta Nua]（KiriKiri2 2.31/BCB）真机第三轮：文本/音频三门全通，但 `lookup_diag` 整局零 sensor 位；前台准入、点击风险已逐层排除，收敛到「native 安装本身静默失败」）
- **真实性**：✅ 真 bug。根因 `native/galgame_hook/hook/lookup_overlay_window.inc:231`（改前）`if (GetWindow(window, GW_OWNER) != nullptr) return TRUE;`——Borland VCL 把每个 TForm 建成 `Application.Handle`（隐藏、0x0 的 TApplication 窗）的 owned window，`TTVPWindowForm` 因此永远不入选，`FindGameMainWindow()==nullptr`，三处下游一起静默死掉：① `kirikiri_adapter.inc` `ResolveKirikiriEngineMainThreadId()` 返回 0 → `EnsureLookupMainThreadSeam` 不挂 `WH_GETMESSAGE` 接缝、`RunKirikiriLookupInstallOnMainThread` 在线程身份那行 return，传感器永不安装；② BUG-2118 的 exe 直取 exporter 门 `FindGameMainWindow() != nullptr` 永不开（真机 decdiag 0x10000 整局不亮与此一致）；③ `lookup_overlay_window.inc` overlay owner 为空。安装路径上 9 个静默 return 没有任何 diag 位，症状与「这个引擎不支持」完全同形（engine-support.yaml 2026-08-19 的负向测量就是这么记的）。辅证：`%TEMP%\krkr_*\dirlist.dll`（Fate RN 自己 `Plugins.link` 的 krkr2 插件）tp_stub 明文 `void ::TVPExecuteExpression(const ttstr &,tTJSVariant *)` / `void tTJSVariantString::Release()` 与我们 `QueryFunctionsByNarrowString` 的串逐字相同，「BCB 导出名不同」假说排除；主 exe 带 `adata`（ASProtect）段，静态扫不到导出名，只能运行期看位。
- **[x] ① 已修复** — `native/galgame_hook/hook/game_main_window.h`（新，唯一判据：本进程可见顶层窗口里客户区面积最大者；owner 只排除「被**可见**窗口 own」的——对话框/工具提示/overlay 仍排除，隐藏 owner 不算）；`lookup_overlay_window.inc` 改为转发；`dll_main.cpp` 文件作用域引入。安装路径可见化：`kirikiri_adapter.inc` 的 `EnsureLookupMainThreadSeam` / `LookupMainThreadSeamProc` / `RunKirikiriLookupInstallOnMainThread` 7 个 bail/里程碑点打 `xaudio_diagnostics2`（第二引擎诊断字，`lookup_diag`/`reserved_luna` 已满）粘滞位 `kXAudioDiag2KirikiriLookup{MainWindowMissing,SeamArmed,SeamHookFailed,SeamFired,ExportQueryFailed,ExpressionQueryFailed,BootstrapStarted}`（`voice_hook_ipc.h` 0x20000..0x800000）；`adapter_registry.inc` 陈旧的「经典 KAG3 装不上」注释改正（BUG-2116 后已可装）。提交 `9661fa4e51`（分支 `worktree-gal-kirikiri-classic-kag3`）。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/game_main_window_test.cpp`（真 Win32 窗口、屏幕外 NOACTIVATE：隐藏 owner + owned 可见窗体 = VCL 形状必选中；被可见主窗 own 的更大对话框仍排除；owner 隐藏但自身隐藏的窗排除；异 pid 为空），双架构 CTest 58/58；变异实测：改回「有 owner 就排除」→ 仅 VCL 用例红，还原后绿。源码守卫 `tests/kirikiri_lookup_source_guard_test.py` 规则 7 改指向头文件，新增「owner 排除须以 owner 可见为条件」「`.inc` 只许转发不许再抄判据」两条不变式 + 5 条变异，139/139。
- **备注**：真机复验（2026-09-04 深夜，桌面空闲窗口）**第一段已通过**，并沿同一条失败路径又量出三段，都在本 bug 内修完。

  **第一段复验通过**：helper `c892859b…` 起 Fate RN，`xaudiodiag2` 亮 `SeamArmed(0x40000) | SeamFired(0x100000)`——修复前这两位整局不亮。VCL 实测形状是 `cls=TApplication vis=True client=0x0`（**可见但 0x0**，不是原先假设的隐藏窗；任务栏按钮挂在它上面），故判据再收紧成「只排除被**可见且客户区非空**的窗口 own 的」，`game_main_window_test.cpp` 与守卫同步加这一形状。

  **第二段：`TryHookKirikiriVoiceStream` 返回值语义错**。它返回 `ll_installed`（LoadLibrary hook 装没装，恒 true），registry 据此**立刻停轮询**；而 KiriKiri2/BCB 的插件全在 boot 首帧内 link 完（真机：8 个插件同一 tick 的连号 `%TEMP%\krkr_*` 目录，全部早于 worker 装 hook），V2Link 路径永远等不到 exporter，唯一确定的路径是 exe 直取，而它要等主窗——于是 exe 直取只在启动瞬间（主窗还没出现）评估过一次，两条路一起静默死掉。改为 `return g_voice_installed != 0`。守卫 `find_voice_stream_poll_stopping_before_exporter` + 3 变异。

  **第三段：Borland 异常穿透 MSVC `catch(...)`** → 拆出独立的 [[BUG-2144]]（游戏弹致命错误框并强制写用户快速存档，影响所有 BCB 构建的 KiriKiri2 游戏），已修并真机复验。

  **第四段：`kag.addHook` 被写进 bootstrap 前置条件**。三个新诊断位在真机上给出唯一解（`xaudiodiag2=0x0d94000c`）：`TjsBootstrapFnAlive` ✓（脚本跑完、bootstrap 函数还挂着说明从没成功进过安装体）、`KagObjectReady` ✓、**`KagAddHookReady` ✗**。`addHook` 是 KAGEX 系框架的扩展点，TYPE-MOON 的 KAG 3.25 没有；那条 `typeof global.kag.addHook != "Object") return;` 排在 KAGEX 缺席门**之前**，于是 [[BUG-2116]] 的整条经典逐实例分支从来就是死代码——与注释里对 TextRender 担心过的是同一个错误。修复：前置条件只认 `global.kag`；输入接缝在 installStage 40 由新函数 `fushiLookupInstallKagSeams` 分叉——有 `addHook` 就用它，没有则用同一套 TJS2 逐实例包装（对象从 MessageLayer 换成 `kag` 窗口实例：`onPrimaryClick`/`onMouseMove`/`onMouseWheel`/`onKeyDown`，每个 fail-open 转发原方法），一条都挂不上时主动抛异常走 install-failed 分支留证据，不留假成功。守卫新增 `find_addhook_in_bootstrap_precondition`，前置条件/阶段序列/接缝安装三条既有断言与 clean 语料、2 条变异锚点同步更新，145/145 绿。

  **第四段真机复验已过（09-05 02:45，第五轮）**。合并 develop 后重建的 helper x86 `4f66bce2…`（双架构 CTest 61/61）+ injector 直驱 `--launch --hold` + `fushi_voice_lookup_probe <pid> 10 1000`：
  `lookup_diag=0xB0000541` = `sensor_installed` | `expression_ready` | `classic_patch_installed` | `classic_processch_fired`（后两位证明 [[BUG-2116]] 的经典逐实例补丁真的装上并触发了，不再是死代码）；
  `xaudiodiag2=0x0194000c` 经 `galhook.py explain-diag --xaudiodiag2` 符号化 = `SeamArmed` | `SeamFired` | `BootstrapStarted` | `BootstrapFired`（外加与本 bug 无关的既有低位 `SgreAnchorsUnresolved` | `LeafProfileUnmatched`），**无** `BootstrapFaulted` / `ExportQueryFailed` / `ExpressionQueryFailed` / `MainWindowMissing`；
  `text_hooked=1 luna_active=1 text_events=8 voice_clips=47`；进程内可见窗口只有 `TTVPWindowForm` + `TApplication`，**没有 `#32770` 致命错误框**（[[BUG-2144]] 的 SEH 边界随之复验）。
  四段至此全部真机复验通过，游戏内查词传感器在经典 KAG3 / KiriKiri2-BCB 上装得上了。

  **审查补修（2026-09-05 集成时，7 条必须修）**。这四段落地后集成审查又沿同一条安装路径查出
  七个问题，都在合入 develop 前修完，双架构 CTest 63/63、源码守卫 163/163（含 8 条新变异自测）：

  1. **安装失败仍报 `sensor_installed`**。DLL 判「传感器活了没」的唯一判据是
     `typeof global.fushiLookupNotify == "Integer"`，而它在 installStage 0 就建立；第四段新加的
     「一个接缝都没挂上就抛异常」那条 throw 走 catch 分支后**没有撤销它**——于是 host 读到的仍是
     sensor_installed + 几何 provider 被认领 + UI 显示查词就绪，点字永远没有卡片，且没有任何一位
     说明卡在哪。这正是本 bug 通篇在消灭的「同形失败」，只是换了个位置又长回来。修复：catch 里
     `global.fushiLookupNotify = void;`，DLL 退回每 30 帧一次的 typeof 探测并继续记前置条件位。
  2. **主线程接缝永不卸载**。`g_lookup_install_requested` 全文件只置 1、从不清 0，于是钩子过程里
     `done` 判据的「或请求撤销」那一半恒为假，退化成「只有 bootstrap 真起来了才卸」。bootstrap
     起不来的机器（例如 `ExportQueryFailed` 那种非标准 build）上，`WH_GETMESSAGE` 会挂在游戏主
     线程上直到进程退出、每条消息跑一次完整安装尝试，用户关掉查词也停不下来。同处 `HHOOK` 是普通
     非原子指针而装/卸分属两个线程。修复：`PollKirikiriLookupInstall` 在前置条件不成立时撤销请求并
     摘接缝，句柄统一走 `InterlockedExchangePointer`（新 `ReleaseLookupMainThreadSeam`）。
  3. **classic 位 3 读不到**。`fushiLookupSweepClassicLayers` 置的位 3（至少挂上过一个实例）DLL 侧
     从没读过，而它恰恰是当前唯一还没答上的问题——真机两个样本都没有 `classic_geometry`，分不出
     「分支根本没跑到」和「跑到了但 `kag.fore.messages` 不是标准 KAG3 结构」。`lookup_diag` 与
     `xaudiodiag2` 两个字都已用满，故落在 `reserved_luna` 的新具名位
     `kDiagKirikiriClassicLayerPatched`（0x40），不动协议布局、不动 `kSharedVersion`；
     `galhook_evidence.py` 的 lunadiag 段自动符号化它。
  4. **逐实例补丁的幂等标记写晚了**（见 [[BUG-2116]]）。
  5. **exporter 候选盲调后没校验回填值**（见 [[BUG-2145]]）。
  6. **`reserved_luna |= 0x10000` 的语义被第三条路径污染**（见 [[BUG-2145]]）。
  7. **SEH 边界漏了 alloc/release**（见 [[BUG-2144]]）。

  七条各配一条源码守卫 + 变异自测（`tests/kirikiri_lookup_source_guard_test.py` 的
  `ReviewFixGuardTest`，变异跑在真文件副本上）。第 7 条的守卫当场又抓出一处我自己漏掉的裸
  `g_lookup_release_string(script)`（bootstrap 回调里，跑在引擎主线程的连续事件上）。
