## BUG-2779 · 暂停有声书时翻到别章被拽回音频章（iOS VN 插图章回翻闪回）
- **报告**：2026-09-29（用户：iOS VN 模式，《やはり俺の青春ラブコメはまちがっている。》1 卷在插图处往回翻，会闪回全书约 6654 字的位置；附录屏）
- **真实性**：✅ 真 bug。录屏逐帧：有声书暂停（底栏 ▶），音频停在 ch12（`part0012`）「文芸部か」；插图是独立纯图片章 ch11（`part0011`）。在插图章往回翻，ch10 末屏「…メンバーを集めることができないから…」只露一帧就被拉回 ch12「文芸部か」（带当前 cue 高亮）；再往回翻落到插图章，又被拉回。
  根因：每章文档载入 `_injectAudiobookBridge`（`fushi/lib/src/pages/implementations/reader_fushi/mining.part.dart`，由 `webview.part.dart` 载入链调用）都会 `setChapterCues(allCues)`。`setChapterCues`（`packages/fushi_audio/lib/src/audiobook/audiobook_controller.dart`）先把 `_currentCue` 置空、`_currentCueIndex = -1` 再按位置重算，**同一句**被 `_updateCurrentCue` 判成「cue 变了」，走变更分支：`_manualReaderOverrideCue = null` 清掉手动翻页护栏，随后 `_maybeEmitCrossChapter` 不看是否在播放 → 只要本会话按过播放、跟随音频开着，暂停时翻到别章都会被 `onCrossChapter` 拽回音频章。同函数「cue 未变」分支本来就写明「暂停态不补检查，避免覆盖用户手动翻页」，变更分支因为这次假变更绕开了它。不限 VN：分页/连续模式同样受影响，VN + 独立插图章只是最容易撞上（插图章夹在音频章前面）。
- **[x] ① 已修复** — `setChapterCues` 只换列表不换当前句身份：旧句仍在新列表里就保留（只改下标），重算得到同一句时走「未变」分支（暂停不跨章、护栏保留）；真换了句仍照旧发跨章。逐章 cue 列表换章（旧句不在新列表）行为不变。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/audiobook_paused_cue_reload_no_yank_test.dart`：暂停 + 手动翻到别章后重灌同一份 cue 不得发跨章（修复前得到 `[12]`）、当前句身份保留；对照：换句后跟随照常发跨章；逐章列表换章照旧按位置重算。
- **备注**：iOS 真机/模拟器复测待做（模拟器被其它 agent 占用中）。
