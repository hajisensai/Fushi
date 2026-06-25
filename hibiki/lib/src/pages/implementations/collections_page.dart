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

enum _CollectionType { bookmark, sentence, mined }

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

    final Bookmark? bookmark = item.sectionIndex != null
        ? Bookmark(
            sectionIndex: item.sectionIndex!,
            normCharOffset: item.normCharOffset ?? 0,
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

  /// 当前列表中是否存在收藏句条目（TODO-829）。AppBar 的「导出」按钮仅在为真时显示
  /// （没有收藏句就没有可导出内容——收藏词单独由导出面板内的全部导出处理）。
  bool get _hasExportableSentences =>
      _items.any((item) => item.type == _CollectionType.sentence);

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

  /// 打开导出面板（TODO-829）：第一项按书分组导出收藏句，第二项导出全部收藏词。
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

    if (choice.kind == _ExportKind.sentencesByBook) {
      await _exportSentencesForBook(choice.bookTitle!, choice.format);
    } else {
      await _exportAllWords(choice.format);
    }
  }

  /// 导出某本书的收藏句。
  Future<void> _exportSentencesForBook(
    String bookTitle,
    ExportFormat format,
  ) async {
    final List<ExportSentence> all = _favoriteSentencesForExport();
    final List<ExportSentence> forBook =
        all.where((s) => s.bookTitle == bookTitle).toList();
    if (forBook.isEmpty) return;
    final String content = buildSentenceExport(forBook, format: format);
    final ExportFileMeta meta = exportFileMeta(format);
    final String fileName = '${_sanitizeFileName(bookTitle)}.${meta.extension}';
    if (!mounted) return;
    await saveOrShareExport(
      context: context,
      content: content,
      fileName: fileName,
      mimeType: meta.mimeType,
      subject: bookTitle,
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
        if (!_loading && _hasExportableSentences)
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
    final IconData icon = isBookmark
        ? Icons.bookmark_outline
        : isMined
            ? Icons.style_outlined
            : Icons.format_quote_outlined;
    final String typeLabel = isBookmark
        ? t.collection_bookmark
        : isMined
            ? t.collection_mined
            : t.collection_sentence;

    final String title;
    final String? subtitle;

    final bool isVideoSentence =
        !isBookmark && item.source == kFavoriteSentenceSourceVideo;

    if (isBookmark) {
      title = item.label ?? '';
      subtitle = item.bookTitle;
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

/// 导出目标种类（TODO-829）。
enum _ExportKind { sentencesByBook, allWords }

/// 导出面板的选择结果。
class _ExportChoice {
  const _ExportChoice({
    required this.kind,
    required this.format,
    this.bookTitle,
  });

  final _ExportKind kind;
  final ExportFormat format;

  /// [_ExportKind.sentencesByBook] 时为目标书名（恒非空）。
  final String? bookTitle;
}

/// 导出面板（TODO-829）：选目标（按书的收藏句 / 全部收藏词）+ 选格式（默认 Markdown）
/// → 确认返回 [_ExportChoice]。焦点驱动可达：所有可选项是 [RadioListTile]，格式是
/// [ChoiceChip]，确认是 [FilledButton]，Tab 可遍历、Enter 可确认。
class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.bookTitles});

  final List<String> bookTitles;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  // 目标：null 表示「全部收藏词」，否则为书名。
  late String? _targetBookTitle =
      widget.bookTitles.isNotEmpty ? widget.bookTitles.first : null;
  ExportFormat _format = ExportFormat.markdown;

  static const Map<ExportFormat, String> _formatLabels = <ExportFormat, String>{
    ExportFormat.markdown: 'Markdown',
    ExportFormat.txt: 'TXT',
    ExportFormat.csv: 'CSV',
    ExportFormat.json: 'JSON',
  };

  void _confirm() {
    final _ExportChoice choice = _targetBookTitle == null
        ? _ExportChoice(kind: _ExportKind.allWords, format: _format)
        : _ExportChoice(
            kind: _ExportKind.sentencesByBook,
            format: _format,
            bookTitle: _targetBookTitle,
          );
    Navigator.pop(context, choice);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                t.dialog_export,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            // ── 收藏句（按书） ──
            if (widget.bookTitles.isNotEmpty) ...<Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  t.collection_export_pick_book,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              for (final String title in widget.bookTitles)
                RadioListTile<String?>(
                  value: title,
                  groupValue: _targetBookTitle,
                  onChanged: (String? v) =>
                      setState(() => _targetBookTitle = v),
                  title: Text(title, maxLines: 2),
                ),
            ],
            // ── 全部收藏词 ──
            RadioListTile<String?>(
              value: null,
              groupValue: _targetBookTitle,
              onChanged: (String? v) => setState(() => _targetBookTitle = v),
              title: Text(t.collection_export_all_words),
            ),
            const Divider(),
            // ── 格式 ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                t.collection_export_format,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Wrap(
                spacing: 8,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  icon: const Icon(Icons.ios_share_outlined, size: 18),
                  label: Text(t.dialog_export),
                  onPressed: _confirm,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
