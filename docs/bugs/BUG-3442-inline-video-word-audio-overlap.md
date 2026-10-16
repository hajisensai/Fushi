## BUG-3442 · 视频片段（WebM 内嵌）制卡翻面时单词音频与句子片段同时播放
- **报告**：2026-10-15（用户反馈：视频片段制卡，单词和句子一块播放；附 `选中的笔记 (2).apkg`）
- **真实性**：✅ 真 bug。解包用户 apkg（Lapis，单张笔记「想定」）：ExpressionAudio = `[sound:fushi_audio_….mp3]`，Picture = `<video class="fushi-inline-video" … oncanplay="…play()">`（WebM 片段，自带句子音轨），SentenceAudio = 重播按钮 + 隐藏 `<audio class="fushi-inline-audio">`；Lapis 背面 `addAudioButtons` 渲染 `{{ExpressionAudio}}`。翻面时 Anki 原生队列自动播放单词 `[sound:]`，同时 `<video>` 的 `oncanplay` 在页内自己 `play()`——原生播放结束不会通知卡片 JS，两路无法排先后，于是叠音。根因 `packages/fushi_anki/lib/src/anki_note_composer.dart` 的 `renderMediaPayload`：同步 WebM 片段分支只把句子音频改成页内播放（`inlineVideoSentenceAudioHtml`），单词音频 `processedAudio` 仍原样是 `[sound:]`。MP4 片段卡不受影响（句子视频也是 `[sound:]`，原生队列顺序播放）。
- **[x] ① 已修复** — 同步 WebM 片段卡（非托管模板）把单词音频 `[sound:x]` 换成 `inlineVideoWordAudioHtml(x)`：重播按钮 + 隐藏 `<audio class="fushi-word-audio">`。片段 `<video>` 的 `oncanplay` 改为先播单词（多份副本只响一份）、`ended` 后再播可见片段；单词 `play()` 被拒且不是 `NotAllowedError`（文件坏）时跳过单词照常播片段。句子重播按钮先停掉单词并撤销接续；句子 `<audio>` 见到单词音频就让出；页面上没有片段时由单词 `<audio>` 自己开头、播完接句子，`onerror` 时直接放句子。
- **[x] ② 已加自动化测试** — `packages/fushi_anki/test/inline_video_cover_test.dart`：`renderMediaPayload` 字段形态（WebM 同步卡零 `[sound:]`；MP4 / 非同步 / 托管模板仍 `[sound:]`）、新 HTML 可安全嵌入 Lapis JS 模板字面量、node 实跑 ④–⑨（先单词后片段、手动重播不重复、坏文件不吞片段、关自动播放不硬播、无片段时单词接句子、单词加载失败直接放句子）。
- **备注**：
  - 代价：这类卡上 Anki 的「重播音频」快捷键（R）不再重播单词，用卡上的单词按钮。
  - 已制的存量卡不会自动修复，需重制或覆盖制卡。
  - 托管视频模板（`{card-video}`，`anki_video_template.dart` 的 `_playerScript` 加载即 `play()`）有同样的叠音，本次未改：已安装的 v1 模板块不会自动升级，需要单独设计模板版本迁移。
  - 未在真 Anki / AnkiDroid 上复测，只有 node 模拟 DOM 实跑。
