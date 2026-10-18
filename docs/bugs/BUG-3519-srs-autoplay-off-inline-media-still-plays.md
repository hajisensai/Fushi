## BUG-3519 · SRS 牌组关了自动播放音频，卡面内嵌片段/音频仍自己播放，且时播时不播
- **报告**：2026-10-18（用户：srs 卡组设置音频，自动播放音频关了音频还会播放，而且有时候会播有时候不播）
- **真实性**：✅ 真 bug。两条独立根因：
  1. **卡面页面自己出声，不看牌组开关**（主因）。牌组开关只管宿主序列播 `[sound:]`（`fushi/lib/src/pages/implementations/srs/srs_review_page.dart` `_autoplayAudio`）。但视频制卡写进 Fushi 复习的同步片段是页内媒体：`packages/fushi_anki/lib/src/anki_note_composer.dart:138`（`inlineVideoCoverHtml`）/ `:190`（`inlineVideoWordAudioHtml`）/ `:235`（`inlineVideoSentenceAudioHtml`）在 `oncanplay` 里自己 `play()`，并约定「关了自动播放 = 宿主拒绝无手势播放（`NotAllowedError`）」（Anki 的行为，见 `:133` 注释）。卡面 WebView（`fushi/lib/src/pages/implementations/srs/srs_card_face.dart:1481` 起的 `InAppWebViewSettings`，修前）没有任何与牌组开关挂钩的闸门，放任平台默认策略：Windows WebView2 默认放行 → 关了照样播；Android / iOS 默认要手势 → 开着也不播。于是同步片段卡（视频来源）会播、普通 `[sound:]` 卡不播——「时播时不播」。
  2. **宿主序列取消不掉「解析中」的那一段**。`fushi/lib/src/srs/srs_card_autoplay.dart` 的 `SrsCardAudioSequencer.play`（修前）只在调 `playToEnd(name)` 之前查代号；生产出口 `_DefaultSrsCardAudioOutput.playToEnd`（修前）先 `await srsMediaStoreProvider.future`、`await file.exists()` 才交给 `DesktopAudioPlayback`。这段异步间隙里来的 `cancel()`（换卡 / 翻面 / 关自动播放 / 离开复习页）先 `DesktopAudioPlayback.stop()` 抢占代号，随后那段才登记，登记时拿到的已是新代号 → 照样开播。时序相关，表现为偶发。
- **[x] ① 已修复** — 提交 f00044c71a：
  - 卡面外壳加自动播放闸门 `kSrsCardAutoplayGateScript`（`srs_card_autoplay.dart`）：关闭时包住 `HTMLMediaElement.prototype.play`，不在可信用户输入（点按 / 按键）派发过程中的调用以 `NotAllowedError` 拒绝；MutationObserver 摘掉新插入媒体的 `autoplay` 属性。宿主经 `SrsCardFace.autoplayMedia` → `SrsCardFaceDocument` → `__fushiSrsSetAutoplay` 在每次换卡前下发；开关进 `_cardKey`，复习中改开关当前这一面立即重放。WebView 设 `mediaPlaybackRequiresUserGesture: false` + `allowsInlineMediaPlayback: true`，自动播放与否只由闸门（牌组开关）决定，四端一致。复习页把 `_autoplayEnabled` 传给卡面；Fushi 卡片的释义 WebView 同样透传。
  - `SrsCardAudioOutput` 拆成 `resolve(name)` + `playToEnd(path)`；序列在解析完后重查代号再**同步**交给播放器（`DesktopAudioPlayback._play` 在首个 await 之前记下激活代号），之后的 stop 必然能取消它。
- **[x] ② 已加自动化测试** —
  - `fushi/test/srs/srs_card_autoplay_gate_test.dart`：node 里真跑生产闸门脚本（关时 canplay 里的 play 被拒且不碰原生播放、可信点按派发内放行含合成 click、派发结束复位、不可信事件不算手势、摘 autoplay 属性、重复注入不重复包装）；`SrsCardFaceSync` 开关先于换卡下发、只改开关也重放。
  - `fushi/test/srs/srs_card_autoplay_test.dart`：解析途中 cancel / 被新序列取代后不再开播（变异实测：去掉解析后的代号检查两条变红）。
  - `fushi/test/srs/srs_review_live_settings_test.dart`：复习页工具栏进牌组设置关自动播放 → 卡面 `autoplayMedia` 立即为 false、翻面与下一张都不自动播、手动重播可用（变异实测：旧复习页变红）。
- **备注**：WebView / 播放类修复，Windows 与 Android 真机上用一张视频同步片段卡复测「关自动播放 → 不出声；开 → 出声」**待补**。已知边界：Web Audio API（`AudioContext`）不经 `HTMLMediaElement.play`，闸门不覆盖（现有制卡模板不用）。另：卡面上点词查词时的发音走的是全局「查词自动朗读」，不归牌组开关管。
