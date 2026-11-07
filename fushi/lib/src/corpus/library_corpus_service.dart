import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart' show TableUpdateQuery, TableInfo;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_corpus/fushi_corpus.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart' show FushiDicts;
import 'package:fushi_music/fushi_music.dart'
    show FushiLyrics, LyricTimeline, decodeLyricTimeline;
import 'package:path/path.dart' as p;

import 'package:fushi/src/corpus/corpus_documents.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart'
    show parseStoredMusicLyrics, preferredMusicLyricRow;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一批句子 → fushidicts 语料词元线格式（原样交给 fushi_corpus）。在后台 isolate 里调用。
typedef CorpusTermsFn = Uint8List Function(List<String> sentences);

/// 纯函数：词元线格式（每句 `u32 词数`，每词 `u32 起点 · u32 长度 · str 词典形`）里出现的
/// 全部词典形，去重、保持首次出现的顺序。文本搜索把查询文本分词后用它取查询键。
List<String> corpusTermKeys(Uint8List terms) {
  final ByteData v = ByteData.sublistView(terms);
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  int at = 0;
  int u32() {
    final int x = v.getUint32(at, Endian.little);
    at += 4;
    return x;
  }

  while (at + 4 <= terms.length) {
    final int count = u32();
    for (int i = 0; i < count; i++) {
      at += 8; // 起点 + 长度
      final int n = u32();
      final String lemma = utf8.decode(
        Uint8List.sublistView(terms, at, at + n),
        allowMalformed: true,
      );
      at += n;
      if (lemma.isNotEmpty && seen.add(lemma)) out.add(lemma);
    }
  }
  return out;
}

/// 词元归一：曲库歌词搜索按**词典的词形还原**建倒排，归一口径就是当前装载的词典集合。
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

/// 曲库「歌词命中」的本机语料库编排（native/fushi_corpus）：打开语料库、按歌词表增量喂入、
/// 文本搜索。
///
/// 状态全在 native/fushi_corpus：这里只决定**什么时候**喂**什么**，不另存镜像。
///
/// 来源只有**音乐**：`music_lyrics` / `music_tracks` 表一变就按选中的歌词行对账（缓存的
/// 时间轴直接解码，缓存过期的用 Rust 解析器重解）。词典换了（[CorpusNormalizer.signature]
/// 变化）就按新口径从歌词行重新分词。
///
/// 查词弹窗「我库里的例句」（书 / 视频 / 游戏台词也进索引）已按反馈 4S2_J80DfK 下架：
/// 旧版本留在语料目录里的这三类文档在每次启动的首轮对账前删掉（[_purgeRetiredKinds]，
/// 一文档一文件，删了就释放磁盘；没有残留时是空操作，天然幂等）。
class LibraryCorpusService {
  LibraryCorpusService({
    CorpusNormalizer normalizer = const FushiDictsCorpusNormalizer(),
    Duration startDelay = const Duration(seconds: 20),
    Duration debounce = const Duration(seconds: 5),
  }) : _normalizer = normalizer,
       _startDelay = startDelay,
       _debounce = debounce;

  /// app 唯一实例（[AppModel] 启动时 [start]）。
  static LibraryCorpusService instance = LibraryCorpusService();

  /// 已下架的「我库里的例句」独有的来源：语料库里这些 kind 的文档都是残留，启动时清掉。
  /// [CorpusSourceKind] 的值与磁盘格式共用、冻结不删，这里只决定不再喂、并清掉存量。
  static const List<CorpusSourceKind> retiredKinds = <CorpusSourceKind>[
    CorpusSourceKind.book,
    CorpusSourceKind.video,
    CorpusSourceKind.game,
  ];

  final CorpusNormalizer _normalizer;
  final Duration _startDelay;
  final Duration _debounce;

  FushiDatabase? _db;
  String? _directory;
  Future<int?>? _opening;
  int? _address;
  Future<void> _serial = Future<void>.value();
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  Timer? _debouncer;
  Timer? _startTimer;

  /// 词典集合变化的轮询：签名与上次对账时不同（导入 / 删除词典、启动时词典还没装好）
  /// 就对账一次（口径过期的歌词按新词典重新分词）。签名只是几次目录 stat，很便宜。
  Timer? _signatureWatch;
  String? _reconciledSignature;

  /// 启动：记下数据库 / 语料目录，[_startDelay] 后打开索引、清掉下架来源的残留并对账
  /// （不和首帧抢），之后订阅歌词表的变化做增量。重复调用以最后一次为准。
  void start({required FushiDatabase database, required String directory}) {
    _db = database;
    _directory = directory;
    _startTimer?.cancel();
    _startTimer = Timer(_startDelay, () {
      _startTimer = null;
      unawaited(_enqueue('purge', _purgeRetiredKinds));
      _subscribe(database);
      scheduleReconcile();
    });
  }

  bool get _started => _db != null;

  void _subscribe(FushiDatabase db) {
    if (_subscriptions.isNotEmpty) return;
    void on(TableInfo<dynamic, dynamic> table) {
      _subscriptions.add(
        db
            .tableUpdates(TableUpdateQuery.onTable(table))
            .listen((_) => _debounced(scheduleReconcile)),
      );
    }

    on(db.musicLyrics);
    on(db.musicTracks);
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
    _debouncer?.cancel();
    _debouncer = null;
  }

  void _debounced(void Function() action) {
    _debouncer?.cancel();
    _debouncer = Timer(_debounce, () {
      _debouncer = null;
      action();
    });
  }

  /// 测试 / 关闭：停掉订阅与计时器，等在跑的任务结束。
  Future<void> stop() async {
    _startTimer?.cancel();
    _startTimer = null;
    _unsubscribe();
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
  /// （计时器 / 订阅都不可发送）拖过 isolate 边界。
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

  static void Function(FushiCorpusIndex) _removeOp(
    CorpusSourceKind kind,
    List<String> keys,
  ) => (FushiCorpusIndex i) {
    for (final String key in keys) {
      i.remove(kind, key);
    }
  };

  static int _removeRetiredOp(FushiCorpusIndex i) =>
      i.removeKinds(retiredKinds);

  // ── 查询 ─────────────────────────────────────────────────────────────

  /// 按**一段文本**搜 [kind] 的句子（曲库「歌词命中」）：文本先用同一个词典归一分词，
  /// 再要求句子含全部词（[FushiCorpusIndex.query] 的 `matchAll`），每份文档至多
  /// [perDoc] 条、共至多 [limit] 条。归一与查询都在后台 isolate。没启动 / 索引没打开 /
  /// 没有词典（分不出词）时返回空。
  Future<List<CorpusHit>> searchText(
    String text, {
    required CorpusSourceKind kind,
    int limit = 20,
    int perDoc = 1,
  }) async {
    final int? address = _address;
    final String q = text.trim();
    if (!_started || address == null || q.isEmpty) {
      return const <CorpusHit>[];
    }
    try {
      final List<String>? keys = await _normalizer
          .runInBackground<List<String>>(_queryKeysJob(q));
      if (keys == null || keys.isEmpty) return const <CorpusHit>[];
      final CorpusQueryResult r = await _inIsolate(
        address,
        _textQueryOp(keys, kind.code, limit, perDoc),
      );
      return <CorpusHit>[
        for (final CorpusGroup g in r.groups)
          if (g.kind == kind) ...g.items,
      ];
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('corpus.searchText', error, stack);
      return const <CorpusHit>[];
    }
  }

  static List<String> Function(CorpusTermsFn terms) _queryKeysJob(
    String text,
  ) =>
      (CorpusTermsFn terms) => corpusTermKeys(terms(<String>[text]));

  static CorpusQueryResult Function(FushiCorpusIndex) _textQueryOp(
    List<String> keys,
    int kindCode,
    int limit,
    int perDoc,
  ) =>
      (FushiCorpusIndex i) => i.query(
        keys,
        perKind: limit,
        perDoc: perDoc,
        kinds: <CorpusSourceKind>[CorpusSourceKind.fromCode(kindCode)!],
        matchAll: true,
      );

  /// 语料库统计（诊断 / 测试观测）。
  Future<CorpusStats?> stats() async {
    if (!_started) return null;
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
    final Future<void> next = _serial.then((_) async {
      try {
        if (_started) await job();
      } on Object catch (error, stack) {
        ErrorLogService.instance.log('corpus.$label', error, stack);
      }
    });
    _serial = next;
    return next;
  }

  /// 对账歌词（启动 / 歌词表变化 / 词典变化之后）。
  void scheduleReconcile() =>
      unawaited(_enqueue('reconcile.music', _reconcileMusicNow));

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

  // ── 下架来源的清理 ────────────────────────────────────────────────────

  /// 删掉「我库里的例句」留下的书 / 视频 / 游戏文档（连同各自的磁盘文件）。不依赖词典：
  /// 没装词典时也照删。
  Future<void> _purgeRetiredKinds() async {
    final int? removed = await _withIndex(_removeRetiredOp);
    if (removed != null && removed > 0) {
      debugPrint('[corpus] removed $removed retired library-sentence docs');
    }
  }

  // ── 对账 ─────────────────────────────────────────────────────────────

  Future<void> _reconcileMusicNow() async {
    final FushiDatabase? db = _db;
    final String? normalizer = _normalizer.signature;
    if (db == null || normalizer == null) return;
    _reconciledSignature = normalizer;
    final List<CorpusDocInfo>? docs = await _withIndex(
      _docsOp(CorpusSourceKind.music),
    );
    if (docs == null) return;
    await _reconcileMusic(db, docs, normalizer);
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

  Future<void> _reconcileMusic(
    FushiDatabase db,
    List<CorpusDocInfo> docs,
    String normalizer,
  ) async {
    final List<MusicLyricRow> lyricRows = await db.select(db.musicLyrics).get();
    final Map<String, List<MusicLyricRow>> byTrack =
        <String, List<MusicLyricRow>>{};
    for (final MusicLyricRow row in lyricRows) {
      byTrack.putIfAbsent(row.trackUid, () => <MusicLyricRow>[]).add(row);
    }
    // 与歌词页同一个判据（[preferredMusicLyricRow]）：搜到的行就是点进去显示的那份。
    final Map<String, MusicLyricRow> chosen = <String, MusicLyricRow>{
      for (final MapEntry<String, List<MusicLyricRow>> e in byTrack.entries)
        if (preferredMusicLyricRow(e.value) case final MusicLyricRow row)
          e.key: row,
    };
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

  static void _putWith(
    FushiCorpusIndex index,
    CorpusTermsFn terms,
    CorpusDocument doc,
  ) {
    index.put(doc, terms(<String>[for (final s in doc.sentences) s.text]));
  }

  /// 语料目录：`<数据根>/corpus`。
  static String directoryUnder(String databaseDirectory) =>
      p.join(databaseDirectory, 'corpus');
}
