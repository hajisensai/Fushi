## BUG-3888 · video-subtitle-list-toggle-jank
- **报告**：2026-10-30（用户：Windows 本地视频，push-aside 字幕列表打开和关闭都很卡）
- **真实性**：✅ 真 bug（沿代码路径确认，未做真机帧时测量）。字幕列表列宽走 200ms `AnimatedSize`（`fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart` `_subtitleJumpSidePanel`），画面区每帧换一次宽度；而 `fushi/lib/src/pages/implementations/video_fushi/layout.part.dart` `_buildVideoControls` 用裸 `LayoutBuilder` 把**整棵** controls 子树（控制条 / 字幕 overlay / rail …）建在回调里（7970c81228 控件按窗口分档引入），约束一变就整棵重建——开、关各重建几十次整套 chrome。关闭时面板内容立即卸载、只剩宽度收缩，所以开关两个方向同样卡。
- **[x] ① 已修复** — 新增 `VideoControlsDensityBuilder`（`fushi/lib/src/media/video/video_controls_density.dart`）：只在密度档变化、父级重建或小窗表面变化时重建子树，约束连续变化但档位不变时原样返回上次的 widget 实例；子树包在自己的 `Builder` 里，InheritedWidget 依赖变化仍单独触发重建。`_buildVideoControls` 改用它。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_controls_density_test.dart`（`VideoControlsDensityBuilder` 组：宽度逐帧收窄全程同档只 build 一次、跨阈值才重建；父级重建与小窗表面变化照常刷新）。
- **备注**：真 app 帧时未测，需用户在 Windows 上复测开关手感。

### 续 · 2026-11-01（用户：上一轮修完「还是很卡」，关闭时露出白条）
- **用户录屏**（Windows，视频暂停，60fps 去重）：打开 0.83→1.17s 有 333ms 无新帧，之后 200ms 宽度动画基本流畅；关闭时面板内容瞬间消失、原位露出白条随宽度收缩，动画期间 2.53→2.77s、3.13→3.37s 两次约 240ms 停顿。
- **真机帧时探针**：`fushi/integration_test/video_subtitle_list_toggle_perf_itest.dart`（真 app、1080p 素材、400 行互不相同的字幕；暂停后按 `L` 开 / 关三轮，记 `FrameTiming` 与相邻帧 vsync 间隔；首轮可带 widget 级 VM timeline，`--dart-define=SUBLIST_TRACE=false` 关掉）。本机 RTX 4070 Ti，窗口 2864×1766@2x。
- **测量结果**（maxGap = 按键后相邻帧最大间隔；b = 单帧 UI 线程 build+layout+paint）：

  | 模式 | 版本 | open#1 | close#1 | 之后各轮 |
  |---|---|---|---|---|
  | debug（只作相对归因） | 修复前（5 句循环素材） | 首帧 b=385ms，maxGap 433 | 首帧 b=115，maxGap 167 | close#2 首帧 67 / gap 117 |
  | debug | 修复后（400 句不同素材） | 首帧 b=237，maxGap 300 | 首帧 b=147，maxGap 167 | close#2 gap 107，open#3 gap 161 |
  | profile，不带 trace | 修复前 | 首帧 b=21，maxGap 50 | maxGap 33，b≤1 | open#2 maxGap 33；close#2 时进程崩溃（见下） |
  | profile，不带 trace | 修复后 | 首帧 b=18，maxGap 33 | 进程崩溃 | — |
  | profile，首轮带 trace | 修复后 | 首帧 b=24，maxGap 33 | 首帧 b=13，maxGap 33 | open#2 maxGap 17 / b≤1；close#2 maxGap 33 / b≤1；open#3 崩溃 |

- **归因（debug timeline）**：首开长帧在 `LAYOUT > RenderSliverVariedExtentList`（172ms，面板首次排版：建可见行 + 行高测量），外加 `_buildVideoControlsInner` 的 ListenableBuilder 因 `_subtitleListVisible` 翻转重建整套 media_kit 控制条主题（`hideMouseOnControlsRemoval` 依赖它）；关闭首帧是同一主题重建 + `_pokeControlsVisible` 唤出后 `_MaterialDesktopVideoControls` 重新挂载控制条（47ms，debug）；关闭动画帧里字幕 overlay 的 `LayoutBuilder`（`video_subtitle_overlay.dart` 约 1511 行）每帧随画面宽度重建。
- **结论**：本机 profile 下开 / 关两个方向都**没有复现** 240–333ms 级停顿（修复前后最大帧间隔都 ≤50ms），录屏里的停顿量级在这台机器上测不出来，根因未定位，**不宣称已修卡顿**。debug 下的长帧是上面三处，profile 下都在 25ms 内。
- **关闭白条根因**：`fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart` `_subtitleJumpSidePanel`（upstream/develop 6d44336d33 第 3637–3772 行）`AnimatedSize(child: SizedBox(width: visible ? w : 0, child: visible ? 面板 : SizedBox.shrink()))`——`visible` 一翻 false，面板当帧卸载，`AnimatedSize` 把一块空列从 w 收到 0，露出页面底色。修复后探针在关闭 70ms 时读到画面列宽 1031/1432、面板仍在树上（debug runId `sublist-after-debug`）。
- **[x] ① 关闭白条已修**：新增 `fushi/lib/src/media/video/video_push_aside_column.dart`（`VideoPushAsideColumn`）替换 `AnimatedSize`：收起动画全程保留面板（`IgnorePointer` 不接指针），动画走完才卸载；面板约束恒为列宽（`OverflowBox` + `ClipRect`），动画帧不重建、不重排面板。
- **[ ] ① 停顿**：未复现、未修，见结论。
- **[x] ② 自动化测试**：`fushi/test/media/video/video_push_aside_column_test.dart`（收起全程面板在树内、贴住收缩中的列左缘、结束才卸载；开 / 关动画面板只 build 一次、不随帧重排；零时长直接到终态；收起途中重开不重挂），本地 4/4 通过。
- **另一个问题（既有，未修）**：profile 模式下连续开关字幕列表几轮后进程 FATAL 退出：`impeller/renderer/backend/gles/render_pass_gles.cc(314) Could not create a complete framebuffer: GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT` → `(844) Check failed`。修复前、修复后各 2–3 次都会崩（出现在 close#1 / close#2 / open#3，不固定），debug 模式两次都没崩。只在测试窗口（`FUSHI_TEST_HIDDEN` 非激活窗口）里见过，用户的 release 包上是否会发生没有验证。应单开一条 bug 查。

### 续 · 2026-11-02（停顿定位到「视频纹理逐帧换尺寸绘制」，修法：动画期间冻结画面宽度）
- **复现条件**：profile 真 app、**边播放**（暂停时测不出，这是上一轮「未复现」的主因）、不录 timeline、窗口不置顶、客户区 2864×1766@2x、Windows Impeller GLES/ANGLE（随包 HDR 引擎 hdr2），`SUBLIST_CYCLES=10` 开 / 关各 10 轮。录 timeline 只会放大尖峰，不录同样有（`d-notrace` 仍有 46ms 级、j-p0 不录 67–319ms）。窗口被别的窗口遮住照样有（`h-p0-occl` 185–429ms），与置顶 / 前台无关。
- **尖峰的形态**：长帧全部落在 raster 线程，`ScopedFrame::Raster` 本身 <50ms，余下时间卡在 embedder 的 `FlutterCompositorPresentLayers`（present 调用，内部没有子事件）；UI 线程 build ≤21ms。
- **逐项 A/B（同一 exe、只换 app.so，maxRaster 取 10 轮里收起 / 展开动画帧最大值）**：

  | 变体 | 改了什么 | maxRaster |
  |---|---|---|
  | j-p0 | 修复前 | 67–319ms（中位约 100） |
  | j-head2 | 上一轮修复（面板保留） | 10–563ms（中位约 202） |
  | e-p0-nofade | 去掉两层全屏 Opacity 淡入 | 无改善（262ms） |
  | j-norect | 不画视频纹理 | ≤13ms |
  | k-texscale | 画面格宽度不变、用 Transform 每帧缩放纹理 | 212–423ms |
  | k-texfix | **动画期间画面格宽度冻结**（纹理尺寸不变） | 9–42ms |

  排除项：小内存模式、timeline 录制、全屏淡入 Opacity 层、字形图集重建（开 / 关各只有约 30 次 AppendToExistingAtlas）、media_kit `setSize`（只在 macOS 生效）、引擎 `external_texture_d3d` 重绑（只在句柄变化时发生）。
- **结论**：触发条件已确认——**外部视频纹理每帧以不同尺寸 / 缩放绘制**时 present 阻塞 100–500ms；纹理尺寸不变就消失。引擎 / 驱动层面为什么会阻塞**没有确认**（没有同步过的引擎源码可插桩，见上文）。
- **[ ] ① 停顿：已按规避方案改（未在实验室证实，待用户真机复测后再勾）**：`fushi/lib/src/media/video/video_push_aside_column.dart` 由 `VideoPushAsideColumn` 改为 `VideoPushAsideRow`，接管整条 `Row[画面格, 面板列]`。动画期间画面格的布局宽度冻结在起点：展开时画面保持全宽、由滑入的面板盖住右侧；收起时画面保持窄宽，露出的空隙用面板整列底色（`VideoSubtitleJumpPanel.columnSurfaceColor`）填上，不露页面底色（保留上一轮的白条修复）。动画结束（含零时长、途中反向）一次性提交新宽度；窗口缩放、全屏切换、拖拽改面板宽度时立即生效、不冻结。代价是动画期间画面不再平滑挤压，引擎层问题查清后可以恢复。
- **[x] ② 自动化测试**：`fushi/test/media/video/video_push_aside_column_test.dart`（8 条：展开冻结全宽且面板只 build / layout 一次；面板下方的点击不落到画面；收起冻结窄宽、空隙整列填色；零时长；途中反向不跳、不重挂；动画中窗口缩放与面板宽度变化解除冻结；静止时窗口变化立即生效）。
- **证据（k 轮，同一时段的受控 A/B）**：同一 exe、同一 hdr2 引擎、同一配置，只换 app.so，各跑 10 轮。尖峰都出在收起动画上（展开各轮 maxRaster ≤18ms）。收起动画的 maxRaster：
  - `k-texfix`（动画期间冻结画面格宽度，也就是本次的修法）：10/10 都低于 50ms（9–42ms）。
  - `k-texscale`（画面格宽度不变、用 Transform 逐帧缩放纹理）：10/10 都高于 200ms（212–423ms）。
  - `j-p0`（修复前）：67–319ms，中位数约 100ms。
- **未证实**：m 轮（2026-11-02 凌晨）照 j-p0 的条件重编了修复前的基线（`m-p0`，4 个修复文件换回 `upstream/develop`）和修复后的构建（`m-fix`），各跑 10 轮。`m-p0` 本身没有复现卡顿：收起动画的 maxGap 在 17–33ms，maxRaster 在 10–20ms，和 `m-fix`（maxRaster 9–16ms）分不开。j-p0 和 m-p0 看起来条件相同，结果一个卡一个不卡，说明实验室环境抖动太大，所以「修复后不卡」在实验室里**没有证实**。① 先不勾，需要用户在真机上复测：PR 合并后装 CI 调试通道包，打开视频诊断日志，开关字幕列表几次后导出流水。流水里有 `subtitle list open` / `subtitle list close` 标记，可以和每秒一窗的帧耗时逐秒对上。
- **未定位**：引擎这一层的根因还没找到，即为什么外部纹理逐帧换尺寸绘制时，`FlutterCompositorPresentLayers` 会阻塞上百毫秒。本次只是规避了触发条件。
- **探针的坑**：drive 断言失败时仍然返回 exit 0。`flutter drive` 在 integration_test 插件没被识别时，`expect` 失败照样打印 `All tests passed` 并退出 0，所以判定必须核对 summary 里的实际轮数，以及有没有 `Expected` 行。另外，不置顶时测试框架注入的按键偶尔落不到画面上，探针每次按键前先把焦点放回 `Video`。
- **工具**：runner 新增仅测试模式生效的 `FUSHI_TEST_WINDOW_RECT=x,y,w,h`（钉住外框位置 + 尺寸，不置顶、不抢焦点，见 `docs/agent/integration-testing.md`）；探针新增 `SUBLIST_DPR` / `SUBLIST_LAYERS` / `SUBLIST_CYCLES`，以及 `fushi/integration_test/helpers/layer_tree_probe.dart`（profile 下比较前后帧 layer 树）；视频诊断日志记录字幕列表开 / 关。

### 续 · 2026-11-04（冻结宽度在用户真机上无效；修掉 raster 线程等 libmpv 锁）
- **用户真机证据**（`%APPDATA%\Fushi\Fushi\logs\video_diag_log.txt`，debug.23345，18:41–18:59，RTX 5090）：每次 `subtitle list open/close` 后 1–3 秒内帧窗口掉到 4–11fps，单帧 raster 300–880ms，build 很小；卡顿持续到宽度早已稳定之后，所以 11-02 的「动画期间冻结画面宽度」没有消掉它。播放条件 `hwdec=nvdec-copy`、`p010`、mkv，开着 Anime4K 全套 7 个着色器 + ewa_lanczossharp。
- **实验室复现**（profile、hdr-output-2 引擎、2880×1800、边播边开关，素材 `D:\fushi-probe-media\`）：H.264 High10 → nvdec-copy p010 与 8-bit d3d11va 都出过 600–835ms 单帧，但频率远低于用户（100 轮里 6 轮 ≥200ms，且不连发）。10-bit / nvdec-copy、Anime4K 都不是区分条件。长帧里 `TexImage2DInitialization` / `TexImage2DUpload` 恒为 0——排除「离屏渲染目标反复重新分配」和「字形图集上传」。
- **根因之一（已修）**：`third_party/media_kit_video/windows/video_output.cc` 的 `GpuSurfaceTexture` 回调在 Flutter raster 线程（`LayerTree::Paint` 内）调 `ANGLESurfaceManager::Read()`，后者 `WaitForSingleObject(mutex_, INFINITE)`；`Draw()` 在整段 `mpv_render_context_render` + `glFinish()` 期间持有这把锁（`angle_surface_manager.cc` 旧 59–75 行）。libmpv 一帧慢，Flutter raster 线程就同步卡住，Flutter 的迟帧又拉长 libmpv 下一次 `glFinish`。
- **[x] ① 修复**：拷贝挪到 `Draw()` 末尾（mpv 渲染线程、`glFinish` 之后、仍在锁内），删掉 `Read()`；raster 线程不再碰这把锁和 media_kit 的 D3D11 设备。记录见 `third_party/media_kit_video/PATCHES.md`。
- **[x] ② 自动化测试**：`fushi/test/third_party/media_kit_video_raster_never_waits_guard_test.dart`（回调不调 `Read`、`Draw` 在 `glFinish` 后锁内拷贝），连同 ANGLE interop 守卫 12 条通过。
- **修复前后实验室对照**（同一 exe / app.so / 引擎，只换插件 DLL，交错跑）：trace 里 >20ms 帧中 `LayerTree::Paint` 自身 >10ms 的帧，修复前 7（c1）/ 8（p8，最长 120ms）→ 修复后 0（f8）。≥200ms 帧：修复后 180 轮 0 轮，修复前 140 轮 3 轮（p≈0.08，不显著）。播放截图、vo-drop 与修复前同量级。
- **[ ] 仍未定位的第二类长帧**：修复前最大的帧不是等锁——p8 close5 +1414 帧 600ms 里 `RenderPassGLES::EncodeCommandsInReactor` 单次 568ms（Flutter 的 ANGLE 上某个 GL 调用阻塞，推测在跨设备共享纹理上等同步），close5 +2331 帧 490ms 里 `FlutterCompositorPresentLayers` 445ms。修复后样本里没再出现，但样本不足以宣称消失。需要用户在真机复测；若仍卡，下一步在 Flutter 侧采样共享纹理前后加 trace，查 legacy shared handle（无 keyed mutex）的隐式跨设备同步。
- **风险**：拷贝现在在 mpv 渲染线程上做，与 Flutter 采样同一块共享纹理在时间上可重叠（两设备间无 keyed mutex，旧实现同样没有）；慢速素材两张截图未见撕裂，高速运动片源未专门验证。

### 续 · 2026-11-04（二）（keyed mutex 方案查证；第二类长帧取证）
- **keyed mutex：插件单侧做不成，本轮未改**。按计划给 `ANGLESurfaceManager` 的共享纹理加 `D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX`、两端 `AcquireSync` / `ReleaseSync`，但核对了 3.47.6 引擎源码树（`D:\fe\flutter`，基线见 `ci/patches/flutter-engine/3.47.6/README.md`）之后发现，**消费端没有一处会去取这把锁**：
  - Flutter `shell/platform/windows/external_texture_d3d.cc` `CreateOrUpdateTexture`：每个句柄只做一次 `eglCreatePbufferFromClientBuffer(EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE)` 加 `eglBindTexImage`，之后一直绑着，直到句柄变化。`shell/platform/windows/` 和 `impeller/renderer/backend/gles/` 里都搜不到 `KeyedMutex` / `AcquireSync`。
  - ANGLE（`84027ac`）`SwapChain11.cpp` 第 315 行：这条路径只把 `IDXGIKeyedMutex` 查出来存着。`SurfaceD3D::querySurfacePointerANGLE`（第 417 行）通过 `EGL_DXGI_KEYED_MUTEX_ANGLE` 把它交给应用，ANGLE 自己在 bind / draw / release 时都不会去 Acquire。
  - keyed mutex 只能同步调用了 `AcquireSync` / `ReleaseSync` 的设备。只在生产端加，Flutter 的设备照样不持锁读写，等于没有同步；而且按 D3D11 的约定，带 keyed mutex 的资源在不持锁时访问，行为未定义。所以这一步只在插件里做，不但修不了撕裂，还会多出新风险。
  - 要真正做成，raster 端必须由引擎去取锁：给 `ExternalTextureD3d` 打补丁，用 `eglQuerySurfacePointerANGLE(EGL_DXGI_KEYED_MUTEX_ANGLE)` 拿到锁，采样前 `AcquireSync(key, 0)`，取不到就沿用上一帧；在这一帧的 GL 命令全部提交之后（合成器 `Present` 之后）再 `ReleaseSync`。生产端在 `Draw()` 末尾、`CopyResource` 前后取锁 / 放锁，超时就跳过这一帧的拷贝。这需要：新的引擎补丁、按三种模式重编 `flutter_windows.dll`、发新的 `patchVersion` release、更新 `artifacts.json`；还要新增一个引擎能力导出，让插件知道引擎会取锁之后才切到 keyed mutex。否则会违反「补丁引擎与原版引擎都能跑同一份 app」这条运行时契约（CI 在 `artifacts.json` 缺失时用的是原版引擎）。这超出了本轮范围，留待单独立项。
  - 守卫：`fushi/test/third_party/media_kit_video_raster_never_waits_guard_test.dart` 新增一条：只要插件给共享纹理用了 keyed mutex，`ci/patches/flutter-engine/` 下就必须有补丁在 `external_texture_d3d` 里 `AcquireSync`，否则判红。这样可以防止有人只在生产端加锁。
- **第二类长帧取证**（只用已有 trace 复核，本轮没有新跑实验室；脚本统计 `D:\fushi-probe-runs\{c1,p8,f8}-hi10-trace\sublist-trace-*.json` 的 raster 线程）：

  | 样本 | 版本 | raster 帧数 | EncodeCommandsInReactor ≥50ms | FlutterCompositorPresentLayers ≥50ms | LayerTree::Paint ≥50ms |
  |---|---|---|---|---|---|
  | c1 | 修复前 | 5104 | 无 | 58, 86 | 59, 89 |
  | p8 | 修复前 | 7288 | 55, 359, 568 | 51, 125, 237, 445 | 71, 120 |
  | f8 | 修复后（#2841） | 7549 | 无 | 无 | 无 |

  - p8 close5 中三段长事件的调用栈与旁证：
    - 两段 `EncodeCommandsInReactor`（359ms / 568ms）都在 `GPURasterizer::Draw > Rasterizer::DoDraw > DrawToSurfaces > ReactorGLES::React > ReactOnce > FlushOps > ReactorGLES::Operation` 下面，**没有任何子事件**。前面几个 render pass 的编码都 <10ms，说明是某一个 GL 调用在 ANGLE / D3D11 里阻塞了。
    - 同一时间 UI 线程在 `Animator::BeginFrame > PipelineFull` 空等 raster，其它 Flutter 线程没有落在这个时间窗里的事件，所以排除了 Dart 侧和 UI 线程持锁。
    - `FlutterCompositorPresentLayers` 445ms 没有子事件，紧挨着的前一帧 `ScopedFrame::Raster` 才 20ms。
  - **结论（推断，未证实）**：这三段 CPU 阻塞都发生在 Flutter 自己那台 ANGLE D3D11 设备的调用里，发生的时候 Flutter 的 CPU 侧没有任何东西在忙。符合这种特征的只有两种可能：一是共享纹理在两台设备之间的隐式同步（legacy `D3D11_RESOURCE_MISC_SHARED` 资源由 OS 隐式串行化，写方是 media_kit 设备上的 `CopyResource`）；二是 Flutter 设备的 GPU 队列被反压（`Present` 卡在帧延迟队列上，draw 卡在命令缓冲区满）。修复前，`CopyResource` 是在 raster 线程上、Flutter 采样之前一刻才提交给 media_kit 设备（旧 `Read()`）。这条写和紧接着的读之间，正好是隐式同步最容易让读方等上的位置。#2841 把拷贝挪到 `Draw()` 末尾之后，f8 的 7549 帧里没有出现一次 ≥50ms 的 encode / present / paint。不过修复前这类帧本身就很稀（c1+p8 共 12392 帧里 encode 3 次、present 6 次）。假设修复前后每帧发生率相同，用条件二项检验算「全部落在修复前那组」的概率：encode 一项 (12392/19941)^3≈0.24，present 一项 ^6≈0.06，都不显著，**不能据此宣称已消除**。引擎层到底卡在哪个 GL 调用上，还要靠给引擎插桩（在 `ExternalTextureD3d` 采样和 `RenderPassGLES` 每个 draw 前后打 trace）或者 PIX / GPUView 抓 GPU 队列才能定下来。本机引擎源码树在，但要重编引擎，本轮没做。
  - **[ ] 仍未关**：第二类长帧未定位，keyed mutex 留待引擎补丁立项。需要用户装 #2841 之后的包在真机复测（视频诊断日志里的 `subtitle list open/close` 与每秒帧窗口）。
