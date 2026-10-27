## BUG-3820 · 歌词模式没碰屏幕也会自动对齐中断、弹出「跟随音频」
- **报告**：2026-10-27（用户：应用内反馈 0rvPl6s6tR，Android 平板 HONOR CHG-W60；追加「关掉互联以后就再也没发生」；关联 VNz9dsLeIy / I1Bg6uMZ32）
- **真实性**：✅ 真 bug（沿代码路径确认判据缺陷；与后台同步的关联为推测，见备注）。弹出的是歌词覆盖层「手动滚动脱离跟随」的胶囊 `#ly-follow`，进入条件是 JS `_lyEnterBrowse()`。旧判据（`fushi/lib/src/media/audiobook/lyrics_mode_html.dart:837-839`）：**任何**落在程序化滚动免判窗口（`_lyricsScrollByAxis` 置的 `_lyProgUntil = now + 150`，同文件 `:685`）之外的 `scroll` 事件都算用户手动滚。scroll 事件是异步派发的，以下情况都会在没有任何触摸的情况下打断跟随：
  1. 设备忙（后台同步 ingest / 媒体下载、解码等占满 CPU）时，自动跟随那一帧的 scroll 事件晚于 150 ms 才到；
  2. 视口尺寸变化（`resize` → `__lyricsFitCues` 改字号后重排）、滚动位置被钳到新的可滚范围、滚动锚定调整，都会发 scroll 而不经 `_lyricsScrollByAxis`。
  反馈人「关掉互联后不再出现」与第 1 条吻合：互联开着时复习数据的后台同步（快速通道、常规同步后置步骤、BUG-3818 的多余推送轮）在阅读时不定期跑，但日志里没有能直接对上时刻的记录（反馈日志只有错误级条目），这一层是推测。
- **[x] ① 已修复** — 提交 `fix(lyrics): only real user input detaches lyrics from audio follow`。「手动滚动」改为只认真的用户输入：手指按着（`touchstart`→`touchend/touchcancel`），或 1 s 内有过触摸 / 按着键的指针移动 / 键盘输入时的 scroll 才进浏览态；滚轮照旧由 `wheel` 监听进入；其余 scroll 一律不算。抬手后的惯性滚动落在 1 s 窗口内照算，浏览态的 4 s 自动回到当前行不变。另加诊断：JS `onLyricsBrowseDiag` 每类（`user-scroll` / `ignored-scroll`）每 30 s 最多一次，Dart 侧 `ErrorLogService.logDiagnostic('ReaderFushi.lyrics.browse', …)` 记下距上次程序化滚动 / 用户输入多久、是否在播放，以及**此刻常规同步与复习同步是否在跑**（`lyricsBrowseDiagLine`），随反馈日志上传。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_user_scroll_js_test.dart`：node 真跑生成文档里的判据片段（迟到 400 ms 的程序化 scroll、重排 scroll 不进浏览态并上报一次诊断；按住拖动、抬手惯性、按键拖动的指针、键盘才算；只划过的鼠标不算）；诊断行格式。
- **备注**：未在真机复测（需要有声书歌词模式 + 互联开着的 Android 平板长时间播放）。已知边界：若某个 WebView 在原生滚动开始后改发 `touchcancel` 且用户拖动超过 1 s，后续 scroll 不再续 4 s 回中计时（已进的浏览态不受影响）。正文（非歌词）的跟随判据不在这条路径上，未改。
