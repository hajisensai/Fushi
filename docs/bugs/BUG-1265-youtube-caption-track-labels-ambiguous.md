## BUG-1265 · YouTube 字幕轨标签退化成语言码且人工/ASR 重名，无法分辨选哪条

- **报告**：2026-07-31（用户：「app内对油管适配极差 字幕有问题 不能选字幕是哪」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/youtube_source_resolver.dart:936`
  （`languageName: t.languageName ?? t.languageCode`）+
  `hibiki/lib/src/pages/implementations/video_hibiki/subtitle.part.dart:783-788`（旧代码）。

### 根因

app 的 YouTube 字幕轨表走 **ANDROID_VR innertube player response**（`_fetchCaptionTracks`）——
web 端 timedtext 已被 proof-of-origin 拦死，这是唯一还能直取的路径。但该 client 的 player
response **不返回 `name.simpleText`**。

实测（真实网络，代理 127.0.0.1:34151，`dQw4w9WgXcQ`）：

```
[字幕轨] androidVr OK 387ms  轨数=6
    - en     | null | asr=false
    - en     | null | asr=true      ← 与上一行标签完全相同
    - de-DE  | null | asr=false
    - ja     | null | asr=false
    - pt-BR  | null | asr=false
    - es-419 | null | asr=false
```

`languageName` **6 条全是 null**。于是两条链路一起坏：

1. `_fetchCaptionTracks` 的 `t.languageName ?? t.languageCode` 把名字兜底成**裸语言码**，
   字幕轨选择器列出的是 `en` / `de-DE` / `es-419` 这种机器码，不是人话；
2. `_youtubeCaptionTrackLabel` 直接返回该名字，而源码注释写的假设是
   「ASR 轨 YouTube 常已含 (auto-generated) 标注，A3 人工/ASR 由排序区分」——名字既然是
   null 兜底出来的语言码，**同一语言的人工轨与 ASR 轨标签就完全相同**（上例两行都叫 `en`），
   排序上相邻却无任何可见差异。

用户看到的是一串机器码、其中还有两行一模一样，自然「不知道该选哪个」。注意 cue 解析本身是好的
（同一轨实测 srv1 解析出 61 条 cue），坏的只是**轨的呈现**。

### 修复

- **[x] ① 已修复** — 分两层，各自归位：
  - 数据层 `youtube_source_resolver.dart` 新增纯函数 `youtubeCaptionLanguageLabel(track)`：
    YouTube **真给了**本地化名（非空且不等于语言码）时优先用它（保留自愈——哪天 androidVr
    开始回 `name.simpleText` 或换带名字的 client，自动受益）；否则按语言主码查表出母语写法
    （`ja`→`日本語`、`es`→`Español`），地区子码原样括注（`pt-BR`→`Português (BR)`、
    `es-419`→`Español (419)`），表外回退原码大写。
  - UI 层 `subtitle.part.dart` 的 `_youtubeCaptionTrackLabel`：语言名 + **显式 ASR 标注**
    （新 i18n key `video_subtitle_youtube_auto_generated`）+ 既有翻译标注，令同语言的
    人工轨与 ASR 轨标签必然不同。

### 测试

- **[x] ② 已加自动化测试** — `hibiki/test/media/video/youtube_caption_track_label_test.dart`：
  用**实测抓到的那 6 条轨**（`languageName` 全 null）钉住：语言名不再是裸码、
  `es-419`/`pt-BR` 地区括注正确、以及**同语言人工轨与 ASR 轨的最终标签互不相同**
  （回归这条即撞回原 bug）。

- **备注**：同轮修复见 [BUG-1266](BUG-1266-youtube-quality-entry-self-locked.md)（同一份用户报告的画质部分）。
  用户还提到「字幕有问题」，该项现象描述不足、未复现，另行确认，不并入本条。
