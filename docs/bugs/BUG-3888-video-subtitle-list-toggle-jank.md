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
