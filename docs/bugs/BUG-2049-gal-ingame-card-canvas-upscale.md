## BUG-2049 · 游戏内查词卡在放大运行的游戏里模糊且过大：直连覆盖窗被 1:1 闸门挡掉，回退成画布内位图合成
- **报告**：2026-09-02（用户：「游戏内查词这一块……分辨率很低而且缩放很大，和 galgame 浮窗弹出来的不一致」）
- **真实性**：✅ 真 bug。根因 `fushi/windows/runner/global_lookup_window.cpp:2194`（present 入口的 1:1 闸门）
  与同文件 `ResizeStackForGal` 里的 `one_to_one` 分支。

  两条路径都要求**游戏客户区与画布（KiriKiri primaryLayer）逐像素相等**（容差 1px），否则拒绝
  直连 composition HWND、回退到位图路径；位图被 `card.setSizeToImageSize()` 按 1:1 落进
  primaryLayer 的子层，随整个画布被引擎缩放到客户区，于是既糊又按同一比例变大。而
  galgame 台词浮窗是独立的原生分层窗口、按屏幕物理像素绘制，所以两者观感对不上。

  真机测量（9-nine Episode 1，KiriKiri Z x86）：显示器 3840×2160 @192 DPI，游戏客户区
  1902×1069，画布 1280×720（日志 `workCss=640.0x360.0` @ dpr=2）。游戏进程为 Per-Monitor
  DPI aware，故与 Windows 位图拉伸无关；放大源就是画布→客户区这一次引擎缩放，且游戏
  「画面」菜单里的「拡大時スムージング」处于勾选状态，正是模糊的直接来源。

  旧代码把限制写成「等 DComp visual transform 与输入逆映射就绪再放开」。实测这两个前提
  都不成立：卡片是屏幕空间的真实窗口，**只需映射位置、不需要缩放卡片**（保持自身物理
  像素既是清晰的原因，也让它与浮窗同尺度；缩放 HWND 才会改 Chromium 视口触发重排）；
  而直连成功时宿主不再推位图帧（`gal_ingame_lookup_controller.dart` 的 `directSurface`
  分支把 `_recaptureDirty` 置假），引擎 Layer 为空，hook 不对卡片做命中测试，鼠标由系统
  直接投递给覆盖窗，因此不存在需要逆映射的输入。
- **[x] ① 已修复** — `09cf2a93ca`。放开 1:1 闸门，改为按引擎的「等比缩放 + 居中」把画布映射到
  客户区（`fushi/windows/runner/gal_direct_card_geometry.h` 的 `CanvasToClientScale` /
  `LetterboxOffset`），present 与嵌套 resize 共用同一套映射；卡片宽高原样使用，绝不乘 scale。
  1:1 时 scale 恰为 1、信箱边为 0，与旧行为逐像素相同。

  修复过程中第一版只把 anchor 乘了 scale 却让卡片保持自然尺寸，导致卡片离命中的字
  (scale−1)×卡片高（真机全屏 3 倍时约 1000px，用户当场报「没有出现在选词的正上方」）。
  根因是 Dart 的 anchor 是**按画布尺寸**排出来的，卡片改成自然尺寸后这个 anchor 不再成立。
  最终改为把字形矩形经 `galLookupPresent` 送到 runner，用 `GlyphAnchoredCardOrigin` 在屏幕
  空间以字形为基准重排（水平居中、优先正上方、放不下翻下方），再用 `ClampDirectCardOrigin`
  夹回客户区。该中间态未进入任何提交。
- **[x] ② 已加自动化测试** — `fushi/windows/runner/tests/gal_direct_card_geometry_test.cpp`
  （新增，经 `fushi/windows/runner/CMakeLists.txt` 接为构建门，随 runner 构建自动执行）：
  钉住 1:1 等价性（scale 恰为 1、信箱边恰为 0，保证放开闸门不改既有行为）、放大/缩小、
  宽高比不一致时的信箱边、退化输入返回 0、原点夹取四个边界，以及一条直接复刻本 bug 真机
  形态的用例（画布 1280×720 放大 3 倍、字形在画布 y=600，断言卡片贴在字形正上方且不再落回
  画面上三分之一）。
  另更新 `fushi/test/lookup/global_lookup_shell_region_guard_test.dart` 两条源码守卫：它们原本
  钉的是 `constexpr double scale = 1.0;` 与 `const bool one_to_one`，现改为钉**真正的不变式**
  ——卡片宽高必须原样使用、不得乘 scale，且必须经 `CanvasToClientScale` 映射、
  `GlyphAnchoredCardOrigin` 贴附、`ClampDirectCardOrigin` 夹取。
- **备注**：已按 CLAUDE.md 验证纪律在真机复测原始失败路径：9-nine Episode 1 窗口与全屏各一次，
  日志出现 `gal-ingame: direct WebView surface active`（改动前非 1:1 必然回退位图、绝不会有这行），
  卡片清晰且贴在命中字的正上方，用户截图确认。
  清晰度仍有一条固有上界：若直连不可用（如独占全屏，`DesktopOverlayAvailableForTarget` 拒绝）
  而回退到引擎 Layer，分辨率上限仍是画布分辨率——这属于回退路径的既有性质，非本 bug。
