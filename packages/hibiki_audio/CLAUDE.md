[根目录](../../CLAUDE.md) > [packages](../) > **hibiki_audio**

# hibiki_audio

## 模块职责

音频播放与有声书匹配模块：提供字幕解析器（SRT/VTT/LRC/ASS/SMIL/JSON alignment）、有声书播放控制器、音频-文本对齐匹配算法、阅读位置管理和统计追踪。

## 入口与启动

- 库入口：`lib/hibiki_audio.dart`
- 播放控制器：`lib/src/audiobook/audiobook_controller.dart` -- `AudiobookPlayerController` (ChangeNotifier)，管理 `just_audio` 播放器。
- 无独立启动，由主应用页面按需实例化控制器。

## 对外接口

### 字幕解析器
- `SrtParser` / `VttParser` / `LrcParser` / `AssParser` / `SmilParser` / `JsonAlignmentParser` -- 各格式字幕解析。
- `TextFileIo` -- 文本文件读取（含编码检测）。

### 有声书核心
- `Audiobook` / `AudiobookModel` -- 有声书数据模型。
- `AudiobookPlayerController` -- 播放控制器（play/pause/seek/skipToCue/setSpeed），每 200ms 轮询定位当前句。
- `AudiobookRepository` / `AudiobookStorage` -- 有声书持久化。
- `SrtBook` / `SrtBookRepository` -- 字幕书管理。
- `ReaderPositionModel` / `ReaderPositionRepository` -- 阅读位置。
- `ReadingStatisticModel` / `ReadingTimeTracker` -- 阅读统计。
- `BookmarkRepository` / `FavoriteSentenceRepository` -- 书签与收藏句子。
- `AudiobookHealth` -- 有声书健康度检测。

### 匹配与对齐
- `EpubSrtMatcher` / `EpubCueMatcher` -- EPUB 章节与字幕 cue 对齐。
- `CollectionAudioMatcher` -- 集合级音频匹配。
- `SasayakiMatchCodec` -- Sasayaki 匹配结果编解码。
- `AudioTextNormalizer` -- 文本规范化（匹配前预处理）。
- `CuesToEpub` -- cue 数据转 EPUB 格式。

## 关键依赖与配置

- `just_audio: ^0.9.31` -- 音频播放引擎。
- `audio_session: ^0.1.13` -- 音频会话管理。
- `hibiki_core` -- 数据库（AudioCues/SrtBooks/ReaderPositions 等表）。
- `xml / flutter_charset_detector` -- 字幕格式解析。
- `drift` -- 直接使用数据库类型。

## 数据模型

- `Audiobook` -- 有声书实体（bookKey / audioRoot / alignmentFormat / healthKindRaw 等）。
- `AudioCue` -- 音频 cue（chapterHref / sentenceIndex / textFragmentId / startMs / endMs）。
- `SrtBook` -- 字幕书（uid / title / audioRoot / srtPath）。
- `ReaderPosition` -- 阅读位置（bookKey / sectionIndex / normCharOffset）。
- `ReadingStatistic` -- 阅读统计（title / dateKey / charactersRead / readingTimeMs）。

## 测试与质量

测试覆盖良好，位于：
- `hibiki/test/media/audiobook/` -- srt/vtt/lrc/ass/smil parser tests, audiobook_controller_seek_test, audiobook_health_test, epub_srt_matcher_test, sasayaki_match_codec_test, collection_audio_matcher_test, cues_to_epub_test, 等。
- `packages/hibiki_audio/test/audiobook/` -- audiobook_model_test, audio_file_sort_test。

## 相关文件清单

- `lib/hibiki_audio.dart` -- 库入口
- `lib/src/parsers/` -- 字幕解析器（8 个）
- `lib/src/audiobook/` -- 有声书核心（控制器/仓库/模型，14 个文件）
- `lib/src/matching/` -- 匹配与对齐（6 个文件）

## 变更记录 (Changelog)

- 2026-05-23: 初始文档生成。
