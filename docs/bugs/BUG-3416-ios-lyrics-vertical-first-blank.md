## BUG-3416 · iOS竖排进入歌词模式不显示且切横排无法恢复
- **报告**：2026-10-14（用户：iOS 上一进去就是竖排歌词模式时直接显示不出来，切回横排也不行，得退出歌词模式再以横排进入）
- **真实性**：✅ 真 bug，Mac iOS 26.5 模拟器（真 WebKit）复现：600 句竖排进入后歌词区空白约 27 秒。根因 `fushi/lib/src/media/audiobook/lyrics_mode_html.dart` `__lyricsFitCues` / `_lyricsFitCue`：
  1. 歌词 WebView 就绪前被 Flutter 设为透明（`reader_fushi/lyrics.part.dart` 的 `AnimatedOpacity`），WKWebView 此时 `innerWidth/innerHeight = 0`，文档按 0×0 视口排版；`_lyricsAvailExtent` 退化为 1，每句都判溢出，竖排每字一列（body scrollWidth 318120px）。
  2. 旧 `_lyricsFitCue` 逐句「写 `style.fontSize=''` → 读 `offsetHeight`」，每句强制一次整页同步布局：竖排实测 11.4–13.0 s（横排 0.46 s，所以横排无感），就绪后 `__lyricsApplyTheme` 再在零视口跑一遍又是 13 s。
  3. 期间 WebContent 主线程被同步 JS 占满：`evaluateJavascript` 超时、resize 进不来（视口一直是 0）、切横排发出的 `loadData` 排在后面——模拟器上 11 秒后才轮到，真书句子更长、真机更慢，表现为「切了也没用」。退出再横排进入能好，是因为新建了 WebView 且横排零视口 fit 只要几百毫秒。
  原先「WebContent 被杀、死亡守卫预算耗尽」的推断被推翻（全程 `deaths=0`）。
- **[x] ① 已修复** — `lyrics_mode_html.dart`：零视口不量尺（`__lyricsHasViewport`），等 resize 带来真实视口再 fit；fit 改为「统一清空 → 统一测量 → 统一写入」三遍，强制布局从 N 次降到常数次；初始居中推迟到第一次拿到真实视口时做一次（`_lyInitialPosition`）。Mac 同条件复测：fit 0–2 ms，进入约 1 s ready、约 2 s 竖排正常显示，当前句居中；切横排、退出重进都正常。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_mode_html_test.dart`「fit pass skips a zero viewport and batches reads (BUG-3416)」：在 node 里跑生产 JS + 计数强制布局的假 DOM，断言零视口不量不写不定位、600 句有视口时强制布局 ≤ 2 次、初始定位只做一次。
- **备注**：真机 + 真书（长句、当前句在窗口中段）尚未复测；Mac 侧探针 worktree `~/dev/hibiki-lyricsvert`（`lv_run.sh vertical_first`）保留可复跑。
