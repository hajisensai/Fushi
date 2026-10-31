import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart' show TableUpdateQuery, TableInfo;
import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_corpus/fushi_corpus.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart' show FushiDicts;
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart'
    show playlistEpisodeCount;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_music/fushi_music.dart'
    show FushiLyrics, LyricTimeline, decodeLyricTimeline;
import 'package:path/path.dart' as p;

import 'package:fushi/src/corpus/corpus_documents.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart'
    show parseStoredMusicLyrics;
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一批句子 → fushidicts 语料词元线格式（原样交给 fushi_corpus）。在后台 isolate 里调用。
typedef CorpusTermsFn = Uint8List Function(List<String> sentences);

/// 词元归一：「我库里的例句」按**词典的词形还原**建倒排，归一口径就是当前装载的词典集合。
///
/// 抽成接口是为了让服务的调度 / 增量 / 重建逻辑能在没有词典原生库的测试里跑（注入一个
/// 确定性的假词元器），生产只有 [FushiDictsCorpusNormalizer] 一个实现。
abstract interface class CorpusNormalizer {
  /// 当前归一口径的签名；没有任何释义词典时为 null（没有词典就没有词典形，不建索引）。
  String? get signature;

  /// 在后台 isolate 里跑 [job]，给它一个可用的词元函数。[job] 只能捕获可发送的值。
  /// 归一器暂不可用（词典正在重载 / 已释放）时返回 null。
  Future<T?> runInBackground<T>(T Function(CorpusTermsFn terms) job);
}

/// 生产实现：借当前 [FushiDicts] 句柄给后台 isolate（借用协议见
/// [FushiDicts.borrowForBackground]），后台里一次 FFI 处理一整批句子。
class FushiDictsCorpusNormalizer implements CorpusNormalizer {
  const FushiDictsCorpusNormalizer();

  @override
  String? get signature {
    // 有待办（词典集合刚变、还没装载）时不在这里触发同步装载——那会在 UI isolate 上一口气
    // 装完全部词典；等 app 自己的异步装载结算后，签名轮询（[_signatureWatch]）再来。
    if (!FushiDicts.isInitialized || FushiDicts.hasPendingDicts) return null;
    final List<String> paths = FushiDicts.instance.termDictionaryPaths;
    if (paths.isEmpty) return null;
    // 路径 + 目录修改时刻：同一路径重新导入（覆盖）也算换了词典。
    return corpusFingerprint(<Object?>[
      for (final String path in paths) ...<Object?>[path, _modifiedMs(path)],
    ]);
  }

  static int _modifiedMs(String path) {
    try {
      return Directory(path).statSync().modified.millisecondsSinceEpoch;
    } on FileSystemException {
      return 0;
    }
  }

  @override
  Future<T?> runInBackground<T>(T Function(CorpusTermsFn terms) job) {
    if (!FushiDicts.isInitialized || FushiDicts.hasPendingDicts) {
      return Future<T?>.value();
    }
    return FushiDicts.instance.borrowForBackground<T>(
      (int address, String? libraryPath) => Isolate.run<T>(
        () => job(
          (List<String> sentences) =>
              FushiDicts.corpusTermsBorrowed(address, libraryPath, sentences),
        ),
        debugName: 'fushi-corpus-ingest',
      ),
    );
  }
}

/// 建索引进度（设置页「我库里的例句」一行显示）。
class LibraryCorpusProgress {
  const LibraryCorpusProgress({
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.sentences,
    this.documents,
  });

  final bool running;
  final int done;
  final int total;

  /// 最近一次统计（null = 还没打开索引）。
  final int? sentences;
  final int? documents;
}

/// 「我库里的例句」（作品图谱 L4）的 app 侧编排：打开语料库、增量喂入、重建、查询。
///
/// 状态全在 native/fushi_corpus：这里只决定**什么时候**喂**什么**，不另存镜像。
///
/// 增量的来源：
/// - **书**：`epub_books` 表一变（导入 / 同步 / 备份恢复 / 删除）就按元数据指纹对账，
///   比挂在某个导入入口上可靠——互联拉书、备份合并都不经 `EpubImporter`。
/// - **视频**：播放页每次加载出 cue 就喂这一集（[feedVideoCues]，覆盖播放列表各集——
///   它们的字幕不落库）；对账时补上已落库 cue 但还没进索引的单视频。
/// - **音乐**：`music_lyrics` 表一变就按选中的歌词行对账（缓存的时间轴直接解码，缓存
///   过期的用 Rust 解析器重解）。
/// - **游戏**：文本钩子每收到一行台词就攒进当前批次（[feedGameLine]），去抖落盘——
///   这份就是游戏台词唯一的持久副本（文本钩子历史只在会话内存里）。
///
/// 词典换了（[CorpusNormalizer.signature] 变化）：已有文档从语料库读回原文
/// （`fcorp_export`）重新分词，不必回到来源。首次建索引逐份提交，中途退出下次接着做。
class LibraryCorpusService {
  LibraryCorpusService({
    CorpusNormalizer normalizer = const FushiDictsCorpusNormalizer(),
    Duration startDelay = const Duration(seconds: 20),
    Duration debounce = const Duration(seconds: 5),
    Duration gameFlushDelay = const Duration(seconds: 20),
  }) : _normalizer = normalizer,
       _startDelay = startDelay,
       _debounce = debounce,
       _gameFlushDelay = gameFlushDelay;

  /// app 唯一实例（[AppModel] 启动时 [start]）。
  static LibraryCorpusService instance = LibraryCorpusService();

  /// 「回到出处」的落地（由持有根 `WidgetRef` 的 app 根状态装上，见 main.dart）：查词弹窗
  /// 在 app 内 WebView 与 app 外查词窗里都有，打开书要 `openMedia(ref:)`，只有根状态有一个
  /// 始终活着的 ref。没装（测试 / 独立弹窗 entry point）时点击不跳。
  static Future<bool> Function(CorpusHit hit)? openHitHandler;

  /// 打开一条例句的出处。
  static Future<bool> openHit(CorpusHit hit) =>
      openHitHandler?.call(hit) ?? Future<bool>.value(false);

  final CorpusNormalizer _normalizer;
  final Duration _startDelay;
  final Duration _debounce;
  final Duration _gameFlushDelay;

  final ValueNotifier<LibraryCorpusProgress> progress =
      ValueNotifier<LibraryCorpusProgress>(const LibraryCorpusProgress());

  FushiDatabase? _db;
  String? _directory;
  bool Function() _isEnabled = () => false;
  Future<int?>? _opening;
  int? _address;
  Future<void> _serial = Future<void>.value();
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  final Map<String, Timer> _debouncers = <String, Timer>{};
  Timer? _startTimer;

  /// 词典集合变化的轮询：签名与上次对账时不同（导入 / 删除词典、启动时词典还没装好）
  /// 就整库对账一次（过期文档读回原文重新分词）。签名只是几次目录 stat，很便宜。
  Timer? _signatureWatch;
  String? _reconciledSignature;
  ExitFlushCallback? _exitFlush;
  int _jobsDone = 0;
  int _jobsTotal = 0;

  /// 启动：记下数据库 / 语料目录 / 开关，[_startDelay] 后打开索引并对账（不和首帧抢），
  /// 之后订阅来源表的变化做增量。重复调用以最后一次为准。
  void start({
    required FushiDatabase database,
    required String directory,
    required bool Function() isEnabled,
  }) {
    _db = database;
    _directory = directory;
    _isEnabled = isEnabled;
    _exitFlush ??= ExitFlushRegistry.instance.register(flushGameLines);
    _startTimer?.cancel();
    _startTimer = Timer(_startDelay, () {
      _startTimer = null;
      if (!_isEnabled()) return;
      _subscribe(database);
      scheduleReconcile();
    });
  }

  /// 开关变化（设置页）：打开时开始对账，关闭时停止喂入（索引留着，再开时增量补齐）。
  void onEnabledChanged() {
    final FushiDatabase? db = _db;
    if (db == null) return;
    if (_isEnabled()) {
      _subscribe(db);
      scheduleReconcile();
    } else {
      _unsubscribe();
    }
  }

  bool get enabled => _db != null && _isEnabled();

  void _subscribe(FushiDatabase db) {
    if (_subscriptions.isNotEmpty) return;
    void on(TableInfo<dynamic, dynamic> table, CorpusSourceKind kind) {
      _subscriptions.add(
        db
            .tableUpdates(TableUpdateQuery.onTable(table))
            .listen(
              (_) => _debounced(kind.name, () => _enqueueReconcile(kind)),
            ),
      );
    }

    on(db.epubBooks, CorpusSourceKind.book);
    on(db.videoBooks, CorpusSourceKind.video);
    on(db.musicLyrics, CorpusSourceKind.music);
    on(db.musicTracks, CorpusSourceKind.music);
    on(db.galgames, CorpusSourceKind.game);
    on(db.galgameTextLines, CorpusSourceKind.game);
    _signatureWatch ??= Timer.periodic(_signaturePollInterval, (_) {
      final String? signature = _normalizer.signature;
      if (signature != null && signature != _reconciledSignature) {
        scheduleReconcile();
      }
    });
  }

  static const Duration _signaturePollInterval = Duration(minutes: 2);

  void _unsubscribe() {
    for (final StreamSubscription<Object?> s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
    _signatureWatch?.cancel();
    _signatureWatch = null;
    for (final Timer t in _debouncers.values) {
      t.cancel();
    }
    _debouncers.clear();
  }

  void _debounced(String key, void Function() action) {
    _debouncers.remove(key)?.cancel();
    _debouncers[key] = Timer(_debounce, () {
      _debouncers.remove(key);
      action();
    });
  }

  /// 测试 / 关闭：停掉订阅与计时器，冲刷游戏台词，等在跑的任务结束。
  Future<void> stop() async {
    final ExitFlushCallback? exitFlush = _exitFlush;
    if (exitFlush != null) ExitFlushRegistry.instance.unregister(exitFlush);
    _exitFlush = null;
    _startTimer?.cancel();
    _startTimer = null;
    _unsubscribe();
    await flushGameLines();
    await _serial;
  }

  // ── 句柄 ─────────────────────────────────────────────────────────────

  /// 打开语料库（整库载入一遍，后台 isolate 里做）；失败记日志、返回 null。
  Future<int?> _index() {
    final int? address = _address;
    if (address != null) return Future<int?>.value(address);
    final String? dir = _directory;
    if (dir == null) return Future<int?>.value();
    return _opening ??= () async {
      try {
        final int opened = await _openInBackground(dir);
        _address = opened;
        return opened;
      } on Object catch (error, stack) {
        _opening = null;
        ErrorLogService.instance.log('corpus.open', error, stack);
        return null;
      }
    }();
  }

  static Future<int> _openInBackground(String dir) => Isolate.run(
    () => FushiCorpusIndex.open(dir).address,
    debugName: 'fushi-corpus-open',
  );

  /// 在后台 isolate 里对已打开的句柄做一次操作。[body] 必须来自下面的静态构造器
  /// （`_docsOp` 等）或静态函数，不能是实例方法里现写的闭包（见 [_inIsolate]）。
  Future<T?> _withIndex<T>(T Function(FushiCorpusIndex index) body) async {
    final int? address = await _index();
    if (address == null) return null;
    return _inIsolate(address, body);
  }

  /// 静态作用域里造交给 `Isolate.run` 的闭包：只捕获 [address] 与 [body]，不会把 `this`
  /// （计时器 / 订阅 / ValueNotifier 都不可发送）拖过 isolate 边界。
  static Future<T> _inIsolate<T>(
    int address,
    T Function(FushiCorpusIndex index) body,
  ) => Isolate.run(() => body(FushiCorpusIndex.attach(address)));

  static List<CorpusDocInfo> Function(FushiCorpusIndex) _docsOp(
    CorpusSourceKind kind, [
    String? key,
  ]) =>
      (FushiCorpusIndex i) => i.docs(kind: kind, key: key);

  static CorpusStats _statsOp(FushiCorpusIndex i) => i.stats();

  static CorpusDocument? Function(FushiCorpusIndex) _exportOp(
    CorpusSourceKind kind,
    String key,
    int part,
  ) =>
      (FushiCorpusIndex i) => i.export(kind, key, part);

  static int Function(FushiCorpusIndex) _removePartOp(
    CorpusSourceKind kind,
    String key,
    int part,
  ) =>
      (FushiCorpusIndex i) => i.remove(kind, key, part: part);

  static void Function(FushiCorpusIndex) _removeOp(
    CorpusSourceKind kind,
    List<String> keys,
  ) => (FushiCorpusIndex i) {
    for (final String key in keys) {
      i.remove(kind, key);
    }
  };

  /// 「重建」删得掉的文档：四类来源都能从各自的真相源重新生成（游戏台词自 v134 在
  /// `galgame_text_lines`）。只有播放列表各集字幕要等再次播放才回来（不落库）。
  static int _removeRebuildableOp(FushiCorpusIndex i) =>
      i.removeKinds(CorpusSourceKind.values);

  static CorpusQueryResult Function(FushiCorpusIndex) _queryOp(
    List<String> keys,
    int perKind,
    int perDoc,
  ) =>
      (FushiCorpusIndex i) => i.query(keys, perKind: perKind, perDoc: perDoc);

  // ── 查询 ─────────────────────────────────────────────────────────────

  /// 查词弹窗「我库里的例句」：按词典形 [keys] 查，每个模块至多 [perKind] 条、每份
  /// 文档至多 [perDoc] 条。关着 / 索引没打开时返回空结果（不在查词路径上触发整库载入）。
  Future<CorpusQueryResult> query(
    List<String> keys, {
    int perKind = 3,
    // 每份文档至多 2 条：一本书 / 一集里换个语境再给一句，又不至于整组被同一部作品占满。
    int perDoc = 2,
  }) async {
    final int? address = _address;
    if (!enabled || address == null || keys.isEmpty) {
      return CorpusQueryResult.empty;
    }
    try {
      return await _inIsolate(
        address,
        _queryOp(List<String>.of(keys), perKind, perDoc),
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('corpus.query', error, stack);
      return CorpusQueryResult.empty;
    }
  }

  /// 统计（设置页显示）。
  Future<CorpusStats?> stats() async {
    if (_db == null) return null;
    try {
      return await _withIndex(_statsOp);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('corpus.stats', error, stack);
      return null;
    }
  }

  // ── 任务队列 ──────────────────────────────────────────────────────────

  /// 串行跑 [job]（一个时刻只有一个喂入任务在后台占 CPU）。
  Future<void> _enqueue(String label, Future<void> Function() job) {
    _jobsTotal++;
    _publish();
    final Future<void> next = _serial.then((_) async {
      try {
        if (enabled) await job();
      } on Object catch (error, stack) {
        ErrorLogService.instance.log('corpus.$label', error, stack);
      } finally {
        _jobsDone++;
        if (_jobsDone >= _jobsTotal) {
          _jobsDone = 0;
          _jobsTotal = 0;
          unawaited(_refreshStats());
        }
        _publish();
      }
    });
    _serial = next;
    return next;
  }

  Future<void> _runNow(String label, Future<void> Function() job) async {
    try {
      if (enabled) await job();
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('corpus.$label', error, stack);
    }
  }

  void _publish({int? sentences, int? documents}) {
    final LibraryCorpusProgress old = progress.value;
    progress.value = LibraryCorpusProgress(
      running: _jobsTotal > 0,
      done: _jobsDone,
      total: _jobsTotal,
      sentences: sentences ?? old.sentences,
      documents: documents ?? old.documents,
    );
  }

  Future<void> _refreshStats() async {
    final CorpusStats? s = await stats();
    if (s != null) _publish(sentences: s.sentences, documents: s.docs);
  }

  /// 对账全部模块（启动 / 打开开关 / 重建之后）。
  void scheduleReconcile() {
    for (final CorpusSourceKind kind in CorpusSourceKind.values) {
      _enqueueReconcile(kind);
    }
  }

  void _enqueueReconcile(CorpusSourceKind kind) =>
      unawaited(_enqueue('reconcile.${kind.name}', () => _reconcile(kind)));

  /// 测试：直接分词写入一份文档（模拟旧版本留下的语料）。
  @visibleForTesting
  Future<void> debugPut(CorpusDocument doc) => _putDocument(doc);

  /// 测试观测：语料库里某个 kind 的文档清单。
  @visibleForTesting
  Future<List<CorpusDocInfo>> debugDocs(CorpusSourceKind kind) async =>
      await _withIndex(_docsOp(kind)) ?? const <CorpusDocInfo>[];

  /// 当前对账（与一次对账要喂入的文档）是不是已经跑完：给测试等。
  @visibleForTesting
  Future<void> get idle async {
    Future<void> current;
    do {
      current = _serial;
      await current;
    } while (!identical(current, _serial));
  }

  // ── 对账 ─────────────────────────────────────────────────────────────

  Future<void> _reconcile(CorpusSourceKind kind) async {
    final FushiDatabase? db = _db;
    final String? normalizer = _normalizer.signature;
    if (db == null || normalizer == null) return;
    _reconciledSignature = normalizer;
    final List<CorpusDocInfo>? docs = await _withIndex(_docsOp(kind));
    if (docs == null) return;
    switch (kind) {
      case CorpusSourceKind.book:
        await _reconcileBooks(db, docs, normalizer);
      case CorpusSourceKind.video:
        await _reconcileVideos(db, docs, normalizer);
      case CorpusSourceKind.music:
        await _reconcileMusic(db, docs, normalizer);
      case CorpusSourceKind.game:
        await _reconcileGames(db, docs, normalizer);
    }
  }

  Future<void> _removeOrphans(
    CorpusSourceKind kind,
    List<CorpusDocInfo> docs,
    Set<String> liveKeys,
  ) async {
    final Set<String> orphans = <String>{
      for (final CorpusDocInfo d in docs)
        if (!liveKeys.contains(d.key)) d.key,
    };
    if (orphans.isEmpty) return;
    await _withIndex(_removeOp(kind, orphans.toList()));
  }

  /// 归一口径过期的文档：从语料库读回原文、重新分词（不必回到来源）。
  Future<void> _renormalize(
    List<CorpusDocInfo> stale,
    String normalizer,
  ) async {
    for (final CorpusDocInfo info in stale) {
      final CorpusSourceKind? kind = info.kind;
      if (kind == null || !enabled) continue;
      final int? address = await _index();
      if (address == null) return;
      await _normalizer.runInBackground<void>(
        _renormalizeJob(address, kind, info.key, info.part, normalizer),
      );
    }
  }

  Future<void> _reconcileBooks(
    FushiDatabase db,
    List<CorpusDocInfo> docs,
    String normalizer,
  ) async {
    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    final Map<String, CorpusDocInfo> byKey = <String, CorpusDocInfo>{
      for (final CorpusDocInfo d in docs) d.key: d,
    };
    final Set<String> live = <String>{};
    for (final EpubBookRow row in rows) {
      // 只索引文字书（漫画 / PDF 等没有可切句的正文）。
      if (BookFormat.parseOrEpub(row.format) != BookFormat.epub) continue;
      live.add(row.bookKey);
      final String fingerprint = bookFingerprint(
        uid: row.uid,
        importedAt: row.importedAt,
        chapterCount: row.chapterCount,
        extractDir: row.extractDir,
      );
      final CorpusDocInfo? existing = byKey[row.bookKey];
      if (existing != null &&
          existing.fingerprint == fingerprint &&
          existing.normalizer == normalizer) {
        continue;
      }
      // 一本书一个任务：进度按份计，中途关掉开关 / 退出时没跑到的下次对账接着做。
      unawaited(
        _enqueue('book', () => _ingestBook(row, fingerprint, normalizer)),
      );
    }
    await _removeOrphans(CorpusSourceKind.book, docs, live);
  }

  Future<void> _ingestBook(
    EpubBookRow row,
    String fingerprint,
    String normalizer,
  ) async {
    final int? address = await _index();
    if (address == null) return;
    final String extractDir = row.extractDir;
    final String bookKey = row.bookKey;
    final String title = row.title;
    final int updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _normalizer.runInBackground<void>(
      _bookJob(
        address: address,
        extractDir: extractDir,
        bookKey: bookKey,
        title: title,
        fingerprint: fingerprint,
        normalizer: normalizer,
        updatedAt: updatedAt,
      ),
    );
  }

  Future<void> _reconcileVideos(
    FushiDatabase db,
    List<CorpusDocInfo> docs,
    String normalizer,
  ) async {
    final VideoBookRepository repo = VideoBookRepository(db);
    final List<VideoBookRow> rows = await repo.listAll();
    final Set<String> indexed = <String>{for (final d in docs) d.key};
    final Set<String> live = <String>{
      for (final VideoBookRow r in rows) r.bookUid,
    };
    await _removeOrphans(CorpusSourceKind.video, docs, live);
    await _renormalize(<CorpusDocInfo>[
      for (final CorpusDocInfo d in docs)
        if (live.contains(d.key) && d.normalizer != normalizer) d,
    ], normalizer);
    // 单视频的 cue 落库（播放列表各集不落库，只在播放时经 [feedVideoCues] 喂入）。
    for (final VideoBookRow row in rows) {
      if (indexed.contains(row.bookUid)) continue;
      if (playlistEpisodeCount(row.playlistJson) > 0) continue;
      unawaited(
        _enqueue('video', () async {
          final List<AudioCue> cues = await repo.loadCues(row.bookUid);
          if (cues.isEmpty) return;
          await _putDocument(
            videoCuesDocument(
              bookUid: row.bookUid,
              episodeIndex: 0,
              title: row.title,
              cues: cues,
              normalizer: normalizer,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }),
      );
    }
  }

  Future<void> _reconcileMusic(
    FushiDatabase db,
    List<CorpusDocInfo> docs,
    String normalizer,
  ) async {
    final List<MusicLyricRow> lyricRows = await db.select(db.musicLyrics).get();
    final Map<String, MusicLyricRow> chosen = <String, MusicLyricRow>{};
    for (final MusicLyricRow row in lyricRows) {
      final MusicLyricRow? current = chosen[row.trackUid];
      chosen[row.trackUid] = current == null
          ? row
          : _preferLyricRow(current, row);
    }
    final Map<String, String> titles = <String, String>{
      for (final MusicTrackRow t in await db.select(db.musicTracks).get())
        t.trackUid: t.title,
    };
    final Map<String, CorpusDocInfo> byKey = <String, CorpusDocInfo>{
      for (final CorpusDocInfo d in docs) d.key: d,
    };
    final Set<String> live = <String>{
      for (final String uid in chosen.keys)
        if (titles.containsKey(uid)) uid,
    };
    await _removeOrphans(CorpusSourceKind.music, docs, live);
    for (final String uid in live) {
      final MusicLyricRow row = chosen[uid]!;
      // 指纹只用行元数据：任一歌词行一变就整表对账，不能为了比对把每首歌的时间轴都解一遍。
      final String fingerprint = corpusFingerprint(<Object?>[
        row.source,
        row.updatedAt,
        row.offsetMs,
        row.isUserEdited,
        row.raw.length,
      ]);
      final CorpusDocInfo? existing = byKey[uid];
      if (existing != null &&
          existing.fingerprint == fingerprint &&
          existing.normalizer == normalizer) {
        continue;
      }
      final String title = titles[uid]!;
      unawaited(
        _enqueue('music', () async {
          final LyricTimeline? timeline = await _timelineOf(row);
          if (timeline == null) return;
          await _putDocument(
            lyricsDocument(
              trackUid: uid,
              title: title,
              timeline: timeline,
              normalizer: normalizer,
              updatedAt: row.updatedAt,
              fingerprint: fingerprint,
            ),
          );
        }),
      );
    }
  }

  /// 一首歌有多个歌词来源时取播放器会选的那一个的近似：用户编辑过的优先，其次最近更新的。
  static MusicLyricRow _preferLyricRow(MusicLyricRow a, MusicLyricRow b) {
    if (a.isUserEdited != b.isUserEdited) return a.isUserEdited ? a : b;
    return b.updatedAt > a.updatedAt ? b : a;
  }

  static Future<LyricTimeline?> _timelineOf(MusicLyricRow row) async {
    try {
      final LyricTimeline t;
      final Uint8List? cache = row.timelineCache;
      if (cache != null && row.timelineVersion == FushiLyrics.parserVersion) {
        t = decodeLyricTimeline(cache);
      } else {
        // 与歌词服务同一条「落库行 → 时间轴」：插件原始各轨要重新合并，手动指定的 ASS 行按
        // ASS 解析，不在这里另猜解析提示。
        t = await parseStoredMusicLyrics(
          row.raw,
          row.format,
          isUserEdited: row.isUserEdited,
          parse: _parseLyricsInBackground,
        );
      }
      return t.copyWith(offsetMs: row.offsetMs);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('corpus.lyrics', error, stack);
      return null;
    }
  }

  static Future<LyricTimeline> _parseLyricsInBackground(
    Uint8List raw,
    String hint,
    int? durationMs,
  ) => Isolate.run(
    () => FushiLyrics.parse(raw, hint: hint, durationMs: durationMs),
  );

  /// 游戏：语料文档由 `galgame_text_lines`（v134，台词唯一的持久副本，随备份走）派生，
  /// 一个游戏按本机 id 每 [kGalgameTextLineChunkSize] 行一块（part = id ~/ 块大小），新台词
  /// 只让最后一块变化。块的指纹 = 行数 + 最大 id（只增不改的表，两者不变内容就不变）。
  ///
  /// L4 首版把台词直接存在语料文档里（指纹没有 `db:` 前缀）：先把那些文档的原句读回、
  /// 写进表里再删掉文档，台词不丢。
  Future<void> _reconcileGames(
    FushiDatabase db,
    List<CorpusDocInfo> docs,
    String normalizer,
  ) async {
    final List<CorpusDocInfo> legacy = <CorpusDocInfo>[
      for (final CorpusDocInfo d in docs)
        if (!d.fingerprint.startsWith(kGameChunkFingerprintPrefix)) d,
    ];
    for (final CorpusDocInfo d in legacy) {
      final CorpusDocument? doc = await _withIndex<CorpusDocument?>(
        _exportOp(CorpusSourceKind.game, d.key, d.part),
      );
      if (doc != null) {
        await db
            .insertGalgameTextLines(d.key, <({String text, int receivedAt})>[
              for (final CorpusSentence s in doc.sentences)
                (text: s.text, receivedAt: s.pos),
            ]);
      }
      await _withIndex(_removePartOp(CorpusSourceKind.game, d.key, d.part));
    }
    final Map<String, String> titles = <String, String>{
      for (final GalgameRow g in await db.getAllGalgames()) g.id: g.name,
    };
    final Map<(String, int), CorpusDocInfo> byIdentity =
        <(String, int), CorpusDocInfo>{
          for (final CorpusDocInfo d in docs)
            if (d.fingerprint.startsWith(kGameChunkFingerprintPrefix))
              (d.key, d.part): d,
        };
    final Set<(String, int)> live = <(String, int)>{};
    for (final GalgameTextLineChunk chunk in await db.galgameTextLineChunks()) {
      final String? title = titles[chunk.gameId];
      if (title == null) continue;
      live.add((chunk.gameId, chunk.part));
      final String fingerprint = gameChunkFingerprint(
        count: chunk.count,
        maxId: chunk.maxId,
      );
      final CorpusDocInfo? existing = byIdentity[(chunk.gameId, chunk.part)];
      if (existing != null &&
          existing.fingerprint == fingerprint &&
          existing.normalizer == normalizer) {
        continue;
      }
      unawaited(
        _enqueue('game', () async {
          final List<GalgameTextLineRow> rows = await db
              .galgameTextLinesInChunk(chunk.gameId, chunk.part);
          await _putDocument(
            gameLinesDocument(
              gameId: chunk.gameId,
              title: title,
              part: chunk.part,
              lines: <({String text, int atMs})>[
                for (final GalgameTextLineRow r in rows)
                  (text: r.lineText, atMs: r.receivedAt),
              ],
              normalizer: normalizer,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
              fingerprint: fingerprint,
            ),
          );
        }),
      );
    }
    // 游戏被移除（台词随外键 cascade 删掉）/ 块不存在了：删文档。
    for (final MapEntry<(String, int), CorpusDocInfo> e in byIdentity.entries) {
      if (live.contains(e.key)) continue;
      await _withIndex(
        _removePartOp(CorpusSourceKind.game, e.key.$1, e.key.$2),
      );
    }
  }

  /// 分词 + 写入一份已构造好的文档（后台 isolate）。
  Future<void> _putDocument(CorpusDocument doc) async {
    final int? address = await _index();
    if (address == null) return;
    await _normalizer.runInBackground<void>(_putJob(address, doc));
  }

  // 后台任务闭包一律在静态作用域里造：交给 `Isolate.run` 的闭包只能捕获可发送的值，
  // 在实例方法里写的闭包可能把 `this`（含计时器 / 订阅）一起拖过 isolate 边界。

  static void Function(CorpusTermsFn) _putJob(
    int address,
    CorpusDocument doc,
  ) =>
      (CorpusTermsFn terms) =>
          _putWith(FushiCorpusIndex.attach(address), terms, doc);

  static void Function(CorpusTermsFn) _renormalizeJob(
    int address,
    CorpusSourceKind kind,
    String key,
    int part,
    String normalizer,
  ) => (CorpusTermsFn terms) {
    final FushiCorpusIndex index = FushiCorpusIndex.attach(address);
    final CorpusDocument? doc = index.export(kind, key, part);
    if (doc == null) return;
    _putWith(index, terms, withNormalizer(doc, normalizer));
  };

  /// 一本书：后台里解析 EPUB、逐章切句 + 换算阅读器锚点、逐章取词元，整本一次写入。
  static void Function(CorpusTermsFn) _bookJob({
    required int address,
    required String extractDir,
    required String bookKey,
    required String title,
    required String fingerprint,
    required String normalizer,
    required int updatedAt,
  }) => (CorpusTermsFn terms) {
    final List<CorpusSentence> sentences = <CorpusSentence>[];
    final BytesBuilder termBytes = BytesBuilder(copy: false);
    EpubBook? book;
    try {
      book = EpubParser.parseFromExtracted(extractDir);
    } on FormatException {
      // 解不开的书（容器 / OPF 坏了）：照样写一份空文档记下这个指纹，免得每次对账都重试；
      // 书被重新导入（指纹变了）时会再来。
      book = null;
    }
    for (int i = 0; i < (book?.chapters.length ?? 0); i++) {
      final List<CorpusSentence> chapter = bookChapterSentences(
        i,
        book!.chapterPlainText(i),
      );
      if (chapter.isEmpty) continue;
      sentences.addAll(chapter);
      // 一章一次词元 FFI：整本书一次的话词元缓冲在大书上会到几十 MB。
      termBytes.add(
        terms(<String>[for (final CorpusSentence s in chapter) s.text]),
      );
    }
    FushiCorpusIndex.attach(address).put(
      CorpusDocument(
        kind: CorpusSourceKind.book,
        key: bookKey,
        part: -1,
        title: title,
        fingerprint: fingerprint,
        normalizer: normalizer,
        updatedAt: updatedAt,
        sentences: sentences,
      ),
      termBytes.takeBytes(),
    );
  };

  static void _putWith(
    FushiCorpusIndex index,
    CorpusTermsFn terms,
    CorpusDocument doc,
  ) {
    index.put(doc, terms(<String>[for (final s in doc.sentences) s.text]));
  }

  // ── 播放 / 游戏的实时喂入 ────────────────────────────────────────────

  /// 视频页加载出一集字幕时调用：内容没变（指纹一致）就什么都不做。
  /// 只认本地库里有行的视频（网页剧集 / 远端原盘的临时 uid 不进索引——对账会把它们当
  /// 孤儿删掉，喂了也白喂）。
  void feedVideoCues({
    required String bookUid,
    required int episodeIndex,
    required List<AudioCue> cues,
  }) {
    final FushiDatabase? db = _db;
    if (db == null || !enabled || cues.isEmpty) return;
    final List<AudioCue> snapshot = List<AudioCue>.of(cues);
    unawaited(
      _enqueue('video', () async {
        final String? normalizer = _normalizer.signature;
        if (normalizer == null) return;
        final VideoBookRow? row = await VideoBookRepository(
          db,
        ).getByBookUid(bookUid);
        if (row == null) return;
        final CorpusDocument doc = videoCuesDocument(
          bookUid: bookUid,
          episodeIndex: episodeIndex,
          title: row.title,
          cues: snapshot,
          normalizer: normalizer,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
        final List<CorpusDocInfo>? existing = await _withIndex(
          _docsOp(CorpusSourceKind.video, bookUid),
        );
        if (existing == null) return;
        for (final CorpusDocInfo d in existing) {
          if (d.part == episodeIndex &&
              d.fingerprint == doc.fingerprint &&
              d.normalizer == normalizer) {
            return;
          }
        }
        await _putDocument(doc);
      }),
    );
  }

  final Map<String, _GameBatch> _gameBatches = <String, _GameBatch>{};
  Timer? _gameFlushTimer;

  /// 文本钩子收到一行台词（[lineKey] = 工作台行 id；同一行被引擎逐段重绘时文本会变长，
  /// 按 key 覆盖。外部通道没有行 id 时传 null，前缀续写按上一行覆盖）。攒批后写进
  /// `galgame_text_lines`（台词的持久副本，随备份走），语料文档随表变化对账派生。
  void feedGameLine({
    required String gameId,
    required String? lineKey,
    required String text,
    required int atMs,
  }) {
    if (!enabled || gameId.isEmpty) return;
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _gameBatches
        .putIfAbsent(gameId, () => _GameBatch(gameId))
        .add(lineKey, trimmed, atMs);
    _gameFlushTimer ??= Timer(_gameFlushDelay, () {
      _gameFlushTimer = null;
      unawaited(_flushGameLines(includeOpenLine: false));
    });
  }

  /// 把攒着的游戏台词全部落库（停止捕获 / 退出时；测试）。
  Future<void> flushGameLines() => _flushGameLines(includeOpenLine: true);

  /// 去抖落库时留下每个游戏的最后一行：它可能还在被引擎逐段重绘 / 打字机续写，现在写进去
  /// 再等它写完，表里就会多出一行半句（按 (游戏, 台词) 去重挡不住前缀）。
  Future<void> _flushGameLines({required bool includeOpenLine}) async {
    _gameFlushTimer?.cancel();
    _gameFlushTimer = null;
    final FushiDatabase? db = _db;
    if (db == null) return;
    for (final _GameBatch batch in _gameBatches.values.toList()) {
      final List<({String text, int receivedAt})> lines = batch.take(
        includeOpenLine: includeOpenLine,
      );
      if (lines.isEmpty) continue;
      // 不排进喂入队列：队列里可能正跑着一整本书，退出时的冲刷不能等它。
      await _runNow('game', () async {
        await db.insertGalgameTextLines(batch.gameId, lines);
      });
    }
    if (!includeOpenLine &&
        _gameBatches.values.any((_GameBatch b) => b.pending)) {
      _gameFlushTimer ??= Timer(_gameFlushDelay, () {
        _gameFlushTimer = null;
        unawaited(_flushGameLines(includeOpenLine: false));
      });
    }
  }

  // ── 重建 ─────────────────────────────────────────────────────────────

  /// 「重建索引」：删掉全部文档后整库对账（书 / 视频 / 音乐 / 游戏台词都从各自的真相源
  /// 重新生成）。播放列表各集字幕要等再次播放才会回来（它们不落库）。
  Future<void> rebuild() async {
    await _enqueue('rebuild', () async {
      await _withIndex(_removeRebuildableOp);
    });
    scheduleReconcile();
  }

  /// 语料目录：`<数据根>/corpus`。
  static String directoryUnder(String databaseDirectory) =>
      p.join(databaseDirectory, 'corpus');
}

/// 一个游戏当前在攒、还没落库的台词。
class _GameBatch {
  _GameBatch(this.gameId);

  final String gameId;

  final List<({String? key, String text, int atMs})> _lines =
      <({String? key, String text, int atMs})>[];

  bool get pending => _lines.isNotEmpty;

  void add(String? key, String text, int atMs) {
    if (_lines.isNotEmpty) {
      final ({String? key, String text, int atMs}) last = _lines.last;
      final bool sameLine = key != null
          ? last.key == key
          : last.key == null && text.startsWith(last.text);
      if (sameLine) {
        _lines[_lines.length - 1] = (key: key, text: text, atMs: last.atMs);
        return;
      }
      if (key != null) {
        for (int i = _lines.length - 1; i >= 0; i--) {
          if (_lines[i].key == key) {
            _lines[i] = (key: key, text: text, atMs: _lines[i].atMs);
            return;
          }
        }
      }
    }
    _lines.add((key: key, text: text, atMs: atMs));
  }

  /// 取走可以落库的行：[includeOpenLine] 为 false 时留下最后一行（可能还在续写）。
  List<({String text, int receivedAt})> take({required bool includeOpenLine}) {
    final int n = includeOpenLine ? _lines.length : _lines.length - 1;
    if (n <= 0) return const <({String text, int receivedAt})>[];
    final List<({String text, int receivedAt})> out =
        <({String text, int receivedAt})>[
          for (int i = 0; i < n; i++)
            (text: _lines[i].text, receivedAt: _lines[i].atMs),
        ];
    _lines.removeRange(0, n);
    return out;
  }
}
