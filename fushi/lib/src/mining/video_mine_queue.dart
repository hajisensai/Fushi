import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show BooleanExpressionOperators, OrderingTerm;
import 'package:fushi/src/mining/web_mine_queue_store.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 「看完再制卡」的暂存队列（在线视频，见 `VideoOnlineMiningMode.deferred`）。
///
/// 点制卡时引擎照常把封面与句子音频抽好（在线视频走播放器缓冲副本，本地秒出），但
/// **不写 Anki**：媒体拷进每条一个的暂存目录，行落进 `web_mine_queue`——与网页播放器
/// 的自动制卡队列同一张表、同一套 pending / done / failed 语义（每行冻结点击那一刻的
/// Anki 字段；那边是之后重放补媒体，这边媒体已经备好，之后只差写入）。两边按 `bookUid`
/// 分开（网页流媒体书是 `video/stream/…`），互不相见。
///
/// 表里没有的东西（卡面文本、标签、媒体文件名、统计与制卡历史的归属）放在暂存目录的
/// `meta.json`：它们只跟这一份媒体一起活，媒体没了行也就没法写入了，放一起反而一致。
class VideoMineQueue {
  VideoMineQueue({required this.db, required this.root});

  final FushiDatabase db;

  /// 暂存根目录（`<support>/video_mine_queue`），每行一个 `<id>/` 子目录。
  final Directory root;

  static const String dirName = 'video_mine_queue';
  static const String _metaFile = 'meta.json';

  WebMineQueueStore get _store => WebMineQueueStore(db);

  Directory bundleDir(int id) => Directory(p.join(root.path, '$id'));

  /// 把引擎备好的一张卡暂存起来（`ImmersionMiningRequest.stageNote` 里调用）。
  ///
  /// **必须在返回前拷走** [context] 里的媒体：引擎的临时文件名是固定的，下一张卡会覆盖。
  /// 返回新行 id。
  Future<int> stage({
    required String bookUid,
    required String videoKey,
    required Map<String, String> fields,
    required AnkiMiningContext context,
    required VideoMineStagedMeta meta,
  }) async {
    final int id = await _store.enqueue(
      bookUid: bookUid,
      videoKey: videoKey,
      href: '',
      cueStartMs: context.clipStartMs ?? 0,
      cueEndMs: context.clipEndMs ?? 0,
      sentence: context.sentence,
      cueSentence: context.cueSentence,
      fields: fields,
    );
    try {
      final Directory dir = bundleDir(id);
      await dir.create(recursive: true);
      final String? cover = await _copyInto(dir, context.coverPath, 'cover');
      final String? audio = await _copyInto(
        dir,
        context.sentenceAudioPath,
        'audio',
      );
      final VideoMineStagedMeta stored = meta.copyWith(
        coverFile: cover,
        audioFile: audio,
        synchronizedVideo: context.synchronizedVideo,
      );
      await File(
        p.join(dir.path, _metaFile),
      ).writeAsString(jsonEncode(stored.toJson()));
    } catch (_) {
      // 媒体没落稳就不留一个写不出去的半截行。
      await discard(id);
      rethrow;
    }
    return id;
  }

  /// 某本书（视频）还没写入的暂存卡，按点击顺序。
  Future<List<WebMineQueueRow>> pending(String bookUid) =>
      _store.pending(bookUid);

  /// 写入失败的暂存卡（Anki 没开 / 重复 等），供列表展示与重试。
  Future<List<WebMineQueueRow>> failed(String bookUid) async {
    return (db.select(db.webMineQueue)
          ..where(
            ($WebMineQueueTable t) =>
                t.bookUid.equals(bookUid) &
                t.status.equals(WebMineQueueStatus.failed),
          )
          ..orderBy(<OrderingTerm Function($WebMineQueueTable)>[
            ($WebMineQueueTable t) => OrderingTerm.asc(t.id),
          ]))
        .get();
  }

  /// 删掉一张暂存卡（行 + 媒体）。
  Future<void> discard(int id) async {
    await _store.remove(id);
    final Directory dir = bundleDir(id);
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 把 [bookUid] 下全部待写入（含之前失败的）暂存卡写进 Anki，按点击顺序串行。
  ///
  /// 每张：用暂存的媒体组 context → [BaseAnkiRepository.mineEntry] → 成功记统计与制卡
  /// 历史、删暂存；失败标 failed 留着（下次可重试），原因写进行里。暂存媒体丢了的行
  /// 同样标 failed——没有媒体就不建空壳卡（与引擎「无音频中止」同一纪律）。
  ///
  /// 同一 [bookUid] 的写入在进程内**串行**：列表弹窗的「全部写入」与退出页面时的
  /// 后台写入可能同时触发，两边若各自读到同一批 pending 行，就会把同一张卡写两遍，
  /// 或者后跑的一边把先跑那边已成功的行又标成 failed（重复）。第二个调用排在第一个
  /// 之后，等它写完再读 pending 行——那时已写完的行不在 pending 里了。锁是静态的：
  /// 调用方每次都新建 [VideoMineQueue]，锁必须跨实例。
  Future<VideoMineCommitSummary> commitAll({
    required String bookUid,
    required BaseAnkiRepository repo,
    void Function(int done, int total)? onProgress,
    DateTime Function() now = DateTime.now,
  }) async {
    final Future<void>? previous = _commitChains[bookUid];
    final Completer<void> done = Completer<void>();
    _commitChains[bookUid] = done.future;
    try {
      if (previous != null) await previous;
      return await _commitAllLocked(
        bookUid: bookUid,
        repo: repo,
        onProgress: onProgress,
        now: now,
      );
    } finally {
      done.complete();
      if (identical(_commitChains[bookUid], done.future)) {
        _commitChains.remove(bookUid);
      }
    }
  }

  /// 按 bookUid 串起来的 [commitAll] 链尾（完成 = 该作品当前没有写入在跑）。只会
  /// 正常完成，不带错误：链上某次写入抛错不能把后面排队的写入一起拖垮。
  static final Map<String, Future<void>> _commitChains =
      <String, Future<void>>{};

  Future<VideoMineCommitSummary> _commitAllLocked({
    required String bookUid,
    required BaseAnkiRepository repo,
    void Function(int done, int total)? onProgress,
    required DateTime Function() now,
  }) async {
    await _store.requeueFailed(bookUid);
    final List<WebMineQueueRow> rows = await _store.pending(bookUid);
    int succeeded = 0;
    final List<String> failures = <String>[];
    for (int i = 0; i < rows.length; i++) {
      final WebMineQueueRow row = rows[i];
      final String? error = await _commitOne(row, repo: repo, now: now);
      if (error == null) {
        succeeded++;
      } else {
        failures.add(error);
      }
      onProgress?.call(i + 1, rows.length);
    }
    return VideoMineCommitSummary(
      succeeded: succeeded,
      failed: failures.length,
      firstError: failures.isEmpty ? null : failures.first,
    );
  }

  /// 写入一行；成功返回 null，失败返回原因（行已标 failed）。
  Future<String?> _commitOne(
    WebMineQueueRow row, {
    required BaseAnkiRepository repo,
    required DateTime Function() now,
  }) async {
    final Directory dir = bundleDir(row.id);
    final VideoMineStagedMeta? meta = await _readMeta(dir);
    if (meta == null) {
      const String reason = 'staged media missing';
      await _store.markFailed(row.id, reason);
      return reason;
    }
    final String? coverPath = meta.coverFile == null
        ? null
        : p.join(dir.path, meta.coverFile);
    final String? audioPath = meta.audioFile == null
        ? null
        : p.join(dir.path, meta.audioFile);
    final AnkiMiningContext context = AnkiMiningContext(
      sentence: row.sentence,
      cueSentence: row.cueSentence,
      documentTitle: meta.documentTitle,
      coverPath: coverPath,
      sentenceAudioPath: audioPath,
      synchronizedVideo: meta.synchronizedVideo,
      source: AnkiMiningSource.video,
      bookTitleTag: meta.bookTitleTag,
      collectionTag: meta.collectionTag,
      clipStartMs: row.cueStartMs,
      clipEndMs: row.cueEndMs,
    );
    final Map<String, String> fields = decodeWebMineFields(row.fieldsJson);
    final MineOutcome outcome;
    try {
      outcome = await repo.mineEntry(
        rawPayloadJson: jsonEncode(fields),
        context: context,
      );
    } catch (e) {
      final String reason = '$e';
      await _store.markFailed(row.id, reason);
      return reason;
    }
    if (outcome.result != MineResult.success) {
      final String reason = outcome.result == MineResult.duplicate
          ? 'duplicate'
          : (outcome.errorDetail ?? outcome.result.name);
      await _store.markFailed(row.id, reason);
      return reason;
    }
    await _recordLanded(meta, fields, row.sentence, outcome.noteId, now());
    await _store.markDone(row.id, noteId: outcome.noteId);
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
    return null;
  }

  /// 与视频页即时制卡成功时同两笔账：制卡统计（按书）+ 制卡历史（可回跳）。best-effort。
  Future<void> _recordLanded(
    VideoMineStagedMeta meta,
    Map<String, String> fields,
    String sentence,
    int? noteId,
    DateTime at,
  ) async {
    try {
      await db.recordMiningEvent(
        bookKey: meta.statBookKey,
        title: meta.statTitle ?? '',
        sourceType: kStatSourceVideo,
        at: at,
      );
    } catch (_) {}
    if (!meta.recordHistory) return;
    try {
      await db.addMinedSentence(
        source: kStatSourceVideo,
        dateKey: meta.historyDateKey,
        expression: fields['expression'] ?? '',
        reading: fields['reading'] ?? '',
        glossary: fields['glossary'] ?? '',
        sentence: sentence,
        documentTitle: meta.historyDocumentTitle,
        bookKey: meta.historyBookKey,
        sectionIndex: meta.historySectionIndex,
        normCharOffset: meta.historyCueStartMs,
        normCharLength: meta.historyCueLengthMs,
        noteId: noteId,
      );
    } catch (_) {}
  }

  Future<VideoMineStagedMeta?> _readMeta(Directory dir) async {
    final File file = File(p.join(dir.path, _metaFile));
    try {
      if (!file.existsSync()) return null;
      final Object? raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, Object?>) return null;
      final VideoMineStagedMeta meta = VideoMineStagedMeta.fromJson(raw);
      for (final String? name in <String?>[meta.coverFile, meta.audioFile]) {
        if (name != null && !File(p.join(dir.path, name)).existsSync()) {
          return null;
        }
      }
      return meta;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _copyInto(
    Directory dir,
    String? source,
    String stem,
  ) async {
    if (source == null) return null;
    final File file = File(source);
    if (!file.existsSync()) return null;
    final String ext = p.extension(source);
    final String name = '$stem$ext';
    await file.copy(p.join(dir.path, name));
    return name;
  }
}

/// 一批写入的结局（OSD 用）。
class VideoMineCommitSummary {
  const VideoMineCommitSummary({
    required this.succeeded,
    required this.failed,
    this.firstError,
  });

  final int succeeded;
  final int failed;
  final String? firstError;
}

/// 暂存卡的附带信息（`meta.json`）。
class VideoMineStagedMeta {
  const VideoMineStagedMeta({
    this.documentTitle,
    this.bookTitleTag,
    this.collectionTag,
    this.coverFile,
    this.audioFile,
    this.synchronizedVideo = false,
    this.statBookKey,
    this.statTitle,
    this.recordHistory = true,
    this.historyDateKey = '',
    this.historyDocumentTitle,
    this.historyBookKey,
    this.historySectionIndex,
    this.historyCueStartMs,
    this.historyCueLengthMs,
  });

  factory VideoMineStagedMeta.fromJson(Map<String, Object?> json) {
    String? str(String key) {
      final Object? v = json[key];
      return v is String ? v : null;
    }

    int? integer(String key) {
      final Object? v = json[key];
      return v is int ? v : null;
    }

    return VideoMineStagedMeta(
      documentTitle: str('documentTitle'),
      bookTitleTag: str('bookTitleTag'),
      collectionTag: str('collectionTag'),
      coverFile: str('coverFile'),
      audioFile: str('audioFile'),
      synchronizedVideo: json['synchronizedVideo'] == true,
      statBookKey: str('statBookKey'),
      statTitle: str('statTitle'),
      recordHistory: json['recordHistory'] != false,
      historyDateKey: str('historyDateKey') ?? '',
      historyDocumentTitle: str('historyDocumentTitle'),
      historyBookKey: str('historyBookKey'),
      historySectionIndex: integer('historySectionIndex'),
      historyCueStartMs: integer('historyCueStartMs'),
      historyCueLengthMs: integer('historyCueLengthMs'),
    );
  }

  /// 卡面 `{document-title}`。
  final String? documentTitle;

  /// 「自动添加书名到标签」开时的番名 / 系列名标签（点击时已清洗）。
  final String? bookTitleTag;
  final String? collectionTag;

  /// 暂存目录里的媒体文件名（null = 这张卡本来就没有这项媒体）。
  final String? coverFile;
  final String? audioFile;
  final bool synchronizedVideo;

  /// 制卡统计的归属（视频页 `lookupBookIdentity`）。
  final String? statBookKey;
  final String? statTitle;

  /// 制卡历史行（收藏页可回跳）。回看已制卡片的会话不写历史，与即时路径一致。
  final bool recordHistory;
  final String historyDateKey;
  final String? historyDocumentTitle;
  final String? historyBookKey;
  final int? historySectionIndex;
  final int? historyCueStartMs;
  final int? historyCueLengthMs;

  VideoMineStagedMeta copyWith({
    String? coverFile,
    String? audioFile,
    bool? synchronizedVideo,
  }) => VideoMineStagedMeta(
    documentTitle: documentTitle,
    bookTitleTag: bookTitleTag,
    collectionTag: collectionTag,
    coverFile: coverFile ?? this.coverFile,
    audioFile: audioFile ?? this.audioFile,
    synchronizedVideo: synchronizedVideo ?? this.synchronizedVideo,
    statBookKey: statBookKey,
    statTitle: statTitle,
    recordHistory: recordHistory,
    historyDateKey: historyDateKey,
    historyDocumentTitle: historyDocumentTitle,
    historyBookKey: historyBookKey,
    historySectionIndex: historySectionIndex,
    historyCueStartMs: historyCueStartMs,
    historyCueLengthMs: historyCueLengthMs,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'documentTitle': documentTitle,
    'bookTitleTag': bookTitleTag,
    'collectionTag': collectionTag,
    'coverFile': coverFile,
    'audioFile': audioFile,
    'synchronizedVideo': synchronizedVideo,
    'statBookKey': statBookKey,
    'statTitle': statTitle,
    'recordHistory': recordHistory,
    'historyDateKey': historyDateKey,
    'historyDocumentTitle': historyDocumentTitle,
    'historyBookKey': historyBookKey,
    'historySectionIndex': historySectionIndex,
    'historyCueStartMs': historyCueStartMs,
    'historyCueLengthMs': historyCueLengthMs,
  };
}
