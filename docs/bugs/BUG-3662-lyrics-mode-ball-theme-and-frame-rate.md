## BUG-3662 · lyrics-mode-ball-theme-and-frame-rate
- **报告**：2026-10-23（用户：歌词模式悬浮球着色不一致；手机发热严重，PC 歌词滚动掉帧）
- **真实性**：✅ 真 bug。① 应用内悬浮球挂在导航之上（`fushi/lib/src/floating_ball/app_floating_ball_host.dart` build），读的是根主题；歌词模式的封面取色主题只由 `LyricsThemeHost` 套在阅读器页面内，球拿不到 → 紫色球配棕色歌词页。② MD3 流动背景 `FushiMeshBackdrop` 常驻 Ticker、波浪进度条 `FushiWavySeekBar` 播放中逐 vsync setState（`fushi/lib/src/utils/components/fushi_m3e_player.dart`），只在回调里限 30fps，引擎仍每个 vsync 整帧合成（含封面大投影、WebView 平台视图），120Hz 屏每秒 120 次整屏重画；减弱动态效果下波浪条仍逐 vsync 出帧。
- **[x] ① 已修复** — 场景登记带上页面此刻的主题（`FloatingBallSceneSnapshot.theme`），宿主恒包一层 `Theme` 按它画球；背景 / 波浪条改为约 30fps 按需出帧（`_ThrottledFrameDriver`），过渡期才用 vsync Ticker，动效关闭零帧；读数块 / 封面 / Apple 进度条加 `RepaintBoundary`。
- **[x] ② 已加自动化测试** — `fushi/test/floating_ball/floating_ball_test.dart`（场景带上页面主题并随之变化）；`fushi/test/widgets/fushi_m3e_player_frame_rate_test.dart`（背景 / 播放中波浪条每秒 25–35 帧、暂停与减弱动效零帧；旧实现实测 1000 帧/秒档与动效关闭下 300 帧，测试红）。
- **备注**：未在 Android 真机 / Windows 上实测发热与掉帧前后对比。未处理的剩余热点：歌词模式下底层阅读器 WebView 仍随音频翻页高亮（架构拍板项）；逐字扫过 `@property --ly-p` transition 让 WebView 持续 60fps 出帧；Apple 背景两层整屏 ImageFiltered 模糊每帧重算。
