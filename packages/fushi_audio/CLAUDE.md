[根目录](../../CLAUDE.md) > [packages](../) > **fushi_audio**

# fushi_audio

## 模块职责

有声书匹配模块（**纯 Dart，零 Flutter**，2026-09-30 起）：提供字幕解析器（SRT/VTT/LRC/ASS/SMIL/JSON alignment）、有声书仓储、音频-文本对齐匹配算法、阅读位置管理和统计追踪。被 app 与无头服务端共同消费；pubspec 不得声明 `sdk: flutter` / method-channel 插件（守卫 `fushi/test/build/fushi_engine_purity_guard_test.dart`）。

## 入口与启动

- 库入口：`lib/fushi_audio.dart`（与 `lib/fushi_audio_core.dart` 等价）。
- 平台实现住在 app 的 `fushi/lib/src/media/audiobook/`：播放控制器 `audiobook_controller.dart`（`AudiobookPlayerController`，ChangeNotifier + just_audio / audio_session）、`audiobook_storage_platform.dart`（path_provider documents 根 + just_audio 时长探测，经 `AudiobookStorage.documentsRootResolver` / `audioDurationProbeMs` 注入）、`platform_charset_detector.dart`（flutter_charset_detector，经 `platformCharsetDecoder` 注入）。装配在 `fushi/lib/src/engine_bindings.dart`。

## 对外接口

### 字幕解析器
- `SrtParser` / `VttParser` / `LrcParser` / `AssParser` / `SmilParser` / `JsonAlignmentParser` -- 各格式字幕解析。
- `TextFileIo` -- 文本文件读取（含编码检测）。

### 有声书核心
- `Audiobook` / `AudiobookModel` -- 有声书数据模型。
- （`AudiobookPlayerController` 播放控制器已搬到 app，见上。）
- `AudiobookRepository` / `AudiobookStorage` -- 有声书持久化。
- `SrtBook` / `SrtBookRepository` -- 字幕书管理。
- `ReaderPositionModel` / `ReaderPositionRepository` -- 阅读位置。
- `StudyClock` -- v92 唯一学习时钟（阅读 / 视频共用：60s tick、120s 间隙、空闲门、整点切段），取代已删除的 `ReadingTimeTracker`；`kArrivalDwellMs` 只剩视频 cue 停留门在用。`ReadingStatistic`（`reading_statistic_model.dart`）是冻结的 legacy 日聚合模型，新代码不再写它。
- `BookmarkRepository` / `FavoriteSentenceRepository` -- 书签与收藏句子。
- `AudiobookHealth` -- 有声书健康度检测。

### 匹配与对齐
- `EpubSrtMatcher` / `EpubCueMatcher` -- EPUB 章节与字幕 cue 对齐。
- `CollectionAudioMatcher` -- 集合级音频匹配。
- `SasayakiMatchCodec` -- Sasayaki 匹配结果编解码。
- `AudioTextNormalizer` -- 文本规范化（匹配前预处理）。
- `CuesToEpub` -- cue 数据转 EPUB 格式。

## 关键依赖与配置

- `fushi_core` -- 数据库（AudioCues/SrtBooks/ReaderPositions 等表）。
- `xml` -- 字幕格式解析（平台字符集探测由 app 注入）。
- 包测试用 `package:test`（不是 flutter_test）。
- `drift` -- 直接使用数据库类型。

## 数据模型

- `Audiobook` -- 有声书实体（bookKey / audioRoot / alignmentFormat / healthKindRaw 等）。
- `AudioCue` -- 音频 cue（chapterHref / sentenceIndex / textFragmentId / startMs / endMs）。
- `SrtBook` -- 字幕书（uid / title / audioRoot / srtPath）。
- `ReaderPosition` -- 阅读位置（bookKey / sectionIndex / normCharOffset）。
- `ReadingStatistic` -- 阅读统计（title / dateKey / charactersRead / readingTimeMs）。

## 测试与质量

测试覆盖良好，位于：
- `fushi/test/media/audiobook/` -- srt/vtt/lrc/ass/smil parser tests, audiobook_controller_seek_test, audiobook_health_test, epub_srt_matcher_test, sasayaki_match_codec_test, collection_audio_matcher_test, cues_to_epub_test, 等。
- `packages/fushi_audio/test/` -- 纯 Dart 包测试（`package:test`）；依赖播放控制器 / 平台装配的测试在 `fushi/test/media/audiobook/`。

## 相关文件清单

- `lib/fushi_audio.dart` -- 库入口
- `lib/src/parsers/` -- 字幕解析器（8 个）
- `lib/src/audiobook/` -- 有声书核心（控制器/仓库/模型，14 个文件）
- `lib/src/matching/` -- 匹配与对齐（6 个文件）

## 变更记录 (Changelog)

- 2026-05-23: 初始文档生成。
