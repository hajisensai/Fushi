import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/favorites/favorite_batch_mining_plan.dart';
import 'package:fushi/src/media/favorites/favorite_mining_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_webview_media.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 一条收藏写卡的结果，外加「整批要不要就此停下」。
///
/// [abortBatch] 只在 Anki 未配置时为真：那不是这一条的问题，后面每一条都会同样失败，
/// 批量流程据此只报一次、把剩下的标成跳过，而不是刷一屏同样的错误。
class FavoriteBatchMineOutcome {
  const FavoriteBatchMineOutcome(this.result, {this.abortBatch = false});

  final FavoriteBatchItemResult result;
  final bool abortBatch;
}

/// 收藏夹一键制卡的「媒体 + 落卡」执行层：拿到一条收藏和弹窗产出的词典字段后，
/// 配上句子媒体写进 Anki，并记制卡统计与制卡历史。不碰 UI、不碰 WebView。
///
/// 媒体口径与各宿主的手动制卡一致：
/// - 视频：本地文件走 [ImmersionMiningEngine]（与视频页同一引擎、同一套图片模式 /
///   动图格式 / 压缩档偏好）；
/// - 书 / 有声书 / 歌词：按收藏锚点在有声书 cue 里定位，[TtsChannel.extractAudioSegment]
///   截句子音频（与阅读器同一个裁剪入口、同一压缩档），封面取书的封面；
/// - 其余（游戏、流媒体、没挂有声书、锚点对不上）：纯文字卡，结果里写明原因。
///
/// 同一个 runner 实例在一批里复用：书的 cue / 音频文件 / 视频行按 bookKey 缓存，
/// 一本书收藏了几十句也只查一次库。
class FavoriteBatchMiningRunner {
  FavoriteBatchMiningRunner({
    required this.appModel,
    required this.repo,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AppModel appModel;
  final BaseAnkiRepository repo;
  final DateTime Function() _now;

  final Map<String, Future<_AudiobookSource?>> _audiobookCache =
      <String, Future<_AudiobookSource?>>{};
  final Map<String, Future<VideoBookRow?>> _videoCache =
      <String, Future<VideoBookRow?>>{};
  final Map<String, Future<EpubBookRow?>> _epubCache =
      <String, Future<EpubBookRow?>>{};

  FushiDatabase get _db => appModel.database;

  /// 写一条卡。[payload] 是 popup.js `fushiPopupBuildMinePayloadFor` 的产物（与手动
  /// 点「+」交给宿主的字段逐字段一致）。永不抛异常：任何意外都折成 failed。
  Future<FavoriteBatchMineOutcome> mine(
    FavoriteMiningItem item,
    Map<String, String> payload,
  ) async {
    try {
      return await _mine(item, payload);
    } catch (e, stack) {
      ErrorLogService.instance.log('FavoriteBatchMining.mine', e, stack);
      return FavoriteBatchMineOutcome(
        FavoriteBatchItemResult(
          status: FavoriteBatchItemStatus.failed,
          message: '$e',
        ),
      );
    }
  }

  Future<FavoriteBatchMineOutcome> _mine(
    FavoriteMiningItem item,
    Map<String, String> payload,
  ) async {
    // 外字等词典媒体：repo 落卡时从缓存读字节，必须先落盘（与弹窗 mineEntry 桥同序）。
    await writeDictionaryMediaCache(payload['dictionaryMedia'] ?? '');
    final Map<String, String> fields = Map<String, String>.of(payload)
      ..remove('entryIndex');
    final FavoriteMiningMediaPlan plan = await planFor(item);
    return switch (plan) {
      FavoriteVideoClipPlan() => _mineVideo(item, fields, plan),
      FavoriteAudioClipPlan() => _mineWithAudio(item, fields, plan),
      FavoriteTextOnlyPlan(:final FavoriteTextOnlyReason reason) =>
        _mineWithContext(
          item,
          fields,
          await _textContext(item),
          textOnlyReason: reason,
        ),
    };
  }

  /// 这一条该配什么媒体（查库 + 纯决策层）。公开给页面预览用。
  Future<FavoriteMiningMediaPlan> planFor(FavoriteMiningItem item) async {
    final String? bookKey = item.bookKey;
    if (item.isVideo) {
      if (bookKey == null || bookKey.isEmpty) {
        return const FavoriteTextOnlyPlan(FavoriteTextOnlyReason.videoMissing);
      }
      final VideoBookRow? row = await _videoRow(bookKey);
      final FavoriteMiningMediaPlan plan = planVideoFavoriteMedia(
        item: item,
        videoTitle: row?.title,
        videoPath: row?.videoPath,
        playlistJson: row?.playlistJson,
      );
      if (plan is FavoriteVideoClipPlan && !File(plan.filePath).existsSync()) {
        return const FavoriteTextOnlyPlan(FavoriteTextOnlyReason.videoMissing);
      }
      return plan;
    }
    if (item.source == kFavoriteSentenceSourceGame ||
        bookKey == null ||
        bookKey.isEmpty) {
      return const FavoriteTextOnlyPlan(FavoriteTextOnlyReason.noMediaSource);
    }
    final _AudiobookSource? audio = await _audiobook(bookKey);
    return planAudioFavoriteMedia(
      item: item,
      cues: audio?.cues ?? const <AudioCue>[],
      audioFiles: audio?.audioFiles ?? const <String>[],
    );
  }

  // ── 视频 ────────────────────────────────────────────────────────────────

  Future<FavoriteBatchMineOutcome> _mineVideo(
    FavoriteMiningItem item,
    Map<String, String> fields,
    FavoriteVideoClipPlan plan,
  ) async {
    final bool tagTitles = appModel.autoAddBookNameToTags;
    String? audioFailure;
    final ImmersionMiningResult res = await ImmersionMiningEngine().mine(
      ImmersionMiningRequest(
        fields: fields,
        mediaSource: plan.filePath,
        clipStartMs: plan.startMs,
        clipEndMs: plan.endMs,
        stillFrameAtMs: plan.startMs,
        sentence: item.sentence,
        cueSentence: item.sentence.isEmpty ? null : item.sentence,
        documentTitle: plan.documentTitle.isEmpty ? null : plan.documentTitle,
        source: AnkiMiningSource.video,
        bookTitleTag: tagTitles
            ? BaseAnkiRepository.sanitizeTitleTag(plan.titleTag)
            : null,
        imageMode: appModel.videoMiningImageMode,
        animatedFormat: appModel.videoMiningAnimatedFormat,
        stillFormat: appModel.videoMiningStillFormat,
      ),
      compression: _compression(),
      tempDir: getTemporaryDirectory().then((Directory d) => d.path),
      repo: repo,
      onAudioFailure: (String summary) => audioFailure ??= summary,
    );
    if (res.aborted) {
      // 与视频页同一纪律：应带句子音频却抽不出来 → 不建无音频的卡，如实报原因。
      final String reason =
          res.abortReason ??
          (audioFailure == null
              ? 'sentence audio export failed'
              : 'sentence audio export failed: $audioFailure');
      ErrorLogService.instance.log(
        'FavoriteBatchMining.video',
        reason,
        StackTrace.current,
      );
      return FavoriteBatchMineOutcome(
        FavoriteBatchItemResult(
          status: FavoriteBatchItemStatus.failed,
          message: reason,
        ),
      );
    }
    final Object? outcome = res.outcome;
    if (outcome is! MineOutcome) {
      return const FavoriteBatchMineOutcome(
        FavoriteBatchItemResult(
          status: FavoriteBatchItemStatus.failed,
          message: 'mining engine returned no outcome',
        ),
      );
    }
    return _land(
      item,
      fields,
      outcome,
      documentTitle: plan.documentTitle,
      statTitle: plan.titleTag,
    );
  }

  // ── 书 / 有声书 / 歌词 ──────────────────────────────────────────────────

  Future<FavoriteBatchMineOutcome> _mineWithAudio(
    FavoriteMiningItem item,
    Map<String, String> fields,
    FavoriteAudioClipPlan plan,
  ) async {
    final MiningMediaCompression compression = _compression();
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'fushi_favorite_mine_audio_',
    );
    try {
      String? failure;
      final String? audioPath = await TtsChannel.instance.extractAudioSegment(
        inputPath: plan.audioFilePath,
        startMs: plan.startMs,
        endMs: plan.endMs,
        outputPath: p.join(
          tempDir.path,
          'sentence.${immersionMiningAudioExtension()}',
        ),
        audioChannels: compression.audioChannels,
        audioBitrate: compression.audioBitrate,
        onFailure: (String summary) => failure ??= summary,
      );
      if (audioPath == null) {
        // 与阅读器同一纪律：有有声书、定位也对上了，却截不出音频 → 不悄悄降成
        // 纯文字卡，报失败让用户知道（多半是 ffmpeg 缺失 / 音频文件被移走）。
        final String reason = failure == null
            ? 'sentence audio export failed'
            : 'sentence audio export failed: $failure';
        ErrorLogService.instance.log(
          'FavoriteBatchMining.audio',
          reason,
          StackTrace.current,
        );
        return FavoriteBatchMineOutcome(
          FavoriteBatchItemResult(
            status: FavoriteBatchItemStatus.failed,
            message: reason,
          ),
        );
      }
      final _TextContext base = await _textContext(item);
      return await _mineWithContext(
        item,
        fields,
        base.withSentenceAudio(audioPath),
      );
    } finally {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (e, stack) {
        ErrorLogService.instance.log('FavoriteBatchMining.cleanup', e, stack);
      }
    }
  }

  Future<FavoriteBatchMineOutcome> _mineWithContext(
    FavoriteMiningItem item,
    Map<String, String> fields,
    _TextContext context, {
    FavoriteTextOnlyReason? textOnlyReason,
  }) async {
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: context.toAnki(item),
    );
    return _land(
      item,
      fields,
      outcome,
      documentTitle: context.documentTitle,
      statTitle: context.statTitle,
      textOnlyReason: textOnlyReason,
    );
  }

  /// 纯文字卡 / 有声书卡共用的上下文：句子、卡片标题、封面、书名标签。
  Future<_TextContext> _textContext(FavoriteMiningItem item) async {
    final String? bookKey = item.bookKey;
    String rawTitle = item.bookTitle ?? '';
    String? coverPath;
    if (item.isVideo && bookKey != null && bookKey.isNotEmpty) {
      final VideoBookRow? row = await _videoRow(bookKey);
      if (rawTitle.isEmpty) rawTitle = row?.title ?? '';
      return _TextContext(
        documentTitle: rawTitle,
        statTitle: rawTitle,
        titleTag: rawTitle,
        tagTitle: appModel.autoAddBookNameToTags,
      );
    }
    if (!item.isVideo && bookKey != null && bookKey.isNotEmpty) {
      final EpubBookRow? book = await _epubRow(bookKey);
      if (book != null) {
        if (rawTitle.isEmpty) rawTitle = book.title;
        coverPath = ReaderFushiSource.resolveCoverFilePath(
          extractDir: book.extractDir,
          coverPath: book.coverPath,
        );
      }
    }
    // 卡片上给人看的标题过显示门面（与阅读器 `displayTitleForBook` 同口径）；统计
    // 聚合键仍用原始标题（身份语境，见阅读器 mining.part.dart 的 P4 注释）。
    final String documentTitle = rawTitle.isEmpty
        ? ''
        : displayTitleForBook(bookKey: bookKey, rawTitle: rawTitle);
    return _TextContext(
      documentTitle: documentTitle,
      statTitle: rawTitle,
      titleTag: documentTitle,
      tagTitle: appModel.autoAddBookNameToTags,
      coverPath: coverPath,
    );
  }

  // ── 落卡收尾 ──────────────────────────────────────────────────────────────

  Future<FavoriteBatchMineOutcome> _land(
    FavoriteMiningItem item,
    Map<String, String> fields,
    MineOutcome outcome, {
    required String documentTitle,
    required String statTitle,
    FavoriteTextOnlyReason? textOnlyReason,
  }) async {
    // describeMineOutcome 的 error 分支自己写 ErrorLogService（logMineFailure）。
    final described = describeMineOutcome(outcome);
    switch (outcome.result) {
      case MineResult.success:
        if (described.record) {
          await _recordLanded(
            item,
            fields,
            outcome.noteId,
            documentTitle: documentTitle,
            statTitle: statTitle,
          );
        }
        final String? warning = outcome.audioWarning;
        return FavoriteBatchMineOutcome(
          FavoriteBatchItemResult(
            status: FavoriteBatchItemStatus.added,
            noteId: outcome.noteId,
            textOnlyReason: textOnlyReason,
            message: warning == null || warning.isEmpty ? null : warning,
          ),
        );
      case MineResult.queued:
        // Anki 暂不可达，卡已冻结进待发队列、稍后自动补发：对批量结果而言与
        // 成功同待遇（记账、计入已添加），message 说明它还没进 Anki。
        if (described.record) {
          await _recordLanded(
            item,
            fields,
            outcome.noteId,
            documentTitle: documentTitle,
            statTitle: statTitle,
          );
        }
        return FavoriteBatchMineOutcome(
          FavoriteBatchItemResult(
            status: FavoriteBatchItemStatus.added,
            textOnlyReason: textOnlyReason,
            message: described.message,
          ),
        );
      case MineResult.duplicate:
        return FavoriteBatchMineOutcome(
          FavoriteBatchItemResult(
            status: FavoriteBatchItemStatus.duplicate,
            message: described.message,
          ),
        );
      case MineResult.notConfigured:
        return FavoriteBatchMineOutcome(
          FavoriteBatchItemResult(
            status: FavoriteBatchItemStatus.failed,
            message: described.message,
          ),
          abortBatch: true,
        );
      case MineResult.error:
        return FavoriteBatchMineOutcome(
          FavoriteBatchItemResult(
            status: FavoriteBatchItemStatus.failed,
            message: described.message,
          ),
        );
    }
  }

  /// 与手动制卡成功时同两笔账：制卡统计（按书）+ 制卡历史（带收藏锚点，可回跳）。
  /// best-effort：记账失败不影响「卡已写入」这个事实。
  Future<void> _recordLanded(
    FavoriteMiningItem item,
    Map<String, String> fields,
    int? noteId, {
    required String documentTitle,
    required String statTitle,
  }) async {
    final String source = statSourceOf(item);
    final String? bookKey = item.bookKey == null || item.bookKey!.isEmpty
        ? null
        : item.bookKey;
    try {
      await _db.recordMiningEvent(
        bookKey: bookKey,
        title: statTitle,
        sourceType: source,
        at: _now(),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('FavoriteBatchMining.stats', e, stack);
    }
    try {
      await _db.addMinedSentence(
        source: source,
        dateKey: statTodayKey(),
        expression: fields['expression'] ?? item.expression,
        reading: fields['reading'] ?? item.reading,
        glossary: fields['glossary'] ?? '',
        sentence: item.sentence,
        documentTitle: documentTitle.isEmpty ? null : documentTitle,
        bookKey: bookKey,
        sectionIndex: item.sectionIndex,
        normCharOffset: item.normCharOffset,
        normCharLength: item.normCharLength,
        noteId: noteId,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('FavoriteBatchMining.history', e, stack);
    }
  }

  MiningMediaCompression _compression() => MiningMediaCompression.resolve(
    imageTier: appModel.miningImageQuality,
    audioTier: appModel.miningAudioQuality,
    format: appModel.videoMiningAnimatedFormat,
  );

  // ── 按 bookKey 缓存的查库 ─────────────────────────────────────────────────

  Future<VideoBookRow?> _videoRow(String bookUid) => _videoCache.putIfAbsent(
    bookUid,
    () => VideoBookRepository(_db).getByBookUid(bookUid),
  );

  Future<EpubBookRow?> _epubRow(String bookKey) =>
      _epubCache.putIfAbsent(bookKey, () => _db.getEpubBook(bookKey));

  Future<_AudiobookSource?> _audiobook(String bookKey) =>
      _audiobookCache.putIfAbsent(bookKey, () => _loadAudiobook(bookKey));

  /// 与收藏夹页 `_load` 同一套来源解析：先 SRT 书（有 cue 且有音频才算），再
  /// Sasayaki 有声书。
  Future<_AudiobookSource?> _loadAudiobook(String bookKey) async {
    final SrtBook? srtBook = await SrtBookRepository(
      _db,
    ).findByBookKey(bookKey);
    if (srtBook != null) {
      final List<AudioCue> cues = await SrtBookRepository(
        _db,
      ).cuesFor(srtBook.uid);
      if (cues.isNotEmpty) {
        final List<String> files = await _resolveAudioFiles(
          audioPaths: srtBook.audioPaths,
          audioRoot: srtBook.audioRoot,
        );
        if (files.isNotEmpty) {
          return _AudiobookSource(cues: cues, audioFiles: files);
        }
      }
    }
    final AudiobookRepository abRepo = AudiobookRepository(_db);
    final Audiobook? ab = (await abRepo.buildBookKeyMap())[bookKey];
    if (ab == null) return null;
    final List<AudioCue> cues = await abRepo.cuesForBook(ab.bookKey);
    if (cues.isEmpty) return null;
    final List<String> files = await _resolveAudioFiles(
      audioPaths: ab.audioPaths,
      audioRoot: ab.audioRoot,
    );
    if (files.isEmpty) return null;
    return _AudiobookSource(cues: cues, audioFiles: files);
  }

  /// 文件模式：按给定顺序、只留仍在盘上的；文件夹模式：扫目录再排序。与收藏夹页
  /// `_resolveAudioFiles` 同口径（cue 的 audioFileIndex 依赖这个顺序）。
  static Future<List<String>> _resolveAudioFiles({
    required List<String>? audioPaths,
    required String? audioRoot,
  }) async {
    if (audioPaths != null && audioPaths.isNotEmpty) {
      final List<String> files = <String>[];
      for (final String path in audioPaths) {
        if (await File(path).exists()) files.add(path);
      }
      return files;
    }
    if (audioRoot == null) return const <String>[];
    final Directory dir = Directory(audioRoot);
    if (!await dir.exists()) return const <String>[];
    final List<FileSystemEntity> entries = await dir.list().toList();
    return selectAudiobookFilesInRoot(
      entries.whereType<File>().map((File f) => f.path),
    );
  }
}

class _AudiobookSource {
  const _AudiobookSource({required this.cues, required this.audioFiles});

  final List<AudioCue> cues;
  final List<String> audioFiles;
}

@immutable
class _TextContext {
  const _TextContext({
    required this.documentTitle,
    required this.statTitle,
    required this.titleTag,
    required this.tagTitle,
    this.coverPath,
    this.sentenceAudioPath,
  });

  final String documentTitle;
  final String statTitle;
  final String titleTag;

  /// 「自动添加书名到标签」开关（落卡那一刻的值）。
  final bool tagTitle;
  final String? coverPath;
  final String? sentenceAudioPath;

  _TextContext withSentenceAudio(String path) => _TextContext(
    documentTitle: documentTitle,
    statTitle: statTitle,
    titleTag: titleTag,
    tagTitle: tagTitle,
    coverPath: coverPath,
    sentenceAudioPath: path,
  );

  AnkiMiningContext toAnki(FavoriteMiningItem item) => AnkiMiningContext(
    sentence: item.sentence,
    cueSentence: sentenceAudioPath != null && item.sentence.isNotEmpty
        ? item.sentence
        : null,
    documentTitle: documentTitle.isEmpty ? null : documentTitle,
    coverPath: coverPath,
    sentenceAudioPath: sentenceAudioPath,
    source: ankiMiningSourceOf(item),
    bookTitleTag: tagTitle
        ? BaseAnkiRepository.sanitizeTitleTag(titleTag)
        : null,
  );
}
