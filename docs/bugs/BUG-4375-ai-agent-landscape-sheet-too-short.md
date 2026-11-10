## BUG-4375 · 横屏打开 AI 助手只剩标题和输入框
- **报告**：2026-11-08（用户反馈 cP3rFztWT2：「ai对话框横屏太窄 而且在横屏模式下没办法转成竖屏」，Android 横屏播视频，窗口 792×360dp）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/ai_agent_page.dart:99`（修前）浮层摆法只按宽度判（`width >= kAiAgentSidePanelBreakpoint` 840 才用侧栏），792dp 宽的横屏手机落进底部半屏面板；`:107`（修前）面板高固定 `height * 0.55` = 198dp，一打开就低于 `kAiAgentTightHeight`（200）进紧凑排版，标题 + 输入框占满、对话几乎看不见。横屏的富余在宽度上，而面板只拿高度的一半；播放器锁横屏，用户也没法转竖屏换回正常高度。
- **[x] ① 已修复** — 摆法改由 `aiAgentUsesSidePanel(Size)` 判：宽窗口（≥ 840）**或横屏窗口（宽 > 高）**都用靠边侧栏，侧栏吃满窗口高度（减 12dp 外边距，792×360 下 336dp），视频仍露在另一侧；竖屏窄窗口照旧底部面板。侧栏外框抽成 `AiAgentSidePanelFrame`：宽度 `aiAgentSidePanelWidth`（440，窄窗口收到窗口宽减外边距），软键盘让位不变；表面 MD3 用 surfaceContainerLow 面板，Apple 用 `FushiAppleDialogPanel`（横屏 iPhone 现在也会走侧栏）。滑入动效沿用原 `showGeneralDialog` 转场。复核补：对话框路由不套 SafeArea，侧栏外边距叠上 `MediaQuery.paddingOf`（横屏刘海 / 挖孔 / Home 指示条），宽度按扣掉左右安全区后的窗口算。
- **[x] ② 已加自动化测试** — `fushi/test/pages/ai_agent_landscape_layout_test.dart`：摆法判据（横屏手机 / 小横屏 / 竖屏手机 / 竖屏平板 / 宽窗口）、侧栏宽度收缩、MD3 与 Apple 两套下 792×360 侧栏高度 = 336dp（> 紧凑阈值）、844×390 带刘海 / Home 指示条安全区时侧栏右缘与底边让开安全区。
- **备注**：测试未在本分支运行，统一在合并后验证。「转竖屏」未改：播放器的方向锁属于播放器行为，本次按拍板只修布局约束——横屏下 AI 助手已可正常使用。
