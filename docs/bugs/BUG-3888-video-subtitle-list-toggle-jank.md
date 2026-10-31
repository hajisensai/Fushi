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
