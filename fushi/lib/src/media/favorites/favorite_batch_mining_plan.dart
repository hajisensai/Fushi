import 'dart:convert';

import 'package:fushi/src/media/favorites/favorite_mining_item.dart';
import 'package:fushi_anki/fushi_anki.dart' show AnkiMiningSource;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart'
    show kStatSourceBook, kStatSourceGame, kStatSourceVideo;
import 'package:fushi_engine/media/video/m3u8_playlist.dart';

/// 收藏夹一键制卡：每一条收藏「该配什么句子媒体」的纯决策层（无 IO，可单测）。
///
/// 真正的抽取（ffmpeg 截音频 / 视频片段）与落卡在 `favorite_batch_mining_runner.dart`；
/// 这里只回答「这一条能不能配媒体、配哪个文件的哪一段、不能的话为什么」。
sealed class FavoriteMiningMediaPlan {
  const FavoriteMiningMediaPlan();
}

/// 视频收藏：对本地视频文件 [filePath] 的 `[startMs, endMs)` 走沉浸制卡引擎
/// （句子音频 + 动图/静帧封面，与视频页手动制卡同一条引擎）。
class FavoriteVideoClipPlan extends FavoriteMiningMediaPlan {
  const FavoriteVideoClipPlan({
    required this.filePath,
    required this.startMs,
    required this.endMs,
    required this.documentTitle,
    required this.titleTag,
  });

  final String filePath;
  final int startMs;
  final int endMs;

  /// 写到卡片 `{document-title}` 的显示标题（播放列表 =「系列名 - 剧集名」）。
  final String documentTitle;

  /// 书名标签候选（视频 = 作品标题；是否真的追加由「自动添加书名到标签」开关决定）。
  final String titleTag;
}

/// 书 / 有声书 / 歌词收藏：从有声书音频 [audioFilePath] 截 `[startMs, endMs)` 作句子音频。
class FavoriteAudioClipPlan extends FavoriteMiningMediaPlan {
  const FavoriteAudioClipPlan({
    required this.audioFilePath,
    required this.startMs,
    required this.endMs,
  });

  final String audioFilePath;
  final int startMs;
  final int endMs;
}

/// 为什么这一条只能制纯文字卡（诊断 / 结果列表里的说明用）。
enum FavoriteTextOnlyReason {
  /// 游戏收藏、或来源本来就没有可截的媒体。
  noMediaSource,

  /// 视频收藏的作品已不在库里（`VideoBooks` 查不到）。
  videoMissing,

  /// 视频收藏的锚点不完整（缺 cue 起点 / 时长非正 / 播放列表越界或解析失败）。
  videoAnchorUnusable,

  /// 该集是流媒体地址（http / 扩展源），不是本地文件，批量流程不去远端抽取。
  videoStreaming,

  /// 书收藏没有挂有声书（没有 cue 或没有音频文件）。
  noAudiobook,

  /// 挂了有声书，但收藏的句子在 cue 里对不上。
  audioRangeUnresolved,
}

class FavoriteTextOnlyPlan extends FavoriteMiningMediaPlan {
  const FavoriteTextOnlyPlan(this.reason);

  final FavoriteTextOnlyReason reason;
}

/// 路径是否是本机文件（不是 `http://` / `anime-source://` 之类带 scheme 的地址）。
/// 与 `VideoSourceFingerprint.isLocalPath` 同一判据；Windows 盘符 `C:\` 不含 `://`。
bool isLocalMediaPath(String path) =>
    path.isNotEmpty && !RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(path);

/// 视频收藏 → 媒体计划。
///
/// 解析口径与收藏夹「播放这句」的 `resolveVideoFavoriteAudioClip`（collections_page.dart）
/// 逐字一致——那个函数是 `@visibleForTesting`，从 lib 引用会触发 CI 致命的
/// `invalid_use_of_visible_for_testing_member`，所以这里按同一规则再写一份，并由
/// `favorite_batch_mining_plan_test.dart` 钉住：
/// - [FavoriteMiningItem.normCharOffset] = cue 起点毫秒，[FavoriteMiningItem.normCharLength]
///   = cue 时长毫秒；缺起点 / 时长非正 → 不可用；
/// - 单视频（[playlistJson] 无集）用 [videoPath]；播放列表按 [FavoriteMiningItem.sectionIndex]
///   （夹到合法范围）取那一集的路径。
///
/// [videoPath] 为 null 表示作品不在库（调用方查 `VideoBooks` 落空）。
FavoriteMiningMediaPlan planVideoFavoriteMedia({
  required FavoriteMiningItem item,
  required String? videoTitle,
  required String? videoPath,
  required String? playlistJson,
}) {
  if (videoPath == null) {
    return const FavoriteTextOnlyPlan(FavoriteTextOnlyReason.videoMissing);
  }
  final int? startMs = item.normCharOffset;
  final int duration = item.normCharLength ?? 0;
  if (startMs == null || startMs < 0 || duration <= 0) {
    return const FavoriteTextOnlyPlan(
      FavoriteTextOnlyReason.videoAnchorUnusable,
    );
  }
  final String seriesTitle = videoTitle ?? '';
  String filePath = videoPath;
  String documentTitle = seriesTitle;
  final int episodeCount = playlistEpisodeCount(playlistJson);
  if (episodeCount > 0) {
    final int episodeIndex = (item.sectionIndex ?? 0).clamp(
      0,
      episodeCount - 1,
    );
    final PlaylistEntry? entry = _playlistEntryAt(playlistJson!, episodeIndex);
    if (entry == null || entry.path.isEmpty) {
      return const FavoriteTextOnlyPlan(
        FavoriteTextOnlyReason.videoAnchorUnusable,
      );
    }
    filePath = entry.path;
    documentTitle = composeFavoriteVideoDocumentTitle(
      seriesTitle: seriesTitle,
      episodeTitle: entry.title,
    );
  }
  if (!isLocalMediaPath(filePath)) {
    return const FavoriteTextOnlyPlan(FavoriteTextOnlyReason.videoStreaming);
  }
  return FavoriteVideoClipPlan(
    filePath: filePath,
    startMs: startMs,
    endMs: startMs + duration,
    documentTitle: documentTitle,
    titleTag: seriesTitle,
  );
}

PlaylistEntry? _playlistEntryAt(String playlistJson, int index) {
  try {
    final Object? decoded = jsonDecode(playlistJson);
    if (decoded is! List || index < 0 || index >= decoded.length) return null;
    final Object? raw = decoded[index];
    if (raw is! Map<String, dynamic>) return null;
    return PlaylistEntry.fromJson(raw);
  } catch (_) {
    return null;
  }
}

/// 播放列表的卡片标题：「系列名 - 剧集名」，任一为空退化为另一个（与视频页
/// `composeVideoMiningDocumentTitle` 同口径）。
String composeFavoriteVideoDocumentTitle({
  required String seriesTitle,
  required String episodeTitle,
}) {
  if (seriesTitle.isEmpty) return episodeTitle;
  if (episodeTitle.isEmpty) return seriesTitle;
  return '$seriesTitle - $episodeTitle';
}

/// 书 / 有声书 / 歌词收藏 → 媒体计划。
///
/// [cues] / [audioFiles] 是该书挂的有声书（SRT 书或 Sasayaki 有声书，与收藏夹播放按钮
/// 同一套来源解析）；任一为空 = 没挂有声书 → 纯文字卡。句子定位走
/// [CollectionAudioMatcher.findPlaybackRange]（位置优先、文本兜底），与收藏夹「播放这句」
/// 同一个匹配器。
FavoriteMiningMediaPlan planAudioFavoriteMedia({
  required FavoriteMiningItem item,
  required List<AudioCue> cues,
  required List<String> audioFiles,
}) {
  if (cues.isEmpty || audioFiles.isEmpty) {
    return const FavoriteTextOnlyPlan(FavoriteTextOnlyReason.noAudiobook);
  }
  final String sentence = item.sentence.trim();
  final AudioPlaybackRange? range = CollectionAudioMatcher.findPlaybackRange(
    cues: cues,
    sectionIndex: item.sectionIndex,
    normCharOffset: item.normCharOffset,
    normCharLength: item.normCharLength,
    text: sentence.isEmpty ? null : sentence,
  );
  if (range == null ||
      range.audioFileIndex < 0 ||
      range.audioFileIndex >= audioFiles.length ||
      range.endMs <= range.startMs) {
    return const FavoriteTextOnlyPlan(
      FavoriteTextOnlyReason.audioRangeUnresolved,
    );
  }
  return FavoriteAudioClipPlan(
    audioFilePath: audioFiles[range.audioFileIndex],
    startMs: range.startMs,
    endMs: range.endMs,
  );
}

/// 卡片分类标签（`book` / `video` / `game`）。有声书 / 歌词都是「读书」语境，归书籍
/// ——与阅读器 / 有声书页手动制卡打的标签一致。
///
/// 按原始 [FavoriteMiningItem.source] 字符串判：[SentenceSourceKind] 没有 game 成员
/// （宽松解析会把 'game' 回退成 book），不能拿它区分游戏收藏。
AnkiMiningSource ankiMiningSourceOf(FavoriteMiningItem item) =>
    switch (item.source) {
      kFavoriteSentenceSourceVideo => AnkiMiningSource.video,
      kFavoriteSentenceSourceGame => AnkiMiningSource.game,
      _ => AnkiMiningSource.book,
    };

/// 制卡统计 / 制卡历史的来源桶（`mined_sentences.source` 与统计同值域）。
String statSourceOf(FavoriteMiningItem item) => switch (item.source) {
  kFavoriteSentenceSourceVideo => kStatSourceVideo,
  kFavoriteSentenceSourceGame => kStatSourceGame,
  _ => kStatSourceBook,
};

/// popup.js 回来的 payload 是不是**这一条**的：表记必须是这一条收藏的词，或本次查词
/// 结果里某个词条的表记。防的是渲染信号串台——上一条的渲染回执晚到、被当成这一条
/// 渲染完成，于是拿上一个词的释义制了这一张卡。对不上宁可判失败，也不制一张张冠李戴
/// 的卡。只比表记不比读音：弹窗的词条来自原生 popupJson，读音写法（空串 / 与表记相同）
/// 未必与 Dart 侧 entries 逐字节一致，比读音会把正常的卡误判成串台。
bool favoritePayloadBelongsToResult({
  required Map<String, String> payload,
  required String itemExpression,
  required Iterable<String> resultWords,
}) {
  final String expression = payload['expression'] ?? '';
  if (expression.isEmpty) return false;
  if (expression == itemExpression) return true;
  return resultWords.contains(expression);
}

/// 一条收藏在批量制卡里的结局。
enum FavoriteBatchItemStatus {
  pending,
  running,

  /// 已写入 Anki（可能是纯文字卡，见 [FavoriteBatchItemResult.textOnlyReason]）。
  added,

  /// Anki 里已有这张卡（按用户的查重设置），没有新增。
  duplicate,
  failed,

  /// 没轮到：用户中途停止，或 Anki 未配置导致整批中止。
  skipped,
}

class FavoriteBatchItemResult {
  const FavoriteBatchItemResult({
    required this.status,
    this.message,
    this.textOnlyReason,
    this.noteId,
  });

  const FavoriteBatchItemResult.pending()
    : status = FavoriteBatchItemStatus.pending,
      message = null,
      textOnlyReason = null,
      noteId = null;

  final FavoriteBatchItemStatus status;

  /// 给用户看的一句话（失败原因 / 媒体降级说明）；成功且有媒体时为 null。
  final String? message;

  /// 非 null = 这张卡没有句子媒体（纯文字卡），以及原因。
  final FavoriteTextOnlyReason? textOnlyReason;
  final int? noteId;

  bool get isFinished =>
      status != FavoriteBatchItemStatus.pending &&
      status != FavoriteBatchItemStatus.running;
}

/// 整批汇总（结束时的一行摘要）。
class FavoriteBatchSummary {
  const FavoriteBatchSummary({
    required this.added,
    required this.duplicate,
    required this.failed,
    required this.skipped,
  });

  factory FavoriteBatchSummary.of(Iterable<FavoriteBatchItemResult> results) {
    int added = 0;
    int duplicate = 0;
    int failed = 0;
    int skipped = 0;
    for (final FavoriteBatchItemResult r in results) {
      switch (r.status) {
        case FavoriteBatchItemStatus.added:
          added++;
        case FavoriteBatchItemStatus.duplicate:
          duplicate++;
        case FavoriteBatchItemStatus.failed:
          failed++;
        case FavoriteBatchItemStatus.skipped:
        case FavoriteBatchItemStatus.pending:
        case FavoriteBatchItemStatus.running:
          skipped++;
      }
    }
    return FavoriteBatchSummary(
      added: added,
      duplicate: duplicate,
      failed: failed,
      skipped: skipped,
    );
  }

  final int added;
  final int duplicate;
  final int failed;
  final int skipped;
}

/// 有声书「文件夹模式」下哪些文件算音频（与收藏夹播放按钮的目录扫描同一扩展名表），
/// 并按有声书的文件排序规则（[compareAudioFilePath]）排好——cue 的 `audioFileIndex`
/// 就是这个顺序里的下标。
List<String> selectAudiobookFilesInRoot(Iterable<String> paths) {
  const Set<String> audioExtensions = <String>{
    '.mp3',
    '.m4a',
    '.m4b',
    '.ogg',
    '.aac',
    '.wav',
    '.mp4',
    '.flac',
    '.opus',
    '.wma',
    '.ac3',
    '.eac3',
  };
  final List<String> files = paths.where((String path) {
    final String lower = path.toLowerCase();
    final int dot = lower.lastIndexOf('.');
    return dot >= 0 && audioExtensions.contains(lower.substring(dot));
  }).toList()..sort(compareAudioFilePath);
  return files;
}
