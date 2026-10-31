/// Anki .apkg / .colpkg 导入（PR3b，铁律 C）。
///
/// 新旧两种格式解出 SQLite 之后走同一条路径（见 srs_anki_package.dart）。导入事件的身份与内容只由来源决定：
/// 笔记类型 / 字段 / 模板 / 笔记 / 卡片的 ID 按 SrsIds 规则派生，revlog 日志与导入锚点按
/// anki_import_rules.dart 的规则写；多台设备各自导入同一个包，同步后不出重复。
///
/// 包里有 `fushi-ext`（Fushi 自己导出的包）时按它恢复 Fushi 日志与牌组设置，revlog 只作校验；
/// Anki 端在导出之后新增的 revlog 照常按来源规则导入。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:fushi_engine/srs/apkg/anki_collection_snapshot.dart';
import 'package:fushi_engine/srs/apkg/srs_anki_package.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_common.dart';
import 'package:fushi_engine/srs/apkg/srs_import_options.dart';
import 'package:fushi_engine/srs/apkg/srs_import_report.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart'
    show SrsLegacyLapisMigrationOps, srsLapisDeckRenamed;

export 'package:fushi_engine/srs/apkg/srs_anki_package.dart'
    show SrsImportException, SrsZstdDecoder;
export 'package:fushi_engine/srs/apkg/srs_import_options.dart';
export 'package:fushi_engine/srs/apkg/srs_import_report.dart';

/// 导入被调用方叫停（`shouldStop` 在两批之间返回 true）。已落库的批保留：每批只含完整的
/// 笔记（一条笔记的事件不会跨批），且导入幂等，重新导入同一份来源会补齐剩下的。
class SrsImportStopped implements Exception {
  const SrsImportStopped();

  @override
  String toString() => 'SrsImportStopped';
}

/// 媒体落盘回调：返回存储后的文件名（例如按内容哈希改名），字段里的引用按它改写。
typedef SrsImportMediaSink =
    Future<String> Function(String name, Uint8List bytes);

/// 导入一个 .apkg / .colpkg（新旧格式都支持）。
///
/// - [options]：对齐 Anki 导入页的五个选项（合并笔记类型 / 更新笔记 / 更新笔记类型 /
///   包含排程 / 包含牌组预设），默认值与 Anki 相同，见 [SrsAnkiImportOptions]。
///   .colpkg（整库包）也走这条合并路径：Anki 会用它替换整个集合，Fushi 不替换、不删本机任何数据。
/// - [zstdDecompress]：新格式需要的 zstd 解码，缺省用排程内核（FfiFsrsEngine.zstdDecompress）；
///   内核不可用时新格式抛 [SrsImportException]（code = needsKernel）。
Future<SrsImportReport> importAnkiPackage({
  required SrsDbStore store,
  required Uint8List bytes,
  required SrsImportMediaSink storeMedia,
  SrsAnkiImportOptions options = const SrsAnkiImportOptions(),
  void Function(double progress)? onProgress,
  SrsZstdDecoder? zstdDecompress,
  bool Function()? shouldStop,
}) async {
  // 内存里的包落一份临时文件，走与 [importAnkiPackageFile] 同一条流式路径（只有一条解包实现）。
  final Directory tmp = await Directory.systemTemp.createTemp('fushi_apkg_in_');
  try {
    final File f = File('${tmp.path}${Platform.pathSeparator}package.apkg');
    await f.writeAsBytes(bytes, flush: true);
    return await importAnkiPackageFile(
      store: store,
      file: f,
      storeMedia: storeMedia,
      options: options,
      onProgress: onProgress,
      zstdDecompress: zstdDecompress,
      shouldStop: shouldStop,
    );
  } finally {
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 上句柄偶尔晚释放：临时目录留给系统清理。
    }
  }
}

/// 同 [importAnkiPackage]，从文件读。**不把整个包读进内存**（BUG：Android 上 AnkiDroid 导出的
/// 带媒体 .colpkg 整包 `readAsBytes` 后又被 Isolate.run 复制一份、archive 再把每个解压过的媒体
/// 缓存在条目上，峰值 ≈ 2×包 + 全部媒体解压后大小 → Out of Memory）：
/// 后台 isolate 只读 zip 中央目录、把集合流式解压到临时目录（见 [SrsAnkiPackage.openFile]），
/// 媒体在导入时按引用逐个从文件里取。新格式的集合经 [zstdDecompressFile] 文件到文件解 zstd；
/// 缺省时给了 [zstdDecompress] 就用它（读进内存解），否则用排程内核的文件到文件解码。
Future<SrsImportReport> importAnkiPackageFile({
  required SrsDbStore store,
  required File file,
  required SrsImportMediaSink storeMedia,
  SrsAnkiImportOptions options = const SrsAnkiImportOptions(),
  void Function(double progress)? onProgress,
  SrsZstdDecoder? zstdDecompress,
  SrsZstdFileDecoder? zstdDecompressFile,
  bool Function()? shouldStop,
}) async {
  final SrsZstdDecoder zstd = zstdDecompress ?? _defaultZstd;
  final SrsZstdFileDecoder zstdFile =
      zstdDecompressFile ??
      (zstdDecompress == null ? _defaultZstdFile : _fileViaBytes(zstd));
  final Directory work = await Directory.systemTemp.createTemp('fushi_apkg_');
  final String path = file.path;
  final String workPath = work.path;
  final SrsAnkiPackage pkg;
  try {
    // 解 zip 目录、流式解压集合、zstd 是纯 CPU / IO 活：放后台 isolate，不卡 UI 帧（BUG-3549）。
    pkg = await Isolate.run(
      () => SrsAnkiPackage.openFile(
        path,
        zstd: zstd,
        zstdFile: zstdFile,
        workDir: workPath,
      ),
      debugName: 'srs-apkg-open',
    );
  } catch (_) {
    try {
      await work.delete(recursive: true);
    } on FileSystemException {
      // 临时目录留给系统清理。
    }
    rethrow;
  }
  // 关闭时连同工作目录一起删（打开失败也删）。
  final SrsAnkiCollection col = await SrsAnkiCollection.openExtracted(
    pkg.collectionFile!,
  );
  return _importOpened(
    store: store,
    pkg: pkg,
    col: col,
    storeMedia: storeMedia,
    options: options,
    onProgress: onProgress,
    shouldStop: shouldStop,
  );
}

/// 导入本机 Anki 用户数据目录里的集合（[snapshot] = 集合文件的只读快照 + 原位媒体目录，
/// 见 [snapshotAnkiCollection]）。与 [importAnkiPackage] 走同一条导入路径、同一套 ID 派生：
/// 先迁移一次、之后又导入同一份集合导出的 .colpkg 不会出重复。
///
/// 用户的 Anki 数据只读：集合读的是快照，媒体只按字段引用逐个读。
Future<SrsImportReport> importAnkiCollectionSnapshot({
  required SrsDbStore store,
  required AnkiCollectionSnapshot snapshot,
  required SrsImportMediaSink storeMedia,
  SrsAnkiImportOptions options = const SrsAnkiImportOptions(),
  void Function(double progress)? onProgress,
  bool Function()? shouldStop,
}) async {
  final AnkiMediaFolder media = AnkiMediaFolder(snapshot.mediaDir);
  final SrsAnkiPackage pkg = SrsAnkiPackage.fromCollectionFolder(
    mediaIndex: await media.index(),
    loadEntry: media.read,
  );
  final SrsAnkiCollection col = await SrsAnkiCollection.openFile(
    snapshot.collection,
  );
  return _importOpened(
    store: store,
    pkg: pkg,
    col: col,
    storeMedia: storeMedia,
    options: options,
    onProgress: onProgress,
    shouldStop: shouldStop,
  );
}

Future<SrsImportReport> _importOpened({
  required SrsDbStore store,
  required SrsAnkiPackage pkg,
  required SrsAnkiCollection col,
  required SrsImportMediaSink storeMedia,
  required SrsAnkiImportOptions options,
  required void Function(double progress)? onProgress,
  bool Function()? shouldStop,
}) async {
  try {
    final _Importer imp = _Importer(
      store: store,
      pkg: pkg,
      col: col,
      storeMedia: storeMedia,
      options: options,
      onProgress: onProgress,
      shouldStop: shouldStop,
    );
    // 导入之前自动打还原点（设计 §10.2）：导错了包能从时间线回到导入前。
    await store.sync2Checkpoint('apkg', 'import');
    return await store.bulkWrites(imp.run);
  } finally {
    await col.close();
  }
}

/// 缺省 zstd 解码（排程内核）。顶层函数：可随闭包送进后台 isolate。
Uint8List? _defaultZstd(Uint8List data) => FfiFsrsEngine.zstdDecompress(data);

/// 缺省 zstd 文件到文件解码（排程内核，一次 FFI 调用解完整个文件）。顶层函数：可随闭包送进
/// 后台 isolate。
bool? _defaultZstdFile(String inPath, String outPath) =>
    switch (FfiFsrsEngine.zstdDecompressFile(inPath, outPath)) {
      null => null,
      SrsZstdFileResult.ok => true,
      _ => false,
    };

/// 只给了内存版解码（[SrsZstdDecoder]）时的文件版：读进内存解完再写回。调用方注入解码器
/// （测试、旧调用点）时语义不变；生产路径不注入，走 [_defaultZstdFile]。
SrsZstdFileDecoder _fileViaBytes(SrsZstdDecoder zstd) =>
    (String inPath, String outPath) {
      final Uint8List? out = zstd(File(inPath).readAsBytesSync());
      if (out == null) return null;
      File(outPath).writeAsBytesSync(out);
      return true;
    };

/// 一块来源笔记里本机已有那些的预读（[_Importer._prefetchExisting]）。只读快照：块里的写入一律
/// 攒成草稿，不会让它过时（恢复路径例外，它立即落库后自己刷新 [cards]）。
class _ExistingPrefetch {
  _ExistingPrefetch({
    required this.notes,
    required this.cards,
    required this.cardEdits,
    required this.histories,
  });

  static final _ExistingPrefetch empty = _ExistingPrefetch(
    notes: const <String, SrsNoteView?>{},
    cards: const <String, SrsCardCacheRow>{},
    cardEdits: const <String, SrsEntityEdits>{},
    histories: const <String, SrsCardHistory>{},
  );

  final Map<String, SrsNoteView?> notes;
  final Map<String, SrsCardCacheRow> cards;
  final Map<String, SrsEntityEdits> cardEdits;
  final Map<String, SrsCardHistory> histories;
}

/// 一个来源笔记类型映射到本机的结果。
class _NtMap {
  _NtMap({
    required this.id,
    required this.name,
    required this.isCloze,
    required this.fieldIds,
    required this.templateIdByOrd,
    this.conflict,
    this.restored = false,
  });

  final String id;
  final String name;
  final bool isCloze;

  /// 按来源字段顺序（= notes.flds 的顺序）。
  final List<String> fieldIds;
  final Map<int, String> templateIdByOrd;

  /// 本机这个笔记类型先前被删、这次导入把它恢复了：它的笔记一律按「恢复」导回（见 [_Importer._importNote]）。
  final bool restored;

  /// 非 null = 不导入这个笔记类型的笔记（原因代码）。
  final String? conflict;
}

class _SrcCard {
  _SrcCard(Row r)
    : id = r['id'] as int,
      did = r['did'] as int,
      odid = r['odid'] as int,
      ord = r['ord'] as int,
      mod = (r['mod'] as int?) ?? 0,
      type = r['type'] as int,
      queue = r['queue'] as int,
      due = r['due'] as int,
      odue = r['odue'] as int,
      ivl = r['ivl'] as int,
      factor = r['factor'] as int,
      reps = r['reps'] as int,
      lapses = r['lapses'] as int,
      data = (r['data'] as String?) ?? '';

  final int id;
  final int did;
  final int odid;
  final int ord;

  /// Anki 卡片修改时刻（秒）。
  final int mod;
  final int type;
  final int queue;
  final int due;
  final int odue;
  final int ivl;
  final int factor;
  final int reps;
  final int lapses;
  final String data;

  /// 在筛选牌组里的卡按原牌组算。
  int get homeDeck => odid != 0 ? odid : did;
}

class _SrcRevlog {
  _SrcRevlog(Row r)
    : id = r['id'] as int,
      ease = r['ease'] as int,
      ivl = r['ivl'] as int,
      factor = r['factor'] as int,
      time = r['time'] as int,
      type = r['type'] as int;

  final int id;
  final int ease;
  final int ivl;
  final int factor;
  final int time;
  final int type;

  SrsAnkiRevlogRow get row => SrsAnkiRevlogRow(
    id: id,
    ease: ease,
    type: type,
    ivl: ivl,
    factor: factor,
  );

  /// 评分类：type 0/1/2 且 ease 1–4。
  bool get isRating => type <= 2 && type >= 0 && ease >= 1 && ease <= 4;

  bool get isFiltered => type == 3;
}

class _Importer {
  _Importer({
    required this.store,
    required this.pkg,
    required this.col,
    required this.storeMedia,
    required this.options,
    required this.onProgress,
    this.shouldStop,
  }) : srcDay = SrsDayContext(
         utcOffsetMin: col.utcOffsetMin,
         rolloverHour: col.rolloverHour,
       );

  final SrsDbStore store;
  final SrsAnkiPackage pkg;
  final SrsAnkiCollection col;
  final SrsImportMediaSink storeMedia;
  final SrsAnkiImportOptions options;
  final void Function(double progress)? onProgress;

  /// 调用方叫停（后台导入任务被取消）：两批之间检查，见 [_stopIfAsked]。
  final bool Function()? shouldStop;

  /// 叫停了就把已攒的（都是完整的笔记）落库、补上前身链接，再抛 [SrsImportStopped]。
  Future<void> _stopIfAsked() async {
    if (!(shouldStop?.call() ?? false)) return;
    await _flush(force: true);
    if (_historyLinks.isNotEmpty) await store.writeEdits(_historyLinks);
    throw const SrsImportStopped();
  }

  /// 来源集合的「今天」口径（日志里的 utcOffset / 翻日也取它，保证多台设备导出同一份内容）。
  final SrsDayContext srcDay;
  late final int crtDay;
  final SrsImportReport report = SrsImportReport();

  final Map<int, _NtMap> _nts = <int, _NtMap>{};
  final Map<int, String> _deckOf = <int, String>{};
  final Map<String, String> _mediaRenames = <String, String>{};

  /// 每个媒体条目只存一次：并发请求同一个名字共用同一个 future（预存与逐条导入可能
  /// 同时要它；以前「先记已处理、再 await 存」会让并发的第二个请求拿到还没算出的名字）。
  final Map<String, Future<String>> _mediaJobs = <String, Future<String>>{};

  /// 预存媒体的并发度（见 [_prefetchMedia]）。
  static const int _mediaConcurrency = 16;

  /// 进度条分段：扫描引用 0 → [_scanShare]，预存媒体 → [_mediaShare]，其余归笔记导入。
  /// 实测扫描约占 6%、媒体与笔记大致对半；没有要预存的媒体时媒体段长度为 0。
  static const double _scanShare = 0.05;
  double _mediaShare = 0;

  /// [_prefetchMedia] 扫出的「有字段带共享样式或媒体引用」的笔记（Anki 笔记 id）；null =
  /// 没扫过。不在其中的笔记逐条导入时字段原样用、不再扫一遍（含引用的字段只占约一成，
  /// 而字段全文上亿字符，重扫一遍要好几秒）。
  Set<int>? _notesWithRefs;

  /// 扫描时连续占用 UI isolate 的上限（毫秒），到了就让出一次事件循环。
  static const int _scanSliceMs = 8;

  /// 本批攒下的事件草稿：修改记录的序号在落库时（[SrsDbStore.importDrafts]）才分配。
  final List<SrsEventDraft> _pending = <SrsEventDraft>[];

  /// 已存在的卡要补写的新卡位置（重新导入 / 迁移补救，见 [_importNewPosition]），导入结束一次写。
  final Map<String, int> _positionRepairs = <String, int>{};

  // fushi-ext
  bool _extSameProfile = false;
  final Map<int, List<SrsReviewLog>> _extLogsByCard =
      <int, List<SrsReviewLog>>{};
  final Map<String, int> _extRevlogIds = <String, int>{};

  /// fushi-ext 的 logCards：前身卡日志（更改笔记类型继承来的）→ 它在包里归的 Anki 卡 id。
  final Map<String, int> _extLogCards = <String, int>{};

  /// 同 profile 回导时补的「前身」链接（日志原样保留在前身卡上）。
  final List<SrsEditSpec> _historyLinks = <SrsEditSpec>[];

  /// 带 FSRS 参数、导入后改用 RWKV 的来源预设 id → 原算法（报告的「继续用 FSRS」用）。
  final Map<int, SrsAlgorithm> _fsrsOfPreset = <int, SrsAlgorithm>{};
  final Map<String, Map<String, Object?>> _extDecks =
      <String, Map<String, Object?>>{};
  final Map<String, Object?> _extNotes = <String, Object?>{};

  /// fushi-ext 记的笔记创建时刻（guid → 毫秒）。包里笔记的数字 id 是 [SrsIds.ankiNumericId]
  /// 派生的（与 AnkiConnect 同一套），不是创建时刻；没有这项时退回用数字 id（Anki 自己的包里
  /// 两者是一回事）。
  final Map<String, int> _extNoteCreatedAt = <String, int>{};

  String get profileUid => store.profileUid;

  /// Anki 的排程系统标签（gather.rs `remove_system_tags`）。
  static const Set<String> _schedulingTags = <String>{'marked', 'leech'};

  Future<SrsImportReport> run() async {
    report.latestFormat = pkg.latestFormat;
    report.options = options;
    // Anki review 卡的 due 是「相对 crt 的天数」：crt（秒）在来源时区 / 翻日下的日历日。
    final DateTime crtDate = DateTime.fromMillisecondsSinceEpoch(
      col.crtSecs * 1000 +
          col.utcOffsetMin * 60000 -
          col.rolloverHour * 3600000,
      isUtc: true,
    );
    crtDay = srsDateToDay(crtDate.year, crtDate.month, crtDate.day);
    _readExt();
    for (final String name in pkg.mediaIndex.keys) {
      if (name.startsWith('_')) await _media(name);
    }
    for (final SrsAnkiNoteType nt in col.noteTypes.values) {
      _nts[nt.id] = await _mapNoteType(nt);
    }
    await _mapDecks();
    await _stopIfAsked();
    await _prefetchMedia();
    await _importNotes();
    if (!options.withScheduling) {
      report.reviewLogsSkipped =
          col.db.select('SELECT count(*) AS n FROM revlog').first['n'] as int;
    }
    await _flush(force: true);
    if (_historyLinks.isNotEmpty) await store.writeEdits(_historyLinks);
    await _repairNewPositions();
    onProgress?.call(1);
    return report;
  }

  // ------------------------------------------------------------------ fushi-ext

  void _readExt() {
    final Map<String, Object?>? ext = pkg.fushiExt;
    if (ext == null || ext['format'] != srsFushiExtFormat) return;
    final Object? v = ext['version'];
    if (v is! int || v > srsFushiExtVersion) return;
    _extSameProfile = ext['profileUid'] == profileUid;
    final Object? logCards = ext['logCards'];
    if (logCards is Map) {
      for (final MapEntry<Object?, Object?> e in logCards.entries) {
        if (e.value is int) _extLogCards['${e.key}'] = e.value! as int;
      }
    }
    final Object? logs = ext['logs'];
    if (logs is List) {
      for (final Object? j in logs) {
        if (j is! Map) continue;
        final SrsReviewLog l = SrsReviewLog.fromJson(j.cast<String, Object?>());
        final int cid = _extLogCards[l.id] ?? SrsIds.ankiNumericId(l.cardId);
        (_extLogsByCard[cid] ??= <SrsReviewLog>[]).add(l);
      }
    }
    final Object? ids = ext['revlogIds'];
    if (ids is Map) {
      for (final MapEntry<Object?, Object?> e in ids.entries) {
        if (e.value is int) _extRevlogIds['${e.key}'] = e.value! as int;
      }
    }
    final Object? decks = ext['decks'];
    if (decks is List) {
      for (final Object? d in decks) {
        if (d is Map && d['name'] is String) {
          final Object? values = d['values'];
          _extDecks[d['name']! as String] = values is Map
              ? values.cast<String, Object?>()
              : <String, Object?>{};
        }
      }
    }
    final Object? notes = ext['notes'];
    if (notes is Map) _extNotes.addAll(notes.cast<String, Object?>());
    final Object? created = ext['noteCreatedAt'];
    if (created is Map) {
      for (final MapEntry<Object?, Object?> e in created.entries) {
        if (e.key is String && e.value is int) {
          _extNoteCreatedAt[e.key! as String] = e.value! as int;
        }
      }
    }
  }

  // ------------------------------------------------------------------ 媒体

  Future<String> _media(String name) => _mediaJobs[name] ??= _storeMedia(name);

  /// 导入笔记前把笔记字段引用的媒体并发存好，逐条导入时 [_media] 直接命中。
  ///
  /// 以前每条笔记逐个 await 自己的媒体，4 万个媒体文件一个接一个读、写；并发
  /// [_mediaConcurrency] 路后文件读写在 IO 线程池里重叠（实测从 Anki 迁移 1.5 万笔记 /
  /// 4 万媒体：媒体阶段约 140 秒 → 约 30 秒，连同媒体存储不再逐文件 fsync，见
  /// SrsMediaStore.store）。只是提前做、不改变存哪些：与 [_importNote] 同一批笔记（跳过
  /// 笔记类型缺失 / 冲突的）、同一批字段、同一个引用判据；字段里带共享样式引用的留给
  /// 逐条导入（样式展开后引用会变），漏掉的也照旧在逐条导入时补存。
  Future<void> _prefetchMedia() async {
    final List<String> names = <String>[];
    final Set<String> seen = <String>{};
    final Set<int> withRefs = <int>{};
    // 导入跑在 UI isolate：逐行读，连续算满 [_scanSliceMs] 就让出一次事件循环（字段全文
    // 上亿字符，一口气扫完要好几秒，期间界面不出帧）。
    final PreparedStatement notes = col.db.prepare(
      'SELECT id, mid, flds FROM notes',
    );
    final int total = max(
      1,
      col.db.select('SELECT count(*) AS n FROM notes').first['n'] as int,
    );
    final Stopwatch slice = Stopwatch()..start();
    int scanned = 0;
    try {
      final IteratingCursor cur = notes.selectCursor();
      while (cur.moveNext()) {
        scanned++;
        if (slice.elapsedMilliseconds >= _scanSliceMs) {
          onProgress?.call(_scanShare * scanned / total);
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
        final Row n = cur.current;
        final _NtMap? nt = _nts[n['mid'] as int];
        if (nt == null || nt.conflict != null) continue;
        final List<String> raw = (n['flds'] as String).split('\x1f');
        for (int i = 0; i < nt.fieldIds.length && i < raw.length; i++) {
          final String html = raw[i];
          if (srsStyleRefsIn(html).isNotEmpty) {
            withRefs.add(n['id'] as int);
            continue;
          }
          final Set<String> refs = srsMediaRefsIn(html);
          if (refs.isEmpty) continue;
          withRefs.add(n['id'] as int);
          for (final String r in refs) {
            if (pkg.mediaIndex.containsKey(r) && seen.add(r)) names.add(r);
          }
        }
      }
    } finally {
      notes.close();
    }
    _notesWithRefs = withRefs;
    _mediaShare = _scanShare;
    if (names.isEmpty) return;
    _mediaShare = 0.5;
    int next = 0;
    int done = 0;
    // 一路叫停或出错后其余各路也停下：[Future.wait] 要等每一路都结束才报错，不停的话
    // 剩下的几路会把余下的媒体全部存完。
    bool halted = false;
    Future<void> worker() async {
      try {
        while (!halted && next < names.length) {
          await _media(names[next++]);
          done++;
          // 进度与叫停每 50 个文件一次（真实集合上约几十毫秒一次，叫停仍即时）；叫停时
          // 只存了媒体、还没写笔记，重导照常补齐。
          if (done % 50 == 0) {
            onProgress?.call(
              _scanShare + (_mediaShare - _scanShare) * done / names.length,
            );
            await _stopIfAsked();
          }
        }
      } catch (_) {
        halted = true;
        rethrow;
      }
    }

    await Future.wait(<Future<void>>[
      for (int i = 0; i < min(_mediaConcurrency, names.length); i++) worker(),
    ]);
  }

  Future<String> _storeMedia(String name) async {
    final Uint8List? bytes = await pkg.mediaBytes(name);
    if (bytes == null) {
      report.mediaMissing.add(name);
      return name;
    }
    final String stored = await storeMedia(name, bytes);
    report.mediaStored++;
    if (stored != name) _mediaRenames[name] = stored;
    return stored;
  }

  /// 笔记字段的 [_withMedia]：字段里既没有共享样式引用也没有媒体引用（绝大多数字段）时
  /// 同步原样返回，不进异步流程——迁移 1.5 万笔记要处理 45 万个字段，逐个 await 本身就是
  /// 秒级的开销。有引用时与 [_withMedia] 完全相同。
  FutureOr<String> _fieldWithMedia(String html) {
    if (srsStyleRefsIn(html).isEmpty && srsMediaRefsIn(html).isEmpty) {
      return html;
    }
    return _withMedia(html);
  }

  Future<String> _withMedia(String html, {bool includeStatic = false}) async {
    html = await _inlinePackagedStyles(html);
    final Set<String> refs = srsMediaRefsIn(html, includeStatic: includeStatic);
    if (refs.isEmpty) return html;
    for (final String r in refs) {
      await _media(r);
    }
    return srsRewriteMediaRefs(html, _mediaRenames);
  }

  /// 包里带着共享样式文件、字段里是它的引用行（没展开就导出的包）：按包内文件展开回内联
  /// `<style>`，落库时再统一去重成本机的共享样式文件。文件缺失或内容与文件名的哈希不符时原样保留。
  ///
  /// 包内文件先异步读齐（媒体读不卡 UI isolate），再用同步查表展开。
  Future<String> _inlinePackagedStyles(String html) async {
    final Set<String> names = srsStyleRefsIn(html);
    if (names.isEmpty) return html;
    final Map<String, String?> css = <String, String?>{};
    for (final String name in names) {
      final Uint8List? bytes = await pkg.mediaBytes(name);
      String? text;
      if (bytes != null) {
        try {
          final String decoded = utf8.decode(bytes);
          if (srsStyleMediaName(decoded) == name) text = decoded;
        } on FormatException {
          text = null;
        }
      }
      css[name] = text;
    }
    return srsExpandStyles(html, (String name) => css[name]);
  }

  // ------------------------------------------------------------------ 笔记类型

  /// 本机最后一次改某实体「内容」的时刻（导入选项「较新时」的比较基准）：
  /// [relevant] 选出的键里所有在场修改记录的 HLC 物理时刻取最大，没有就取 [fallback]。
  static int _lastEditMs(
    SrsEntityEdits edits,
    bool Function(String key) relevant,
    int fallback,
  ) {
    int out = fallback;
    for (final SrsRegister r in edits.registers) {
      if (!relevant(r.key)) continue;
      for (final SrsFieldEdit e in r.live) {
        if (e.hlc.physical > out) out = e.hlc.physical;
      }
    }
    return out;
  }

  static bool _isNoteTypeContentKey(String key) =>
      key == SrsFieldKeys.name ||
      key == SrsFieldKeys.css ||
      key.startsWith('fieldDef/') ||
      key.startsWith('tmplDef/');

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _isNoteContentKey(String key) =>
      key.startsWith('f/') || key == SrsFieldKeys.noteTags;

  /// 字段 / 模板 → 本机 ID（铁律 C）。
  static String _resolveId(
    int? configId,
    String name,
    Iterable<(String, int?)> have,
    String Function(int) byNum,
    String Function(String) byName,
  ) {
    final Map<String, int?> h = <String, int?>{
      for (final (String id, int? n) in have) id: n,
    };
    if (configId != null) {
      // ankiNum 已记成某项的别名 → 那一项。
      for (final MapEntry<String, int?> e in h.entries) {
        if (e.value == configId) return e.key;
      }
      final String direct = byNum(configId);
      if (h.containsKey(direct)) return direct;
      // 先前按名字回退生成、还没有 ankiNum 的项：只把 ankiNum 记成它的别名，ID 不换。
      final String named = byName(name);
      if (h.containsKey(named) && h[named] == null) return named;
      return direct;
    }
    return byName(name);
  }

  /// 本机已有的全部定义（含已删除的、内置默认值）。
  /// 本机笔记类型里有定义的全部字段 / 模板（未删除的物化结果 + 每条定义修改记录本身，含已删除的；
  /// 合并在字段寄存器内核里，见 [SrsNoteTypeView.definedFields]）。
  static (Map<String, SrsFieldDef>, Map<String, SrsTemplateDef>) _haveDefs(
    SrsNoteTypeView? view,
  ) => (
    <String, SrsFieldDef>{
      if (view != null)
        for (final SrsFieldDef f in view.definedFields) f.id: f,
    },
    <String, SrsTemplateDef>{
      if (view != null)
        for (final SrsTemplateDef t in view.definedTemplates) t.id: t,
    },
  );

  static List<String> _resolveFields(
    String ntId,
    SrsAnkiNoteType src,
    Map<String, SrsFieldDef> have,
  ) => <String>[
    for (final SrsAnkiField f in src.fields)
      _resolveId(
        f.configId,
        f.name,
        have.values.map((SrsFieldDef d) => (d.id, d.ankiNum)),
        (int n) => SrsIds.field(ntId, n),
        (String n) => SrsIds.fieldByName(ntId, n),
      ),
  ];

  static Map<int, String> _resolveTemplates(
    String ntId,
    SrsAnkiNoteType src,
    Map<String, SrsTemplateDef> have,
  ) => <int, String>{
    for (final SrsAnkiTemplate t in src.templates)
      t.ord: _resolveId(
        t.configId,
        t.name,
        have.values.map((SrsTemplateDef d) => (d.id, d.ankiNum)),
        (int n) => SrsIds.template(ntId, n),
        (String n) => SrsIds.templateByName(ntId, n),
      ),
  };

  /// 来源与本机笔记类型的字段 / 模板是不是同一组（Anki `equal_schema` 的对应：
  /// 来源的每一项都解析到本机一个未删除的项，且本机没有多出来的未删除项）。
  static bool _equalSchema(SrsNoteTypeView view, SrsAnkiNoteType src) {
    final (
      Map<String, SrsFieldDef> haveFields,
      Map<String, SrsTemplateDef> haveTmpls,
    ) = _haveDefs(
      view,
    );
    final Set<String> liveFields = <String>{
      for (final SrsFieldDef f in haveFields.values)
        if (!f.deleted) f.id,
    };
    final Set<String> liveTmpls = <String>{
      for (final SrsTemplateDef t in haveTmpls.values)
        if (!t.deleted) t.id,
    };
    final List<String> fields = _resolveFields(view.id, src, haveFields);
    final Iterable<String> tmpls = _resolveTemplates(
      view.id,
      src,
      haveTmpls,
    ).values;
    return fields.length == liveFields.length &&
        fields.toSet().length == fields.length &&
        liveFields.containsAll(fields) &&
        tmpls.length == liveTmpls.length &&
        tmpls.toSet().length == tmpls.length &&
        liveTmpls.containsAll(tmpls);
  }

  /// 「不合并笔记类型」时另建的那一份的 ankiNum：由来源身份 + 字段 / 模板组成确定性派生，
  /// 两台设备导入同一个包得到同一个 ID（铁律 C）；同一种结构再导入回到同一份副本
  /// （对应 Anki 的 get_previously_duplicated_notetype）。
  static int _duplicateAnkiNum(SrsAnkiNoteType src) => hash53(
    'notetype-dup/${src.ankiNum}/${srsCanonicalJson(<String, Object?>{
      'cloze': src.isCloze,
      'fields': <Object?>[for (final SrsAnkiField f in src.fields) f.configId ?? 'name:${f.name}'],
      'tmpls': <Object?>[for (final SrsAnkiTemplate t in src.templates) t.configId ?? 'name:${t.name}'],
    })}',
  );

  Future<_NtMap> _mapNoteType(SrsAnkiNoteType src) async {
    final String baseId = SrsIds.noteType(profileUid, src.ankiNum);
    final String kind = src.isCloze
        ? SrsNoteTypeKind.cloze
        : SrsNoteTypeKind.standard;
    final SrsNoteTypeView? base = await store.noteType(baseId);
    if (base != null && base.kind != kind) {
      return _NtMap(
        id: baseId,
        name: src.name,
        isCloze: src.isCloze,
        fieldIds: const <String>[],
        templateIdByOrd: const <int, String>{},
        conflict: SrsImportIssueReason.noteTypeKindMismatch,
      );
    }
    // 本机删掉了的那一个不另建副本：导入就是把它恢复回来（结构按来源合进去，见 [_mapInto]）。
    if (base != null &&
        base.deletedAt == null &&
        !options.mergeNoteTypes &&
        !_equalSchema(base, src)) {
      // 不合并：本机那一个不动，来源笔记类型另建一份。
      final int dupNum = _duplicateAnkiNum(src);
      final String dupId = SrsIds.noteType(profileUid, dupNum);
      final SrsNoteTypeView? dup = await store.noteType(dupId);
      if (dup == null) report.noteTypesDuplicated.add(src.name);
      return _mapInto(src, dupId, dupNum, dup);
    }
    return _mapInto(src, baseId, src.ankiNum, base);
  }

  Future<_NtMap> _mapInto(
    SrsAnkiNoteType src,
    String ntId,
    int ankiNum,
    SrsNoteTypeView? existing,
  ) async {
    final String kind = src.isCloze
        ? SrsNoteTypeKind.cloze
        : SrsNoteTypeKind.standard;
    final bool created = existing == null;
    // 先前导入过、后来在本机被删：重新导入即恢复（与笔记 / 牌组同一条规则）。以前只按「已存在」走，
    // 删除标记永远不清：笔记类型页里看不到，它的笔记全被当成「笔记类型已删」隐藏，浏览 / 复习都是 0。
    // 恢复时名字、CSS、模板一律回到来源：本机的旧定义只是删除前的残留，不参与「较新时更新」的比较。
    final bool restored = existing != null && existing.deletedAt != null;
    // 来源较新 / 总是 / 从不：只管名字、CSS、模板正文、已有项的名字与顺序。
    final bool update =
        existing == null ||
        restored ||
        options.updateNoteTypes.shouldUpdate(
          localMs: _lastEditMs(existing.edits, _isNoteTypeContentKey, 0),
          sourceMs: src.mtimeSecs * 1000,
        );
    final SrsNoteTypeView view;
    if (existing != null) {
      view = existing;
    } else {
      await store.importEvents(<SrsEvent>[
        SrsEntityEvent(
          SrsEntityRecord(
            id: ntId,
            profileUid: profileUid,
            kind: SrsEntityKind.noteType,
            payload: <String, Object?>{
              'ankiNum': ankiNum,
              'ntKind': kind,
              'createdAt': src.ankiNum,
            },
          ),
        ),
      ]);
      view = (await store.noteType(ntId))!;
    }

    final (
      Map<String, SrsFieldDef> haveFields,
      Map<String, SrsTemplateDef> haveTmpls,
    ) = _haveDefs(
      view,
    );
    final List<String> fieldIds = _resolveFields(ntId, src, haveFields);
    final Map<int, String> tmplByOrd = _resolveTemplates(ntId, src, haveTmpls);

    final Map<String, Object?> edits = <String, Object?>{};
    final Map<String, String> nameToId = <String, String>{};
    for (final (int i, SrsAnkiField f) in src.fields.indexed) {
      final String id = fieldIds[i];
      nameToId[f.name] = id;
      final SrsFieldDef? have = haveFields[id];
      final bool keepLocal = have != null && !update;
      final SrsFieldDef want = SrsFieldDef(
        id: id,
        name: keepLocal ? have.name : f.name,
        ord: keepLocal ? have.ord : f.ord,
        ankiNum: f.configId ?? have?.ankiNum,
      );
      if (have == null ||
          srsCanonicalJson(have.toValue()) !=
              srsCanonicalJson(want.toValue())) {
        edits[SrsFieldKeys.fieldDef(id)] = want.toValue();
      }
      // 字段说明：本地从没写过（没有这个键的记录）才取 Anki 里的；本地写过（含主动清空）
      // 一律保留，导入不覆盖也不复活。
      final String descKey = SrsFieldKeys.fieldDescription(id);
      if (f.description.isNotEmpty && view.edits[descKey] == null) {
        edits[descKey] = f.description;
      }
    }

    for (final SrsAnkiTemplate t in src.templates) {
      final String id = tmplByOrd[t.ord]!;
      final SrsTemplateDef? have = haveTmpls[id];
      final bool writeBody = have == null || update;
      final SrsTemplateDef want = SrsTemplateDef(
        id: id,
        name: writeBody ? t.name : have.name,
        ord: writeBody ? t.ord : have.ord,
        front: writeBody
            ? templateNamesToIds(
                await _withMedia(t.qfmt, includeStatic: true),
                nameToId,
              )
            : have.front,
        back: writeBody
            ? templateNamesToIds(
                await _withMedia(t.afmt, includeStatic: true),
                nameToId,
              )
            : have.back,
        ankiNum: t.configId ?? have?.ankiNum,
      );
      if (have == null ||
          srsCanonicalJson(have.toValue()) !=
              srsCanonicalJson(want.toValue())) {
        edits[SrsFieldKeys.templateDef(id)] = want.toValue();
      }
    }

    // 来源删掉的项本地不删，只进报告。
    final Set<String> fieldSet = fieldIds.toSet();
    for (final SrsFieldDef f in haveFields.values) {
      if (!f.deleted && !fieldSet.contains(f.id)) {
        report.removedInSource.add(
          SrsImportRemovedItem(
            noteType: src.name,
            name: f.name,
            isTemplate: false,
          ),
        );
      }
    }
    final Set<String> tmplSet = tmplByOrd.values.toSet();
    for (final SrsTemplateDef t in haveTmpls.values) {
      if (!t.deleted && !tmplSet.contains(t.id)) {
        report.removedInSource.add(
          SrsImportRemovedItem(
            noteType: src.name,
            name: t.name,
            isTemplate: true,
          ),
        );
      }
    }

    if (update) {
      if (view.name != src.name) edits[SrsFieldKeys.name] = src.name;
      final String css = await _withMedia(src.css, includeStatic: true);
      if (view.css != css) edits[SrsFieldKeys.css] = css;
    }
    if (restored) {
      edits[SrsFieldKeys.deleted] = null;
      report.noteTypesRestored.add(src.name);
    }
    if (edits.isNotEmpty) {
      await store.editFields(SrsEntityKind.noteType, ntId, edits);
      if (!created && !restored) report.noteTypesUpdated++;
    }
    return _NtMap(
      id: ntId,
      name: src.name,
      isCloze: src.isCloze,
      fieldIds: fieldIds,
      templateIdByOrd: tmplByOrd,
      restored: restored,
    );
  }

  // ------------------------------------------------------------------ 牌组

  Future<void> _mapDecks() async {
    final Set<int> used = <int>{
      for (final Row r in col.db.select(
        'SELECT DISTINCT CASE WHEN odid != 0 THEN odid ELSE did END AS d FROM cards',
      ))
        r['d'] as int,
    };
    final Map<String, SrsAnkiDeck> byName = <String, SrsAnkiDeck>{
      for (final SrsAnkiDeck d in col.decks.values)
        if (!d.filtered) d.name: d,
    };
    final Set<String> names = <String>{};
    for (final int id in used) {
      final SrsAnkiDeck? d = col.decks[id];
      if (d == null || d.filtered) continue;
      final List<String> parts = _parts(d.name);
      for (int i = 1; i <= parts.length; i++) {
        names.add(parts.sublist(0, i).join('::'));
      }
    }
    final List<String> ordered = names.toList()
      ..sort((String a, String b) {
        final int c = _parts(a).length.compareTo(_parts(b).length);
        return c != 0 ? c : a.compareTo(b);
      });

    SrsDeckTree tree = await store.deckTree();
    final Map<String, String> idByName = <String, String>{};
    final Set<String> created = <String>{};
    final Set<int> reportedPresets = <int>{};
    for (final String full in ordered) {
      final List<String> parts = _parts(full);
      final String leaf = parts.last;
      final String? parent = parts.length == 1
          ? null
          : idByName[parts.sublist(0, parts.length - 1).join('::')];
      String? found;
      for (final SrsDeckView d in tree.decks) {
        if (d.name == leaf && tree.parentOf(d.id) == parent) {
          found = d.id;
          break;
        }
      }
      found ??= _renamedLapisDeck(tree, full, parent);
      if (found != null) {
        idByName[full] = found;
        continue;
      }
      // 用户把先前导入的同名牌组改了名 / 挪了位置（全名派生的 ID 还活着、却不在这个全名上）：
      // 不复用，按 createDeck 的规则另挑 ID（[SrsDbStore.deckIdForNew]：备选 ID，或沿用名字与
      // 父牌组都一致的那个；以前这里重新派生出的还是同一个 ID，会把挪走的牌组改回来）。它不算
      // 本次「首次新建」，不带牌组设置（与以前相同）。
      final bool renamedImport =
          tree[srsImportedDeckId(profileUid, full)] != null;
      final String id = await store.deckIdForNew(leaf, parentId: parent);
      // 身份记录、名字 / 父牌组、牌组设置**同一个事务**落库（writeEdits）：以前先建牌组、全部
      // 建完再另起一轮写设置，中间失败或被杀时牌组已在、重跑不再算「新建」，设置永远不写（BUG-3552）。
      final Map<String, Object?> values = <String, Object?>{
        SrsFieldKeys.name: leaf,
        if (parent != null) SrsFieldKeys.deckParent: parent,
        // 先前导入过（或同名建过）、后来被删：重新导入即恢复。
        if (await _deckDeleted(id)) SrsFieldKeys.deleted: null,
        if (!renamedImport)
          ..._newDeckSettings(full, byName, created, reportedPresets),
      };
      await store.writeEdits(
        <SrsEditSpec>[
          for (final MapEntry<String, Object?> v in values.entries)
            SrsEditSpec(SrsEntityKind.deck, id, v.key, v.value),
        ],
        records: <SrsEntityRecord>[
          SrsEntityRecord(
            id: id,
            profileUid: profileUid,
            kind: SrsEntityKind.deck,
            payload: const <String, Object?>{'createdAt': 0},
          ),
        ],
      );
      final SrsAlgorithm? fromFsrs = _fsrsOfPreset[byName[full]?.configId];
      if (fromFsrs != null && values.containsKey(SrsFieldKeys.deckAlgorithm)) {
        report.fsrsDecks[id] = fromFsrs;
      }
      idByName[full] = id;
      if (!renamedImport) created.add(full);
      tree = await store.deckTree();
    }

    for (final SrsAnkiDeck d in col.decks.values) {
      final String? id = idByName[d.name];
      if (id != null) _deckOf[d.id] = id;
    }

    // 不含牌组预设：新建的牌组用本机默认设置（Anki：预设 id 重置为默认预设）。
    if (!options.withDeckConfigs) {
      report.deckPresetsSkipped = <int>{
        for (final String full in ordered)
          if (created.contains(full) && byName[full] != null)
            byName[full]!.configId,
      }.where(col.presets.containsKey).length;
    }
  }

  /// Anki 牌组 [full]（本机父牌组 [parent]）先前导入过、又被 Lapis 迁移改名成了 Fushi Card
  /// （[SrsLegacyLapisMigrationOps.renameLapisDecks]）时，本机那个牌组的 ID；否则 null。
  ///
  /// 导入按「名字 + 父牌组」找牌组，Anki 那边仍叫「Lapis」，对不上改过名的本机牌组；以前这里就
  /// 另建一个「Lapis」并把卡挪进去，随后的改名又因同级已有「Fushi Card」被跳过——重跑迁移后
  /// 牌组重复、卡被拆成两半。认回的判据是确定的：按 Anki 全名派生的导入 ID（[srsImportedDeckId]）
  /// 还活着、仍在同一父牌组下、名字正是 [srsLapisDeckRenamed] 的结果——即它就是从这个 Anki 牌组
  /// 导入、再由迁移改名的那个。用户手改成别的名字的不认（照旧另建，见 [_mapDecks]）。
  String? _renamedLapisDeck(SrsDeckTree tree, String full, String? parent) {
    final String? renamed = srsLapisDeckRenamed(_parts(full).last);
    if (renamed == null) return null;
    final String id = srsImportedDeckId(profileUid, full);
    final SrsDeckView? d = tree[id];
    if (d == null || d.name != renamed || tree.parentOf(id) != parent) {
      return null;
    }
    return id;
  }

  /// 首次建牌组 [full] 时随它一起写的设置（预设参数 / 继承方式 / 收起 / fushi-ext 的牌组键）。
  /// [created] 是本次已新建的牌组全名（父牌组先于子牌组建）。牌组预设与 FSRS 参数各归一个开关
  /// （[SrsAnkiImportOptions.withDeckConfigs] / [SrsAnkiImportOptions.withFsrsParams]）；两个
  /// 都关时什么也不写（新牌组用本机默认，同 Anki）。
  Map<String, Object?> _newDeckSettings(
    String full,
    Map<String, SrsAnkiDeck> byName,
    Set<String> created,
    Set<int> reportedPresets,
  ) {
    final SrsAnkiDeck? src = byName[full];
    final Map<String, Object?> values = <String, Object?>{};
    final bool configs = options.withDeckConfigs;
    final bool fsrs = options.withFsrsParams;
    // 某个键归哪个开关：排程算法 / 参数 / 期望保留率归 FSRS 参数，其余（含继承方式）归预设；
    // 继承方式决定参数从哪个牌组取，两个开关任一开着都要写。
    bool wanted(String key) => key == SrsFieldKeys.deckParamsMode
        ? true
        : _fsrsDeckKeys.contains(key)
        ? fsrs
        : configs;
    if (configs || fsrs) {
      final SrsAnkiPreset? preset = src == null
          ? null
          : col.presets[src.configId];
      final List<String> parts = _parts(full);
      final String? parentName = parts.length == 1
          ? null
          : parts.sublist(0, parts.length - 1).join('::');
      final SrsAnkiDeck? parentSrc = parentName == null
          ? null
          : byName[parentName];
      // 父牌组也是本次新建、且两者的排程设置相同 → 继承；否则 own（顶层恒 own）。「相同」不只
      // 认同一个预设 id：Anki 里给子牌组复制一份内容一模一样的预设很常见，按 id 判会把这些子牌组
      // 全落成「单独设置」，之后改父牌组的参数就得逐个子牌组去改。
      final SrsAnkiPreset? parentPreset = parentSrc == null
          ? null
          : col.presets[parentSrc.configId];
      final bool inherit =
          preset != null &&
          parentPreset != null &&
          created.contains(parentName) &&
          _sameInheritedSettings(preset, parentPreset);
      if (preset != null) {
        values.addAll(
          _presetValues(
            preset,
            own: !inherit,
            report: reportedPresets.add(preset.id),
          ),
        );
      }
      if (parentName != null) {
        values[SrsFieldKeys.deckParamsMode] = inherit ? 'inherit' : 'own';
      }
      // Anki 里收起的牌组导入后同样收起（缺省展开，不写记录）。
      if (configs && src != null && src.collapsed) {
        values[SrsFieldKeys.deckCollapsed] = true;
      }
      final Map<String, Object?>? ext = _extDecks[full];
      if (ext != null) {
        for (final String k in srsFushiExtDeckKeys) {
          if (ext.containsKey(k)) values[k] = ext[k];
        }
      }
      values.removeWhere((String k, Object? _) => !wanted(k));
    }
    // 关着「使用 RWKV」：自己管参数的新牌组一律落在 FSRS 上——Fushi 自己导出的 RWKV 牌组改回
    // FSRS-7；没写算法的（两个开关都关、或不导入 FSRS 参数——算法键已在上面滤掉）也明确写
    // FSRS-7，否则会落到默认算法 RWKV。必须在上面的按开关过滤之后，不然又被滤掉。
    // 继承父牌组的子牌组不写，随父牌组。
    if (!options.useRwkv) {
      final Object? alg = values[SrsFieldKeys.deckAlgorithm];
      final bool owns =
          _parts(full).length == 1 ||
          values[SrsFieldKeys.deckParamsMode] == 'own';
      if (alg is Map && alg['alg'] == SrsAlgorithm.rwkv.wire) {
        values[SrsFieldKeys.deckAlgorithm] = <String, Object?>{
          ...alg.cast<String, Object?>(),
          'alg': SrsAlgorithm.fsrs7.wire,
        };
      } else if (alg == null && owns) {
        values[SrsFieldKeys.deckAlgorithm] = <String, Object?>{
          'alg': SrsAlgorithm.fsrs7.wire,
          'auto': true,
        };
      }
    }
    return values;
  }

  /// 两个预设落到 Fushi 后、随参数继承的那部分（记忆率、音频、算法、参数组）是否一致。步长 /
  /// 上限 / 最大间隔在 Fushi 里是每个牌组自己的，继承与否都照写，不参与比较；本次不导入的键
  /// （按 [SrsAnkiImportOptions.withDeckConfigs] / [SrsAnkiImportOptions.withFsrsParams]）也不比。
  bool _sameInheritedSettings(SrsAnkiPreset a, SrsAnkiPreset b) {
    if (a.id == b.id) return true;
    Map<String, Object?> inherited(SrsAnkiPreset p) =>
        _presetValues(p, own: true, report: false)
          ..remove(SrsFieldKeys.deckSteps)
          ..remove(SrsFieldKeys.deckLimits)
          ..remove(SrsFieldKeys.deckMaxInterval)
          ..removeWhere(
            (String k, Object? _) => _fsrsDeckKeys.contains(k)
                ? !options.withFsrsParams
                : !options.withDeckConfigs,
          );
    return jsonEncode(inherited(a)) == jsonEncode(inherited(b));
  }

  /// 归「FSRS 参数」开关管的牌组键（其余预设键归「牌组预设」开关）。
  static const Set<String> _fsrsDeckKeys = <String>{
    SrsFieldKeys.deckAlgorithm,
    SrsFieldKeys.deckFsrs6Params,
    SrsFieldKeys.deckFsrs7Params,
    SrsFieldKeys.deckRetention,
  };

  /// 身份记录已存在、却不在牌组树里 = 先前导入过、后来被删。
  Future<bool> _deckDeleted(String id) async {
    final SrsEntityRow? row = await (store.db.select(
      store.db.srsEntities,
    )..where(($SrsEntitiesTable t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return false;
    return (await store.deckTree())[id] == null;
  }

  static List<String> _parts(String full) => full
      .split('::')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();

  Map<String, Object?> _presetValues(
    SrsAnkiPreset p, {
    required bool own,
    required bool report,
  }) {
    final Map<String, Object?> v = <String, Object?>{};
    List<double> steps(List<double> src, List<double> fallback, String kind) {
      final List<double> kept = srsSanitizeSteps(src, fallback);
      final List<double> removed = <double>[
        for (final double s in src)
          if (!(s > 0 && s < 1440)) s,
      ];
      if (removed.isNotEmpty && report && options.withDeckConfigs) {
        this.report.truncatedSteps.add(
          SrsImportTruncatedSteps(
            preset: p.name,
            kind: kind,
            removed: removed,
            kept: kept,
          ),
        );
      }
      return kept;
    }

    v[SrsFieldKeys.deckSteps] = <String, Object?>{
      'learn': steps(p.learnSteps, SrsDeckView.defaultLearnSteps, 'learn'),
      'relearn': steps(
        p.relearnSteps,
        SrsDeckView.defaultRelearnSteps,
        'relearn',
      ),
    };
    v[SrsFieldKeys.deckLimits] = <String, Object?>{
      'new': p.newPerDay,
      'review': p.reviewsPerDay,
    };
    if (p.maxIntervalDays > 0) {
      v[SrsFieldKeys.deckMaxInterval] = p.maxIntervalDays;
    }
    if (!own) return v;
    // 音频两项随参数继承（只写在 own 牌组上）；与缺省值相同时不写，不产生多余记录。
    if (!p.autoplay) v[SrsFieldKeys.deckAutoplay] = false;
    if (!p.replayQuestion) v[SrsFieldKeys.deckReplayQuestion] = false;
    if (p.desiredRetention > 0 && p.desiredRetention < 1) {
      v[SrsFieldKeys.deckRetention] = p.desiredRetention;
    }
    // 带来的 FSRS 参数组（按它自己的算法存）。
    SrsAlgorithm? fsrs;
    List<double>? params;
    if (col.fsrsEnabled) {
      if (p.fsrs7Params.length == SrsAlgorithm.fsrs7.paramCount &&
          (p.fsrsVersion ?? 0) == 0) {
        fsrs = SrsAlgorithm.fsrs7;
        params = p.fsrs7Params;
      } else if (p.fsrs6Params.length == SrsAlgorithm.fsrs6.paramCount) {
        fsrs = SrsAlgorithm.fsrs6;
        params = p.fsrs6Params;
      }
    }
    // 开着「使用 RWKV」（默认）：一律用默认算法 RWKV（RWKV fork 的 rwkvReviewEnabled 预设本来就是）。
    // 带着 FSRS 参数来的预设参数照样存下、报告里写明，用户不要 RWKV 就在报告里「继续用 FSRS」或去
    // 牌组设置切回，参数还在；没有参数的（SM-2 或没优化过）同样写进报告，不静默换算法。
    // 关着：保留来源的 FSRS 算法，没有参数（含 Anki 里开了 RWKV 的）用 FSRS-7，同样进报告。
    // 「参数保留了、可以切回 FSRS」只在导入 FSRS 参数（[SrsAnkiImportOptions.withFsrsParams]）时
    // 成立：关着时算法 / 参数键在 [_newDeckSettings] 里整组滤掉，参数根本没落库，不能这样报。
    final bool rwkv = options.useRwkv;
    final bool keepsParams = options.withFsrsParams;
    if (report) {
      if (p.rwkvEnabled) {
        (rwkv ? this.report.rwkvPresets : this.report.rwkvPresetsOnFsrs).add(
          p.name,
        );
      } else if (fsrs == null) {
        (rwkv
                ? this.report.defaultAlgorithmPresets
                : this.report.defaultFsrsPresets)
            .add(p.name);
      } else if (rwkv && keepsParams) {
        this.report.fsrsPresets[p.name] = fsrs;
      }
    }
    if (rwkv && keepsParams && fsrs != null && !p.rwkvEnabled) {
      _fsrsOfPreset[p.id] = fsrs;
    }
    v[SrsFieldKeys.deckAlgorithm] = <String, Object?>{
      'alg': (rwkv ? srsDefaultAlgorithm : (fsrs ?? SrsAlgorithm.fsrs7)).wire,
      'auto': true,
    };
    if (fsrs != null && params != null) {
      final String? bad = _validate(fsrs, params);
      if (bad != null) {
        if (report && options.withFsrsParams) {
          this.report.invalidParams[p.name] = bad;
        }
      } else {
        v[fsrs == SrsAlgorithm.fsrs6
            ? SrsFieldKeys.deckFsrs6Params
            : SrsFieldKeys.deckFsrs7Params] = SrsParamSet(
          params: params,
        ).toValue();
      }
    }
    return v;
  }

  String? _validate(SrsAlgorithm alg, List<double> params) {
    if (params.length != alg.paramCount) {
      return 'expected ${alg.paramCount} params, got ${params.length}';
    }
    if (params.any((double x) => !x.isFinite)) return 'non-finite parameter';
    return store.engine?.validateParams(alg, params);
  }

  // ------------------------------------------------------------------ 笔记 / 卡片 / 日志

  Future<void> _importNotes() async {
    final int total = max(
      1,
      col.db.select('SELECT count(*) AS n FROM notes').first['n'] as int,
    );
    final PreparedStatement cardsOf = col.db.prepare(
      'SELECT id, did, odid, ord, mod, type, queue, due, odue, ivl, factor, '
      'reps, lapses, data FROM cards WHERE nid = ? ORDER BY ord, id',
    );
    final PreparedStatement revlogOf = col.db.prepare(
      'SELECT id, ease, ivl, factor, time, type FROM revlog WHERE cid = ? ORDER BY id',
    );
    final PreparedStatement notes = col.db.prepare(
      'SELECT id, guid, mid, mod, tags, flds FROM notes ORDER BY id',
    );
    // 本机已有哪些笔记：一次读出 ID 集合，新笔记不必逐条查库（绝大多数导入全是新笔记）。
    _existingNotes = await store.entityIds(SrsEntityKind.note);
    try {
      final IteratingCursor cur = notes.selectCursor();
      int done = 0;
      final List<(Row, List<_SrcCard>)> chunk = <(Row, List<_SrcCard>)>[];
      Future<void> drain() async {
        final _ExistingPrefetch pre = await _prefetchExisting(chunk);
        for (final (Row n, List<_SrcCard> cards) in chunk) {
          await _importNote(n, cards, revlogOf, pre);
          done++;
          if (done % 50 == 0) {
            onProgress?.call(_mediaShare + (1 - _mediaShare) * done / total);
          }
          await _flush();
          await _stopIfAsked();
        }
        chunk.clear();
      }

      while (cur.moveNext()) {
        final Row n = cur.current;
        chunk.add((
          n,
          <_SrcCard>[
            for (final Row r in cardsOf.select(<Object?>[n['id']])) _SrcCard(r),
          ],
        ));
        if (chunk.length >= _noteChunk) await drain();
      }
      await drain();
    } finally {
      cardsOf.close();
      revlogOf.close();
      notes.close();
    }
  }

  /// 一批攒多少条事件再落库（一个事务 + 一次缓存刷新）。太小则事务与刷新次数多；太大则单个
  /// 事务占住连接太久（后台导入时用户仍在用复习页，别的写入要排在事务后面）。
  static const int _batchEvents = 1000;

  /// 来源笔记按块处理：一块里本机已有的笔记，其笔记 / 卡片 / 修改记录 / 历史一次预读
  /// （[_prefetchExisting]）。
  static const int _noteChunk = 200;

  /// 导入开始时本机已有的笔记 ID（见 [_importNotes]）。
  Set<String> _existingNotes = const <String>{};

  /// 来源卡片 → 本机卡片 ID（没有对应模板的卡跳过）。
  List<(_SrcCard, String)> _cardIdsOf(
    _NtMap nt,
    String noteId,
    List<_SrcCard> cards,
  ) => <(_SrcCard, String)>[
    for (final _SrcCard c in cards)
      if (_cardIdOf(nt, noteId, c) case final String id) (c, id),
  ];

  /// 一块来源笔记里本机已有的那些：笔记视图、卡片缓存行、卡片修改记录、（带排程时）卡片历史
  /// 各按块一次读出。以前每条已有笔记逐条读笔记、每张卡逐条读缓存行 / 修改记录 / 历史，
  /// 写入也逐条各开一个事务（重导入同一个包时每条笔记十几次往返）。
  Future<_ExistingPrefetch> _prefetchExisting(
    List<(Row, List<_SrcCard>)> chunk,
  ) async {
    final List<String> noteIds = <String>[];
    final List<String> cardIds = <String>[];
    for (final (Row n, List<_SrcCard> cards) in chunk) {
      final _NtMap? nt = _nts[n['mid'] as int];
      if (nt == null || nt.conflict != null) continue;
      final String noteId = SrsIds.note(profileUid, n['guid'] as String);
      if (!_existingNotes.contains(noteId)) continue;
      noteIds.add(noteId);
      for (final (_SrcCard _, String cardId) in _cardIdsOf(nt, noteId, cards)) {
        cardIds.add(cardId);
      }
    }
    if (noteIds.isEmpty) return _ExistingPrefetch.empty;
    return _ExistingPrefetch(
      notes: await store.notes(noteIds),
      cards: <String, SrsCardCacheRow>{
        for (final SrsCardCacheRow r in await store.cardRows(cardIds)) r.id: r,
      },
      cardEdits: await store.entityEditsMany(SrsEntityKind.card, cardIds),
      histories: options.withScheduling
          ? await store.histories(cardIds)
          : const <String, SrsCardHistory>{},
    );
  }

  /// 本批里当作新笔记攒下的（noteId, 卡数）：落库后按实际是否新建计入报告（BUG-3553）。
  final List<(String, int)> _pendingNewNotes = <(String, int)>[];

  Future<void> _flush({bool force = false}) async {
    if (_pending.isEmpty || (!force && _pending.length < _batchEvents)) return;
    final List<SrsEventDraft> batch = List<SrsEventDraft>.of(_pending);
    final List<(String, int)> newNotes = List<(String, int)>.of(
      _pendingNewNotes,
    );
    _pending.clear();
    _pendingNewNotes.clear();
    final Set<String> existed = await store.importDrafts(batch);
    for (final (String noteId, int cards) in newNotes) {
      if (existed.contains(noteId)) {
        // 攒批期间同一条笔记已被同步 / 别处建好：初值里键已有记录的没落（见
        // SrsEditDraft.initial），不算新增。
        report.notesSkipped++;
      } else {
        report.notesAdded++;
        report.cardsAdded += cards;
      }
    }
  }

  Future<void> _importNote(
    Row n,
    List<_SrcCard> cards,
    PreparedStatement revlogOf,
    _ExistingPrefetch pre,
  ) async {
    final String guid = n['guid'] as String;
    final int mid = n['mid'] as int;
    final _NtMap? nt = _nts[mid];
    if (nt == null || nt.conflict != null) {
      report.conflictNotes.add(
        SrsImportNoteIssue(
          guid: guid,
          noteType: nt?.name ?? '$mid',
          reason: nt?.conflict ?? SrsImportIssueReason.missingNoteType,
        ),
      );
      return;
    }
    final List<String> raw = (n['flds'] as String).split('\x1f');
    final Map<String, String> fields = <String, String>{};
    final bool hasRefs = _notesWithRefs?.contains(n['id'] as int) ?? true;
    for (int i = 0; i < nt.fieldIds.length; i++) {
      if (i >= raw.length) {
        fields[nt.fieldIds[i]] = '';
        continue;
      }
      if (!hasRefs) {
        fields[nt.fieldIds[i]] = raw[i];
        continue;
      }
      final FutureOr<String> v = _fieldWithMedia(raw[i]);
      fields[nt.fieldIds[i]] = v is String ? v : await v;
    }
    final List<String> tags = (n['tags'] as String)
        .split(RegExp(r'\s+'))
        .where((String t) => t.isNotEmpty)
        // 不含排程：与 Anki 相同，去掉 marked / leech 这两个排程系统标签。
        .where(
          (String t) =>
              options.withScheduling ||
              !_schedulingTags.contains(t.toLowerCase()),
        )
        .toList();
    final String noteId = SrsIds.note(profileUid, guid);
    final SrsNoteView? existing = !_existingNotes.contains(noteId)
        ? null
        : pre.notes.containsKey(noteId)
        ? pre.notes[noteId]
        : await store.note(noteId);
    final String firstDeck = cards.isEmpty
        ? store.defaultDeckId
        : (_deckOf[cards.first.homeDeck] ?? store.defaultDeckId);

    final bool isNew = existing == null;
    final bool noteDeleted = existing != null && existing.deletedAt != null;
    // 先前导入过、后来在本机被删：重新导入即恢复（与牌组同一条规则，见 [_importDecks]；Anki
    // 里删掉的笔记不留身份，再导入就是新加）。以前按「已存在、较新时更新」走，本机内容的
    // 修改时刻晚于来源 mod → 记为未改动，删除标记永远不清：牌组复活了、笔记仍是删除态，
    // 卡片留在删牌组时移去的默认牌组里且被隐藏。
    //
    // 笔记类型这次被恢复的，它的笔记同样算恢复：删笔记类型时它们一并被删（[SrsNoteTypeStoreOps.deleteNoteType]），
    // 先前的导入只清了笔记的删除标记、笔记类型仍是删除态，笔记还在、却因笔记类型已删全部隐藏（再导入时
    // 「较新时更新」又算成已更新）——这些也要回到来源内容、卡片回到来源牌组。
    //
    // 本机已删的笔记连笔记类型也回到来源：Anki 里删掉的笔记不留身份，来源换过笔记类型（Anki「更改
    // 笔记类型」不换 guid）再导入就是按新类型新加。以前「本机笔记类型不同 → 冲突跳过」排在恢复
    // 之前，删了的笔记照样被拦，用户删光重导也永远导不回来（BUG-3887）。
    final bool restored = existing != null && (noteDeleted || nt.restored);
    final bool retype = noteDeleted && existing?.noteTypeId != nt.id;
    final List<(_SrcCard, String)> cardIds = _cardIdsOf(nt, noteId, cards);
    bool update = false;
    if (isNew) {
      // 新笔记的事件攒进本批，与它的卡片标志、日志同一个事务落库（以前每条笔记各自
      // 落两三次库、各刷新一遍缓存，见 BUG-3549）。
      _pending.addAll(
        store.newNoteDrafts(
          noteTypeId: nt.id,
          fieldsById: fields,
          deckId: firstDeck,
          tags: tags,
          source: SrsSourceRef.fromJson(_extNotes[guid]),
          guid: guid,
          createdAt: _extNoteCreatedAt[guid] ?? n['id'] as int,
        ),
      );
      _pendingNewNotes.add((noteId, cards.length));
    } else if (existing.noteTypeId != nt.id && !retype) {
      report.conflictNotes.add(
        SrsImportNoteIssue(
          guid: guid,
          noteType: nt.name,
          reason: SrsImportIssueReason.noteTypeChanged,
        ),
      );
      // 本机换过笔记类型（旧 Lapis 迁到 Fushi 卡片）：内容与日志不动，但从没排过的新卡位置照样
      // 补上（写到继承这些卡的可见卡上，见 [_repairNewPositions]）——已迁移用户重迁的补救路径。
      if (options.withScheduling) {
        for (final _SrcCard c in cards) {
          final String? cardId = _cardIdOf(nt, noteId, c);
          if (cardId != null) _importNewPosition(cardId, c, noteExisted: true);
        }
      }
      return;
    } else if (restored) {
      // 删除标记、内容、标签、首选牌组一律回到来源：用户要的是「把它导回来」，本机的旧内容
      // 只是删除前的残留，不参与「较新时更新」的比较。
      update = true;
      // 恢复是少见路径，这里仍立即落库：恢复会改笔记的首选牌组 / 隐藏态，卡片缓存行（下面
      // 比较牌组用）要在它落库之后重读才是真值（没有自己牌组记录的卡跟着笔记走）。
      await store.editFields(SrsEntityKind.note, noteId, <String, Object?>{
        if (noteDeleted) SrsFieldKeys.deleted: null,
        if (retype) SrsFieldKeys.noteType: nt.id,
        for (final MapEntry<String, String> f in fields.entries)
          if (existing.field(f.key) != f.value)
            SrsFieldKeys.noteField(f.key): f.value,
        if (!_sameList(existing.tags, tags)) SrsFieldKeys.noteTags: tags,
        if (existing.deckId != firstDeck) SrsFieldKeys.noteDeck: firstDeck,
      });
      for (final SrsCardCacheRow r in await store.cardRows(<String>[
        for (final (_SrcCard _, String id) in cardIds) id,
      ])) {
        pre.cards[r.id] = r;
      }
      report.notesRestored++;
    } else if (options.updateNotes.shouldUpdate(
      localMs: _lastEditMs(
        existing.edits,
        _isNoteContentKey,
        existing.createdAt,
      ),
      sourceMs: ((n['mod'] as int?) ?? 0) * 1000,
    )) {
      update = true;
      // 修改记录攒进本批（与新笔记同一个事务落库；以前每条已有笔记各开一个事务）。值没变且无
      // 冲突的键按块开头读到的现值滤掉（同 editFields 的规则）。
      final List<SrsEditDraft> drafts = store.newEditDrafts(
        SrsEntityKind.note,
        noteId,
        <String, Object?>{
          // 只写与本机物化值不同的项（缺记录的字段读作空、空标签不必再写一遍）。
          for (final MapEntry<String, String> f in fields.entries)
            if (existing.field(f.key) != f.value)
              SrsFieldKeys.noteField(f.key): f.value,
          if (!_sameList(existing.tags, tags)) SrsFieldKeys.noteTags: tags,
        },
        current: existing.edits,
      );
      if (drafts.isNotEmpty) {
        _pending.addAll(drafts);
        report.notesUpdated++;
      } else {
        report.notesSkipped++;
      }
    } else {
      report.notesSkipped++;
    }

    for (final (_SrcCard c, String cardId) in cardIds) {
      await _importCardFlags(
        cardId,
        c,
        firstDeck,
        pre,
        isNew: isNew,
        update: update,
        restored: restored,
      );
      if (options.withScheduling) {
        await _importCardSchedule(
          cardId,
          c,
          revlogOf,
          isNew ? null : pre.histories[cardId] ?? await store.history(cardId),
        );
      } else if (isNew && (c.type != 0 || c.queue < 0)) {
        report.cardsResetToNew++;
      }
    }
  }

  /// 来源卡在本机的卡 ID（模板按 ord 对应；填空题共用一个模板、按填空序号区分）。
  String? _cardIdOf(_NtMap nt, String noteId, _SrcCard c) {
    final String? tplId = nt.isCloze
        ? (nt.templateIdByOrd.isEmpty
              ? null
              : nt.templateIdByOrd[nt.templateIdByOrd.keys.reduce(min)])
        : nt.templateIdByOrd[c.ord];
    if (tplId == null) return null;
    return SrsIds.card(noteId, tplId, nt.isCloze ? c.ord + 1 : 0);
  }

  Future<void> _importCardFlags(
    String cardId,
    _SrcCard c,
    String noteDeck,
    _ExistingPrefetch pre, {
    required bool isNew,
    required bool update,
    bool restored = false,
  }) async {
    if (!isNew && !update) return;
    final String deck = _deckOf[c.homeDeck] ?? store.defaultDeckId;
    // 暂停属于排程（Anki 不含排程时整卡 schedule_as_new，暂停一并清掉）。
    final bool suspended = c.queue == -1;
    final bool withSuspend = options.withScheduling;
    if (isNew) {
      // 卡片随笔记在同一批里新建：修改记录直接攒进本批（本机没有这张卡的记录，不必读库判 no-op）。
      _pending.addAll(
        store.newEditDrafts(SrsEntityKind.card, cardId, <String, Object?>{
          if (deck != noteDeck) SrsFieldKeys.cardDeck: deck,
          if (withSuspend && suspended) SrsFieldKeys.suspended: true,
        }),
      );
      return;
    }
    // 缓存行与修改记录在块开头一次预读（[_prefetchExisting]）。
    final SrsCardCacheRow? row = pre.cards[cardId];
    if (row == null) return;
    // 本机在来源卡片最后修改之后改过的（用户在 Fushi 里挪过牌组 / 暂停过）不覆盖：按这个键的
    // 修改记录时刻与 Anki 卡片 mod 比，新的赢（同 Anki 导入对已有卡片的「较新时更新」）。
    // 以前笔记内容一更新就无条件改回 Anki 的牌组 / 暂停状态（BUG-3554）。
    final SrsEntityEdits edits =
        pre.cardEdits[cardId] ??
        await store.entityEdits(SrsEntityKind.card, cardId);
    final int sourceMs = c.mod * 1000;
    // 恢复的笔记不比：本机那次改动（删牌组「保留卡片」时移去默认牌组）正是要撤回的。
    bool localNewer(String key) =>
        !restored && _lastEditMs(edits, (String k) => k == key, 0) > sourceMs;
    // 同 moveCard / setSuspended，但攒进本批（以前每个键各开一个事务）。
    _pending.addAll(
      store.newEditDrafts(SrsEntityKind.card, cardId, <String, Object?>{
        if (row.deckId != deck && !localNewer(SrsFieldKeys.cardDeck))
          SrsFieldKeys.cardDeck: deck,
        if (withSuspend &&
            row.suspended != suspended &&
            !localNewer(SrsFieldKeys.suspended))
          SrsFieldKeys.suspended: suspended,
      }, current: edits),
    );
  }

  /// Anki 新卡的出卡位置（`due` 是新卡序号；在筛选牌组里时原值在 `odue`）→ Fushi 的
  /// [SrsFieldKeys.cardNewPosition]。以前不导：迁移后的新卡全部「没排过」，按笔记创建时刻出，
  /// Anki 里按词频 / 手动排好的顺序丢了。
  ///
  /// 本机已有的卡（重新导入 / 已迁移用户再迁一次）只补「从没排过」的：本机排过的（「按词频
  /// 重排新卡」、Fushi 里改过位置）不覆盖。
  void _importNewPosition(
    String cardId,
    _SrcCard c, {
    required bool noteExisted,
  }) {
    if (c.type != 0) return;
    final int pos = c.odid != 0 && c.odue != 0 ? c.odue : c.due;
    if (!noteExisted) {
      _pending.addAll(
        store.newEditDrafts(SrsEntityKind.card, cardId, <String, Object?>{
          SrsFieldKeys.cardNewPosition: pos,
        }),
      );
      return;
    }
    _positionRepairs[cardId] = pos;
  }

  /// 已有卡的新卡位置补救：导入的卡若已被换成别的卡（旧 Lapis 迁到 Fushi 卡片后旧卡隐藏），写到
  /// 继承它的可见卡上；只补此刻可见、还是新卡、从没排过位置的（本机排过的不覆盖）。
  Future<void> _repairNewPositions() async {
    if (_positionRepairs.isEmpty) return;
    final Map<String, String> owners = await store.historyOwnerIndex();
    final Map<String, int> target = <String, int>{};
    for (final MapEntry<String, int> e in _positionRepairs.entries) {
      target.putIfAbsent(owners[e.key] ?? e.key, () => e.value);
    }
    final Map<String, int> unpositioned = <String, int>{
      for (final SrsCardCacheRow c in await store.cardRows(target.keys))
        if (c.newPosition == null) c.id: target[c.id]!,
    };
    report.newPositionsRepaired = (await store.setNewCardPositions(
      unpositioned,
    )).length;
  }

  Future<void> _importCardSchedule(
    String cardId,
    _SrcCard c,
    PreparedStatement revlogOf,
    // 已有笔记的卡在本机的历史（块开头预读）；新笔记为 null（据此也判断笔记是否已存在）。
    SrsCardHistory? existingHistory,
  ) async {
    final List<_SrcRevlog> revlogs = <_SrcRevlog>[
      for (final Row r in revlogOf.select(<Object?>[c.id])) _SrcRevlog(r),
    ];
    // 整张卡的 revlog id 一次批量派生（UUIDv5 在 native/fushi_compute 里算）。
    final List<String> revlogIds = SrsIds.importedRevlogs(cardId, <int>[
      for (final _SrcRevlog r in revlogs) r.id,
    ]);
    _importNewPosition(cardId, c, noteExisted: existingHistory != null);
    final (int nowMs, _) = store.now();
    final int latest = revlogs.isEmpty ? 0 : revlogs.last.id;
    if (latest > nowMs + srsClockToleranceMs) {
      report.futureCards.add(c.id);
      return;
    }

    // fushi-ext：恢复 Fushi 日志；它导出的 revlog 只作校验。
    final List<SrsReviewLog> extLogs =
        _extLogsByCard[c.id] ?? const <SrsReviewLog>[];
    final Set<int> extRevlogs = <int>{};
    if (extLogs.isNotEmpty) {
      for (final SrsReviewLog l in extLogs) {
        final int? rid = _extRevlogIds[l.id];
        if (rid != null) extRevlogs.add(rid);
        _pending.add(SrsReadyDraft(SrsLogEvent(_remapExtLog(l, cardId))));
        report.fushiLogsRestored++;
      }
    }

    final List<SrsReviewLog>? native = existingHistory?.all
        .where((SrsReviewLog l) => l.origin == SrsLogOrigin.fushi)
        .toList();

    int reps = 0;
    int lapses = 0;
    int? lastRated;
    for (int i = 0; i < revlogs.length; i++) {
      final _SrcRevlog r = revlogs[i];
      final bool rating = r.isRating;
      if (rating) {
        reps++;
        if (r.type == 1 && r.ease == 1) lapses++;
        lastRated = r.id;
      } else if (!r.isFiltered && r.row.isReset) {
        reps = 0;
        lapses = 0;
      }
      if (extRevlogs.contains(r.id)) {
        report.revlogsVerifiedByExt++;
        continue;
      }
      if (pkg.fushiExt != null) report.revlogsNotInExt++;
      _pending.add(
        SrsReadyDraft(
          SrsLogEvent(
            _revlogLog(
              cardId,
              r,
              id: revlogIds[i],
              reps: reps,
              lapses: lapses,
              lastRated: lastRated,
            ),
          ),
        ),
      );
      report.reviewLogsImported++;
    }

    final SrsAnchorDecision d = srsDecideAnchor(
      sourceIsNew: c.type == 0,
      revlogs: <SrsAnkiRevlogRow>[for (final _SrcRevlog r in revlogs) r.row],
      collectionCreatedMs: col.crtSecs * 1000,
      equivalentToNative: (SrsAnkiRevlogRow last) {
        if (extRevlogs.contains(last.id)) return true;
        final List<SrsReviewLog>? nat = native;
        if (nat == null || nat.isEmpty) return false;
        final int at = revlogs.lastIndexWhere(
          (_SrcRevlog r) => r.id == last.id,
        );
        if (at < 0) throw StateError('No element');
        final SrsReviewLog imported = _revlogLog(
          cardId,
          revlogs[at],
          id: revlogIds[at],
          reps: 0,
          lapses: 0,
          lastRated: null,
        );
        // native 是这张卡的整份历史（含前身卡的日志），同一张逻辑卡。判据在卡片历史内核里
        // （与历史选取里的等价导入同一个函数）；这张卡本来就要单独读一次历史，判重随它一次 FFI。
        return srsImportEquivalentAny(<(SrsReviewLog, List<SrsReviewLog>)>[
          (imported, nat),
        ]).single;
      },
    );
    if (!d.write) return;
    final int t = d.anchorMs!;
    final SrsMemory? mem = _memoryOf(c.data);
    _pending.add(
      SrsReadyDraft(
        SrsLogEvent(
          SrsReviewLog(
            id: SrsIds.importAnchor(cardId, t),
            profileUid: profileUid,
            cardId: cardId,
            kind: SrsLogKind.importAnchor,
            hlc: srsImportAnchorHlc(t),
            occurredAt: t,
            timeSource: SrsTimeSource.wall,
            origin: SrsLogOrigin.anki,
            reviewType: SrsReviewType.manual,
            utcOffsetMin: srcDay.utcOffsetMin,
            dayRolloverHour: srcDay.rolloverHour,
            result: _cardState(c, lastRated, mem),
            extra: mem == null
                ? const <String, Object?>{}
                : <String, Object?>{'memAlg': SrsAlgorithm.fsrs6.wire},
          ),
        ),
      ),
    );
    report.anchorsWritten++;
  }

  SrsReviewLog _remapExtLog(SrsReviewLog l, String cardId) {
    if (_extSameProfile && l.cardId == cardId) return l;
    if (_extSameProfile && _extLogCards.containsKey(l.id)) {
      // 同 profile：前身卡的身份在本 profile 下不变，日志原样落回前身卡，再补上前身链接。
      _historyLinks.add(
        SrsEditSpec(
          SrsEntityKind.card,
          cardId,
          SrsFieldKeys.cardHistoryFrom(l.cardId),
          true,
        ),
      );
      return l;
    }
    final Map<String, Object?> j = l.toJson();
    j['id'] = SrsIds.remappedLog(cardId, l.id);
    if (l.revokesId != null) {
      j['revokes'] = SrsIds.remappedLog(cardId, l.revokesId!);
    }
    j['card'] = cardId;
    j['p'] = profileUid;
    return SrsReviewLog.fromJson(j);
  }

  SrsReviewLog _revlogLog(
    String cardId,
    _SrcRevlog r, {
    required String id,
    required int reps,
    required int lapses,
    required int? lastRated,
  }) {
    final bool manual = !r.isFiltered && !r.isRating;
    return SrsReviewLog(
      id: id,
      profileUid: profileUid,
      cardId: cardId,
      kind: manual ? SrsLogKind.manual : SrsLogKind.review,
      rating: r.ease >= 1 && r.ease <= 4 ? r.ease : null,
      hlc: srsImportedRevlogHlc(r.id),
      occurredAt: r.id,
      timeSource: SrsTimeSource.wall,
      origin: SrsLogOrigin.anki,
      reviewType: SrsReviewType.fromAnki(r.type),
      durationMs: r.time,
      algorithm: 'anki',
      utcOffsetMin: srcDay.utcOffsetMin,
      dayRolloverHour: srcDay.rolloverHour,
      result: r.isFiltered
          ? null
          : _revlogResult(r, reps: reps, lapses: lapses, lastRated: lastRated),
      ankiRevlogId: r.id,
    );
  }

  /// 该次之后 Anki 的状态近似。
  SrsScheduleResult _revlogResult(
    _SrcRevlog r, {
    required int reps,
    required int lapses,
    required int? lastRated,
  }) {
    final int day = srcDay.dayIndexOf(r.id);
    final int? ease = r.factor > 0 ? r.factor : null;
    SrsScheduleResult review() => SrsScheduleResult(
      queue: SrsQueue.review,
      dueDay: day + max(0, r.ivl),
      scheduledDays: max(0, r.ivl),
      lastReviewedAt: lastRated,
      reps: reps,
      lapses: lapses,
      ease: ease,
    );
    SrsScheduleResult learning(SrsQueue q) => SrsScheduleResult(
      queue: q,
      dueAt: r.id + (r.ivl < 0 ? -r.ivl * 1000 : 0),
      lastReviewedAt: lastRated,
      reps: reps,
      lapses: lapses,
      ease: ease,
    );
    if (!r.isRating) {
      if (r.row.isReset) {
        return const SrsScheduleResult(queue: SrsQueue.newCard);
      }
      return r.ivl < 0 ? learning(SrsQueue.learning) : review();
    }
    return switch (r.type) {
      0 => r.ivl > 0 ? review() : learning(SrsQueue.learning),
      1 => r.ease == 1 && r.ivl <= 0 ? learning(SrsQueue.relearning) : review(),
      _ => r.ivl > 0 ? review() : learning(SrsQueue.relearning),
    };
  }

  /// 锚点结果：来源卡的状态。
  SrsScheduleResult _cardState(_SrcCard c, int? lastRated, SrsMemory? mem) {
    final SrsQueue q = switch (c.type) {
      1 => SrsQueue.learning,
      2 => SrsQueue.review,
      3 => SrsQueue.relearning,
      _ => SrsQueue.newCard,
    };
    final int due = c.odid != 0 && c.odue != 0 ? c.odue : c.due;
    int? dueDay;
    int? dueAt;
    switch (q) {
      case SrsQueue.review:
        dueDay = crtDay + due;
      case SrsQueue.learning:
      case SrsQueue.relearning:
        // queue 1 的 due 是秒级时间戳；跨天学习（queue 3）的 due 是相对 crt 的天数。
        dueAt = c.queue == 3 || due < 1000000000
            ? srcDay.dayStartMs(crtDay + due)
            : due * 1000;
      case SrsQueue.newCard:
        break;
    }
    return SrsScheduleResult(
      queue: q,
      dueDay: dueDay,
      dueAt: dueAt,
      scheduledDays: max(0, c.ivl),
      memory: mem,
      lastReviewedAt: q == SrsQueue.newCard ? null : lastRated,
      reps: c.reps,
      lapses: c.lapses,
      scheduler: srsAnchorScheduler,
      ease: c.factor > 0 ? c.factor : null,
    );
  }

  static SrsMemory? _memoryOf(String data) {
    if (data.isEmpty) return null;
    try {
      final Object? j = jsonDecode(data);
      if (j is! Map) return null;
      final Object? s = j['s'];
      final Object? d = j['d'];
      if (s is! num || d is! num) return null;
      return SrsMemory(stability: s.toDouble(), difficulty: d.toDouble());
    } on FormatException {
      return null;
    }
  }
}
