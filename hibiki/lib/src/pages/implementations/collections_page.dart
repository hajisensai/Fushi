import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/pages/base_page.dart';
import 'package:hibiki/src/utils/misc/collection_exporter.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadLongPressActions;

enum _CollectionType { bookmark, sentence, mined, word }

@visibleForTesting
({int? episodeIndex, int? startMs}) resolveVideoFavoriteOpenTarget({
  required VideoBookRow row,
  required int? favoriteSectionIndex,
  required int? favoriteStartMs,
}) {
  final int episodeCount = playlistEpisodeCount(row.playlistJson);
  if (episodeCount <= 0) {
    return (episodeIndex: null, startMs: favoriteStartMs);
  }
  if (favoriteSectionIndex == null) {
    return (episodeIndex: null, startMs: null);
  }
  return (
    episodeIndex: favoriteSectionIndex.clamp(0, episodeCount - 1),
    startMs: favoriteStartMs,
  );
}

/// 从一条**视频来源**收藏句解析出「该截哪个文件的哪段音频」。纯函数（无 IO），可单测。
///
/// 视频收藏句保存时（[VideoHibikiPage] `_toggleFavoriteSentenceForVideo` /
/// `_toggleFavoriteCueForVideo`）把 cue 时间窗直接编进收藏字段：
/// - [favoriteSectionIndex] = 集索引（`_currentEpisode`，单视频恒 0）；
/// - [favoriteStartMs] = cue 起点毫秒（存进 `normCharOffset`，**非字符偏移**）；
/// - [favoriteDurationMs] = cue 时长毫秒（存进 `normCharLength`，可空）。
///
/// 因此收藏句**自带**裁剪所需的全部信息，无需经 [CollectionAudioMatcher]：直接据此
/// 算出 `[startMs, endMs)`，并选出该集对应的视频文件路径（单视频用 [VideoBookRow.videoPath]；
/// 多集播放列表按集索引从 [VideoBookRow.playlistJson] 取那一集的绝对路径）。
///
/// 返回 null 表示无法播放（缺起点、时长非正、播放列表越界 / 解析失败）——调用方据此
/// 不显示播放按钮 / 点击后提示。
@visibleForTesting
({String filePath, int startMs, int endMs})? resolveVideoFavoriteAudioClip({
  required VideoBookRow row,
  required int? favoriteSectionIndex,
  required int? favoriteStartMs,
  required int? favoriteDurationMs,
}) {
  final int? startMs = favoriteStartMs;
  if (startMs == null || startMs < 0) return null;
  final int duration = favoriteDurationMs ?? 0;
  if (duration <= 0) return null;
  final int endMs = startMs + duration;

  final int episodeCount = playlistEpisodeCount(row.playlistJson);
  if (episodeCount <= 0) {
    // 单视频：直接用 videoPath（与播放器单视频路径一致）。
    return (filePath: row.videoPath, startMs: startMs, endMs: endMs);
  }

  // 多集播放列表：按收藏的集索引取那一集的绝对路径。
  final int episodeIndex =
      (favoriteSectionIndex ?? 0).clamp(0, episodeCount - 1);
  try {
    final dynamic decoded = jsonDecode(row.playlistJson!);
    if (decoded is! List) return null;
    final PlaylistEntry entry =
        PlaylistEntry.fromJson(decoded[episodeIndex] as Map<String, dynamic>);
    if (entry.path.isEmpty) return null;
    return (filePath: entry.path, startMs: startMs, endMs: endMs);
  } catch (_) {
    return null;
  }
}

MediaItem buildCollectionReaderMediaItem({
  required String bookKey,
  required String title,
}) {
  return MediaItem(
    mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(bookKey),
    title: title,
    mediaTypeIdentifier: ReaderHibikiSource.instance.mediaType.uniqueKey,
    mediaSourceIdentifier: ReaderHibikiSource.instance.uniqueKey,
    position: 0,
    duration: 1,
    canDelete: false,
    canEdit: true,
  );
}

class _CollectionItem {
  _CollectionItem({
    required this.type,
    required this.createdAt,
    this.bookTitle,
    this.bookKey,
    this.label,
    this.text,
    this.chapterLabel,
    this.sectionIndex,
    this.normCharOffset,
    this.normCharLength,
    this.bookmarkId,
    this.favoriteId,
    this.minedId,
    this.wordReading,
    this.wordSourceType,
    this.source = kFavoriteSentenceSourceBook,
  });

  final _CollectionType type;
  final DateTime createdAt;
  final String? bookTitle;
  final String? bookKey;
  final String? label;
  final String? text;
  final String? chapterLabel;
  final int? sectionIndex;
  final int? normCharOffset;
  final int? normCharLength;
  final int? bookmarkId;
  final String? favoriteId;

  /// 制卡历史行 id（TODO-633，[_CollectionType.mined] 专用，供删除一条用）。
  final int? minedId;

  /// 收藏词的振假名读音（[_CollectionType.word] 专用）。删除按 (expression, reading,
  /// sourceType) 复合唯一键匹配 [HibikiDatabase.removeFavoriteWord]，故读音/来源都要留存。
  /// 这里 [text] 复用为 expression（词形），[chapterLabel] 复用为 glossary（释义）。
  final String? wordReading;

  /// 收藏词来源（'book' / 'video'，[_CollectionType.word] 专用），同上供删除匹配。
  final String? wordSourceType;

  /// 收藏句子来源（[kFavoriteSentenceSourceBook]/`Video`/`Audiobook`/`Lyrics`）。书签恒
  /// 默认书籍；句子按 [FavoriteSentence.source] 透传。视频来源句子的 [bookKey] 是视频
  /// bookUid，点击时走 [VideoHibikiPage] 并按 [normCharOffset] 的 startMs seek。
  final String source;
}

class CollectionsPage extends BasePage {
  const CollectionsPage({super.key});

  @override
  BasePageState<CollectionsPage> createState() => _CollectionsPageState();
}

class _CollectionsPageState extends BasePageState<CollectionsPage> {
  bool _loading = true;
  List<_CollectionItem> _items = [];
  Map<String, String> _bookTitleMap = {};
  Map<String, List<AudioCue>> _cueMap = {};
  Map<String, List<File>> _audioFileMap = {};

  /// 视频来源收藏句的 [VideoBookRow]（按 bookUid 索引），由 [_load] 填充。视频句的
  /// 播放音频不走 [_cueMap]/[_audioFileMap]——收藏句字段自带 cue 时间窗，配上这里的
  /// row 即可定位「该集视频文件 + 时间段」，按需 ffmpeg 抽音（见
  /// [resolveVideoFavoriteAudioClip] / [_playVideoFavoriteAudio]）。
  Map<String, VideoBookRow> _videoRowMap = {};
  bool _playingAudio = false;
  final _dateFmt = DateFormat('MM/dd HH:mm');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    final db = appModel.database;
    final bookmarkRepo = BookmarkRepository(db);
    final favoriteRepo = FavoriteSentenceRepository(db);
    final srtBookRepo = SrtBookRepository(db);
    final abRepo = AudiobookRepository(db);

    final allBookmarks = await bookmarkRepo.getAllBookmarks();
    final allFavorites = await favoriteRepo.getAll();
    final allMined = await db.getAllMinedSentences();
    // BUG-462：弹窗 ☆ 收藏的词（FavoriteWords 表）此前只进导出管线、从不进收藏列表，
    // 用户「收藏里没有收藏的单词」。这里与书签/收藏句/制卡句同结构落 _CollectionItem。
    final allWords = await db.getAllFavoriteWords();

    final srtBooks = await srtBookRepo.listAll();
    final bookTitleMap = <String, String>{};
    for (final b in srtBooks) {
      if (b.bookKey.isNotEmpty) {
        bookTitleMap[b.bookKey] = b.title;
      }
    }

    final items = <_CollectionItem>[];

    for (final bm in allBookmarks) {
      items.add(
        _CollectionItem(
          type: _CollectionType.bookmark,
          createdAt: bm.createdAt,
          bookTitle: bm.bookTitle ??
              (bm.bookKey != null ? bookTitleMap[bm.bookKey] : null),
          bookKey: bm.bookKey,
          label: bm.label,
          sectionIndex: bm.sectionIndex,
          normCharOffset: bm.normCharOffset,
          bookmarkId: bm.id,
        ),
      );
    }

    for (final fav in allFavorites) {
      items.add(
        _CollectionItem(
          type: _CollectionType.sentence,
          createdAt: fav.createdAt,
          bookTitle: fav.bookTitle,
          bookKey: fav.bookKey,
          text: fav.text,
          chapterLabel: fav.chapterLabel,
          sectionIndex: fav.sectionIndex,
          normCharOffset: fav.normCharOffset,
          normCharLength: fav.normCharLength,
          favoriteId: fav.id,
          source: fav.source,
        ),
      );
    }

    // TODO-633 制卡历史：与收藏句同结构落 _CollectionItem，复用 _openBook /
    // _openVideoSentence 跳回原文（来源 book/video 由 row.source 区分）。
    for (final m in allMined) {
      items.add(
        _CollectionItem(
          type: _CollectionType.mined,
          createdAt: DateTime.fromMillisecondsSinceEpoch(m.createdAt),
          bookTitle: m.documentTitle,
          bookKey: m.bookKey,
          text: m.sentence.isNotEmpty ? m.sentence : m.expression,
          chapterLabel: m.chapterLabel,
          sectionIndex: m.sectionIndex,
          normCharOffset: m.normCharOffset,
          normCharLength: m.normCharLength,
          minedId: m.id,
          source: m.source,
        ),
      );
    }

    for (final w in allWords) {
      items.add(
        _CollectionItem(
          type: _CollectionType.word,
          createdAt: DateTime.fromMillisecondsSinceEpoch(w.createdAt),
          // text=词形（标题行）、chapterLabel=释义（副标题行）；无 bookKey（不可跳转，
          // 收藏词不携带原文定位）。删除复合键由 wordReading/wordSourceType 保留。
          text: w.expression,
          chapterLabel: w.glossary.isNotEmpty ? w.glossary : null,
          wordReading: w.reading,
          wordSourceType: w.sourceType,
          source: w.sourceType,
        ),
      );
    }

    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final allBookKeys = <String>{};
    for (final bm in allBookmarks) {
      if (bm.bookKey != null && bm.bookKey!.isNotEmpty) {
        allBookKeys.add(bm.bookKey!);
      }
    }
    for (final fav in allFavorites) {
      if (fav.bookKey != null && fav.bookKey!.isNotEmpty) {
        allBookKeys.add(fav.bookKey!);
      }
    }
    for (final m in allMined) {
      if (m.source != kFavoriteSentenceSourceVideo &&
          m.bookKey != null &&
          m.bookKey!.isNotEmpty) {
        allBookKeys.add(m.bookKey!);
      }
    }

    // 视频来源收藏句的 bookUid（按需查 VideoBooks 表）。视频句的 bookKey 是视频
    // bookUid，既不在 SrtBooks 也不在 Audiobooks 里，故单独解析。
    final videoBookUids = <String>{};
    for (final fav in allFavorites) {
      if (fav.source == kFavoriteSentenceSourceVideo &&
          fav.bookKey != null &&
          fav.bookKey!.isNotEmpty) {
        videoBookUids.add(fav.bookKey!);
      }
    }
    for (final m in allMined) {
      if (m.source == kFavoriteSentenceSourceVideo &&
          m.bookKey != null &&
          m.bookKey!.isNotEmpty) {
        videoBookUids.add(m.bookKey!);
      }
    }
    final videoRepo = VideoBookRepository(db);
    final videoRowMap = <String, VideoBookRow>{};
    for (final bookUid in videoBookUids) {
      final VideoBookRow? row = await videoRepo.getByBookUid(bookUid);
      if (row != null) videoRowMap[bookUid] = row;
    }

    final cueMap = <String, List<AudioCue>>{};
    final audioFileMap = <String, List<File>>{};

    final audiobookByKey = await abRepo.buildBookKeyMap();

    for (final bookKey in allBookKeys) {
      // SrtBook
      final srtBook = await srtBookRepo.findByBookKey(bookKey);
      if (srtBook != null) {
        final cues = await srtBookRepo.cuesFor(srtBook.uid);
        if (cues.isNotEmpty) {
          final audioFiles = await _resolveAudioFiles(
            audioPaths: srtBook.audioPaths,
            audioRoot: srtBook.audioRoot,
          );
          if (audioFiles.isNotEmpty) {
            cueMap[bookKey] = cues;
            audioFileMap[bookKey] = audioFiles;
            continue;
          }
        }
      }

      // Audiobook (Sasayaki)
      final ab = audiobookByKey[bookKey];
      if (ab == null) continue;

      final cues = await abRepo.cuesForBook(ab.bookKey);
      if (cues.isEmpty) continue;

      final audioFiles = await _resolveAudioFiles(
        audioPaths: ab.audioPaths,
        audioRoot: ab.audioRoot,
      );
      if (audioFiles.isEmpty) continue;

      cueMap[bookKey] = cues;
      audioFileMap[bookKey] = audioFiles;
    }

    if (mounted) {
      setState(() {
        _items = items;
        _bookTitleMap = bookTitleMap;
        _cueMap = cueMap;
        _audioFileMap = audioFileMap;
        _videoRowMap = videoRowMap;
        _loading = false;
      });
    }
  }

  void _openBook(_CollectionItem item) {
    final String? bookKey = item.bookKey;
    if (bookKey == null || bookKey.isEmpty) return;

    final String title = _bookTitleMap[bookKey] ?? item.bookTitle ?? '';

    final MediaItem mediaItem = buildCollectionReaderMediaItem(
      bookKey: bookKey,
      title: title,
    );

    // BUG-459: 三类行的 normCharOffset 计量不同——
    //   bookmark：0-10000 章内进度分数（reader `_addBookmarkAtCurrentPosition` 写）。
    //   sentence/mined：`getNormalizedOffset` 的章节内绝对可匹配字符索引（0..数千，
    //                   收藏 `_toggleFavoriteSentence` / 制卡 `_recordMinedSentence` 写）。
    // 旧代码把后者也塞进 Bookmark.normCharOffset，跳转端按分数 `/10000≈0` 还原 → 恒
    // 跳章首。这里按行类型分流：句子/制卡走绝对字符锚（charAnchor）让阅读器精确恢复，
    // 且标 preserveSavedPosition——临时浏览跳转不覆盖用户真实阅读进度。
    final bool isSentenceJump = item.type == _CollectionType.sentence ||
        item.type == _CollectionType.mined;
    final Bookmark? bookmark = item.sectionIndex != null
        ? Bookmark(
            sectionIndex: item.sectionIndex!,
            normCharOffset: isSentenceJump ? 0 : (item.normCharOffset ?? 0),
            charAnchor: isSentenceJump ? item.normCharOffset : null,
            // BUG-461: 句子/制卡跳转把句长一并透传，连续模式横排据此整句对齐进可见区，
            // 句尾不被阅读底栏切（句子行才有 normCharLength；制卡行/老收藏可能为 null）。
            charAnchorLength: isSentenceJump ? item.normCharLength : null,
            preserveSavedPosition: isSentenceJump,
            label: item.label ?? '',
            createdAt: item.createdAt,
          )
        : null;

    appModel.openMedia(
      ref: ref,
      mediaSource: ReaderHibikiSource.instance,
      item: mediaItem,
      initialBookmarkJump: bookmark,
    );
  }

  Future<void> _openVideoSentence(_CollectionItem item) async {
    final String? bookUid = item.bookKey;
    if (bookUid == null || bookUid.isEmpty) return;

    final VideoBookRepository repo = VideoBookRepository(appModel.database);
    final VideoBookRow? row = await repo.getByBookUid(bookUid);
    if (row == null) return;

    final int? startMs = await _resolveVideoFavoriteStartMs(repo, row, item);
    final target = resolveVideoFavoriteOpenTarget(
      row: row,
      favoriteSectionIndex: item.sectionIndex,
      favoriteStartMs: startMs,
    );
    if (!mounted) return;
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        builder: (_) => VideoHibikiPage.neutralized(
          bookUid: row.bookUid,
          repo: repo,
          initialCueStartMs: target.startMs,
          initialEpisodeIndex: target.episodeIndex,
          initialSubtitleListVisible: true,
        ),
      ),
    );
  }

  Future<int?> _resolveVideoFavoriteStartMs(
    VideoBookRepository repo,
    VideoBookRow row,
    _CollectionItem item,
  ) async {
    if (_isPlaylistVideo(row) && item.sectionIndex == null) {
      return null;
    }
    if (item.normCharOffset != null) return item.normCharOffset;
    final String? text = item.text?.trim();
    final String? bookUid = item.bookKey;
    if (text == null || text.isEmpty || bookUid == null || bookUid.isEmpty) {
      return null;
    }
    final List<AudioCue> cues = await repo.loadCues(bookUid);
    for (final AudioCue cue in cues) {
      if (cue.text.trim() == text) return cue.startMs;
    }
    return null;
  }

  bool _isPlaylistVideo(VideoBookRow row) =>
      playlistEpisodeCount(row.playlistJson) > 0;

  Future<List<File>> _resolveAudioFiles({
    required List<String>? audioPaths,
    required String? audioRoot,
  }) async {
    if (audioPaths != null && audioPaths.isNotEmpty) {
      final files = <File>[];
      for (final path in audioPaths) {
        final f = File(path);
        if (await f.exists()) files.add(f);
      }
      return files;
    }
    if (audioRoot != null) {
      final dir = Directory(audioRoot);
      if (!await dir.exists()) return [];
      final entries = await dir.list().toList();
      final files = entries.whereType<File>().where((f) {
        final ext = f.path.toLowerCase();
        return ext.endsWith('.mp3') ||
            ext.endsWith('.m4a') ||
            ext.endsWith('.m4b') ||
            ext.endsWith('.ogg') ||
            ext.endsWith('.aac') ||
            ext.endsWith('.wav') ||
            ext.endsWith('.mp4') ||
            ext.endsWith('.flac') ||
            ext.endsWith('.opus') ||
            ext.endsWith('.wma') ||
            ext.endsWith('.ac3') ||
            ext.endsWith('.eac3');
      }).toList()
        ..sort((a, b) => compareAudioFilePath(a.path, b.path));
      return files;
    }
    return [];
  }

  Future<void> _playItemAudio(_CollectionItem item) async {
    final String? bookKey = item.bookKey;
    if (bookKey == null || bookKey.isEmpty) {
      HibikiToast.show(msg: t.srt_audio_unresolved);
      return;
    }

    // 视频来源句：从收藏字段自带的 cue 时间窗 + 该集视频文件抽音（容器内交错，但
    // ffmpeg `-ss`/`-t` 在 `-i` 前快速输入定位，只解码这几秒，不读穿整个文件）。
    if (item.source == kFavoriteSentenceSourceVideo) {
      await _playVideoFavoriteAudio(item, bookKey);
      return;
    }

    final List<File>? audioFiles = _audioFileMap[bookKey];
    if (audioFiles == null || audioFiles.isEmpty) {
      HibikiToast.show(msg: t.srt_audio_unresolved);
      return;
    }

    final List<AudioCue>? cues = _cueMap[bookKey];
    if (cues == null || cues.isEmpty) {
      HibikiToast.show(msg: t.srt_audio_unresolved);
      return;
    }

    final AudioPlaybackRange? range = CollectionAudioMatcher.findPlaybackRange(
      cues: cues,
      sectionIndex: item.sectionIndex,
      normCharOffset: item.normCharOffset,
      normCharLength: item.normCharLength,
      text: item.text,
    );
    if (range == null) {
      HibikiToast.show(msg: t.srt_audio_unresolved);
      return;
    }
    if (range.audioFileIndex < 0 || range.audioFileIndex >= audioFiles.length) {
      HibikiToast.show(msg: t.srt_audio_unresolved);
      return;
    }

    await _extractAndPlay(
      inputPath: audioFiles[range.audioFileIndex].path,
      startMs: range.startMs,
      endMs: range.endMs,
    );
  }

  /// 视频来源收藏句的音频播放：用 [resolveVideoFavoriteAudioClip] 从该集视频文件 +
  /// 收藏自带的时间窗解析出 `[startMs, endMs)`，再走 [_extractAndPlay] 抽音播放。
  /// 无法解析（缺 row / 缺起点时长 / 播放列表越界）时提示。
  Future<void> _playVideoFavoriteAudio(
    _CollectionItem item,
    String bookUid,
  ) async {
    final VideoBookRow? row = _videoRowMap[bookUid];
    if (row == null) {
      HibikiToast.show(msg: t.srt_audio_unresolved);
      return;
    }
    final ({String filePath, int startMs, int endMs})? clip =
        resolveVideoFavoriteAudioClip(
      row: row,
      favoriteSectionIndex: item.sectionIndex,
      favoriteStartMs: item.normCharOffset,
      favoriteDurationMs: item.normCharLength,
    );
    if (clip == null) {
      HibikiToast.show(msg: t.srt_audio_unresolved);
      return;
    }
    await _extractAndPlay(
      inputPath: clip.filePath,
      startMs: clip.startMs,
      endMs: clip.endMs,
    );
  }

  /// 抽取 [inputPath] 的 `[startMs, endMs)` 段并播放。抽取失败（ffmpeg 不存在 / 损坏 /
  /// 退出非零，返回 null）时弹 [t.audio_clip_failed] 提示——BUG-252：原先 result==null
  /// 静默无反馈，用户看到「点了没用」；现在明确告知是音频截取失败而非按钮坏了。
  /// 桌面端经 [TtsChannel.extractAudioSegment] → ffmpeg；ffmpeg 可执行的「覆盖>捆绑>
  /// PATH」解析与捆绑损坏自动回退 PATH 由 ffmpeg_backend.dart 统一保证（BUG-233）。
  Future<void> _extractAndPlay({
    required String inputPath,
    required int startMs,
    required int endMs,
  }) async {
    setState(() => _playingAudio = true);
    try {
      final Directory tmpDir = await getTemporaryDirectory();
      final String outputPath = p.join(
        tmpDir.path,
        'collections_audio_segment.aac',
      );

      final String? result = await TtsChannel.instance.extractAudioSegment(
        inputPath: inputPath,
        startMs: startMs,
        endMs: endMs,
        outputPath: outputPath,
      );
      if (result != null) {
        await TtsChannel.instance.playFile(result);
      } else {
        HibikiToast.show(msg: t.audio_clip_failed);
      }
    } finally {
      if (mounted) setState(() => _playingAudio = false);
    }
  }

  Future<void> _deleteItem(_CollectionItem item) async {
    final db = appModel.database;
    if (item.type == _CollectionType.bookmark) {
      final bookKey = item.bookKey;
      if (bookKey == null || bookKey.isEmpty) return;
      final repo = BookmarkRepository(db);
      final bookmarkId = item.bookmarkId;
      if (bookmarkId != null) {
        await repo.removeBookmarkById(bookmarkId);
      } else {
        await repo.removeBookmarkMatching(
          bookKey,
          sectionIndex: item.sectionIndex ?? 0,
          normCharOffset: item.normCharOffset ?? 0,
          createdAt: item.createdAt,
        );
      }
    } else if (item.type == _CollectionType.mined) {
      // TODO-633：制卡历史按行 id 删一条。
      final minedId = item.minedId;
      if (minedId == null) return;
      await db.removeMinedSentence(minedId);
    } else if (item.type == _CollectionType.word) {
      // BUG-462：收藏词按 (expression, reading, sourceType) 复合唯一键删除（与
      // [HibikiDatabase.addFavoriteWord] 的 uniqueKeys 对齐）。
      final String? expression = item.text;
      if (expression == null || expression.isEmpty) return;
      await db.removeFavoriteWord(
        expression: expression,
        reading: item.wordReading ?? '',
        sourceType: item.wordSourceType ?? kFavoriteSentenceSourceBook,
      );
    } else {
      final id = item.favoriteId;
      if (id == null) return;
      await FavoriteSentenceRepository(db).removeById(id);
    }
    setState(() => _items.remove(item));
  }

  /// 当前列表中是否存在制卡历史条目（TODO-633 W1）。AppBar 的「清空制卡历史」按钮
  /// 仅在为真时显示——没有制卡句时不渲染该按钮（避免对空集合提供清空入口）。
  bool get _hasMinedItems =>
      _items.any((item) => item.type == _CollectionType.mined);

  /// 清空全部制卡历史（TODO-633 W1）：弹 adaptive 确认对话框（复用 [CollectionDeleteDialog]
  /// 的销毁确认范式，message 用 [Translations] 的 `collection_mined_clear_confirm`），
  /// 确认后调 [HibikiDatabase.clearMinedSentences] 一次性删表，再本地移除所有
  /// [_CollectionType.mined] 项刷新列表（与单条 [_deleteItem] 同样走本地 setState，
  /// 不重跑昂贵的 [_load] 音频解析）。仅清空制卡句，不触碰书签 / 收藏句。
  Future<void> _clearMinedHistory() async {
    final bool confirmed = await showAppDialog<bool>(
          context: context,
          builder: (ctx) => CollectionDeleteDialog(
            message: t.collection_mined_clear_confirm,
            onConfirm: () => Navigator.pop(ctx, true),
          ),
        ) ??
        false;
    if (!confirmed) return;

    await appModel.database.clearMinedSentences();
    if (!mounted) return;
    setState(() {
      _items.removeWhere((item) => item.type == _CollectionType.mined);
    });
  }

  /// 当前列表中是否存在可导出条目（收藏句或制卡句任一存在即显示，TODO-913）。
  /// AppBar 的「导出」按钮仅在为真时显示；收藏词单独由导出面板内的全部导出处理。
  bool get _hasExportableItems => _items.any((item) =>
      item.type == _CollectionType.sentence ||
      item.type == _CollectionType.mined);

  /// 把当前列表里的收藏句转成导出载体（按 bookTitle 分组、来源透传）。
  List<ExportSentence> _favoriteSentencesForExport() => _items
      .where((item) => item.type == _CollectionType.sentence)
      .map((item) => ExportSentence(
            text: item.text ?? '',
            bookTitle: (item.bookTitle != null && item.bookTitle!.isNotEmpty)
                ? item.bookTitle!
                : t.collection_sentence,
            chapterLabel: item.chapterLabel,
            source: item.source,
            createdAt: item.createdAt,
          ))
      .toList();

  /// 打开导出面板（TODO-829 / 913 / 914）：勾选制卡句/收藏句（默认全勾）+ 去重开关
  /// （默认开），可单独导出收藏词；「全部」= 两类都勾，产出两段一份文件。
  Future<void> _openExportSheet() async {
    final List<ExportSentence> sentences = _favoriteSentencesForExport();
    // 按 bookTitle 分组出可选书目（恒非空键）。
    final List<String> bookTitles = <String>[];
    for (final ExportSentence s in sentences) {
      if (!bookTitles.contains(s.bookTitle)) bookTitles.add(s.bookTitle);
    }

    final _ExportChoice? choice = await showModalBottomSheet<_ExportChoice>(
      context: context,
      builder: (ctx) => _ExportSheet(bookTitles: bookTitles),
    );
    if (choice == null || !mounted) return;

    // 收藏词独立项：与三模式并列，单独成文件（不进句料、不参与去重）。
    if (choice.includeWords) {
      await _exportAllWords(choice.format);
      if (!mounted) return;
    }

    final bool wantMined = choice.scopes.contains(ExportScope.mined);
    final bool wantFavorites = choice.scopes.contains(ExportScope.favorites);
    if (!wantMined && !wantFavorites) return; // 仅导收藏词时已处理完。

    if (wantMined && wantFavorites) {
      await _exportCombined(choice);
    } else if (wantMined) {
      await _exportMinedOnly(choice);
    } else {
      await _exportFavoritesOnly(choice);
    }
  }

  /// 读 DB 全量制卡句并映射成导出载体（与 913 口径一致）。
  Future<List<ExportMinedSentence>> _loadMinedForExport() async {
    final List<MinedSentenceRow> rows =
        await appModel.database.getAllMinedSentences();
    return rows
        .map((r) => ExportMinedSentence(
              sentence: r.sentence,
              expression: r.expression,
              reading: r.reading,
              glossary: r.glossary,
              bookTitle:
                  (r.documentTitle != null && r.documentTitle!.isNotEmpty)
                      ? r.documentTitle!
                      : t.collection_export_mined_title,
              source: r.source,
              createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
            ))
        .toList();
  }

  /// 读 DB 全量收藏句并映射成导出载体（口径=DB 全量，对齐制卡句 全量；不依赖页面
  /// 内存 [_items]，避免「全部」模式两段覆盖范围隐性不一致）。可选按书过滤。
  Future<List<ExportSentence>> _loadFavoritesForExport(
      {String? bookTitle}) async {
    final List<FavoriteSentence> all =
        await FavoriteSentenceRepository(appModel.database).getAll();
    final List<ExportSentence> mapped = all
        .map((FavoriteSentence f) => ExportSentence(
              text: f.text,
              bookTitle:
                  f.bookTitle.isNotEmpty ? f.bookTitle : t.collection_sentence,
              chapterLabel: f.chapterLabel,
              source: f.source,
              createdAt: f.createdAt,
            ))
        .toList();
    if (bookTitle == null) return mapped;
    return mapped
        .where((ExportSentence s) => s.bookTitle == bookTitle)
        .toList();
  }

  Future<void> _emptyExportToast() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.collection_export_no_items)),
    );
  }

  /// 仅制卡句（去重聚合 / 平铺二分，TODO-914）。
  Future<void> _exportMinedOnly(_ExportChoice choice) async {
    final List<ExportMinedSentence> items = await _loadMinedForExport();
    if (!mounted) return;
    if (items.isEmpty) {
      await _emptyExportToast();
      return;
    }
    final String content = choice.dedupe
        ? buildMinedGroupedExport(dedupeMinedBySentence(items),
            format: choice.format)
        : buildMinedExport(items, format: choice.format);
    await _saveExport(
      content: content,
      format: choice.format,
      baseName: t.collection_export_mined_title,
    );
  }

  /// 仅收藏句（去重 / 平铺二分；选具体书则只导该书，TODO-914）。
  Future<void> _exportFavoritesOnly(_ExportChoice choice) async {
    final List<ExportSentence> all =
        await _loadFavoritesForExport(bookTitle: choice.bookTitle);
    if (!mounted) return;
    if (all.isEmpty) {
      await _emptyExportToast();
      return;
    }
    final List<ExportSentence> rows =
        choice.dedupe ? dedupeSentences(all) : all;
    final String content = buildSentenceExport(rows, format: choice.format);
    await _saveExport(
      content: content,
      format: choice.format,
      baseName: choice.bookTitle ?? t.collection_export_sentences_title,
    );
  }

  /// 「全部」= 制卡句段 + 收藏句段，两段一份文件（段内各自去重，段间不互消，TODO-914）。
  Future<void> _exportCombined(_ExportChoice choice) async {
    final List<ExportMinedSentence> minedRows = await _loadMinedForExport();
    if (!mounted) return;
    final List<ExportSentence> favRows =
        await _loadFavoritesForExport(bookTitle: choice.bookTitle);
    if (!mounted) return;
    if (minedRows.isEmpty && favRows.isEmpty) {
      await _emptyExportToast();
      return;
    }
    // 「全部」模式两段语义需要 words 结构，制卡段恒按句聚合（dedupe 开关对收藏段生效）。
    final List<ExportMinedSentenceGroup> mined =
        dedupeMinedBySentence(minedRows);
    final List<ExportSentence> favorites =
        choice.dedupe ? dedupeSentences(favRows) : favRows;
    final String content = buildCombinedExport(
      mined: mined,
      favorites: favorites,
      format: choice.format,
    );
    await _saveExport(
      content: content,
      format: choice.format,
      baseName: t.dialog_export,
    );
  }

  /// 落盘/分享导出内容（统一文件名/meta 处理）。
  Future<void> _saveExport({
    required String content,
    required ExportFormat format,
    required String baseName,
  }) async {
    final ExportFileMeta meta = exportFileMeta(format);
    final String fileName = '${_sanitizeFileName(baseName)}.${meta.extension}';
    if (!mounted) return;
    await saveOrShareExport(
      context: context,
      content: content,
      fileName: fileName,
      mimeType: meta.mimeType,
      subject: baseName,
    );
  }

  /// 导出全部收藏词（按 sourceType 分组）。
  Future<void> _exportAllWords(ExportFormat format) async {
    final List<FavoriteWordRow> rows =
        await appModel.database.getAllFavoriteWords();
    if (!mounted) return;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.collection_export_no_items)),
      );
      return;
    }
    final List<ExportWord> words = rows
        .map((r) => ExportWord(
              expression: r.expression,
              reading: r.reading,
              glossary: r.glossary,
              sourceType: r.sourceType,
              createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
            ))
        .toList();
    final String content = buildWordExport(words, format: format);
    final ExportFileMeta meta = exportFileMeta(format);
    final String fileName =
        '${_sanitizeFileName(t.collection_export_words_title)}.${meta.extension}';
    if (!mounted) return;
    await saveOrShareExport(
      context: context,
      content: content,
      fileName: fileName,
      mimeType: meta.mimeType,
      subject: t.collection_export_words_title,
    );
  }

  /// 把书名/标题清洗成安全文件名（去掉路径分隔符和保留字符），用于默认导出文件名。
  String _sanitizeFileName(String name) {
    final String cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'export' : cleaned;
  }

  bool _hasAudio(_CollectionItem item) {
    // 视频来源句：有该视频的 row 且收藏自带可用 cue 时间窗即可抽音（不进 _cueMap）。
    if (item.source == kFavoriteSentenceSourceVideo) {
      final VideoBookRow? row = _videoRowMap[item.bookKey];
      if (row == null) return false;
      return resolveVideoFavoriteAudioClip(
            row: row,
            favoriteSectionIndex: item.sectionIndex,
            favoriteStartMs: item.normCharOffset,
            favoriteDurationMs: item.normCharLength,
          ) !=
          null;
    }
    return _cueMap.containsKey(item.bookKey) &&
        _audioFileMap.containsKey(item.bookKey);
  }

  Future<void> _showItemDialog(_CollectionItem item) async {
    final isBookmark = item.type == _CollectionType.bookmark;
    final bool isVideoSentence =
        !isBookmark && item.source == kFavoriteSentenceSourceVideo;
    final canNavigate = item.bookKey != null && item.bookKey!.isNotEmpty;
    final hasAudio = _hasAudio(item);
    final displayTitle = isBookmark ? (item.label ?? '') : (item.text ?? '');
    final cs = Theme.of(context).colorScheme;

    await showAppDialog<void>(
      context: context,
      builder: (ctx) => CollectionItemDialogFrame(
        title: SelectableText(displayTitle, maxLines: 3),
        content: item.bookTitle != null
            ? Text(item.bookTitle!, style: textTheme.bodyMedium)
            : null,
        actions: [
          if (hasAudio)
            TextButton.icon(
              icon: Icon(
                _playingAudio ? Icons.hourglass_top : Icons.volume_up_outlined,
                size: 18,
              ),
              label: Text(t.dialog_play),
              onPressed: _playingAudio
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      _playItemAudio(item);
                    },
            ),
          if (!isBookmark && item.text != null)
            TextButton.icon(
              icon: const Icon(Icons.copy_outlined, size: 18),
              label: Text(t.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: item.text!));
                Navigator.pop(ctx);
              },
            ),
          TextButton.icon(
            icon: Icon(Icons.delete_outline, size: 18, color: cs.error),
            label: Text(t.dialog_delete, style: TextStyle(color: cs.error)),
            onPressed: () {
              Navigator.pop(ctx);
              _deleteItem(item);
            },
          ),
          if (canNavigate)
            FilledButton.icon(
              icon: Icon(
                isVideoSentence
                    ? Icons.movie_outlined
                    : Icons.menu_book_outlined,
                size: 18,
              ),
              label: Text(isVideoSentence ? t.nav_video : t.dialog_read),
              onPressed: () {
                Navigator.pop(ctx);
                if (isVideoSentence) {
                  _openVideoSentence(item);
                } else {
                  _openBook(item);
                }
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return HibikiPageScaffold(
      title: t.collections,
      actions: <Widget>[
        // TODO-829: 仅当存在收藏句条目时显示「导出/分享」。
        if (!_loading && _hasExportableItems)
          HibikiIconButton(
            tooltip: t.dialog_export,
            icon: Icons.ios_share_outlined,
            onTap: _openExportSheet,
          ),
        // TODO-633 W1: 仅当存在制卡句条目时显示「清空制卡历史」。
        if (!_loading && _hasMinedItems)
          HibikiIconButton(
            tooltip: t.dialog_clear,
            icon: Icons.delete_sweep_outlined,
            onTap: _clearMinedHistory,
          ),
      ],
      body: _loading
          ? Center(child: adaptiveIndicator(context: context))
          : _items.isEmpty
              ? Center(
                  child: HibikiPlaceholderMessage(
                    icon: Icons.collections_bookmark_outlined,
                    message: t.no_collections,
                  ),
                )
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, index) => _buildItem(_items[index]),
                ),
    );
  }

  Widget _buildItem(_CollectionItem item) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final isBookmark = item.type == _CollectionType.bookmark;
    final bool isMined = item.type == _CollectionType.mined;
    final bool isWord = item.type == _CollectionType.word;
    final IconData icon = isBookmark
        ? Icons.bookmark_outline
        : isMined
            ? Icons.style_outlined
            : isWord
                ? Icons.star_outline
                : Icons.format_quote_outlined;
    final String typeLabel = isBookmark
        ? t.collection_bookmark
        : isMined
            ? t.collection_mined
            : isWord
                ? t.collection_word
                : t.collection_sentence;

    final String title;
    final String? subtitle;

    final bool isVideoSentence =
        !isBookmark && !isWord && item.source == kFavoriteSentenceSourceVideo;

    if (isBookmark) {
      title = item.label ?? '';
      subtitle = item.bookTitle;
    } else if (isWord) {
      // BUG-462：收藏词标题=词形，副标题=读音 · 释义（无原文定位，不显示书名/章节）。
      title = item.text ?? '';
      subtitle = [
        if (item.wordReading != null && item.wordReading!.isNotEmpty)
          item.wordReading,
        item.chapterLabel,
      ].where((s) => s != null && s.isNotEmpty).join(' · ');
    } else {
      title = item.text ?? '';
      subtitle = [
        // 视频来源句子标注「视频」前缀，与书内/有声书来源区分（用现有 nav_video）。
        if (isVideoSentence) t.nav_video,
        item.bookTitle,
        item.chapterLabel,
      ].where((s) => s != null && s.isNotEmpty).join(' · ');
    }

    final canNavigate = item.bookKey != null && item.bookKey!.isNotEmpty;

    final key = isBookmark
        ? 'bm_${item.bookKey}_${item.createdAt.microsecondsSinceEpoch}'
        : isMined
            ? 'mined_${item.minedId}'
            : isWord
                ? 'word_${item.text}_${item.wordReading}_${item.wordSourceType}'
                : 'fav_${item.favoriteId}';

    return Dismissible(
      key: Key(key),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: EdgeInsets.only(
          right: tokens.spacing.card + tokens.spacing.gap / 2,
        ),
        color: Theme.of(context).colorScheme.error,
        child: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.onError,
        ),
      ),
      confirmDismiss: (_) async {
        final String message = isBookmark
            ? '${t.collection_bookmark}: ${item.label ?? ""}'
            : item.text ?? '';
        return await showAppDialog<bool>(
              context: context,
              builder: (ctx) => CollectionDeleteDialog(
                message: message,
                onConfirm: () => Navigator.pop(ctx, true),
              ),
            ) ??
            false;
      },
      onDismissed: (_) => _deleteItem(item),
      child: GamepadLongPressActions(
        // Gamepad: hold-A opens the same item menu a mouse long-press does.
        onLongPress: () => _showItemDialog(item),
        child: GestureDetector(
          onLongPress: () => _showItemDialog(item),
          child: HibikiListItem(
            leading: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  icon,
                  size: 20,
                  color: isBookmark
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.tertiary,
                ),
                Text(
                  typeLabel,
                  style: textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                if (subtitle != null && subtitle.isNotEmpty) subtitle,
                _dateFmt.format(item.createdAt),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_hasAudio(item))
                  HibikiIconButton(
                    tooltip: t.dialog_play,
                    icon: _playingAudio
                        ? Icons.hourglass_top
                        : Icons.volume_up_outlined,
                    size: 18,
                    enabled: !_playingAudio,
                    padding: EdgeInsets.all(tokens.spacing.gap / 2),
                    onTap: () => _playItemAudio(item),
                  ),
                if (!isBookmark && item.text != null)
                  HibikiIconButton(
                    tooltip: t.copy,
                    icon: Icons.copy_outlined,
                    size: 18,
                    padding: EdgeInsets.all(tokens.spacing.gap / 2),
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: item.text!));
                    },
                  ),
                if (canNavigate)
                  Icon(
                    Icons.chevron_right,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
            // Non-navigable rows still get an onTap so they are a gamepad focus
            // stop (otherwise hold-A / the item menu can never be reached).
            onTap: canNavigate
                ? () {
                    if (isVideoSentence) {
                      _openVideoSentence(item);
                    } else {
                      _openBook(item);
                    }
                  }
                : () => _showItemDialog(item),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
class CollectionItemDialogFrame extends StatelessWidget {
  const CollectionItemDialogFrame({
    required this.title,
    required this.content,
    required this.actions,
    super.key,
  });

  final Widget title;
  final Widget? content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 440,
      maxHeightFactor: 0.78,
      child: HibikiModalSheetFrame(
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.card,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DefaultTextStyle.merge(
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.listTitle.copyWith(
                fontWeight: FontWeight.w600,
              ),
              child: title,
            ),
            if (content != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              DefaultTextStyle.merge(
                style: tokens.type.listSubtitle,
                child: content!,
              ),
            ],
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: actions,
        ),
      ),
    );
  }
}

@visibleForTesting
class CollectionDeleteDialog extends StatelessWidget {
  const CollectionDeleteDialog({
    required this.message,
    required this.onConfirm,
    super.key,
  });

  final String message;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      child: HibikiModalSheetFrame(
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.card,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              padding: EdgeInsets.all(tokens.spacing.gap),
              decoration: BoxDecoration(
                color: colors.errorContainer,
                borderRadius: tokens.radii.controlRadius,
              ),
              child: Icon(
                Icons.delete_outline,
                color: colors.onErrorContainer,
                size: 20,
              ),
            ),
            SizedBox(width: tokens.spacing.gap + 4),
            Expanded(child: Text(message, style: tokens.type.listSubtitle)),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.dialog_close),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: onConfirm,
              child: Text(t.dialog_delete),
            ),
          ],
        ),
      ),
    );
  }
}

/// 导出面板的选择结果（TODO-914：可勾选多选 + 去重）。
class _ExportChoice {
  const _ExportChoice({
    required this.scopes,
    required this.includeWords,
    required this.dedupe,
    required this.format,
    this.bookTitle,
  });

  /// 勾选的内容范围（制卡句 / 收藏句）；空集合且未勾收藏词时导出按钮 disabled。
  final Set<ExportScope> scopes;

  /// 是否额外导出全部收藏词（独立成文件，不进句料、不去重）。
  final bool includeWords;

  /// 句级去重开关（默认 on）。
  final bool dedupe;
  final ExportFormat format;

  /// 收藏句仅导某本书时为目标书名；null = 全部书籍。
  final String? bookTitle;
}

/// 导出面板（TODO-829 + 913 MD3 + 914 可勾选去重）：勾选制卡句/收藏句（默认全勾）
/// + 去重开关（默认开）+ 可选收藏词 + 选格式（默认 Markdown）→ 确认返回 [_ExportChoice]。
/// 外壳走 [HibikiModalSheetFrame] + [HibikiDesignTokens]。焦点驱动可达：勾选项与去重
/// 均为共享 [HibikiListItem]（leading [Checkbox] / trailing [Switch]，整行 Tab → Enter
/// 翻转），格式是 [ChoiceChip]，确认是 [FilledButton]（勾选集空且未勾收藏词时
/// `onPressed: null` 灰掉）。
class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.bookTitles});

  final List<String> bookTitles;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  // 默认「全部」= 制卡句 + 收藏句都勾。
  final Set<ExportScope> _scopes = <ExportScope>{
    ExportScope.mined,
    ExportScope.favorites,
  };
  bool _includeWords = false;
  bool _dedupe = true;
  // 收藏句二级：null = 全部书籍；否则某本书。
  String? _targetBookTitle;
  ExportFormat _format = ExportFormat.markdown;

  static const Map<ExportFormat, String> _formatLabels = <ExportFormat, String>{
    ExportFormat.markdown: 'Markdown',
    ExportFormat.txt: 'TXT',
    ExportFormat.csv: 'CSV',
    ExportFormat.json: 'JSON',
  };

  bool get _canExport => _scopes.isNotEmpty || _includeWords;

  void _toggleScope(ExportScope scope, bool? on) {
    setState(() {
      if (on ?? false) {
        _scopes.add(scope);
      } else {
        _scopes.remove(scope);
      }
    });
  }

  void _confirm() {
    final _ExportChoice choice = _ExportChoice(
      scopes: Set<ExportScope>.of(_scopes),
      includeWords: _includeWords,
      dedupe: _dedupe,
      format: _format,
      bookTitle:
          _scopes.contains(ExportScope.favorites) ? _targetBookTitle : null,
    );
    Navigator.pop(context, choice);
  }

  /// 导出范围复选行（MD3）：共享 [HibikiListItem] + 裸 [Checkbox] 为 leading，
  /// 整行 `onTap` 翻转勾选——等价旧 [CheckboxListTile] 的勾选/回调/标题，外观
  /// 走设计令牌而非框架默认行。焦点驱动可达（Tab → Enter）。
  Widget _exportCheckRow({
    required String label,
    required bool checked,
    required ValueChanged<bool> onChanged,
  }) {
    return HibikiListItem(
      selected: checked,
      onTap: () => onChanged(!checked),
      leading: Checkbox(
        value: checked,
        onChanged: (bool? v) => onChanged(v ?? false),
      ),
      title: Text(label),
    );
  }

  /// 去重开关行（MD3）：共享 [HibikiListItem] + 裸 [Switch] 为 trailing，整行
  /// `onTap` 翻转——等价旧 [SwitchListTile] 的开关/回调/标题。
  Widget _exportSwitchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return HibikiListItem(
      selected: value,
      onTap: () => onChanged(!value),
      title: Text(label),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final EdgeInsets sectionPad = EdgeInsets.symmetric(
      horizontal: tokens.spacing.card,
    );

    return HibikiModalSheetFrame(
      title: t.dialog_export,
      maxHeightFactor: 0.82,
      scrollable: true,
      bodyPadding: EdgeInsets.fromLTRB(
        0,
        tokens.spacing.gap,
        0,
        tokens.spacing.gap,
      ),
      footerPadding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.gap,
        tokens.spacing.card,
        tokens.spacing.card,
      ),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // ── 导出范围（可勾选多选）──
          Padding(
            padding: sectionPad,
            child: Text(
              t.collection_export_scope,
              style: tokens.type.listSubtitle.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _exportCheckRow(
            label: t.collection_export_all_mined,
            checked: _scopes.contains(ExportScope.mined),
            onChanged: (bool v) => _toggleScope(ExportScope.mined, v),
          ),
          _exportCheckRow(
            label: t.collection_export_favorites_scope,
            checked: _scopes.contains(ExportScope.favorites),
            onChanged: (bool v) => _toggleScope(ExportScope.favorites, v),
          ),
          _exportCheckRow(
            label: t.collection_export_all_words,
            checked: _includeWords,
            onChanged: (bool v) => setState(() => _includeWords = v),
          ),
          // 勾了「收藏句」且存在书目时展开「全部书籍 / 某本书」二级。
          if (_scopes.contains(ExportScope.favorites) &&
              widget.bookTitles.isNotEmpty) ...<Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                0,
                tokens.spacing.card,
                tokens.spacing.gap,
              ),
              child: Text(
                t.collection_export_pick_book,
                style: tokens.type.listSubtitle,
              ),
            ),
            Padding(
              padding: EdgeInsets.only(left: tokens.spacing.card),
              child: RadioListTile<String?>(
                value: null,
                groupValue: _targetBookTitle,
                onChanged: (String? v) => setState(() => _targetBookTitle = v),
                title: Text(t.collection_export_all_books),
              ),
            ),
            for (final String title in widget.bookTitles)
              Padding(
                padding: EdgeInsets.only(left: tokens.spacing.card),
                child: RadioListTile<String?>(
                  value: title,
                  groupValue: _targetBookTitle,
                  onChanged: (String? v) =>
                      setState(() => _targetBookTitle = v),
                  title: Text(title, maxLines: 2),
                ),
              ),
          ],
          SizedBox(height: tokens.spacing.gap),
          // ── 去重开关 ──
          _exportSwitchRow(
            label: t.collection_export_dedupe,
            value: _dedupe,
            onChanged: (bool v) => setState(() => _dedupe = v),
          ),
          Divider(height: 1, thickness: 1, color: tokens.surfaces.outline),
          SizedBox(height: tokens.spacing.gap),
          // ── 格式 ──
          Padding(
            padding: sectionPad,
            child: Text(
              t.collection_export_format,
              style: tokens.type.listSubtitle.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.gap,
              tokens.spacing.card,
              0,
            ),
            child: Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                for (final ExportFormat f in ExportFormat.values)
                  ChoiceChip(
                    label: Text(_formatLabels[f]!),
                    selected: _format == f,
                    onSelected: (_) => setState(() => _format = f),
                  ),
              ],
            ),
          ),
        ],
      ),
      footer: Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          icon: const Icon(Icons.ios_share_outlined, size: 18),
          label: Text(t.dialog_export),
          onPressed: _canExport ? _confirm : null,
        ),
      ),
    );
  }
}
