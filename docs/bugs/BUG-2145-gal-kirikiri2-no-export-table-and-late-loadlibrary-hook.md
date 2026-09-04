## BUG-2145 · KiriKiri2 无导出表 + 插件早于 LoadLibrary hook link：两条 exporter 路径同时静默落空，游戏内查词整条不装
- **报告**：2026-09-05（自查：经典 KAG3 第二样本真机复测）
- **真实性**：✅ 真 bug，根因 `native/galgame_hook/hook/adapters/kirikiri_adapter.inc:6599`（`ObtainExporter`）与同文件 `TryHookKirikiriVoiceStream` 的两条路径都不成立时无第三条

  **怎么发现的**：[[BUG-2121]] 四段修完、Fate/stay night[Realta Nua] 真机 `sensor_installed` 已亮之后，
  拿 engine-support 里点名的**负样本**フタマタ恋愛 Ver1.00（KiriKiri2/BCB，classic KAG3）复测。
  结果传感器**仍然不装**，而且 `xaudiodiag2=0x0000000c` —— 12 个 `KirikiriLookup*` 位**一个都没亮**，
  连 `MainWindowMissing` 都没有。这说明卡点在 `PollKirikiriLookupInstall` 的第一行
  `if (g_stop || g_lookup_exporter == nullptr) return;`：整条查词安装路径根本没被进入过。

  **根因（真机量出，不是推断）**：拿 exporter 只有两条路径，这个 build 上两条同时不可能成立。
  - ① exe 直取 `GetProcAddress(exe, "TVPGetFunctionExporter")`：`reserved_luna` 的 `0x1000000` 亮着。
    进一步用 `ReadProcessMemory` 读**运行期**的 PE 头确认：主模块的**导出目录 RVA = 0**，磁盘上那份也是 0。
    所以这不是 [[BUG-2118]] 那种"查早了"的时序问题——**这个 build 根本没有导出表**，① 永远不可能成立。
  - ② hook `LoadLibrary` → 截插件 `V2Link`：`reserved_luna` 的 `0x2000000`（hook 已装）亮着，
    但 `0x4000000`（经 V2Link 拿到 exporter）**不亮**。`EnumProcessModulesEx(LIST_MODULES_ALL)` 数出
    **19 个插件已经加载完毕**（KAGParser / ExtKAGParser / hutamata.tpm / wuvorbis / dirlist …），
    全部在 boot 首帧 link 完，早于本 worker 装 hook。V2Link 一辈子只被引擎调一次，事后再 hook 也永远不会触发。

  两条路径都是**静默 return**，症状与"这个引擎不支持游戏内查词"完全同形——engine-support.yaml 里
  2026-08-19 那条负向实测（"classic KAG3 样本上 lookup_diag 全程 0x00000000"）记的就是这个现象，
  当时归因为"缺 textrender.dll"，实际与 textrender 无关。

- **[x] ① 已修复** — 加**第三条 exporter 路径**：从**已经 link 完**的插件数据段反查 exporter 单例。
  判据：exporter 是引擎单例，引擎把同一个指针传进每个插件的 `V2Link`，各插件 tp_stub 存进自己的静态变量，
  于是"在所有已 link 插件的可写节里都出现过的同一个值"就是它。真机实测：19 个插件 → 交集 28 个值 →
  过形状门（首字是可读虚表 + 前 8 个槽全落在 exe 映像内）后**唯一剩 1 个**。
  形状门只负责收敛，**判定靠真调用**：拿 `IStream * ::TVPCreateIStream(const ttstr &,tjs_uint32)` 去
  `QueryFunctionsByNarrowString` 查一次，成功才采用；跨编译器边界按 [[BUG-2144]] 用 SEH 包住。
  纯判据落在新文件 `hook/adapters/kirikiri_exporter_scan.h`（`LooksLikeExporter` / `IntersectWritableWords` /
  `CollectWritableWords`，含 `kMinPlugins`/`kMaxCandidates`/`kMaxSectionBytes` 三个上限——判据失效时**放弃**
  而不是截断后接着猜）；接线在 `kirikiri_adapter.inc` 的 `ScanLinkedPluginsForExporter`，只在 ① 落空后跑、
  次数上限 12 次。诊断三态 `kXAudioDiag2KirikiriExporterScanRan` / `ScanNoCandidate` / `ScanAdopted`
  （`xaudio_diagnostics2` 至此 32 位用尽，下一族必须另立新字）。

- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/kirikiri_exporter_scan_test.cpp`（CTest
  `fushi_kirikiri_exporter_scan_test`）。形状门用**真内存 + 生产同一个 `DefaultReadableSpan`**（真 VirtualQuery）
  验：良构候选被接受、任一虚表槽出界被拒、探测深度真的不止首尾一个槽、不可读候选与不可读虚表都靠
  VirtualQuery 挡住而不是解引用崩掉；交集侧验少于 `kMinPlugins` 拒绝、只留全模块公共值、空交集算拒绝
  而非空成功、零值与不足一个字的尾巴不入表。

- **真机复验（2026-09-05，フタマタ恋愛 Ver1.00，helper x86 `a180314c…`，双架构 CTest 62/62）**：
  injector 直驱 `--launch --hold` + `fushi_voice_lookup_probe <pid> 12 1000`。
  修前 `xaudiodiag2=0x0000000c`（12 个 `KirikiriLookup*` 位一个都不亮）、`lookup_diag=0xB0000000`（无 sensor）。
  修后 `xaudiodiag2=0xa194000c`，经 `galhook.py explain-diag` 符号化为
  `ExporterScanRan` | **`ExporterScanAdopted`**（**无** `ScanNoCandidate`）| `SeamArmed` | `SeamFired` |
  `BootstrapStarted` | `BootstrapFired`；`lookup_diag=0xB0000141` = `sensor_installed` | `expression_ready` |
  `classic_patch_installed`。`reserved_luna` 从 `0x03000101` 变成 `0x031f0101`（exporter 到手、语音流 hook 装上）。
  游戏未崩、无 `#32770` 对话框。`classic_processch_fired` 未亮属预期：这一局停在标题画面，没走过台词。
  这条同时推翻了 engine-support.yaml 里 2026-08-19 那条负向实测的**归因**——当时记的"因为不带
  textrender.dll 所以经典 KAG3 装不上传感器"是错的，真因是本 bug 加 [[BUG-2121]] 的四段。

- **备注**：真机复验状态见台账 `docs/plans/2026-09-04-gal-ceshi-batch-classic-kag3.md`。
  与 [[BUG-2121]]（主窗形状 / 轮询语义 / addHook 前置条件）、[[BUG-2144]]（BCB 异常穿透 MSVC catch）、
  [[BUG-2118]]（早注入灌导出表）同属经典 KAG3 查词链上的相邻边界，但根因互不相同、修复互不替代。
