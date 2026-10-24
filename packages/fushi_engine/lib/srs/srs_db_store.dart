/// Fushi SRS 的数据库副本：事件落 Drift（schema v117 的 srs_* 表），行为与
/// fushi_srs 的 SrsMemoryReplica / SrsEventStore 一致（同一套合并函数），外加本机缓存与 app 用的查询 / 操作 API。
///
/// - 同步的只有三种事件：身份记录、修改记录、复习日志（另有不认识的事件原样保留）。
/// - 卡片行与笔记缓存只在本机，可随时由事件重建（[rebuildCaches]）。
/// - 事件创建即不可变；任何环节都不改事件内容。唯一的表示层例外是释义样式去重（[styles]）：
///   笔记字段值里够大的内联 `<style>` 在落库时换成共享样式文件的引用行，修改记录的身份、因果、
///   排序字段一律不动，合并时两种表示按同一内容比较（fushi_srs style_dedup.dart）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_backup_snapshot.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_fushi_card_native_media.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';

/// 本机时间：服务器校时锚点 + 本进程单调时钟（Stopwatch）。
///
/// 计划要求「含睡眠的开机单调时钟」（Android elapsedRealtime 等）；纯 Dart 拿不到，这里退到本进程内的
/// Stopwatch：同一进程内改系统时间不影响记录，进程重启后要重新校时（锚点按进程 bootId 失效）。
SrsTrustedClock srsProcessTrustedClock() {
  final Stopwatch sw = Stopwatch()..start();
  final int base = DateTime.now().millisecondsSinceEpoch;
  return SrsTrustedClock(
    wallClockMs: () => DateTime.now().millisecondsSinceEpoch,
    monotonicMs: () => base + sw.elapsedMilliseconds,
    bootId: '${base}_${Random.secure().nextInt(1 << 30)}',
  );
}

/// 批量写的一项：某实体的某字段改成 [value]（见 [SrsDbStore.editFieldsBatch]）。
class SrsFieldChange {
  const SrsFieldChange(this.kind, this.entityId, this.key, this.value);

  final SrsEntityKind kind;
  final String entityId;
  final String key;
  final Object? value;
}

/// 「按词频重排新卡」读到的一张新卡（[SrsDbStore.newCardsInDeck]）。
class SrsNewCardEntry {
  const SrsNewCardEntry({
    required this.card,
    required this.note,
    required this.noteType,
    required this.ord,
    required this.position,
  });

  final SrsCardCacheRow card;
  final SrsNoteView note;
  final SrsNoteTypeView noteType;

  /// 同一笔记的第几张卡（标准类型 = 模板序号，填空 = cN - 1），与 AnkiConnect `ord` 同口径。
  final int ord;

  /// 此刻在出卡队列里的位置：排过的卡是它的 [SrsCardCacheRow.newPosition]；没排过的卡
  /// 按出卡顺序接在已排的最大位置后面编号（只供比较与撤销，不落库）。与
  /// [SrsDbStore.compareNewCardOrder] 的顺序一致、严格递增。
  final int position;
}

/// [SrsDbStore.moveDeck] 的结果。
enum SrsDeckMoveResult {
  moved,

  /// 本来就在那里。
  unchanged,

  /// 牌组或目标牌组不存在（已删）。
  missing,

  /// 目标是它自己或它的子孙。
  intoOwnSubtree,

  /// 目标下已有同名牌组。
  nameTaken,
}

/// 牌组列表的一行。
class SrsDeckSummary {
  const SrsDeckSummary({
    required this.deck,
    required this.fullName,
    required this.depth,
    required this.newCount,
    required this.learnCount,
    required this.reviewCount,
    required this.newBudget,
    required this.totalCards,
    this.parentId,
  });

  final SrsDeckView deck;
  final String fullName;
  final int depth;

  /// 牌组树里解析后的父牌组（成环已打破；顶层 = null）。列表的折叠按它找后代。
  final String? parentId;
  final int newCount;
  final int learnCount;
  final int reviewCount;
  final SrsNewCardBudget newBudget;
  final int totalCards;
}

/// 复习页一张卡的全部信息。
class SrsCardDetail {
  const SrsCardDetail({
    required this.card,
    required this.note,
    required this.noteType,
    required this.template,
    required this.deckName,
  });

  final SrsCardCacheRow card;
  final SrsNoteView note;
  final SrsNoteTypeView noteType;
  final SrsTemplateDef? template;
  final String deckName;
}

/// 渲染好的卡面。
class SrsRenderedCard {
  const SrsRenderedCard({
    required this.question,
    required this.answer,
    required this.css,
    required this.isEmpty,
    this.fields = const <String, String>{},
    this.fushiCardDefinitions,
  });

  final String question;
  final String answer;
  final String css;
  final bool isEmpty;

  /// 笔记字段（按字段名）。
  final Map<String, String> fields;

  /// 内置「Fushi 卡片」且模板 / 样式未被改动时：只含释义区的背面（见
  /// [kFushiCardDefinitionsTemplate]），复习页据此走原生 + 释义 WebView 的混合渲染。
  /// 其它类型、或用户改过模板的 Fushi 卡片为 null（整面 WebView，与 Anki 一致）。
  final String? fushiCardDefinitions;
}

/// [SrsDbStore.writeEdits] 的一项：给某实体的某个字段键写一个值。
class SrsEditSpec {
  const SrsEditSpec(this.kind, this.entityId, this.key, this.value);

  final SrsEntityKind kind;
  final String entityId;
  final String key;
  final Object? value;
}

/// 本机事件的草稿（[SrsDbStore.importDrafts]）：修改记录只记「给哪个实体的哪个字段键写什么值」，
/// 写入者序号与 HLC 等到落库的同一个独占区里才分配；其余事件（身份记录、来源给定 HLC 的日志）
/// 已定稿，原样带上。
sealed class SrsEventDraft {
  const SrsEventDraft();
}

/// 已定稿的事件（身份记录、日志、不认识的事件）。
final class SrsReadyDraft extends SrsEventDraft {
  const SrsReadyDraft(this.event);

  final SrsEvent event;
}

/// 一条待分配序号的本机修改记录。
final class SrsEditDraft extends SrsEventDraft {
  const SrsEditDraft(
    this.kind,
    this.entityId,
    this.key,
    this.value, {
    this.machine = false,
    this.initial = false,
  });

  final SrsEntityKind kind;
  final String entityId;
  final String key;
  final Object? value;
  final bool machine;

  /// 新建实体的初值：攒草稿时以为本机还没有这个实体的记录（[SrsDbStore.newEditDrafts] 不给
  /// current）。落库时（[SrsDbStore.importDrafts] 的独占区里）若这个键已经有修改记录——攒批
  /// 期间同步把对端的同一实体（ID 由 guid / 全名确定性派生）应用进来了——这条初值就不落：
  /// 它在落库时才分配 HLC 与因果上下文，会支配对端的编辑、把用户的新值盖成源里的旧值。
  final bool initial;
}

/// 长操作（删牌组）的进度：已完成 / 总数（同一单位，例如张卡）。
typedef SrsProgress = void Function(int done, int total);

/// 墓碑能不能物理清除：[deleted] 是笔记的删除寄存器（已确认是「已删除」），[serverTimeOf] 给出
/// 事件的服务器时间 S（未知 = null）。策略见 srs_purge.dart 的 `srsTombstoneExpired`。
typedef SrsTombstonePredicate =
    bool Function(
      SrsRegister deleted,
      int? Function(String eventId) serverTimeOf,
    );

/// [SrsDbStore.purgeDeletedNotes] 一块的结果。
class SrsPurgeChunk {
  const SrsPurgeChunk({
    required this.notes,
    required this.cardIds,
    required this.events,
    required this.mediaRefs,
  });

  static const SrsPurgeChunk empty = SrsPurgeChunk(
    notes: <String>[],
    cardIds: <String>[],
    events: 0,
    mediaRefs: <String>{},
  );

  /// 真被清除的笔记。
  final List<String> notes;

  /// 随之清除的卡。
  final List<String> cardIds;
  int get cards => cardIds.length;

  /// 删掉的事件行数（身份记录 + 修改记录 + 复习日志）。
  final int events;

  /// 被清除笔记的字段值引用过的媒体文件名（未核对存活引用）。
  final Set<String> mediaRefs;
}

class SrsDbStore implements SrsSyncReplica {
  SrsDbStore._({
    required this.db,
    required this.profileUid,
    required this.deviceId,
    required this.engine,
    required SrsTrustedClock trustedClock,
    required int Function() fallbackRolloverHour,
    this.styles,
  }) : _trusted = trustedClock,
       _fallbackRollover = fallbackRolloverHour;

  /// 打开（或首次初始化）某 profile 的 SRS 副本。
  static Future<SrsDbStore> open({
    required FushiDatabase db,
    required String profileUid,
    required String deviceId,
    FsrsEngine? engine,
    SrsTrustedClock? trustedClock,
    int Function()? fallbackRolloverHour,
    SrsStyleStore? styles,
  }) async {
    final SrsDbStore s = SrsDbStore._(
      db: db,
      profileUid: profileUid,
      deviceId: deviceId,
      engine: engine,
      trustedClock: trustedClock ?? srsProcessTrustedClock(),
      fallbackRolloverHour:
          fallbackRolloverHour ?? () => SrsDayContext.defaultRolloverHour,
      styles: styles,
    );
    final bool hadLocalState = await s._loadLocal();
    // 老版本存的本机状态没有纪元：当场落盘，否则每次打开都是新纪元、指纹每次都「变了」。
    if (hadLocalState && s._epochMissing) await s._saveLocal();
    await s._migrateLegacyFrozenBatch();
    if (hadLocalState && s._cacheRevision < _kCacheRevision) {
      await s._upgradeCaches();
    }
    if (!hadLocalState && await s._hasAnyEvent()) {
      // 有事件却没有本机状态：覆盖恢复了备份（本机状态与缓存不进备份，恢复时清空）。
      // 换新化身、重新发布、重建缓存；绝不沿用备份来源设备的写入者身份。
      await s.afterRestore();
    }
    await s.ensureBuiltins();
    return s;
  }

  final FushiDatabase db;
  final String profileUid;
  final String deviceId;

  /// 排程内核；null = 原生库不可用（只能浏览 / 编辑，不能复习）。
  final FsrsEngine? engine;

  /// RWKV-Instant 排队时「此刻回忆率」的来源（app 装配 `SrsRwkvService`，见 [_instantReviews]）；
  /// null 或它没准备好时 RWKV 牌组按存下的到期日排队（`SrsAnswerPreview.rwkvUnavailable`）。
  SrsRwkvScheduling? rwkv;

  /// 释义样式去重的共享样式文件库；null = 不去重（字段值原样落库）。见 [compactStoredStyles]。
  final SrsStyleStore? styles;
  final SrsTrustedClock _trusted;
  final int Function() _fallbackRollover;

  late SrsSyncLocalState _sync;
  late SrsEditWriter _writer;
  late HlcClock _clock;
  int _incarnation = 1;
  int _outboxSeq = 0;

  /// 存量样式去重的进度：srs_field_edits 里已检查到的 rowid（本机状态，不进备份）。
  int _styleCursor = 0;

  /// 墓碑清除收集到、还没回收的媒体文件名（[purgeDeletedNotes] 与笔记删除同一事务落进本机状态）。
  /// 回收（srs_purge.dart）在独占区里核对存活引用后删文件并从这里移除；刚被写过 / 复用过的文件
  /// 留到下一轮。持久化是为了崩溃、被叫停或宽限期内跳过的名字下次接着处理——否则笔记已清、
  /// 候选只在那一轮内存里，文件就永远没人回收了。
  final Set<String> _pendingMediaGc = <String>{};

  /// 本机缓存按哪一版推导规则建的（本机状态，不进备份）。缓存加了新的派生列、而存量库里
  /// 可能已有喂它的修改记录时 +1，并在 [_upgradeCaches] 里补一步定向重算。
  ///
  /// 1（v123）：srs_cards_cache.new_position。旧版本设备会照常收下对端同步来的 `newPos`
  /// 修改记录（修改记录不认键名、原样落库），但它的卡片缓存没有这一列；升级加列时留 NULL，
  /// 这些卡就一直按创建时刻出、取卡读到的位置也是空的，直到这张卡再被改一次。
  ///
  /// 2（v129）：srs_stat_reviews（有效复习投影）。升级时整张卡片缓存按事件重算一遍，把投影
  /// 填满（投影与卡片缓存出自同一次重算，见 [_cardCacheRow]）。
  static const int _kCacheRevision = 2;
  int _cacheRevision = _kCacheRevision;

  /// 库的变化修订号：任何事件真正落库（本机产生或对端来的）+1（见 [changeFingerprint]）。
  int _revision = 0;

  /// 内容修订号（只在内存）：修订号的子集——复习日志与界面状态类修改记录（牌组收起 / 展开，
  /// [SrsFieldClass.viewState]）不推进它。同步冲突、待裁决笔记、旧 Lapis 迁移提醒这类「整库扫一遍」
  /// 的角标只随它变（见 [contentFingerprint]）：评分一次只落日志，牌组列表 / 首页面板跟着重读计数时
  /// 不必把这些角标再扫一遍。
  int _contentRevision = 0;

  /// 当前修订号（同步可读；与 [changeFingerprint] 同一个数，不含纪元）。牌组列表据此判断一份重读
  /// 结果是不是在某次写入之后取的。
  int get revision => _revision;

  /// 内容指纹：纪元 + 内容修订号。相等 = 两次读之间没有落过日志 / 界面状态以外的事件、没有换过服务器
  /// 时刻、没有重读过本机状态——同步冲突 / 待裁决 / 迁移提醒的计数不可能变。
  String get contentFingerprint => '$_epoch:$_contentRevision';

  /// RWKV-Instant 分数表的全量刷新信号（只在内存）：牌组 / 配置类事件落库（预设归属、排队设置可能
  /// 变了）、应用一批对端事件（同步合并）、重读本机状态时 +1。复习日志、卡片自己的修改（暂停 /
  /// 埋 / 旗标 / 换牌组——换牌组由分数表项的版本覆盖）不推进它。见 `SrsRwkvService` 文件头。
  int _rwkvScoresRevision = 0;

  /// [_rwkvScoresRevision] 连同纪元：变了 = 分数表整表按此刻重查。
  String get rwkvScoresKey => '$_epoch:$_rwkvScoresRevision';

  /// 纪元：变了（覆盖恢复后本机状态重建）= 分数表清空、按历史重算。
  String get rwkvScoresClearKey => _epoch;

  /// 本机状态的随机纪元：本机状态被清空重建（覆盖恢复）后换一个，修订号从 0 重数也不会撞上旧指纹。
  String _epoch = '';
  bool _epochMissing = false;

  String get writerId => _sync.writerId;
  SrsTrustedClock get trustedClock => _trusted;
  bool get canSchedule => engine != null;

  // ------------------------------------------------------------------ 写锁

  /// 本机写入的独占区：「读现值 → 分配修改记录序号（dot）/ HLC → 落库 → 刷新缓存 → 存本机状态」
  /// 必须一气呵成，别的写入排在后面。
  ///
  /// 序号与 HLC 在内存里分配、立刻并进因果上下文（[SrsEditWriter.create]）；若分配与落库之间
  /// 插进别的写入，后分配的记录会先落库、先进发件箱（序号乱序），它的 ctx 还声称看见了尚未落库的
  /// 记录——同一字段上那条记录晚到时会被判为「被支配」而丢弃；中途崩溃时持久化的因果上下文里
  /// 还会留着永远不存在的 dot。以前逐条写的方法各自「await 读库 → 分配」，批量导入更是先攒一批
  /// 已分配序号的事件再落库，都有这个窗口（BUG-3545）。
  ///
  /// 可重入：独占区里再调别的写方法直接执行（按 Zone 认）。在外面先开了数据库事务、再在事务里调
  /// 写方法的调用方（按时间点恢复）必须先进独占区再开事务，否则与排队等锁的写入互相等待。
  Future<T> runExclusive<T>(Future<T> Function() body) async {
    final StateError? unusable = _unusable;
    if (unusable != null) throw unusable;
    if (identical(Zone.current[_writeZoneKey], this)) return body();
    final Future<void>? prev = _writeTail;
    final Completer<void> mine = Completer<void>();
    _writeTail = mine.future;
    try {
      if (prev != null) await prev;
      return await runZoned(
        body,
        zoneValues: <Object, Object>{_writeZoneKey: this},
      );
    } finally {
      mine.complete();
      if (identical(_writeTail, mine.future)) _writeTail = null;
    }
  }

  /// 大批量写入（Anki 迁移 / .apkg 导入）期间暂停这条连接的 WAL 自动 checkpoint，结束后
  /// 恢复原值并 checkpoint 一次。
  ///
  /// 自动 checkpoint 在 WAL 超过阈值（缺省 1000 页）后的每次提交时跑；导入的每个批次
  /// 事务都远超阈值，于是每次提交都把同一批热页（索引、缓存表）拷回主库一遍——实测迁移
  /// 1.5 万笔记时 COMMIT 合计 37 秒，暂停后 6 秒。WAL 在导入期间会长大，结束时一次并回；
  /// 中途崩溃也无妨：下次打开时 SQLite 照常回放 WAL。可嵌套；按数据库连接计数（几个
  /// profile 的副本共用一条连接），只有最外层恢复。
  Future<T> bulkWrites<T>(Future<T> Function() body) async {
    final _BulkWriteState state = _bulkWrites[db] ??= _BulkWriteState();
    if (state.depth++ == 0) {
      final List<QueryRow> rows = await db
          .customSelect('PRAGMA wal_autocheckpoint')
          .get();
      state.restore = rows.isEmpty
          ? 1000
          : (rows.first.data.values.first as int?) ?? 1000;
      await db.customStatement('PRAGMA wal_autocheckpoint = 0');
    }
    try {
      return await body();
    } finally {
      if (--state.depth == 0) {
        await db.customStatement(
          'PRAGMA wal_autocheckpoint = ${state.restore}',
        );
        await db.customSelect('PRAGMA wal_checkpoint(PASSIVE)').get();
      }
    }
  }

  static final Expando<_BulkWriteState> _bulkWrites =
      Expando<_BulkWriteState>();

  /// 排在最后的写入完成时完成（只会正常完成）。
  Future<void>? _writeTail;

  /// 每个副本一把锁（嵌套打开的另一个副本不会误认成持锁）。
  final Object _writeZoneKey = Object();

  // ------------------------------------------------------------------ 本机状态

  Future<bool> _hasAnyEvent() async =>
      await (db.select(db.srsEntities)
            ..where((t) => t.profileUid.equals(profileUid))
            ..limit(1))
          .getSingleOrNull() !=
      null;

  /// 读本机状态；返回之前是否存过。
  Future<bool> _loadLocal() async {
    _contentRevision++;
    _rwkvScoresRevision++;
    final SrsLocalStateRow? row = await (db.select(
      db.srsLocalState,
    )..where((t) => t.profileUid.equals(profileUid))).getSingleOrNull();
    final Map<String, Object?> j = row == null
        ? const <String, Object?>{}
        : (jsonDecode(row.json) as Map).cast<String, Object?>();
    _incarnation = (j['incarnation'] as int?) ?? 1;
    final String writer =
        (j['writerId'] as String?) ?? '$deviceId#$_incarnation';
    final Map<String, Object?> sync =
        (j['sync'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final Object? dirs = sync['dirs'];
    int next = (sync['next'] as int?) ?? 1;
    // 旧版本（不分目录记账）：冻结中、还没确认上传的批次那时存在本机状态里，且 next 还停在它的号上。
    // 搬进留存表（同号同字节，之后照常传到每个目录），next 越过它。
    _legacyFrozen = sync['frozen'] is String
        ? base64Decode(sync['frozen']! as String)
        : null;
    final SrsBatch? frozen = _legacyFrozen == null
        ? null
        : SrsBatch.decode(_legacyFrozen!);
    if (frozen != null && frozen.no >= next) next = frozen.no + 1;
    _sync = SrsSyncLocalState(
      writerId: writer,
      nextBatchNo: next,
      cursors: Map<String, int>.of(
        ((sync['cursors'] as Map?) ?? const <String, int>{})
            .cast<String, int>(),
      ),
      lastBatchServerTime: Map<String, int>.of(
        ((sync['lastS'] as Map?) ?? const <String, int>{}).cast<String, int>(),
      ),
      directories: <String, SrsDirectoryState>{
        if (dirs is Map)
          for (final MapEntry<String, Object?> e
              in dirs.cast<String, Object?>().entries)
            e.key: SrsDirectoryState.fromJson(
              (e.value! as Map).cast<String, Object?>(),
            ),
      },
      // 有过本机状态、却没有按目录的记账：来自旧版本（见 SrsSyncLocalState.legacyDirectories）。
      legacyDirectories:
          sync['legacyDirs'] == true || (row != null && dirs is! Map),
    );
    _writer = SrsEditWriter(
      writerId: writer,
      lastSeq: (j['lastSeq'] as int?) ?? 0,
      applied: SrsCausalContext.fromJson(j['applied']),
    );
    final Object? hlc = j['hlc'];
    _clock = HlcClock(
      writer,
      last: hlc is String ? _rehome(Hlc.decode(hlc), writer) : null,
    );
    _outboxSeq = (j['outboxSeq'] as int?) ?? 0;
    _styleCursor = (j['styleCursor'] as int?) ?? 0;
    _pendingMediaGc
      ..clear()
      ..addAll(<String>[
        for (final Object? n in (j['mediaGc'] as List?) ?? const <Object?>[])
          if (n is String) n,
      ]);
    // 没有本机状态（新设备 / 恢复备份后）：缓存要么还没有、要么随即整份重建，按当前规则算。
    _cacheRevision = row == null
        ? _kCacheRevision
        : (j['cacheRev'] as int?) ?? 0;
    _revision = (j['revision'] as int?) ?? 0;
    _epochMissing = j['epoch'] is! String;
    _epoch =
        (j['epoch'] as String?) ??
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
            '${Random.secure().nextInt(1 << 30).toRadixString(36)}';
    final Object? anchor = j['anchor'];
    if (anchor is Map) {
      _trusted.restoreAnchor(
        serverTimeMs: anchor['s']! as int,
        monotonicMs: anchor['m']! as int,
        bootId: anchor['b']! as String,
      );
    }
    return row != null;
  }

  Hlc _rehome(Hlc h, String writer) => Hlc(h.physical, h.counter, writer);

  /// 旧版本本机状态里的冻结批次（[_loadLocal] 读出，[_migrateLegacyFrozenBatch] 搬进留存表）。
  Uint8List? _legacyFrozen;

  Future<void> _migrateLegacyFrozenBatch() async {
    final Uint8List? bytes = _legacyFrozen;
    _legacyFrozen = null;
    if (bytes == null) return;
    final SrsBatch? b = SrsBatch.decode(bytes);
    await db.transaction(() async {
      if (b != null && b.writerId == _sync.writerId) {
        await db
            .into(db.srsSentBatches)
            .insertOnConflictUpdate(
              SrsSentBatchesCompanion.insert(
                profileUid: profileUid,
                writerId: b.writerId,
                batchNo: b.no,
                bytes: bytes,
              ),
            );
      }
      await _saveLocal();
    });
  }

  Future<void> _saveLocal() async {
    final Map<String, Object?> j = <String, Object?>{
      'incarnation': _incarnation,
      'writerId': _sync.writerId,
      'lastSeq': _writer.lastSeq,
      'applied': _writer.applied.toJson(),
      'hlc': _clock.last.encode(),
      'outboxSeq': _outboxSeq,
      'styleCursor': _styleCursor,
      if (_pendingMediaGc.isNotEmpty)
        'mediaGc': (_pendingMediaGc.toList()..sort()),
      'cacheRev': _cacheRevision,
      'revision': _revision,
      'epoch': _epoch,
      'sync': <String, Object?>{
        'next': _sync.nextBatchNo,
        'cursors': _sync.cursors,
        'lastS': _sync.lastBatchServerTime,
        'dirs': <String, Object?>{
          for (final MapEntry<String, SrsDirectoryState> e
              in _sync.directories.entries)
            e.key: e.value.toJson(),
        },
        if (_sync.legacyDirectories) 'legacyDirs': true,
      },
    };
    await db
        .into(db.srsLocalState)
        .insertOnConflictUpdate(
          SrsLocalStateCompanion.insert(
            profileUid: profileUid,
            json: jsonEncode(j),
          ),
        );
  }

  /// 是否发布过批次（第六轮审查第 15 条：发布过就不能再改 profile uid）。
  bool get everPublished => _sync.everPublished;

  (int, SrsTimeSource) now() => _trusted.now();

  /// 「今天」的口径：profile 设置里的翻日时刻 / UTC 偏移（同步值），没有则用本机统计页的日界与本机偏移。
  /// [deckTree] 与 profile 修改记录的缓存（作答一次以前要物化牌组树 / 日界 8–10 次）。键是
  /// [_structureKey]：内容修订号覆盖了除复习日志与界面状态外的一切落库、服务器时刻变化、重读
  /// 本机状态与清除；界面状态（牌组收起 / 展开）另由 [_viewRevision] 计。
  ({String key, SrsDeckTree tree})? _deckTreeCache;
  ({String key, SrsEntityEdits edits})? _profileEditsCache;
  int _viewRevision = 0;
  String get _structureKey => '$_epoch:$_contentRevision:$_viewRevision';

  Future<SrsDayContext> dayContext() async {
    final String key = _structureKey;
    final ({String key, SrsEntityEdits edits})? cached = _profileEditsCache;
    final SrsEntityEdits p;
    if (cached != null && cached.key == key) {
      p = cached.edits;
    } else {
      p = await _entityEdits(SrsEntityKind.profile, profileUid);
      if (_structureKey == key) _profileEditsCache = (key: key, edits: p);
    }
    final int rollover =
        (p.value(SrsFieldKeys.dayRolloverHour) as int?) ?? _fallbackRollover();
    final int offset =
        (p.value(SrsFieldKeys.utcOffsetMin) as int?) ??
        SrsDayContext.localOffsetMin();
    return SrsDayContext(
      utcOffsetMin: offset,
      rolloverHour: rollover.clamp(0, 23),
    );
  }

  // ------------------------------------------------------------------ 事件落库

  Future<Map<String, int>> _serverTimesFor(Iterable<String> ids) async {
    final _RefreshPrefetch? pre = _RefreshPrefetch.current;
    final List<String> list = ids.toList();
    if (pre != null && list.every(pre.serverTimesKnown.contains)) {
      return <String, int>{
        for (final String id in list)
          if (pre.serverTimes[id] != null) id: pre.serverTimes[id]!,
      };
    }
    if (list.isEmpty) return const <String, int>{};
    final Map<String, int> out = <String, int>{};
    for (int i = 0; i < list.length; i += 500) {
      final List<SrsEventLocalRow> rows =
          await (db.select(db.srsEventLocal)..where(
                (t) =>
                    t.eventId.isIn(list.sublist(i, min(i + 500, list.length))),
              ))
              .get();
      for (final SrsEventLocalRow r in rows) {
        if (r.serverTime != null) out[r.eventId] = r.serverTime!;
      }
    }
    return out;
  }

  /// 一个实体的全部修改记录（只读；导入按记录时刻判断本机改动是否比来源新）。
  Future<SrsEntityEdits> entityEdits(SrsEntityKind kind, String id) =>
      _entityEdits(kind, id);

  /// 一组实体各自的全部修改记录（[entityEdits] 的成批版本：按 ID 分块预读，每块两三次往返）。
  Future<Map<String, SrsEntityEdits>> entityEditsMany(
    SrsEntityKind kind,
    Iterable<String> ids,
  ) => _entityEditsMany(kind, ids);

  Future<SrsEntityEdits> _entityEdits(SrsEntityKind kind, String id) async {
    final List<SrsFieldEditRow> rows =
        _RefreshPrefetch.current?.edits['${kind.wire}/$id'] ??
        await (db.select(db.srsFieldEdits)..where(
              (t) => t.entityKind.equals(kind.wire) & t.entityId.equals(id),
            ))
            .get();
    final List<SrsFieldEdit> edits = <SrsFieldEdit>[
      for (final SrsFieldEditRow r in rows)
        SrsFieldEdit.fromJson(
          (jsonDecode(r.json) as Map).cast<String, Object?>(),
        ),
    ];
    final Map<String, int> s = await _serverTimesFor(edits.map((e) => e.id));
    return SrsEntityEdits.build(edits, serverTimeOf: (String id) => s[id]);
  }

  /// 影响面：哪些笔记 / 卡片 / 笔记类型的缓存要刷新。
  final Set<String> _dirtyNotes = <String>{};
  final Set<String> _dirtyCards = <String>{};
  final Set<String> _dirtyNoteTypes = <String>{};

  /// 一组事件的「服务器时刻 / 发件箱序号」本机元信息（srs_event_local）成批写：每项
  /// `(eventId, serverTime, outboxSeq)`，与按序逐条 upsert 同结果——服务器时刻取已知值与新值里
  /// 较早的（[srsMergeServerTime]），给了 outboxSeq 就覆盖（重新入队）。旧行按 ID 分块一次预读，
  /// 写入合成一个 Drift batch（以前每条事件「先查再写」两次往返，应用一批对端事件 / 恢复后重新入队
  /// 全部事件都是几万次往返，BUG-3543）。
  ///
  /// 返回本机**原先已有**这条事件的发布元信息、且服务器时刻因此变小（含从未知变已知）的事件 ID：
  /// 多目录转发据此把更小的 S 带给只看得到转发的设备（见 [applyRemote] / [observeServerTimes]）。
  Future<Set<String>> _upsertEventLocal(
    List<(String, int?, int?)> items,
  ) async {
    if (items.isEmpty) return <String>{};
    // 服务器时刻参与寄存器裁决（谁胜出）：同步冲突的计数可能随之变。
    _contentRevision++;
    final Map<String, SrsEventLocalRow> old = <String, SrsEventLocalRow>{};
    for (final List<String> chunk in _chunks(<String>{
      for (final (String id, int? _, int? _) in items) id,
    })) {
      for (final SrsEventLocalRow r in await (db.select(
        db.srsEventLocal,
      )..where((t) => t.eventId.isIn(chunk))).get()) {
        old[r.eventId] = r;
      }
    }
    // 按序在内存里推进：同一 ID 出现多次时与逐条落库同结果。
    final Map<String, (int?, int?)> inserts = <String, (int?, int?)>{};
    final Map<String, (int?, Value<int?>)> updates =
        <String, (int?, Value<int?>)>{};
    for (final (String id, int? s, int? outboxSeq) in items) {
      final (int?, int?)? fresh = inserts[id];
      if (fresh != null) {
        inserts[id] = (srsMergeServerTime(fresh.$1, s), outboxSeq ?? fresh.$2);
        continue;
      }
      final SrsEventLocalRow? row = old[id];
      if (row == null) {
        inserts[id] = (s, outboxSeq);
        continue;
      }
      final (int?, Value<int?>)? pending = updates[id];
      final int? before = pending == null ? row.serverTime : pending.$1;
      final int? merged = srsMergeServerTime(before, s);
      if (merged != before || outboxSeq != null) {
        updates[id] = (
          merged,
          outboxSeq != null
              ? Value<int?>(outboxSeq)
              : (pending?.$2 ?? const Value<int?>.absent()),
        );
      }
    }
    final Set<String> lowered = <String>{
      for (final MapEntry<String, (int?, Value<int?>)> e in updates.entries)
        if (e.value.$1 case final int after
            when old[e.key]!.serverTime == null ||
                after < old[e.key]!.serverTime!)
          e.key,
    };
    if (inserts.isEmpty && updates.isEmpty) return lowered;
    final int receivedAt = DateTime.now().millisecondsSinceEpoch;
    await db.batch((Batch b) {
      if (inserts.isNotEmpty) {
        b.insertAll(db.srsEventLocal, <SrsEventLocalCompanion>[
          for (final MapEntry<String, (int?, int?)> e in inserts.entries)
            SrsEventLocalCompanion.insert(
              eventId: e.key,
              profileUid: profileUid,
              outboxSeq: Value<int?>(e.value.$2),
              serverTime: Value<int?>(e.value.$1),
              receivedAt: Value<int>(receivedAt),
            ),
        ]);
      }
      for (final MapEntry<String, (int?, Value<int?>)> e in updates.entries) {
        b.update(
          db.srsEventLocal,
          SrsEventLocalCompanion(
            serverTime: Value<int?>(e.value.$1),
            outboxSeq: e.value.$2,
          ),
          where: ($SrsEventLocalTable t) => t.eventId.equals(e.key),
        );
      }
    });
    return lowered;
  }

  /// 笔记字段值里的内联样式换成共享样式引用（表示层，见库注释）。只动 `f/<fieldId>` 的字符串值；
  /// 其余字段键、没有可换的块、没装样式库时原样返回。本机写、导入、对端事件都经这里落库。
  ///
  /// 没有 `<style>` 块（绝大多数记录）时同步返回，不进异步流程：批量落库时逐条 await 本身
  /// 就是秒级开销（迁移 1.5 万笔记约 28 万条修改记录）。判据与 [srsDedupStyles] 的快速
  /// 判断相同，结果不变。
  FutureOr<SrsFieldEdit> _compactEdit(SrsFieldEdit e) {
    final SrsStyleStore? st = styles;
    final Object? v = e.value;
    if (st == null ||
        e.entityKind != SrsEntityKind.note ||
        v is! String ||
        !e.fieldKey.startsWith(_noteFieldPrefix) ||
        !v.contains('<style>')) {
      return e;
    }
    return _compactWith(st, e, v);
  }

  Future<SrsFieldEdit> _compactWith(
    SrsStyleStore st,
    SrsFieldEdit e,
    String v,
  ) async {
    final String compacted = await st.compact(v);
    if (identical(compacted, v)) return e;
    return _withValue(e, compacted);
  }

  static final String _noteFieldPrefix = SrsFieldKeys.noteField('');

  static SrsFieldEdit _withValue(SrsFieldEdit e, Object? value) => SrsFieldEdit(
    profileUid: e.profileUid,
    entityKind: e.entityKind,
    entityId: e.entityId,
    fieldKey: e.fieldKey,
    dot: e.dot,
    ctx: e.ctx,
    value: value,
    hlc: e.hlc,
    timeSource: e.timeSource,
    machine: e.machine,
  );

  /// 展开共享样式引用（对外的读：导出、AnkiConnect、制卡回读、卡面渲染）。没装样式库时原样返回。
  /// [dropMissing] 见 [srsExpandStyles]。
  Future<String> expandStyles(String html, {bool dropMissing = false}) async {
    final SrsStyleStore? st = styles;
    if (st == null) return html;
    return st.expand(html, dropMissing: dropMissing);
  }

  /// [expandStyles] 逐值作用于一组字段（键不变）。
  Future<Map<String, String>> expandFields(
    Map<String, String> fields, {
    bool dropMissing = false,
  }) async => <String, String>{
    for (final MapEntry<String, String> f in fields.entries)
      f.key: await expandStyles(f.value, dropMissing: dropMissing),
  };

  /// 存量去重：把本 profile 已落库、还带内联样式的笔记字段修改记录就地换成引用表示。
  ///
  /// - 不产生任何新事件、不进发件箱：改的只是本机行的表示，记录的 id / dot / ctx / hlc 不动，
  ///   合并时与对端手里的原表示视为同值（见库注释）。所以存量迁移零同步流量，对端各自迁移各自的。
  /// - 分批（每批一个事务），按 rowid 游标推进并记进本机状态：随时中断（[shouldStop] 返回 true、
  ///   进程被杀）下次从断点续；重复跑幂等（已换过的行不再含可换的块）。
  /// - 恢复备份后本机状态清空、游标归零，恢复进来的行会被重新检查。
  ///
  /// 返回本次改写的行数。没装样式库时什么也不做。
  Future<int> compactStoredStyles({
    int batchSize = 32,
    bool Function()? shouldStop,
  }) async {
    final SrsStyleStore? st = styles;
    if (st == null) return 0;
    int rewritten = 0;
    while (shouldStop?.call() != true) {
      // 每批一个独占区：批末存本机状态（含写入者的序号 / 因果上下文），不能夹在别的写入的分配与落库之间。
      final int done = await runExclusive(
        () => db.transaction(() async {
          final List<QueryRow> rows = await db
              .customSelect(
                'SELECT rowid AS rid, id, json FROM srs_field_edits '
                'WHERE profile_uid = ? AND entity_kind = ? AND rowid > ? '
                "AND field_key LIKE 'f/%' AND instr(json, '<style>') > 0 "
                'ORDER BY rowid LIMIT ?',
                variables: <Variable<Object>>[
                  Variable<String>(profileUid),
                  Variable<String>(SrsEntityKind.note.wire),
                  Variable<int>(_styleCursor),
                  Variable<int>(batchSize),
                ],
              )
              .get();
          if (rows.isEmpty) return -1;
          int n = 0;
          for (final QueryRow r in rows) {
            final SrsFieldEdit e = SrsFieldEdit.fromJson(
              (jsonDecode(r.read<String>('json')) as Map)
                  .cast<String, Object?>(),
            );
            final FutureOr<SrsFieldEdit> pending = _compactEdit(e);
            final SrsFieldEdit c = pending is SrsFieldEdit
                ? pending
                : await pending;
            if (!identical(c, e)) {
              await (db.update(
                db.srsFieldEdits,
              )..where((t) => t.id.equals(r.read<String>('id')))).write(
                SrsFieldEditsCompanion(json: Value<String>(c.canonical())),
              );
              _markEntity(e.entityKind, e.entityId);
              n++;
            }
            _styleCursor = r.read<int>('rid');
          }
          await _flushCaches();
          await _saveLocal();
          return n;
        }),
      );
      if (done < 0) break;
      rewritten += done;
      // 让出事件循环：迁移在后台跑，不长时间占住数据库连接。
      await Future<void>.delayed(Duration.zero);
    }
    return rewritten;
  }

  /// [fieldKey]：修改记录的字段键（身份记录为 null）。笔记类型只有影响缓存行的键才让它的全部笔记
  /// 重算（见 [_noteTypeKeyAffectsCaches]）。
  void _markEntity(SrsEntityKind kind, String id, {String? fieldKey}) {
    switch (kind) {
      case SrsEntityKind.note:
        _dirtyNotes.add(id);
      case SrsEntityKind.card:
        _dirtyCards.add(id);
      case SrsEntityKind.noteType:
        if (fieldKey == null || _noteTypeKeyAffectsCaches(fieldKey)) {
          _dirtyNoteTypes.add(id);
        }
      case SrsEntityKind.deck:
      case SrsEntityKind.profile:
        break;
    }
  }

  /// 笔记类型的这个字段键是否影响笔记 / 卡片缓存行。缓存行只由类型的字段定义（排序字段、卡片生成的
  /// 空卡判断）、模板定义（生成哪些卡）、词条字段（termKey）与删除标记（笔记是否还在）派生（见
  /// [_planNote]）；名字、CSS、字段说明只在渲染 / 编辑时读，改它们不必把整个类型的笔记重算一遍
  /// （以前改一行 CSS 也要物化该类型全部笔记与卡片）。按排除法列：不认识的键一律当作影响，宁可多算。
  static bool _noteTypeKeyAffectsCaches(String fieldKey) =>
      fieldKey != SrsFieldKeys.name &&
      fieldKey != SrsFieldKeys.css &&
      !fieldKey.startsWith(SrsFieldKeys.fieldDescriptionPrefix);

  /// 本机产生事件：落库、进发件箱、刷新缓存。调用方在独占区（[runExclusive]）里、紧接着分配
  /// 序号之后调它：分配与落库之间不插进别的写入。
  Future<void> _emit(List<SrsEvent> events) async {
    assert(
      identical(Zone.current[_writeZoneKey], this),
      '_emit outside runExclusive',
    );
    await _transactionOrReload(() async {
      final List<String> landed = await _storeLocalBatch(events);
      if (landed.isNotEmpty) {
        // 进发件箱：等价于逐条 upsert `(id, null, outboxSeq)`（[_upsertEventLocal]）——本机事件
        // 没有服务器时刻，合并后的 serverTime 恒为旧值，只需写 outboxSeq。
        final int receivedAt = DateTime.now().millisecondsSinceEpoch;
        await db.batch((Batch b) {
          for (final String id in landed) {
            _outboxSeq += 1;
            final int seq = _outboxSeq;
            b.insert(
              db.srsEventLocal,
              SrsEventLocalCompanion.insert(
                eventId: id,
                profileUid: profileUid,
                outboxSeq: Value<int?>(seq),
                receivedAt: Value<int>(receivedAt),
              ),
              onConflict: DoUpdate(
                (_) => SrsEventLocalCompanion(outboxSeq: Value<int?>(seq)),
              ),
            );
          }
        });
      }
      await _flushCaches();
      await _saveLocal();
    });
  }

  /// 落一批事件（幂等；本机产生、导入、对端来的都走这里）：已有的身份记录、日志、相关实体的
  /// 修改记录各按 ID 分块一次预读，写入合成一个 Drift batch。按事件顺序在内存视图上推进，
  /// 与逐条「先查再写」同结果（批内重复、批内互相支配都一样）：
  /// - 身份记录：同 ID 同内容不落；同 ID 异内容取规范编码较小的一份（确定性兜底，只可能是 bug 或损坏）；
  /// - 修改记录：同 ID 已在不落；被同一字段键上已有记录支配的丢掉，支配别人的把对方删掉；
  /// - 日志：同 ID 取规范编码较小的一份；不认识的事件原样保留。
  /// 每条真落库的事件修订号 +1（[changeFingerprint]）。返回真正新落的事件 ID（按序）。
  ///
  /// 以前每条事件「先查再写」各两三次往返（库在后台 isolate，每次往返都是一次跨 isolate 消息），
  /// 导入一个几千条笔记的包、应用一批对端事件都要几万次往返（BUG-3549 / BUG-3543）。
  /// 这条事件是否推进 [_contentRevision]：复习日志与界面状态类修改记录不推进。
  static bool _touchesRwkvScores(SrsEvent e) => switch (e) {
    SrsEntityEvent(:final SrsEntityRecord record) =>
      record.kind == SrsEntityKind.deck || record.kind == SrsEntityKind.profile,
    SrsEditEvent(:final SrsFieldEdit edit) =>
      (edit.entityKind == SrsEntityKind.deck ||
              edit.entityKind == SrsEntityKind.profile) &&
          srsFieldClassOf(edit.entityKind, edit.fieldKey) !=
              SrsFieldClass.viewState,
    _ => false,
  };

  static bool _touchesContent(SrsEvent e) => switch (e) {
    SrsLogEvent() => false,
    SrsEditEvent(:final SrsFieldEdit edit) =>
      srsFieldClassOf(edit.entityKind, edit.fieldKey) !=
          SrsFieldClass.viewState,
    _ => true,
  };

  Future<List<String>> _storeLocalBatch(List<SrsEvent> events) async {
    final Set<String> entityIds = <String>{};
    final Set<String> logIds = <String>{};
    final Map<SrsEntityKind, Set<String>> editEntities =
        <SrsEntityKind, Set<String>>{};
    for (final SrsEvent e in events) {
      switch (e) {
        case SrsEntityEvent(:final SrsEntityRecord record):
          entityIds.add(record.id);
        case SrsEditEvent(:final SrsFieldEdit edit):
          (editEntities[edit.entityKind] ??= <String>{}).add(edit.entityId);
        case SrsLogEvent(:final SrsReviewLog log):
          logIds.add(log.id);
        case SrsUnknownEvent():
          break;
      }
    }
    final Map<String, SrsEntityRecord> entities = <String, SrsEntityRecord>{};
    for (final List<String> chunk in _chunks(entityIds)) {
      for (final SrsEntityRow r in await (db.select(
        db.srsEntities,
      )..where((t) => t.id.isIn(chunk))).get()) {
        entities[r.id] = _entityFromRow(r);
      }
    }
    final Map<String, String> logs = <String, String>{};
    for (final List<String> chunk in _chunks(logIds)) {
      for (final SrsReviewLogRow r in await (db.select(
        db.srsReviewLogs,
      )..where((t) => t.id.isIn(chunk))).get()) {
        logs[r.id] = r.json;
      }
    }
    // 同一字段键（registerKey）上现存的、没被支配的修改记录。
    final Map<String, List<SrsFieldEdit>> registers =
        <String, List<SrsFieldEdit>>{};
    final Set<String> editIds = <String>{};
    for (final MapEntry<SrsEntityKind, Set<String>> k in editEntities.entries) {
      for (final List<String> chunk in _chunks(k.value)) {
        for (final SrsFieldEditRow r
            in await (db.select(db.srsFieldEdits)..where(
                  (t) =>
                      t.entityKind.equals(k.key.wire) & t.entityId.isIn(chunk),
                ))
                .get()) {
          final SrsFieldEdit e = SrsFieldEdit.fromJson(
            (jsonDecode(r.json) as Map).cast<String, Object?>(),
          );
          (registers[e.registerKey] ??= <SrsFieldEdit>[]).add(e);
          editIds.add(r.id);
        }
      }
    }

    final List<void Function(Batch b)> writes = <void Function(Batch b)>[];
    final List<String> landed = <String>[];
    for (final SrsEvent e in events) {
      bool ok;
      switch (e) {
        case SrsEntityEvent(:final SrsEntityRecord record):
          final SrsEntityRecord? old = entities[record.id];
          ok =
              old == null ||
              (old.canonical() != record.canonical() &&
                  SrsEntityRecord.pick(old, record) != old);
          if (ok) {
            entities[record.id] = record;
            final SrsEntitiesCompanion row = SrsEntitiesCompanion.insert(
              id: record.id,
              profileUid: record.profileUid,
              kind: record.kind.wire,
              payloadJson: srsCanonicalJson(record.payload),
              createdAt: Value<int>(record.createdAt),
            );
            writes.add(
              (Batch b) => b.insertAllOnConflictUpdate(
                db.srsEntities,
                <SrsEntitiesCompanion>[row],
              ),
            );
            _markEntity(record.kind, record.id);
          }
        case SrsEditEvent(:final SrsFieldEdit edit):
          _writer.apply(edit);
          final List<SrsFieldEdit> reg = registers[edit.registerKey] ??=
              <SrsFieldEdit>[];
          ok =
              !editIds.contains(edit.id) &&
              !reg.any((SrsFieldEdit b) => b.dominates(edit));
          if (ok) {
            final List<String> dominated = <String>[
              for (final SrsFieldEdit a in reg)
                if (edit.dominates(a)) a.id,
            ];
            if (dominated.isNotEmpty) {
              reg.removeWhere((SrsFieldEdit a) => dominated.contains(a.id));
              editIds.removeAll(dominated);
              writes.add(
                (Batch b) => b.deleteWhere(
                  db.srsFieldEdits,
                  ($SrsFieldEditsTable t) => t.id.isIn(dominated),
                ),
              );
            }
            reg.add(edit);
            editIds.add(edit.id);
            final SrsFieldEditsCompanion row = SrsFieldEditsCompanion.insert(
              id: edit.id,
              profileUid: edit.profileUid,
              entityKind: edit.entityKind.wire,
              entityId: edit.entityId,
              fieldKey: edit.fieldKey,
              writerId: edit.dot.writerId,
              seq: edit.dot.seq,
              // 表示层：内联样式换成共享样式引用（见 [_compactEdit]）。
              json: switch (_compactEdit(edit)) {
                final SrsFieldEdit c => c,
                final Future<SrsFieldEdit> f => await f,
              }.canonical(),
            );
            writes.add((Batch b) => b.insert(db.srsFieldEdits, row));
            _markEntity(
              edit.entityKind,
              edit.entityId,
              fieldKey: edit.fieldKey,
            );
          }
        case SrsLogEvent(:final SrsReviewLog log):
          final String canon = log.canonical();
          final String? old = logs[log.id];
          ok = old == null || canon.compareTo(old) < 0;
          if (ok) {
            logs[log.id] = canon;
            final SrsReviewLogsCompanion row = SrsReviewLogsCompanion.insert(
              id: log.id,
              profileUid: log.profileUid,
              cardId: log.cardId,
              kind: log.kind,
              rating: Value<int?>(log.rating),
              occurredAt: log.occurredAt,
              reviewType: log.reviewType,
              origin: log.origin,
              durationMs: Value<int>(log.durationMs),
              json: canon,
            );
            writes.add(
              (Batch b) => b.insertAllOnConflictUpdate(
                db.srsReviewLogs,
                <SrsReviewLogsCompanion>[row],
              ),
            );
            _dirtyCards.add(log.cardId);
          }
        case SrsUnknownEvent():
          final SrsUnknownEventsCompanion row =
              SrsUnknownEventsCompanion.insert(
                id: e.id,
                profileUid: profileUid,
                json: e.canonical(),
              );
          writes.add(
            (Batch b) => b.insert(
              db.srsUnknownEvents,
              row,
              mode: InsertMode.insertOrIgnore,
            ),
          );
          ok = true;
      }
      if (ok) {
        _revision++;
        if (_touchesContent(e)) {
          _contentRevision++;
        } else if (e is SrsEditEvent) {
          _viewRevision++;
        }
        if (_touchesRwkvScores(e)) _rwkvScoresRevision++;
        landed.add(e.id);
      }
    }
    if (writes.isNotEmpty) {
      await db.batch((Batch b) {
        for (final void Function(Batch b) w in writes) {
          w(b);
        }
      });
    }
    return landed;
  }

  /// 按 SQLite 变量上限分块（IN 列表）。
  static Iterable<List<String>> _chunks(Iterable<String> ids) sync* {
    final List<String> all = ids.toList();
    for (int i = 0; i < all.length; i += 500) {
      yield all.sublist(i, min(i + 500, all.length));
    }
  }

  /// 导入（Anki 包 / fushi-ext）批量落一组事件：视同本机产生（进发件箱）、刷新缓存。幂等。
  ///
  /// 事件内容由调用方按铁律 C 只从来源算出（身份记录 / 复习日志）；本机 HLC 按收到对端事件的规则推进（先钳位）。
  Future<void> importEvents(List<SrsEvent> events) async {
    if (events.isEmpty) return;
    await runExclusive(() async {
      _receiveAll(events);
      await _emit(events);
    });
  }

  /// 来源给定的 HLC（导入的日志 / 记录）按收到对端事件的规则推进本机时钟（先钳位）。
  void _receiveAll(List<SrsEvent> events) {
    final (int nowMs, _) = now();
    for (final SrsEvent e in events) {
      final Hlc? h = switch (e) {
        SrsEditEvent(:final SrsFieldEdit edit) => edit.hlc,
        SrsLogEvent(:final SrsReviewLog log) => log.hlc,
        _ => null,
      };
      if (h != null) _clock.receive(h, trustedNowMs: nowMs);
    }
  }

  /// 导入攒的一批草稿（[newNoteDrafts] / [newEditDrafts] + 已定稿的日志等）落库：同 [importEvents]，
  /// 但修改记录的序号 / HLC 在这里、落库的同一个独占区里才分配——攒批期间（读包、解析、别的写入）
  /// 不占序号，落库顺序 = 序号顺序（BUG-3545，以前攒批时就分配，期间插进来的本机写入先落库）。
  ///
  /// 返回这批身份记录里**落库前就已存在**的实体 ID（导入据此按实际新建数计数：攒批时以为是新
  /// 笔记、落库时已被同步 / 别处建好的，不算「新增」）。
  Future<Set<String>> importDrafts(List<SrsEventDraft> drafts) async {
    if (drafts.isEmpty) return const <String>{};
    return runExclusive(() async {
      final Set<String> existed = await _existingEntityIds(<String>[
        for (final SrsEventDraft d in drafts)
          if (d case SrsReadyDraft(
            event: SrsEntityEvent(:final SrsEntityRecord record),
          ))
            record.id,
      ]);
      final List<SrsEventDraft> live = await _dropAuthoredInitials(drafts);
      _receiveAll(<SrsEvent>[
        for (final SrsEventDraft d in live)
          if (d case SrsReadyDraft(:final SrsEvent event)) event,
      ]);
      await _emit(_finalize(live));
      return existed;
    });
  }

  /// [ids] 里已有身份记录的（按 ID 分块查）。
  Future<Set<String>> _existingEntityIds(List<String> ids) async {
    final Set<String> out = <String>{};
    final $SrsEntitiesTable t = db.srsEntities;
    for (final List<String> chunk in _chunks(ids)) {
      final List<TypedResult> rows =
          await (db.selectOnly(t)
                ..addColumns(<Expression<Object>>[t.id])
                ..where(t.id.isIn(chunk)))
              .get();
      for (final TypedResult r in rows) {
        out.add(r.read(t.id)!);
      }
    }
    return out;
  }

  /// 去掉「初值」草稿（[SrsEditDraft.initial]）里键已有修改记录的：一次按实体分块查出现有的
  /// (实体, 字段键)。只在独占区里、紧接着 [_finalize] 调用，查到的就是落库那一刻的真值。
  Future<List<SrsEventDraft>> _dropAuthoredInitials(
    List<SrsEventDraft> drafts,
  ) async {
    final Map<SrsEntityKind, Set<String>> byKind =
        <SrsEntityKind, Set<String>>{};
    for (final SrsEventDraft d in drafts) {
      if (d is SrsEditDraft && d.initial) {
        (byKind[d.kind] ??= <String>{}).add(d.entityId);
      }
    }
    if (byKind.isEmpty) return drafts;
    final $SrsFieldEditsTable t = db.srsFieldEdits;
    final Set<String> authored = <String>{};
    for (final MapEntry<SrsEntityKind, Set<String>> k in byKind.entries) {
      for (final List<String> chunk in _chunks(k.value)) {
        final List<TypedResult> rows =
            await (db.selectOnly(t, distinct: true)
                  ..addColumns(<Expression<Object>>[t.entityId, t.fieldKey])
                  ..where(
                    t.profileUid.equals(profileUid) &
                        t.entityKind.equals(k.key.wire) &
                        t.entityId.isIn(chunk),
                  ))
                .get();
        for (final TypedResult r in rows) {
          authored.add(
            '${k.key.wire}/${r.read(t.entityId)!}/${r.read(t.fieldKey)!}',
          );
        }
      }
    }
    if (authored.isEmpty) return drafts;
    return <SrsEventDraft>[
      for (final SrsEventDraft d in drafts)
        if (d is! SrsEditDraft ||
            !d.initial ||
            !authored.contains('${d.kind.wire}/${d.entityId}/${d.key}'))
          d,
    ];
  }

  /// 草稿定稿：修改记录按序分配序号与 HLC（同一时刻、逐条 tick），其余原样。只在独占区里、
  /// 紧接着 [_emit] 调用。
  List<SrsEvent> _finalize(List<SrsEventDraft> drafts) {
    final (int nowMs, SrsTimeSource src) = now();
    return <SrsEvent>[
      for (final SrsEventDraft d in drafts)
        switch (d) {
          SrsReadyDraft(:final SrsEvent event) => event,
          SrsEditDraft() => SrsEditEvent(
            _writer.create(
              profileUid: profileUid,
              entityKind: d.kind,
              entityId: d.entityId,
              fieldKey: d.key,
              value: d.value,
              hlc: _clock.tick(nowMs),
              timeSource: src,
              machine: d.machine,
            ),
          ),
        },
    ];
  }

  SrsEntityRecord _entityFromRow(SrsEntityRow r) => SrsEntityRecord(
    id: r.id,
    profileUid: r.profileUid,
    kind: SrsEntityKind.tryParse(r.kind) ?? SrsEntityKind.note,
    payload: (jsonDecode(r.payloadJson) as Map).cast<String, Object?>(),
  );

  // ------------------------------------------------------------------ 内置

  /// 内置默认牌组与内置笔记类型（Lapis、Fushi 卡片；确定性 ID，每台设备都生成同一份；没改过的内置定义不写修改记录）。
  Future<void> ensureBuiltins() => runExclusive(() async {
    final List<SrsEvent> missing = <SrsEvent>[];
    for (final SrsEntityRecord r in srsBuiltinEntities(profileUid)) {
      final SrsEntityRow? row = await (db.select(
        db.srsEntities,
      )..where((t) => t.id.equals(r.id))).getSingleOrNull();
      if (row == null) missing.add(SrsEntityEvent(r));
    }
    if (missing.isNotEmpty) await _emit(missing);
  });

  String get defaultDeckId => SrsIds.builtinDefaultDeck(profileUid);
  String get lapisNoteTypeId => srsLapisNoteTypeId(profileUid);
  String get fushiCardNoteTypeId => srsFushiCardNoteTypeId(profileUid);

  // ------------------------------------------------------------------ 物化

  Future<SrsNoteTypeView?> noteType(String id) async {
    final SrsEntityRow? row = await _entityRow(id);
    if (row == null) return null;
    final SrsEntityRecord rec = _entityFromRow(row);
    return SrsNoteTypeView.materialize(
      rec,
      await _entityEdits(SrsEntityKind.noteType, id),
      builtin: srsBuiltinNoteTypeForKey(
        profileUid,
        rec.payload['builtin'] as String?,
      ),
    );
  }

  Future<List<SrsNoteTypeView>> noteTypes() async {
    final List<SrsEntityRow> rows =
        await (db.select(db.srsEntities)..where(
              (t) =>
                  t.profileUid.equals(profileUid) &
                  t.kind.equals(SrsEntityKind.noteType.wire),
            ))
            .get();
    final List<SrsNoteTypeView> out = <SrsNoteTypeView>[
      for (final SrsNoteTypeView? v in (await noteTypesById(
        rows.map((SrsEntityRow r) => r.id),
      )).values)
        if (v != null && v.deletedAt == null) v,
    ];
    out.sort(
      (SrsNoteTypeView a, SrsNoteTypeView b) => a.name.compareTo(b.name),
    );
    return out;
  }

  /// 一组笔记类型（含已删除的；不存在的 ID 映射到 null），按 ID 分块预读（每块几次往返）。
  Future<Map<String, SrsNoteTypeView?>> noteTypesById(
    Iterable<String> ids,
  ) async {
    final Map<String, SrsNoteTypeView?> out = <String, SrsNoteTypeView?>{};
    for (final List<String> chunk in _chunks(ids.toSet())) {
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchEntities(pre, chunk);
      await _prefetchEdits(pre, SrsEntityKind.noteType, chunk);
      await _readWith(pre, () async {
        for (final String id in chunk) {
          out[id] = await noteType(id);
        }
      });
    }
    return out;
  }

  Future<SrsNoteView?> note(String id) async {
    final SrsEntityRow? row = await _entityRow(id);
    if (row == null) return null;
    return SrsNoteView.materialize(
      _entityFromRow(row),
      await _entityEdits(SrsEntityKind.note, id),
    );
  }

  /// 一组笔记的物化视图（含已删除的；不存在的 ID 映射到 null；按输入顺序去重）。按 ID 分块
  /// 预读身份记录 / 修改记录 / 服务器时刻，每块几次往返——批量读笔记的地方（导出、改标签、
  /// 更改笔记类型、旧 Lapis 迁移）不再每条笔记各查三次（BUG-3543）。
  Future<Map<String, SrsNoteView?>> notes(Iterable<String> ids) async {
    final Map<String, SrsNoteView?> out = <String, SrsNoteView?>{};
    for (final List<String> chunk in _chunks(ids.toSet())) {
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchEntities(pre, chunk);
      await _prefetchEdits(pre, SrsEntityKind.note, chunk);
      await _readWith(pre, () async {
        for (final String id in chunk) {
          out[id] = await note(id);
        }
      });
    }
    return out;
  }

  /// 牌组树：身份记录一次读、全部牌组的修改记录分块一次预读（以前每个牌组各查两次，
  /// 导入几百个牌组的包时每建一个牌组都重读一遍整棵树，BUG-3543）。
  Future<SrsDeckTree> deckTree() async {
    final String key = _structureKey;
    final ({String key, SrsDeckTree tree})? cached = _deckTreeCache;
    if (cached != null && cached.key == key) return cached.tree;
    final SrsDeckTree tree = await _loadDeckTree();
    // 读的途中又落了事件：这份可能是旧的，不缓存（落库在事务里，修订号在事务内推进，之后发出的
    // 读要等事务提交，所以「键没变」= 读到的就是这个键对应的数据）。
    if (_structureKey == key) _deckTreeCache = (key: key, tree: tree);
    return tree;
  }

  Future<SrsDeckTree> _loadDeckTree() async {
    final List<SrsEntityRow> rows =
        await (db.select(db.srsEntities)..where(
              (t) =>
                  t.profileUid.equals(profileUid) &
                  t.kind.equals(SrsEntityKind.deck.wire),
            ))
            .get();
    final Map<String, SrsEntityEdits> edits = await _entityEditsMany(
      SrsEntityKind.deck,
      rows.map((SrsEntityRow r) => r.id),
    );
    return SrsDeckTree(<SrsDeckView>[
      for (final SrsEntityRow r in rows)
        SrsDeckView.materialize(_entityFromRow(r), edits[r.id]!),
    ]);
  }

  /// 一组实体各自的修改记录（[_entityEdits] 的成批版本：按 ID 分块预读，每块两三次往返）。
  Future<Map<String, SrsEntityEdits>> _entityEditsMany(
    SrsEntityKind kind,
    Iterable<String> ids,
  ) async {
    final Map<String, SrsEntityEdits> out = <String, SrsEntityEdits>{};
    for (final List<String> chunk in _chunks(ids.toSet())) {
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchEdits(pre, kind, chunk);
      await _readWith(pre, () async {
        for (final String id in chunk) {
          out[id] = await _entityEdits(kind, id);
        }
      });
    }
    return out;
  }

  /// 在带预读 [pre] 的 Zone 里跑一段**只读**的物化（与缓存刷新同一套预读：[_entityRow] /
  /// [_entityEdits] / [_historyOf] / [_serverTimesFor] 先查预读、没预读的照常查库）。预读是开始
  /// 时刻的快照：body 里不得写库，也不得调会写库的方法。
  Future<T> _readWith<T>(_RefreshPrefetch pre, Future<T> Function() body) =>
      runZoned(
        body,
        zoneValues: <Object, Object>{_RefreshPrefetch.zoneKey: pre},
      );

  // ------------------------------------------------------------------ 缓存

  /// 按影响面刷新缓存（笔记缓存行、卡片缓存行）。与逐条重算同结果：每条笔记 / 每张卡的缓存行
  /// 只由它自己的事件决定，分块预读 + 成批写只是把读写往返摊薄。
  ///
  /// 先清掉外层可能带着的预读：刷新必须读本事务里刚落的行，不能读调用方的旧快照。
  Future<void> _flushCaches() => runZoned(
    _flushCachesNow,
    zoneValues: <Object?, Object?>{_RefreshPrefetch.zoneKey: null},
  );

  Future<void> _flushCachesNow() async {
    if (_dirtyNoteTypes.isNotEmpty) {
      final List<String> types = _dirtyNoteTypes.toList();
      _dirtyNoteTypes.clear();
      // 成员按笔记缓存的**当前**类型找（走 v125 的 idx_srs_notes_cache_type，只读 id）。每条有身份
      // 记录的笔记在它自己落库的那次刷新里就有了缓存行（[_planNote] 只在笔记不存在时返回 null，类型
      // 缺失照样写行），而本批新落的笔记已经因自己的事件进了 _dirtyNotes——所以不必再把全部笔记的
      // 身份记录读回来逐条 JSON 解析创建时的类型（以前每改一次笔记类型都整表扫一遍）。
      final $SrsNotesCacheTable c = db.srsNotesCache;
      for (final List<String> chunk in _chunks(types.toSet())) {
        final List<TypedResult> rows =
            await (db.selectOnly(c)
                  ..addColumns(<Expression<Object>>[c.id])
                  ..where(
                    c.profileUid.equals(profileUid) & c.noteTypeId.isIn(chunk),
                  ))
                .get();
        _dirtyNotes.addAll(rows.map((TypedResult r) => r.read(c.id)!));
      }
    }
    final List<String> notes = _dirtyNotes.toList();
    _dirtyNotes.clear();
    // 一次刷新内同一笔记类型只物化一次（导入一批几百条同类型笔记，类型的模板 / CSS 修改记录
    // 不必每条笔记各读一遍、各解析一遍）。本次刷新的事件都已落库，物化结果在刷新期间不变。
    final Map<String, SrsNoteTypeView?> noteTypes =
        <String, SrsNoteTypeView?>{};
    // 本次刷新里已经按最新事件重算过的卡（笔记刷新会重算它全部的卡）：下面不再算第二遍。
    final Set<String> refreshed = <String>{};
    // 分块：每块先把这些笔记 / 它们的卡（连同全部前身卡）要读的行一次预读进内存（Zone 里的
    // [_RefreshPrefetch]），逐条算，写入攒成一个 Drift batch。以前每条笔记、每张卡各自查身份记录 /
    // 修改记录 / 服务器时刻 / 日志、各写一两条语句，一条笔记十几次往返（BUG-3549 / BUG-3543）。
    for (int i = 0; i < notes.length; i += _refreshChunk) {
      final List<String> chunk = notes.sublist(
        i,
        min(i + _refreshChunk, notes.length),
      );
      final _RefreshPrefetch pre = _RefreshPrefetch();
      // 预读只对本次刷新（同一 Zone 里的调用链）可见：同一时刻 UI 别处读 store 不会读到
      // 这个事务里尚未提交的行。
      await _writeCache(
        await _readWith(
          pre,
          () => _flushChunk(pre, chunk, noteTypes, refreshed),
        ),
      );
    }
    // 卡片的历史 / 标志沿「前身」继承：前身变了，后继卡也要重算。
    final Set<String> cards = <String>{};
    final List<String> queue = _dirtyCards.toList();
    _dirtyCards.clear();
    // 「前身 → 后继」一次读全（走 v119 的部分索引，只碰前身链接那几行；以前每张脏卡各扫
    // 一遍修改记录表，随表长成平方级，BUG-3549）。
    final Map<String, List<String>> successors = queue.isEmpty
        ? const <String, List<String>>{}
        : await _successorIndex();
    while (queue.isNotEmpty) {
      final String c = queue.removeLast();
      if (!cards.add(c)) continue;
      queue.addAll(successors[c] ?? const <String>[]);
    }
    final List<String> rest = <String>[
      for (final String c in cards)
        if (!refreshed.contains(c)) c,
    ];
    for (int i = 0; i < rest.length; i += _refreshChunk) {
      await _refreshCardChunk(
        rest.sublist(i, min(i + _refreshChunk, rest.length)),
      );
    }
  }

  /// 缓存刷新每块的笔记 / 卡数：块内的读写各合成几次往返；块不宜太大（一块的计算在 UI isolate
  /// 上连续跑完，中间不让出事件循环）。
  static const int _refreshChunk = 200;

  /// 一块笔记的缓存刷新（在带预读的 Zone 里跑，见 [_flushCaches]）：只读、只算，写入返回给调用方
  /// 成批写。
  Future<_CacheWrites> _flushChunk(
    _RefreshPrefetch pre,
    List<String> chunk,
    Map<String, SrsNoteTypeView?> noteTypes,
    Set<String> refreshed,
  ) async {
    await _prefetchEntities(pre, chunk);
    await _prefetchEdits(pre, SrsEntityKind.note, chunk);
    await _prefetchCardsOfNotes(pre, chunk);
    final List<_NotePlan> plans = <_NotePlan>[];
    for (final String n in chunk) {
      final _NotePlan? plan = await _planNote(n, noteTypes: noteTypes);
      if (plan != null) plans.add(plan);
    }
    await _prefetchLineage(pre, <String>{
      for (final _NotePlan p in plans) ...p.expected.keys,
    });
    final _CacheWrites out = _CacheWrites();
    for (final _NotePlan p in plans) {
      await _applyNotePlan(p, refreshed, out);
    }
    return out;
  }

  /// 一块「只有卡片事件变了」的卡的缓存刷新：卡片缓存行、笔记缓存行、血统（修改记录 + 日志）
  /// 各分块一次预读，算完一个 batch 写回。缓存里还没有的卡跳过（日志先于笔记到达：笔记到时一起生成）。
  Future<void> _refreshCardChunk(List<String> chunk) async {
    final Map<String, SrsCardCacheRow> rows = <String, SrsCardCacheRow>{
      for (final SrsCardCacheRow c in await cardRows(chunk)) c.id: c,
    };
    if (rows.isEmpty) return;
    final Map<String, SrsNoteCacheRow> notes = <String, SrsNoteCacheRow>{};
    for (final List<String> ids in _chunks(<String>{
      for (final SrsCardCacheRow c in rows.values) c.noteId,
    })) {
      for (final SrsNoteCacheRow n in await (db.select(
        db.srsNotesCache,
      )..where((x) => x.id.isIn(ids))).get()) {
        notes[n.id] = n;
      }
    }
    final _RefreshPrefetch pre = _RefreshPrefetch();
    await _prefetchLineage(pre, rows.keys);
    final _CacheWrites out = _CacheWrites();
    await _readWith(pre, () async {
      for (final String id in chunk) {
        final SrsCardCacheRow? c = rows[id];
        if (c == null) continue;
        final SrsNoteCacheRow? n = notes[c.noteId];
        out.addCard(
          await _cardCacheRow(
            cardId: id,
            noteId: c.noteId,
            templateId: c.templateId,
            clozeOrd: c.clozeOrd,
            noteDeckId: n?.deckId,
            noteCreatedAt: n?.createdAt ?? c.noteCreatedAt,
            hidden: c.hidden,
          ),
          id,
        );
      }
    });
    await _writeCache(out);
  }

  /// 一块缓存刷新攒下的写入：一个 Drift batch（一次往返）。三类行互不重叠（笔记行 / 隐藏的旧卡 /
  /// 重算的卡），顺序无关。
  Future<void> _writeCache(_CacheWrites w) async {
    if (w.isEmpty) return;
    final List<String> noteIds = <String>[
      for (final SrsNotesCacheCompanion n in w.notes) n.id.value,
    ];
    final List<String> cardIds = <String>[
      for (final SrsCardsCacheCompanion c in w.cards) c.id.value,
    ];
    // 变更日志与数字索引随写入同步记下（同一个独占区 / 事务里）；事务回滚时
    // [_transactionOrReload] 会把两者一起作废。
    _journalCacheWrite(noteIds, <String>[...cardIds, ...w.hide]);
    _indexCacheRows(noteIds, cardIds);
    await db.batch((Batch b) {
      if (w.notes.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.srsNotesCache, w.notes);
      }
      for (final List<String> ids in _chunks(w.hide)) {
        b.update(
          db.srsCardsCache,
          const SrsCardsCacheCompanion(hidden: Value<bool>(true)),
          where: ($SrsCardsCacheTable x) => x.id.isIn(ids),
        );
      }
      if (w.cards.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.srsCardsCache, w.cards);
      }
      // 投影整卡替换：先删这些卡名下的行，再写重算结果（每条日志只由它自己的卡投影，
      // 一条日志永远至多一行）。
      for (final List<String> ids in _chunks(w.statCards)) {
        b.deleteWhere(
          db.srsStatReviews,
          ($SrsStatReviewsTable x) => x.cardId.isIn(ids),
        );
      }
      if (w.stats.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.srsStatReviews, w.stats);
      }
    });
  }

  /// 一组卡的「血统」要读的行（自己与全部前身的修改记录 + 日志 + 服务器时刻）分轮预读：每轮把
  /// 上一轮新发现的前身一起读（前身链通常一两层）。只多读不少读：前身键的值是否为 true 由
  /// [_cardLineage] 照常判断。
  Future<void> _prefetchLineage(
    _RefreshPrefetch pre,
    Iterable<String> cardIds,
  ) async {
    const String prefix = SrsFieldKeys.cardHistoryFromPrefix;
    final String kind = SrsEntityKind.card.wire;
    Set<String> next = <String>{
      for (final String c in cardIds)
        if (!pre.edits.containsKey('$kind/$c')) c,
    };
    for (int round = 0; next.isNotEmpty && round < 256; round++) {
      await _prefetchEdits(pre, SrsEntityKind.card, next);
      await _prefetchLogs(pre, next);
      final Set<String> preds = <String>{};
      for (final String c in next) {
        for (final SrsFieldEditRow r in pre.edits['$kind/$c']!) {
          if (!r.fieldKey.startsWith(prefix)) continue;
          final String p = r.fieldKey.substring(prefix.length);
          if (!pre.edits.containsKey('$kind/$p')) preds.add(p);
        }
      }
      next = preds;
    }
  }

  /// 身份记录行（刷新期间先查预读）。
  Future<SrsEntityRow?> _entityRow(String id) async {
    final _RefreshPrefetch? pre = _RefreshPrefetch.current;
    if (pre != null && pre.entities.containsKey(id)) return pre.entities[id];
    return (db.select(
      db.srsEntities,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<void> _prefetchEntities(
    _RefreshPrefetch pre,
    Iterable<String> ids,
  ) async {
    for (final List<String> chunk in _chunks(ids)) {
      for (final String id in chunk) {
        pre.entities[id] = null;
      }
      for (final SrsEntityRow r in await (db.select(
        db.srsEntities,
      )..where((t) => t.id.isIn(chunk))).get()) {
        pre.entities[r.id] = r;
      }
    }
  }

  /// 一组实体的全部修改记录 + 这些记录的服务器时刻。
  Future<void> _prefetchEdits(
    _RefreshPrefetch pre,
    SrsEntityKind kind,
    Iterable<String> ids,
  ) async {
    final List<String> editIds = <String>[];
    for (final List<String> chunk in _chunks(ids)) {
      for (final String id in chunk) {
        pre.edits['${kind.wire}/$id'] = <SrsFieldEditRow>[];
      }
      for (final SrsFieldEditRow r
          in await (db.select(db.srsFieldEdits)..where(
                (t) => t.entityKind.equals(kind.wire) & t.entityId.isIn(chunk),
              ))
              .get()) {
        pre.edits['${kind.wire}/${r.entityId}']!.add(r);
        editIds.add(r.id);
      }
    }
    await _prefetchServerTimes(pre, editIds);
  }

  /// 一组卡的全部复习日志 + 日志的服务器时刻。
  Future<void> _prefetchLogs(
    _RefreshPrefetch pre,
    Iterable<String> cardIds,
  ) async {
    final List<String> logIds = <String>[];
    for (final List<String> chunk in _chunks(cardIds)) {
      for (final String id in chunk) {
        pre.logsByCard[id] = <SrsReviewLogRow>[];
      }
      for (final SrsReviewLogRow r in await (db.select(
        db.srsReviewLogs,
      )..where((t) => t.cardId.isIn(chunk))).get()) {
        pre.logsByCard[r.cardId]!.add(r);
        logIds.add(r.id);
      }
    }
    await _prefetchServerTimes(pre, logIds);
  }

  Future<void> _prefetchServerTimes(
    _RefreshPrefetch pre,
    Iterable<String> eventIds,
  ) async {
    for (final List<String> chunk in _chunks(eventIds)) {
      pre.serverTimesKnown.addAll(chunk);
      for (final SrsEventLocalRow r in await (db.select(
        db.srsEventLocal,
      )..where((t) => t.eventId.isIn(chunk))).get()) {
        if (r.serverTime != null) pre.serverTimes[r.eventId] = r.serverTime!;
      }
    }
  }

  Future<void> _prefetchCardsOfNotes(
    _RefreshPrefetch pre,
    Iterable<String> noteIds,
  ) async {
    for (final List<String> chunk in _chunks(noteIds)) {
      for (final String id in chunk) {
        pre.cardsByNote[id] = <SrsCardCacheRow>[];
      }
      for (final SrsCardCacheRow r in await (db.select(
        db.srsCardsCache,
      )..where((t) => t.noteId.isIn(chunk))).get()) {
        pre.cardsByNote[r.noteId]!.add(r);
      }
    }
  }

  /// 全部「前身卡 → 后继卡」链接（卡的 `historyFrom/<前身>` 修改记录）。
  ///
  /// 条件用 v119 的部分覆盖索引 `idx_srs_field_edits_history_from` 的同一句 WHERE
  /// （[kSrsHistoryFromCondition]，字面量）；实体类型写成 `+entity_kind`，不让规划器改挑
  /// `(entity_kind, entity_id)` 索引去扫全部卡片修改记录。命中时只扫前身链接那几行，不随修改记录表
  /// 增长——每次缓存刷新（每次评分、每次改卡）都要读一遍（BUG-3543，以前全表扫描）。
  Future<Map<String, List<String>>> _successorIndex() async {
    const String prefix = SrsFieldKeys.cardHistoryFromPrefix;
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT entity_id, field_key FROM srs_field_edits '
          'WHERE $kSrsHistoryFromCondition '
          "AND +entity_kind = '${SrsEntityKind.card.wire}'",
          readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
            db.srsFieldEdits,
          },
        )
        .get();
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final QueryRow r in rows) {
      final String pred = r.read<String>('field_key').substring(prefix.length);
      (out[pred] ??= <String>[]).add(r.read<String>('entity_id'));
    }
    return out;
  }

  /// 一张卡的「血统」：自己在前，再按广度优先列出全部前身（防环）。每张卡附带它自己的修改记录。
  Future<List<(String, SrsEntityEdits)>> _cardLineage(String cardId) async {
    final List<(String, SrsEntityEdits)> out = <(String, SrsEntityEdits)>[];
    final Set<String> seen = <String>{cardId};
    final List<String> queue = <String>[cardId];
    while (queue.isNotEmpty && out.length < 256) {
      final String id = queue.removeAt(0);
      final SrsEntityEdits edits = await _entityEdits(SrsEntityKind.card, id);
      out.add((id, edits));
      final List<String> preds = <String>[
        for (final String k in edits.keys)
          if (k.startsWith(SrsFieldKeys.cardHistoryFromPrefix) &&
              edits.value(k) == true)
            k.substring(SrsFieldKeys.cardHistoryFromPrefix.length),
      ]..sort();
      for (final String p in preds) {
        if (seen.add(p)) queue.add(p);
      }
    }
    return out;
  }

  /// 卡片标志按血统继承：自己有记录的键用自己的，没有的取最近的前身的
  /// （换类型后旧卡的暂停 / 旗标 / 牌组跟到新卡；别的设备并发改旧卡也会流过来）。
  static SrsEntityEdits _inheritedCardEdits(
    List<(String, SrsEntityEdits)> lineage,
  ) {
    final Map<String, SrsRegister> regs = <String, SrsRegister>{};
    for (final (String _, SrsEntityEdits edits) in lineage.reversed) {
      for (final String k in edits.keys) {
        if (k.startsWith(SrsFieldKeys.cardHistoryFromPrefix)) continue;
        regs[k] = edits[k]!;
      }
    }
    return SrsEntityEdits(regs);
  }

  /// 本机缓存的推导规则比 [_cacheRevision] 新：只重算受新规则影响的那些行（见
  /// [_kCacheRevision]），记下新版本。一个事务；失败照常抛出（打开失败），下次打开重来。
  Future<void> _upgradeCaches() => runExclusive(() async {
    await db.transaction(() async {
      if (_cacheRevision < 1) {
        final List<QueryRow> rows = await db
            .customSelect(
              'SELECT DISTINCT entity_id FROM srs_field_edits '
              'WHERE profile_uid = ? AND entity_kind = ? AND field_key = ?',
              variables: <Variable<Object>>[
                Variable<String>(profileUid),
                Variable<String>(SrsEntityKind.card.wire),
                Variable<String>(SrsFieldKeys.cardNewPosition),
              ],
            )
            .get();
        _dirtyCards.addAll(
          rows.map((QueryRow r) => r.read<String>('entity_id')),
        );
        await _flushCaches();
      }
      if (_cacheRevision < 2) {
        // 投影表是新建的空表：缓存里的每张卡（含隐藏卡：已删笔记的复习历史照样进统计）重算。
        final List<QueryRow> rows = await db
            .customSelect(
              'SELECT id FROM srs_cards_cache WHERE profile_uid = ?',
              variables: <Variable<Object>>[Variable<String>(profileUid)],
            )
            .get();
        _dirtyCards.addAll(rows.map((QueryRow r) => r.read<String>('id')));
        await _flushCaches();
      }
      _cacheRevision = _kCacheRevision;
      await _saveLocal();
    });
  });

  /// 丢掉全部缓存，由事件重建（缓存不同步，随时可重建）。
  Future<void> rebuildCaches() => runExclusive(() async {
    _cacheRevision = _kCacheRevision;
    _resetCacheJournal();
    await db.transaction(() async {
      await (db.delete(
        db.srsCardsCache,
      )..where((t) => t.profileUid.equals(profileUid))).go();
      await (db.delete(
        db.srsNotesCache,
      )..where((t) => t.profileUid.equals(profileUid))).go();
      await (db.delete(
        db.srsStatReviews,
      )..where((t) => t.profileUid.equals(profileUid))).go();
      final List<SrsEntityRow> notes =
          await (db.select(db.srsEntities)..where(
                (t) =>
                    t.profileUid.equals(profileUid) &
                    t.kind.equals(SrsEntityKind.note.wire),
              ))
              .get();
      _dirtyNotes.addAll(notes.map((SrsEntityRow r) => r.id));
      await _flushCaches();
    });
  });

  Map<String, String> _fieldsByName(SrsNoteView n, SrsNoteTypeView t) =>
      <String, String>{
        for (final SrsFieldDef f in t.fields) f.name: n.field(f.id),
      };

  Map<String, String> _idToName(SrsNoteTypeView t) => <String, String>{
    for (final SrsFieldDef f in t.fields) f.id: f.name,
  };

  /// 笔记缓存刷新的第一步（只读）：物化笔记与类型，算出缓存行的派生值与应有的卡。
  Future<_NotePlan?> _planNote(
    String noteId, {
    required Map<String, SrsNoteTypeView?> noteTypes,
  }) async {
    final SrsNoteView? n = await note(noteId);
    if (n == null) return null;
    final SrsNoteTypeView? t = noteTypes.containsKey(n.noteTypeId)
        ? noteTypes[n.noteTypeId]
        : noteTypes[n.noteTypeId] = await noteType(n.noteTypeId);
    final String term = t?.termFieldId == null
        ? ''
        : srsTermKey(n.field(t!.termFieldId!));
    final String? readingFieldId = srsBuiltinReadingFieldId(
      profileUid,
      t?.builtinKey,
    );
    final String reading = readingFieldId == null
        ? ''
        : srsReadingKey(n.field(readingFieldId));
    final String sortField = t == null || t.fields.isEmpty
        ? ''
        : ankiStripHtml(n.field(t.fields.first.id)).trim();

    // 卡片生成（铁律 D）：期望的 (templateId, clozeOrd) 集合；不在集合里的现存卡片隐藏，不写同步行。
    final Map<String, (String, int, bool)> expected =
        <String, (String, int, bool)>{};
    if (t != null) {
      final Map<String, String> byName = _fieldsByName(n, t);
      final Map<String, String> idToName = _idToName(t);
      if (t.isCloze && t.templates.isNotEmpty) {
        final SrsTemplateDef tpl = t.templates.first;
        final Set<int> ords = clozeOrdinalsIn(byName.values.join('\n'));
        for (final int ord in ords) {
          expected[SrsIds.card(n.id, tpl.id, ord)] = (tpl.id, ord, false);
        }
      } else {
        for (final SrsTemplateDef tpl in t.templates) {
          bool empty;
          try {
            empty = isAnkiCardEmpty(
              questionTemplate: templateIdsToNames(tpl.front, idToName),
              noteFields: byName,
              cardOrd: tpl.ord,
              isCloze: false,
            );
          } on Object {
            empty = false;
          }
          expected[SrsIds.card(n.id, tpl.id, 0)] = (tpl.id, 0, empty);
        }
      }
    }
    final bool noteGone =
        n.deletedAt != null || t == null || t.deletedAt != null;
    return _NotePlan(
      note: n,
      noteType: t,
      term: term,
      reading: reading,
      sortField: sortField,
      expected: expected,
      noteGone: noteGone,
    );
  }

  /// 笔记缓存刷新的第二步：算笔记缓存行、要隐藏的不再应有的卡、应有的卡的缓存行（记进
  /// [refreshed]），攒进 [out] 由调用方成批写。
  Future<void> _applyNotePlan(
    _NotePlan plan,
    Set<String> refreshed,
    _CacheWrites out,
  ) async {
    final SrsNoteView n = plan.note;
    final String sortField = plan.sortField;
    out.notes.add(
      SrsNotesCacheCompanion.insert(
        id: n.id,
        profileUid: profileUid,
        noteTypeId: n.noteTypeId,
        guid: n.guid,
        createdAt: n.createdAt,
        deckId: Value<String?>(n.deckId),
        deletedAt: Value<int?>(n.deletedAt),
        termKey: Value<String>(plan.term),
        readingKey: Value<String>(plan.reading),
        sortField: Value<String>(
          sortField.length > 200 ? sortField.substring(0, 200) : sortField,
        ),
        tagsJson: Value<String>(jsonEncode(n.tags)),
        pendingDecision: Value<bool>(n.hasPendingDecision),
        updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    final Map<String, (String, int, bool)> expected = plan.expected;
    final bool noteGone = plan.noteGone;
    final List<SrsCardCacheRow> existing =
        _RefreshPrefetch.current?.cardsByNote[n.id] ??
        await (db.select(
          db.srsCardsCache,
        )..where((c) => c.noteId.equals(n.id))).get();
    for (final SrsCardCacheRow c in existing) {
      if (!expected.containsKey(c.id)) out.hide.add(c.id);
    }
    for (final MapEntry<String, (String, int, bool)> e in expected.entries) {
      final (String tplId, int ord, bool empty) = e.value;
      out.addCard(
        await _cardCacheRow(
          cardId: e.key,
          noteId: n.id,
          templateId: tplId,
          clozeOrd: ord,
          noteDeckId: n.deckId,
          noteCreatedAt: n.createdAt,
          hidden: noteGone || empty,
        ),
        e.key,
      );
      refreshed.add(e.key);
    }
  }

  /// 一张卡的复习历史：自己的日志 + 全部前身卡（更改笔记类型继承来的）的日志。
  Future<SrsCardHistory> history(String cardId) async => _historyOf(<String>[
    for (final (String id, SrsEntityEdits _) in await _cardLineage(cardId)) id,
  ]);

  /// 复习日志的归属：前身卡 → 继承它历史的可见卡（与 [history] 合并前身日志同一条血统规则）。
  ///
  /// 更改笔记类型 / 旧 Lapis 迁到 Fushi 卡片后，日志仍记在（已隐藏的）前身卡名下；按卡读日志的地方
  /// （统计）要把它们算到继承它们的那张可见卡上，否则那张卡在牌组统计里一条复习都没有。一张前身被
  /// 几张可见卡继承时（极少）归 id 最小的那张，不重复计数。
  Future<Map<String, String>> historyOwnerIndex() async {
    final Map<String, List<String>> successors = await _successorIndex();
    if (successors.isEmpty) return const <String, String>{};
    final Set<String> candidates = <String>{
      for (final List<String> l in successors.values) ...l,
    };
    final List<String> visible = <String>[
      for (final SrsCardCacheRow c in await cardRows(candidates))
        if (!c.hidden) c.id,
    ]..sort();
    final Map<String, String> out = <String, String>{};
    for (int i = 0; i < visible.length; i += _refreshChunk) {
      final List<String> chunk = visible.sublist(
        i,
        min(i + _refreshChunk, visible.length),
      );
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchLineage(pre, chunk);
      await _readWith(pre, () async {
        for (final String owner in chunk) {
          for (final (String id, SrsEntityEdits _) in (await _cardLineage(
            owner,
          )).skip(1)) {
            out.putIfAbsent(id, () => owner);
          }
        }
      });
    }
    // 前身自己还可见（没被换掉）时它的日志仍归它自己。
    for (final SrsCardCacheRow c in await cardRows(out.keys.toList())) {
      if (!c.hidden) out.remove(c.id);
    }
    return out;
  }

  /// 一组卡各自的复习历史（同 [history]；按输入顺序去重）。按块预读整条血统的修改记录、日志与
  /// 服务器时刻（每块几次往返），批量重置 / 设置到期 / 撤销 / 立即重排 / 导出 / 优化器取数不再每张卡
  /// 各查四五次（BUG-3543）。
  Future<Map<String, SrsCardHistory>> histories(
    Iterable<String> cardIds,
  ) async {
    final List<String> ids = cardIds.toSet().toList();
    final Map<String, SrsCardHistory> out = <String, SrsCardHistory>{};
    for (int i = 0; i < ids.length; i += _refreshChunk) {
      final List<String> chunk = ids.sublist(
        i,
        min(i + _refreshChunk, ids.length),
      );
      final _RefreshPrefetch pre = _RefreshPrefetch();
      await _prefetchLineage(pre, chunk);
      await _readWith(pre, () async {
        for (final String id in chunk) {
          out[id] = await history(id);
        }
      });
    }
    return out;
  }

  Future<SrsCardHistory> _historyOf(List<String> cardIds) async {
    final _RefreshPrefetch? pre = _RefreshPrefetch.current;
    final List<SrsReviewLogRow> rows =
        pre != null && cardIds.every(pre.logsByCard.containsKey)
        ? <SrsReviewLogRow>[
            for (final String c in cardIds) ...pre.logsByCard[c]!,
          ]
        : await (db.select(
            db.srsReviewLogs,
          )..where((t) => t.cardId.isIn(cardIds))).get();
    final List<SrsReviewLog> logs = <SrsReviewLog>[
      for (final SrsReviewLogRow r in rows)
        SrsReviewLog.fromJson(
          (jsonDecode(r.json) as Map).cast<String, Object?>(),
        ),
    ];
    final Map<String, int> s = await _serverTimesFor(logs.map((l) => l.id));
    return SrsCardHistory(logs, serverTimeOf: (String id) => s[id]);
  }

  /// 一张卡的缓存行（只算不写）：标志沿血统继承，状态由自己 + 全部前身的日志重放。
  ///
  /// 同一份有效历史同时产出这张卡名下的有效复习投影（`srs_stat_reviews`，统计读它）：
  /// 卡片缓存因任何原因重算（新日志、undo、同步来的同 ID 覆盖 / 晚到日志、服务器时刻改了
  /// 排序、恢复、重建、前身变化），投影跟着重算，两者永远出自同一份历史。
  Future<(SrsCardsCacheCompanion, List<SrsStatReviewsCompanion>)>
  _cardCacheRow({
    required String cardId,
    required String noteId,
    required String templateId,
    required int clozeOrd,
    required String? noteDeckId,
    required int noteCreatedAt,
    required bool hidden,
  }) async {
    final List<(String, SrsEntityEdits)> lineage = await _cardLineage(cardId);
    final SrsCardFlags flags = SrsCardFlags.materialize(
      _inheritedCardEdits(lineage),
      noteDeckId: noteDeckId,
      fallbackDeckId: defaultDeckId,
    );
    final SrsCardHistory h = await _historyOf(<String>[
      for (final (String id, SrsEntityEdits _) in lineage) id,
    ]);
    final SrsScheduleResult s = h.state;
    final List<SrsStatReviewsCompanion> stats = <SrsStatReviewsCompanion>[
      for (final SrsStatProjection p in srsStatProjectionOf(h))
        // 前身卡的日志只用来定本卡日志的前序状态；它们由前身卡自己投影。
        if (p.cardId == cardId)
          SrsStatReviewsCompanion.insert(
            logId: p.logId,
            profileUid: profileUid,
            cardId: cardId,
            occurredAt: p.occurredAt,
            utcOffsetMin: Value<int>(p.utcOffsetMin),
            rating: Value<int?>(p.rating),
            kind: Value<int>(p.kind.index),
            durationMs: Value<int>(p.durationMs),
            prevDueDay: Value<int?>(p.prevDueDay),
            maturityDelta: Value<int>(p.maturityDelta),
          ),
    ];
    final SrsCardsCacheCompanion row = SrsCardsCacheCompanion.insert(
      id: cardId,
      profileUid: profileUid,
      noteId: noteId,
      templateId: templateId,
      clozeOrd: Value<int>(clozeOrd),
      deckId: flags.deckId,
      suspended: Value<bool>(flags.suspended),
      buriedUntilDay: Value<int?>(flags.buriedUntilDay),
      flag: Value<int>(flags.flag),
      hidden: Value<bool>(hidden),
      queue: Value<String>(s.queue.wire),
      dueDay: Value<int?>(s.dueDay),
      dueAt: Value<int?>(s.dueAt),
      scheduledDays: Value<int>(s.scheduledDays),
      reps: Value<int>(s.reps),
      lapses: Value<int>(s.lapses),
      stability: Value<double?>(s.memory?.stability),
      difficulty: Value<double?>(s.memory?.difficulty),
      lastReviewedAt: Value<int?>(s.lastReviewedAt),
      lastLogId: Value<String?>(h.lastEffective?.id),
      scheduler: Value<String>(h.scheduler),
      noteCreatedAt: Value<int>(noteCreatedAt),
      newPosition: Value<int?>(flags.newPosition),
    );
    return (row, stats);
  }

  // ------------------------------------------------------------------ 修改记录

  /// 改一个字段（no-op 不产生记录）。
  Future<SrsFieldEdit?> editField(
    SrsEntityKind kind,
    String entityId,
    String key,
    Object? value, {
    bool machine = false,
  }) async {
    final List<SrsFieldEdit>? out = await editFields(
      kind,
      entityId,
      <String, Object?>{key: value},
      machine: machine,
    );
    return out == null || out.isEmpty ? null : out.single;
  }

  /// 同一实体的多个字段一次写（同一个事务；例如 algorithm 与参数组「同一次修改」）。
  Future<List<SrsFieldEdit>?> editFields(
    SrsEntityKind kind,
    String entityId,
    Map<String, Object?> values, {
    bool machine = false,
  }) => runExclusive(() async {
    final SrsEntityEdits current = await _entityEdits(kind, entityId);
    final List<SrsFieldEdit> out = _createEdits(<SrsEditDraft>[
      for (final MapEntry<String, Object?> e in values.entries)
        if (_changes(current, e.key, e.value))
          SrsEditDraft(kind, entityId, e.key, e.value, machine: machine),
    ]);
    if (out.isNotEmpty) {
      await _emit(<SrsEvent>[
        for (final SrsFieldEdit e in out) SrsEditEvent(e),
      ]);
    }
    return out;
  });

  /// 写 [value] 会不会改变 [current] 里的 [key]（值没变且无冲突的键不产生记录）。
  static bool _changes(SrsEntityEdits current, String key, Object? value) {
    final SrsRegister? reg = current[key];
    return reg == null || !srsEditIsNoop(reg, value);
  }

  /// 按序分配序号 / HLC，把草稿变成修改记录（同一时刻、逐条 tick）。只在独占区里、紧接着
  /// [_emit] 调用。
  List<SrsFieldEdit> _createEdits(List<SrsEditDraft> drafts) => <SrsFieldEdit>[
    for (final SrsEvent e in _finalize(drafts)) (e as SrsEditEvent).edit,
  ];

  /// 一组 (实体类型, 实体 ID) 各自的现值修改记录，键为 `<kind>/<id>`：按类型分组、按 ID 分块
  /// 一次预读（[_entityEditsMany]）。
  Future<Map<String, SrsEntityEdits>> _currentEditsOf(
    Iterable<(SrsEntityKind, String)> entities,
  ) async {
    final Map<SrsEntityKind, Set<String>> byKind =
        <SrsEntityKind, Set<String>>{};
    for (final (SrsEntityKind kind, String id) in entities) {
      (byKind[kind] ??= <String>{}).add(id);
    }
    final Map<String, SrsEntityEdits> out = <String, SrsEntityEdits>{};
    for (final MapEntry<SrsEntityKind, Set<String>> k in byKind.entries) {
      for (final MapEntry<String, SrsEntityEdits> e in (await _entityEditsMany(
        k.key,
        k.value,
      )).entries) {
        out['${k.key.wire}/${e.key}'] = e.value;
      }
    }
    return out;
  }

  /// 一次写多个实体的修改记录（可带新身份记录），同一个事务、同一次缓存刷新。
  /// 值没变且无冲突的键不产生记录（与 [editFields] 同一规则）。
  ///
  /// 现值先按实体分块一次预读，序号再紧接着落库一次分配完（以前每个实体各查两次库，且「查一个
  /// 实体、分配一个实体的序号」交替进行，分配与落库之间夹着几百次往返，BUG-3543）。
  Future<List<SrsFieldEdit>> writeEdits(
    List<SrsEditSpec> specs, {
    List<SrsEntityRecord> records = const <SrsEntityRecord>[],
  }) => runExclusive(() async {
    final Map<String, SrsEntityEdits> current = await _currentEditsOf(
      <(SrsEntityKind, String)>[
        for (final SrsEditSpec spec in specs) (spec.kind, spec.entityId),
      ],
    );
    final List<SrsFieldEdit> out = _createEdits(<SrsEditDraft>[
      for (final SrsEditSpec spec in specs)
        if (_changes(
          current['${spec.kind.wire}/${spec.entityId}']!,
          spec.key,
          spec.value,
        ))
          SrsEditDraft(spec.kind, spec.entityId, spec.key, spec.value),
    ]);
    final List<SrsEvent> events = <SrsEvent>[
      for (final SrsEntityRecord r in records) SrsEntityEvent(r),
      for (final SrsFieldEdit e in out) SrsEditEvent(e),
    ];
    if (events.isNotEmpty) await _emit(events);
    return out;
  });

  // ------------------------------------------------------------------ 牌组

  /// 按名字 [name] 在 [parentId] 下（null = 顶层）新建或复活牌组时用的 ID（[createDeck] 与
  /// Anki 导入共用）。先取「父::子」全名确定性派生的 [SrsIds.deck]：多台设备离线各建同名牌组
  /// 落在同一个 ID 上。
  ///
  /// 「同名」按牌组此刻的名字与父牌组认，不按 ID：牌组改过名或挪过父牌组后 ID 不变，按它原来
  /// 的全名再新建时派生 ID 落在它身上——那不是同一个牌组，沿用就会把它改名 / 拽回原处（BUG：
  /// 拖放挪走 A 后再按「A」建牌组，挪走的那个被拽回顶层）。这时依次试 [SrsIds.deckAlternate]
  /// 的备选 ID，取第一个没被用过的、或名字与父牌组都一致（可沿用 / 复活）的。只由本机牌组状态
  /// 决定：看到同样牌组状态的设备（含收下了挪动 / 改名记录的其它设备）得到同一个 ID。
  Future<String> deckIdForNew(String name, {String? parentId}) async {
    final SrsDeckTree tree = await deckTree();
    final String parentPath = parentId == null || tree[parentId] == null
        ? ''
        : '${tree.fullName(parentId)}::';
    final String fullPath = '$parentPath$name';
    final String trimmed = name.trim();
    String id = SrsIds.deck(profileUid, fullPath);
    for (int n = 1; ; n++) {
      final SrsEntityEdits current = await _entityEdits(SrsEntityKind.deck, id);
      if (current.keys.isEmpty ||
          (current.value(SrsFieldKeys.name) == trimmed &&
              current.value(SrsFieldKeys.deckParent) == parentId)) {
        return id;
      }
      id = SrsIds.deckAlternate(profileUid, fullPath, n);
    }
  }

  /// 新建牌组，ID 见 [deckIdForNew]；名字与父牌组都一致的牌组已存在（含已删除的）时复活并沿用它。
  /// 身份记录不含本机时刻（createdAt = 0），同 ID 同内容。
  Future<String> createDeck(String name, {String? parentId}) => runExclusive(
    () async {
      final String trimmed = name.trim();
      final String id = await deckIdForNew(name, parentId: parentId);
      final SrsEntityEdits current = await _entityEdits(SrsEntityKind.deck, id);
      // 身份记录与名字 / 父牌组记录同一个事务落库（以前分两次事务、两次缓存刷新）。
      await _emit(
        _finalize(<SrsEventDraft>[
          SrsReadyDraft(
            SrsEntityEvent(
              SrsEntityRecord(
                id: id,
                profileUid: profileUid,
                kind: SrsEntityKind.deck,
                payload: const <String, Object?>{'createdAt': 0},
              ),
            ),
          ),
          ...newEditDrafts(SrsEntityKind.deck, id, <String, Object?>{
            SrsFieldKeys.name: trimmed,
            if (parentId != null) SrsFieldKeys.deckParent: parentId,
            if (current.deletedAt != null) SrsFieldKeys.deleted: null,
          }, current: current),
        ]),
      );
      return id;
    },
  );

  /// 按「父::子」全名找或建牌组（AnkiConnect createDeck / 导入用）。
  Future<String> ensureDeckPath(String fullName) async {
    final List<String> parts = fullName
        .split('::')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return defaultDeckId;
    String? parent;
    for (final String part in parts) {
      final SrsDeckTree tree = await deckTree();
      String? found;
      for (final SrsDeckView d in tree.decks) {
        if (d.name == part && tree.parentOf(d.id) == parent) {
          found = d.id;
          break;
        }
      }
      parent = found ?? await createDeck(part, parentId: parent);
    }
    return parent!;
  }

  /// 删牌组每块的卡数（一块一个独占区 + 一个事务 + 一次缓存刷新）。
  static const int _deleteDeckChunk = 500;

  /// 删牌组（连同全部子牌组）：子树里的卡移到被删牌组的父牌组（没有父牌组则到默认牌组），每张卡
  /// 一条修改记录；卡都移完后给子树里每个牌组写删除标记。
  ///
  /// 按块（每块 [_deleteDeckChunk] 张卡）走：块内现值一次预读、序号紧接着分配、一次落库一次刷新缓存，
  /// 都在同一个独占区里；块与块之间别的写入（复习评分）照常插进来，不被一个长事务卡住。记录、顺序、
  /// 「值没变的卡不写」都与以前逐张 `editField` 相同；中途被杀时已提交的块留在库里（以前逐张一个事务
  /// 也是这样），删除标记在最后，再删一次即补齐。
  ///
  /// 以前每张卡一次 `editField`：各自读两次现值、一个事务、一次缓存刷新（含一次修改记录全表扫描）、
  /// 一次存本机状态，几千张卡的牌组要几万次往返、几十秒（BUG-3543）。[onProgress] 按卡数报进度。
  ///
  /// [deleteCards] 为真时（Anki「删除牌组」的语义）先删掉只在这个子树里有卡的笔记（每块一个独占区，
  /// 进度里笔记数在前），之后照样把子树里的卡移走——删掉的笔记的卡已隐藏，移走只是让「恢复笔记」后
  /// 卡不落在已删除的牌组里。Fushi 只能整条删笔记：在子树外还有卡的笔记不删，它在子树里的卡照常移走。
  ///
  /// 返回这次写了删除标记的笔记（[deleteCards] 为假时为空）。删除标记只是墓碑：正文、复习日志、
  /// 媒体留到墓碑过了同步安全期才由 srs_purge.dart 物理清除；从没同步过的副本可以当场清除
  /// （`srsPurgeNotesNow`）。
  Future<List<String>> deleteDeck(
    String deckId, {
    bool deleteCards = false,
    SrsProgress? onProgress,
  }) async {
    if (deckId == defaultDeckId) {
      throw StateError('the default deck cannot be deleted');
    }
    final SrsDeckTree tree = await deckTree();
    final List<String> sub = tree.subtree(deckId);
    final String target = tree.parentOf(deckId) ?? defaultDeckId;
    final List<String> notes = deleteCards
        ? await _notesOnlyInDecks(sub)
        : const <String>[];
    final List<String> cards = await _cardIdsInDecks(sub);
    final int total = notes.length + cards.length;
    onProgress?.call(0, total);
    final (int deletedAt, _) = now();
    for (int i = 0; i < notes.length; i += _deleteDeckChunk) {
      final List<String> chunk = notes.sublist(
        i,
        min(i + _deleteDeckChunk, notes.length),
      );
      await runExclusive(
        () => _editEach(
          SrsEntityKind.note,
          chunk,
          SrsFieldKeys.deleted,
          deletedAt,
        ),
      );
      onProgress?.call(i + chunk.length, total);
    }
    for (int i = 0; i < cards.length; i += _deleteDeckChunk) {
      final List<String> chunk = cards.sublist(
        i,
        min(i + _deleteDeckChunk, cards.length),
      );
      await runExclusive(
        () =>
            _editEach(SrsEntityKind.card, chunk, SrsFieldKeys.cardDeck, target),
      );
      onProgress?.call(notes.length + i + chunk.length, total);
    }
    // 收尾在一个独占区里：子树、目标牌组、子树里还剩的卡都**在这里重读**——分块期间别的写入
    // （后台导入把卡放进这个子树、建了新的子牌组、挪走了父牌组）已经落库，按开头那份快照写删除
    // 标记会把它们留在已删除的牌组下面。重读与写删除标记之间没有别的写入能插进来。
    final List<String> deletedNotes = <String>[...notes];
    await runExclusive(() async {
      final SrsDeckTree now0 = await deckTree();
      if (now0[deckId] == null) return; // 期间已被别处删掉
      final List<String> subNow = now0.subtree(deckId);
      final String targetNow = now0.parentOf(deckId) ?? defaultDeckId;
      if (deleteCards) {
        final List<String> lateNotes = await _notesOnlyInDecks(subNow);
        deletedNotes.addAll(lateNotes);
        for (int i = 0; i < lateNotes.length; i += _deleteDeckChunk) {
          await _editEach(
            SrsEntityKind.note,
            lateNotes.sublist(i, min(i + _deleteDeckChunk, lateNotes.length)),
            SrsFieldKeys.deleted,
            deletedAt,
          );
        }
      }
      final List<String> late = await _cardIdsInDecks(subNow);
      for (int i = 0; i < late.length; i += _deleteDeckChunk) {
        await _editEach(
          SrsEntityKind.card,
          late.sublist(i, min(i + _deleteDeckChunk, late.length)),
          SrsFieldKeys.cardDeck,
          targetNow,
        );
      }
      final (int nowMs, _) = now();
      await _editEach(SrsEntityKind.deck, subNow, SrsFieldKeys.deleted, nowMs);
    });
    return deletedNotes;
  }

  /// 还没删、且卡全都归在 [deckIds] 这些牌组下的笔记（「连卡片一起删牌组」整条删掉的笔记）。
  /// 有卡在别的牌组的笔记不算：删笔记会连带那些卡。
  Future<List<String>> _notesOnlyInDecks(List<String> deckIds) async {
    final Set<String> inside = <String>{
      for (final SrsCardCacheRow c in await (db.select(
        db.srsCardsCache,
      )..where((c) => c.deckId.isIn(deckIds))).get())
        c.noteId,
    };
    final Set<String> outside = <String>{};
    for (final List<String> chunk in _chunks(inside)) {
      for (final SrsCardCacheRow c
          in await (db.select(
                db.srsCardsCache,
              )..where((c) => c.noteId.isIn(chunk) & c.deckId.isNotIn(deckIds)))
              .get()) {
        outside.add(c.noteId);
      }
    }
    final List<String> out = <String>[];
    for (final List<String> chunk in _chunks(inside.difference(outside))) {
      for (final SrsNoteCacheRow n in await (db.select(
        db.srsNotesCache,
      )..where((n) => n.id.isIn(chunk) & n.deletedAt.isNull())).get()) {
        out.add(n.id);
      }
    }
    return out;
  }

  /// 缓存里归在 [deckIds] 这些牌组下的卡。
  Future<List<String>> _cardIdsInDecks(List<String> deckIds) async => <String>[
    for (final SrsCardCacheRow c in await (db.select(
      db.srsCardsCache,
    )..where((c) => c.deckId.isIn(deckIds))).get())
      c.id,
  ];

  // ------------------------------------------------------------------ 墓碑物理清除（策略见 srs_purge.dart）

  /// 本机副本从没参与过同步：没发布过批次、没有任何同步目录的记账、没读过任何别的写入者。
  /// 这时本机的事件只有本机写的 / 导入的 / 备份并进来的，不存在「对端还要靠墓碑得知删除」的情形，
  /// 删掉的笔记可以当场清除（`srsPurgeNotesNow`）。
  bool get neverSynced =>
      !_sync.everPublished &&
      _sync.directories.isEmpty &&
      _sync.cursors.isEmpty;

  /// 墓碑清除的候选笔记：缓存里已删除的笔记，加上「只剩修改记录、没有身份记录、却有删除寄存器」的
  /// 笔记（清除之后对端晚到的同一笔记的内容修改记录；身份记录已删，它们不会进缓存）。
  /// 是否真清由 [purgeDeletedNotes] 在独占区里逐条复核。
  Future<List<String>> purgeCandidateNoteIds() async {
    final Set<String> out = <String>{
      for (final SrsNoteCacheRow n
          in await (db.select(db.srsNotesCache)..where(
                (n) =>
                    n.profileUid.equals(profileUid) & n.deletedAt.isNotNull(),
              ))
              .get())
        n.id,
    };
    final List<QueryRow> orphans = await db
        .customSelect(
          'SELECT DISTINCT e.entity_id AS id FROM srs_field_edits e '
          'WHERE e.profile_uid = ? AND e.entity_kind = ? AND e.field_key <> ? '
          'AND NOT EXISTS (SELECT 1 FROM srs_entities x WHERE x.id = e.entity_id) '
          'AND EXISTS (SELECT 1 FROM srs_field_edits d WHERE d.entity_kind = ? '
          'AND d.entity_id = e.entity_id AND d.field_key = ?)',
          variables: <Variable<Object>>[
            Variable<String>(profileUid),
            Variable<String>(SrsEntityKind.note.wire),
            Variable<String>(SrsFieldKeys.deleted),
            Variable<String>(SrsEntityKind.note.wire),
            Variable<String>(SrsFieldKeys.deleted),
          ],
          readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
            db.srsFieldEdits,
            db.srsEntities,
          },
        )
        .get();
    out.addAll(orphans.map((QueryRow r) => r.read<String>('id')));
    return out.toList()..sort();
  }

  /// 物理清除 [noteIds] 里**此刻仍是已删除、且 [eligible] 认可**的笔记（一个独占区 + 一个事务）：
  ///
  /// - 删：笔记身份记录、笔记除删除寄存器外的全部修改记录（字段 / 标签 / 来源 / 牌组 / 类型）、
  ///   笔记缓存行；它全部卡的修改记录、卡片缓存行；这些事件的本机元信息（srs_event_local，
  ///   含发件箱里还没发出去的）。
  /// - 留复习日志：统计（复习日历 / 复习量 / 时长）以日志为唯一事实，清掉会让过去的学习记录凭空消失
  ///   （用户 2026-10-23 拍板不可接受；与 Anki 删卡保留 revlog 一致）。日志每条只有几十字节，
  ///   占空间的是正文与媒体。
  /// - 留：笔记删除寄存器里的修改记录（墓碑本身，几十字节）。它让清除之后对端晚到的同一笔记的事件
  ///   照样被判为「已删除」，下次维护再清掉（见 [purgeCandidateNoteIds]），不会复活成可见笔记。
  /// - 跳过：已被恢复的；删除寄存器里有并发内容修改（「待裁决」，用户还没决定恢复还是确认删除）的；
  ///   作为前身被别的（不清除的）卡继承复习历史的卡（只留这张卡的事件）。
  ///
  /// [mediaRefsOf] 给出时，从被清除笔记的字段值里收集它们引用的媒体文件名，随结果返回
  /// （是否删文件由调用方再核对存活引用后决定）。修订号随删除的行数推进（[changeFingerprint] 变化，
  /// 自动备份 / RWKV 回放据此知道库变了）。
  Future<SrsPurgeChunk> purgeDeletedNotes(
    List<String> noteIds, {
    required SrsTombstonePredicate eligible,
    Set<String> Function(String html)? mediaRefsOf,
  }) async {
    final SrsPurgeChunk r = await _purgeDeletedNotes(
      noteIds,
      eligible: eligible,
      mediaRefsOf: mediaRefsOf,
    );
    // 事务提交之后再告诉 RWKV：清掉的卡不会再成为候选，常驻分数表里它们的项一并删掉。
    if (r.cardIds.isNotEmpty) unawaited(rwkv?.onCardsPurged(r.cardIds));
    return r;
  }

  Future<SrsPurgeChunk> _purgeDeletedNotes(
    List<String> noteIds, {
    required SrsTombstonePredicate eligible,
    Set<String> Function(String html)? mediaRefsOf,
  }) => runExclusive(
    () => db.transaction(() async {
      if (noteIds.isEmpty) return SrsPurgeChunk.empty;
      final String noteKind = SrsEntityKind.note.wire;
      final String cardKind = SrsEntityKind.card.wire;
      final Map<String, List<SrsFieldEdit>> byNote =
          <String, List<SrsFieldEdit>>{};
      for (final List<String> chunk in _chunks(noteIds)) {
        for (final SrsFieldEditRow r
            in await (db.select(db.srsFieldEdits)..where(
                  (t) => t.entityKind.equals(noteKind) & t.entityId.isIn(chunk),
                ))
                .get()) {
          (byNote[r.entityId] ??= <SrsFieldEdit>[]).add(
            SrsFieldEdit.fromJson(
              (jsonDecode(r.json) as Map).cast<String, Object?>(),
            ),
          );
        }
      }
      final Map<String, int> s = await _serverTimesFor(<String>[
        for (final List<SrsFieldEdit> l in byNote.values)
          for (final SrsFieldEdit e in l) e.id,
      ]);
      int? serverTimeOf(String id) => s[id];
      final List<String> purge = <String>[];
      final List<String> contentEditIds = <String>[];
      final Set<String> media = <String>{};
      for (final String noteId in noteIds) {
        final List<SrsFieldEdit> edits =
            byNote[noteId] ?? const <SrsFieldEdit>[];
        final SrsEntityEdits ee = SrsEntityEdits.build(
          edits,
          serverTimeOf: serverTimeOf,
        );
        final SrsRegister? del = ee[SrsFieldKeys.deleted];
        if (del == null || srsEffectiveDeletedAt(del) == null) continue;
        final List<SrsFieldEdit> content = <SrsFieldEdit>[
          for (final SrsRegister r in ee.registers)
            if (r.key != SrsFieldKeys.deleted) ...r.live,
        ];
        if (srsEditsConcurrentWithDelete(del, content).isNotEmpty) continue;
        if (!eligible(del, serverTimeOf)) continue;
        purge.add(noteId);
        for (final SrsFieldEdit e in edits) {
          if (e.fieldKey == SrsFieldKeys.deleted) continue;
          contentEditIds.add(e.id);
          final Object? v = e.value;
          if (mediaRefsOf != null &&
              v is String &&
              e.fieldKey.startsWith(_noteFieldPrefix)) {
            media.addAll(mediaRefsOf(v));
          }
        }
      }
      if (purge.isEmpty) return SrsPurgeChunk.empty;

      // 这些笔记的卡（缓存里按笔记归属；卡片本身没有身份记录，ID 由笔记派生）。
      final Set<String> cards = <String>{};
      for (final List<String> chunk in _chunks(purge)) {
        for (final SrsCardCacheRow c in await (db.select(
          db.srsCardsCache,
        )..where((c) => c.noteId.isIn(chunk))).get()) {
          cards.add(c.id);
        }
      }
      if (cards.isNotEmpty) {
        // 被不清除的卡当作前身继承历史的卡不清（它的历史还在别处生效）；留下它会让它的前身也留下。
        final Map<String, List<String>> successors = await _successorIndex();
        bool changed = true;
        while (changed) {
          changed = false;
          for (final String c in cards.toList()) {
            final List<String> succ = successors[c] ?? const <String>[];
            if (succ.any((String x) => !cards.contains(x))) {
              cards.remove(c);
              changed = true;
            }
          }
        }
      }
      final List<String> cardList = cards.toList();
      final List<String> cardEditIds = <String>[];
      for (final List<String> chunk in _chunks(cardList)) {
        for (final QueryRow r
            in await db
                .customSelect(
                  'SELECT id FROM srs_field_edits WHERE entity_kind = ? '
                  'AND entity_id IN (${List<String>.filled(chunk.length, '?').join(',')})',
                  variables: <Variable<Object>>[
                    Variable<String>(cardKind),
                    for (final String c in chunk) Variable<String>(c),
                  ],
                  readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
                    db.srsFieldEdits,
                  },
                )
                .get()) {
          cardEditIds.add(r.read<String>('id'));
        }
      }

      int events = 0;
      for (final List<String> chunk in _chunks(contentEditIds)) {
        events += await (db.delete(
          db.srsFieldEdits,
        )..where((t) => t.id.isIn(chunk))).go();
      }
      for (final List<String> chunk in _chunks(cardEditIds)) {
        events += await (db.delete(
          db.srsFieldEdits,
        )..where((t) => t.id.isIn(chunk))).go();
      }
      for (final List<String> chunk in _chunks(purge)) {
        events += await (db.delete(
          db.srsEntities,
        )..where((t) => t.id.isIn(chunk) & t.kind.equals(noteKind))).go();
        await (db.delete(
          db.srsNotesCache,
        )..where((t) => t.id.isIn(chunk))).go();
      }
      for (final List<String> chunk in _chunks(cardList)) {
        await (db.delete(
          db.srsCardsCache,
        )..where((t) => t.id.isIn(chunk))).go();
      }
      for (final List<String> chunk in _chunks(<String>[
        ...contentEditIds,
        ...cardEditIds,
        ...purge,
      ])) {
        await (db.delete(
          db.srsEventLocal,
        )..where((t) => t.eventId.isIn(chunk))).go();
      }
      // 缓存行已直接删掉；同一独占区里不可能还有等刷新的脏标记指向它们，保险起见清掉。
      _dirtyNotes.removeAll(purge);
      _dirtyCards.removeAll(cardList);
      _ankiNoteIndex = null;
      _ankiCardIndex = null;
      _revision += events == 0 ? 1 : events;
      _contentRevision++;
      _pendingMediaGc.addAll(media);
      await _saveLocal();
      return SrsPurgeChunk(
        notes: purge,
        cardIds: cardList,
        events: events,
        mediaRefs: media,
      );
    }),
  );

  /// 待回收的媒体文件名（见 [_pendingMediaGc]）。
  Set<String> get pendingMediaGc => Set<String>.unmodifiable(_pendingMediaGc);

  /// 把 [names] 移出待回收集合并落盘。只能在独占区里调：回收方在同一个独占区里核对存活引用、
  /// 删文件、再调这里，期间不会有别的写入插进来重新引用它们。
  Future<void> settlePendingMediaGc(Iterable<String> names) async {
    assert(
      identical(Zone.current[_writeZoneKey], this),
      'settlePendingMediaGc outside runExclusive',
    );
    final int before = _pendingMediaGc.length;
    _pendingMediaGc.removeAll(names);
    if (_pendingMediaGc.length != before) await _saveLocal();
  }

  /// 给 [ids] 每个实体的同一个字段键写同一个值（值没变的跳过）：现值一次预读，序号按 [ids] 的顺序
  /// 分配，一次落库。与逐个 `editField` 同结果。调用方已在独占区里。
  Future<void> _editEach(
    SrsEntityKind kind,
    List<String> ids,
    String key,
    Object? value,
  ) async {
    final Map<String, SrsEntityEdits> current = await _entityEditsMany(
      kind,
      ids,
    );
    final List<SrsFieldEdit> out = _createEdits(<SrsEditDraft>[
      for (final String id in ids)
        if (_changes(current[id]!, key, value))
          SrsEditDraft(kind, id, key, value),
    ]);
    if (out.isNotEmpty) {
      await _emit(<SrsEvent>[
        for (final SrsFieldEdit e in out) SrsEditEvent(e),
      ]);
    }
  }

  Future<SrsSchedulingConfig> schedulingConfigFor(String deckId) async =>
      _schedulingConfigIn(await deckTree(), deckId);

  SrsSchedulingConfig _schedulingConfigIn(SrsDeckTree tree, String deckId) {
    final String id = tree.effectiveDeckOf(deckId, fallback: defaultDeckId);
    return tree.schedulingConfig(id, defaultsOf: engine?.defaultParams);
  }

  // ------------------------------------------------------------------ 笔记

  /// 新建笔记（Fushi 新建时随机生成 guid；noteId 由 guid 派生）。
  Future<String> createNote({
    required String noteTypeId,
    required Map<String, String> fieldsById,
    String? deckId,
    List<String> tags = const <String>[],
    SrsSourceRef? source,
    String? guid,
    int? createdAt,
  }) => runExclusive(() async {
    final String g = guid ?? newNoteGuid();
    final String id = SrsIds.note(profileUid, g);
    // 身份记录与字段修改记录同一个事务、同一次缓存刷新（以前分两次落库，笔记先以空字段生成一遍卡）。
    final SrsEntityEdits current = await _entityEdits(SrsEntityKind.note, id);
    await _emit(
      _finalize(
        newNoteDrafts(
          noteTypeId: noteTypeId,
          fieldsById: fieldsById,
          deckId: deckId,
          tags: tags,
          source: source,
          guid: g,
          createdAt: createdAt,
          current: current,
        ),
      ),
    );
    return id;
  });

  /// 新笔记的全部事件草稿（身份记录 + 字段 / 标签 / 来源 / 牌组修改记录），**不落库、不占序号**：
  /// 交给 [importDrafts] 与别的事件攒成一批，序号在落库时才分配（Anki 包导入每批几十条笔记一个事务）。
  ///
  /// [current] 是这条笔记已有的修改记录（值相同的键不再写）；null = 调用方确定本机还没有这条笔记
  /// （导入先查过身份记录），跳过逐条读库。noteId = `SrsIds.note(profileUid, guid)`。
  List<SrsEventDraft> newNoteDrafts({
    required String noteTypeId,
    required Map<String, String> fieldsById,
    required String guid,
    String? deckId,
    List<String> tags = const <String>[],
    SrsSourceRef? source,
    int? createdAt,
    SrsEntityEdits? current,
  }) {
    final (int nowMs, _) = now();
    final String id = SrsIds.note(profileUid, guid);
    return <SrsEventDraft>[
      SrsReadyDraft(
        SrsEntityEvent(
          SrsEntityRecord(
            id: id,
            profileUid: profileUid,
            kind: SrsEntityKind.note,
            payload: <String, Object?>{
              'noteTypeId': noteTypeId,
              'guid': guid,
              'createdAt': createdAt ?? nowMs,
            },
          ),
        ),
      ),
      ...newEditDrafts(SrsEntityKind.note, id, <String, Object?>{
        for (final MapEntry<String, String> f in fieldsById.entries)
          if (f.value.isNotEmpty) SrsFieldKeys.noteField(f.key): f.value,
        if (tags.isNotEmpty) SrsFieldKeys.noteTags: tags,
        if (source != null) SrsFieldKeys.noteSource: source.toJson(),
        SrsFieldKeys.noteDeck: deckId ?? defaultDeckId,
      }, current: current),
    ];
  }

  /// 一个实体若干字段的本机修改记录草稿，**不落库、不占序号**（交给 [importDrafts] 成批落）。
  /// [current] 同 [newNoteDrafts]：给了就跳过与现值相同的键；null = 实体刚由同一批事件新建、本机没有记录
  /// ——这时草稿标成初值（[SrsEditDraft.initial]），落库时键已有记录的不落。
  List<SrsEditDraft> newEditDrafts(
    SrsEntityKind kind,
    String entityId,
    Map<String, Object?> values, {
    SrsEntityEdits? current,
  }) => <SrsEditDraft>[
    for (final MapEntry<String, Object?> e in values.entries)
      if (current == null || _changes(current, e.key, e.value))
        SrsEditDraft(kind, entityId, e.key, e.value, initial: current == null),
  ];

  /// 本 profile 某类实体的全部 ID（只读 ID 列；导入据此一次判断哪些笔记本机已有）。
  Future<Set<String>> entityIds(SrsEntityKind kind) async {
    final $SrsEntitiesTable t = db.srsEntities;
    final List<TypedResult> rows =
        await (db.selectOnly(t)
              ..addColumns(<Expression<Object>>[t.id])
              ..where(
                t.profileUid.equals(profileUid) & t.kind.equals(kind.wire),
              ))
            .get();
    return <String>{for (final TypedResult r in rows) r.read(t.id)!};
  }

  Future<void> updateNote(
    String noteId, {
    Map<String, String>? fieldsById,
    List<String>? tags,
  }) async {
    await editFields(SrsEntityKind.note, noteId, <String, Object?>{
      if (fieldsById != null)
        for (final MapEntry<String, String> f in fieldsById.entries)
          SrsFieldKeys.noteField(f.key): f.value,
      if (tags != null) SrsFieldKeys.noteTags: tags,
    });
  }

  Future<void> deleteNote(String noteId) => runExclusive(() async {
    final (int nowMs, _) = now();
    await editField(SrsEntityKind.note, noteId, SrsFieldKeys.deleted, nowMs);
  });

  /// 恢复（「删除与并发修改」待裁决项里的「恢复」也走这里）。
  Future<void> restoreNote(String noteId) =>
      editField(SrsEntityKind.note, noteId, SrsFieldKeys.deleted, null);

  /// 按 guid 找已存在的笔记（导入去重）。
  Future<String?> noteIdByGuid(String guid) async {
    final String id = SrsIds.note(profileUid, guid);
    final SrsEntityRow? row = await (db.select(
      db.srsEntities,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row?.id;
  }

  // ------------------------------------------------------------------ 卡片标志

  Future<void> setSuspended(String cardId, bool value) =>
      editField(SrsEntityKind.card, cardId, SrsFieldKeys.suspended, value);

  Future<void> buryUntil(String cardId, int? dayIndex) => editField(
    SrsEntityKind.card,
    cardId,
    SrsFieldKeys.buriedUntilDay,
    dayIndex,
  );

  Future<void> setFlag(String cardId, int flag) =>
      editField(SrsEntityKind.card, cardId, SrsFieldKeys.flag, flag);

  Future<void> moveCard(String cardId, String deckId) =>
      editField(SrsEntityKind.card, cardId, SrsFieldKeys.cardDeck, deckId);

  // ------------------------------------------------------------------ 批量（浏览页）

  /// 多个实体的多个字段一次写：一个事务、一次发件箱批次（浏览页的批量操作）。
  /// no-op 不产生记录；返回实际写出的修改记录。现值按实体分块一次预读（以前每个实体各查两次）。
  Future<List<SrsFieldEdit>> editFieldsBatch(List<SrsFieldChange> changes) =>
      runExclusive(() async {
        final Map<(SrsEntityKind, String), Map<String, Object?>> byEntity =
            <(SrsEntityKind, String), Map<String, Object?>>{};
        for (final SrsFieldChange c in changes) {
          (byEntity[(c.kind, c.entityId)] ??= <String, Object?>{})[c.key] =
              c.value;
        }
        final Map<String, SrsEntityEdits> current = await _currentEditsOf(
          byEntity.keys,
        );
        final List<SrsFieldEdit> out = _createEdits(<SrsEditDraft>[
          for (final MapEntry<(SrsEntityKind, String), Map<String, Object?>> e
              in byEntity.entries)
            for (final MapEntry<String, Object?> v in e.value.entries)
              if (_changes(
                current['${e.key.$1.wire}/${e.key.$2}']!,
                v.key,
                v.value,
              ))
                SrsEditDraft(e.key.$1, e.key.$2, v.key, v.value),
        ]);
        if (out.isNotEmpty) {
          await _emit(<SrsEvent>[
            for (final SrsFieldEdit e in out) SrsEditEvent(e),
          ]);
        }
        return out;
      });

  /// 一组卡片的缓存行（不存在的 ID 跳过）。
  Future<List<SrsCardCacheRow>> cardRows(Iterable<String> cardIds) async {
    final List<String> ids = cardIds.toSet().toList();
    final List<SrsCardCacheRow> out = <SrsCardCacheRow>[];
    for (int i = 0; i < ids.length; i += 500) {
      final List<String> chunk = ids.sublist(i, min(i + 500, ids.length));
      out.addAll(
        await (db.select(
          db.srsCardsCache,
        )..where((c) => c.id.isIn(chunk))).get(),
      );
    }
    return out;
  }

  /// 批量重置为新卡：每张一条 manual 日志，一个批次落库。已经是新卡的跳过。
  /// 返回写出的日志（撤销用）。各卡历史分块一次预读（以前每张卡各查四五次）。
  Future<List<SrsReviewLog>> resetCards(Iterable<String> cardIds) =>
      runExclusive(() async {
        final SrsDayContext day = await dayContext();
        final List<SrsCardCacheRow> rows = <SrsCardCacheRow>[
          for (final SrsCardCacheRow c in await cardRows(cardIds))
            if (c.queue != SrsQueue.newCard.wire) c,
        ];
        final Map<String, SrsCardHistory> hist = await histories(
          rows.map((SrsCardCacheRow c) => c.id),
        );
        final List<SrsReviewLog> logs = <SrsReviewLog>[
          for (final SrsCardCacheRow c in rows)
            _ops.reset(
              cardId: c.id,
              history: hist[c.id]!,
              ctx: _logContext(day),
            ),
        ];
        await _emitLogs(logs);
        return logs;
      });

  /// 批量设置到期日（cardId → 排程日序号），一个批次落库。返回写出的日志（撤销用）。
  Future<List<SrsReviewLog>> setDueDays(Map<String, int> dueDays) =>
      runExclusive(() async {
        final SrsDayContext day = await dayContext();
        final Map<String, SrsCardHistory> hist = await histories(dueDays.keys);
        final List<SrsReviewLog> logs = <SrsReviewLog>[
          for (final MapEntry<String, int> e in dueDays.entries)
            _ops.setDue(
              cardId: e.key,
              history: hist[e.key]!,
              dueDay: e.value,
              ctx: _logContext(day),
            ),
        ];
        await _emitLogs(logs);
        return logs;
      });

  /// 批量撤销日志（cardId, logId）：一个批次落库。返回撤不了的条数（那条已不是该卡最后一条
  /// 有效日志——别的设备同步来了更新的复习，铁律 B 的协议限制）。
  Future<int> undoLogs(List<(String, String)> targets) =>
      runExclusive(() async {
        final SrsDayContext day = await dayContext();
        final Map<String, SrsCardHistory> hist = await histories(<String>[
          for (final (String cardId, String _) in targets) cardId,
        ]);
        final List<SrsReviewLog> undos = <SrsReviewLog>[];
        int blocked = 0;
        for (final (String cardId, String logId) in targets) {
          final SrsReviewLog? u = _ops.undo(
            cardId: cardId,
            history: hist[cardId]!,
            targetLogId: logId,
            ctx: _logContext(day),
          );
          if (u == null) {
            blocked++;
          } else {
            undos.add(u);
          }
        }
        await _emitLogs(undos);
        return blocked;
      });

  /// 一批本机日志落库（空则什么也不做）。调用方已在独占区里。
  Future<void> _emitLogs(List<SrsReviewLog> logs) async {
    if (logs.isEmpty) return;
    await _emit(<SrsEvent>[for (final SrsReviewLog l in logs) SrsLogEvent(l)]);
  }

  // ------------------------------------------------------------------ 复习

  SrsLogContext _logContext(SrsDayContext day) =>
      SrsLogContext(profileUid: profileUid, clock: _clock, now: now, day: day);

  SrsCardOps get _ops {
    final FsrsEngine? e = engine;
    if (e == null) {
      throw StateError('FSRS native library unavailable');
    }
    return SrsCardOps(engine: e);
  }

  Future<SrsCardCacheRow?> cardRow(String cardId) => (db.select(
    db.srsCardsCache,
  )..where((c) => c.id.equals(cardId))).getSingleOrNull();

  /// 四个评分的预览。
  Future<SrsAnswerPreview> preview(String cardId) async {
    final SrsCardCacheRow c = (await cardRow(cardId))!;
    final SrsDayContext day = await dayContext();
    final SrsSchedulingConfig config = await schedulingConfigFor(c.deckId);
    return _ops.preview(
      cardId: cardId,
      history: await history(cardId),
      config: config,
      ctx: _logContext(day),
      rwkvUnavailable: config.algorithm.usesRwkv && !(rwkv?.ready ?? false),
    );
  }

  /// 评分 = 一个事务：算新状态 → 写日志 → 更新卡片缓存。返回日志（撤销栈用）。
  Future<SrsReviewLog> answer(
    String cardId,
    int rating, {
    int durationMs = 0,
  }) => runExclusive(() async {
    final SrsCardCacheRow c = (await cardRow(cardId))!;
    final SrsDayContext day = await dayContext();
    final SrsSchedulingConfig config = await schedulingConfigFor(c.deckId);
    final SrsReviewLog log = _ops.answer(
      cardId: cardId,
      history: await history(cardId),
      rating: rating,
      config: config,
      ctx: _logContext(day),
      durationMs: durationMs,
      rwkvUnavailable: config.algorithm.usesRwkv && !(rwkv?.ready ?? false),
    );
    await _emit(<SrsEvent>[SrsLogEvent(log)]);
    // RWKV 状态追加这一条（不等：它在后台 isolate 里串行执行，下一次预览前会对齐）。
    unawaited(rwkv?.onAnswered(cardId, log));
    return log;
  });

  /// 撤销一条评分；它已不是该卡最后一条有效日志（别的设备同步来了更新的复习）时返回 false。
  Future<bool> undo(String cardId, String logId) => runExclusive(() async {
    final SrsDayContext day = await dayContext();
    final SrsReviewLog? u = _ops.undo(
      cardId: cardId,
      history: await history(cardId),
      targetLogId: logId,
      ctx: _logContext(day),
    );
    if (u == null) return false;
    await _emit(<SrsEvent>[SrsLogEvent(u)]);
    return true;
  });

  Future<void> resetCard(String cardId) => runExclusive(() async {
    final SrsDayContext day = await dayContext();
    await _emit(<SrsEvent>[
      SrsLogEvent(
        _ops.reset(
          cardId: cardId,
          history: await history(cardId),
          ctx: _logContext(day),
        ),
      ),
    ]);
  });

  Future<void> setDueDay(String cardId, int dueDay) => runExclusive(() async {
    final SrsDayContext day = await dayContext();
    await _emit(<SrsEvent>[
      SrsLogEvent(
        _ops.setDue(
          cardId: cardId,
          history: await history(cardId),
          dueDay: dueDay,
          ctx: _logContext(day),
        ),
      ),
    ]);
  });

  /// 「立即重排整组」：给子树里每张复习卡写一条 reschedule 日志。牌组树只读一次、各卡历史分块
  /// 一次预读（以前每张卡各读一遍历史、各读一遍整棵牌组树，BUG-3543）。
  Future<int> rescheduleDeck(String deckId) => runExclusive(() async {
    final SrsDeckTree tree = await deckTree();
    final List<String> sub = tree.subtree(deckId);
    final SrsDayContext day = await dayContext();
    final List<SrsCardCacheRow> cards =
        await (db.select(db.srsCardsCache)..where(
              (c) => c.deckId.isIn(sub) & c.queue.equals(SrsQueue.review.wire),
            ))
            .get();
    final Map<String, SrsCardHistory> hist = await histories(
      cards.map((SrsCardCacheRow c) => c.id),
    );
    final List<SrsReviewLog> logs = <SrsReviewLog>[];
    for (final SrsCardCacheRow c in cards) {
      final SrsReviewLog? l = _ops.reschedule(
        cardId: c.id,
        history: hist[c.id]!,
        config: _schedulingConfigIn(tree, c.deckId),
        ctx: _logContext(day),
      );
      if (l != null) logs.add(l);
    }
    await _emitLogs(logs);
    return logs.length;
  });

  // ------------------------------------------------------------------ 查询

  Future<Map<int, int>> _reviewsPerDay(
    SrsDayContext day,
    int today,
    int days,
  ) async {
    final int from = day.dayStartMs(today - days + 1);
    // 只取时刻列：整行带着几百字节的 json，一个月几千条日志全搬回来只为按天计数。
    final $SrsReviewLogsTable t = db.srsReviewLogs;
    final List<TypedResult> rows =
        await (db.selectOnly(t)
              ..addColumns(<Expression<Object>>[t.occurredAt])
              ..where(
                t.profileUid.equals(profileUid) &
                    t.kind.equals(SrsLogKind.review) &
                    t.occurredAt.isBiggerOrEqualValue(from),
              ))
            .get();
    final Map<int, int> out = <int, int>{};
    for (final TypedResult r in rows) {
      final int d = day.dayIndexOf(r.read(t.occurredAt)!);
      out[d] = (out[d] ?? 0) + 1;
    }
    return out;
  }

  /// 卡「可出」的 SQL 条件：可见、未暂停、归 Fushi 排程、没埋或埋到期（绑定一个参数：今天）。
  static const String _liveSql =
      "hidden = 0 AND suspended = 0 AND scheduler = '${SrsScheduler.fushi}' "
      'AND (buried_until_day IS NULL OR buried_until_day <= ?)';

  /// `deck_id IN (?, ?, …)`；[decks] 为 null 时不限牌组。
  static String _deckInSql(Iterable<String>? decks) => decks == null
      ? ''
      : ' AND deck_id IN (${List<String>.filled(decks.length, '?').join(', ')})';

  /// 每个牌组**自己**（不含子牌组）的计数原料：在 SQL 里按牌组聚合，只回每个牌组一行。
  ///
  /// 以前把整张卡片缓存表的行（几万行）搬回 Dart 再逐张数，打开一个牌组要等一两秒；
  /// 口径与逐张数相同：可出见 [_liveSql]，队列值不认识的按新卡（[SrsQueue.parse]）。
  Future<Map<String, _DeckTally>> _deckTallies(
    _CountContext ctx, {
    Iterable<String>? decks,
    _Instant? instant,
  }) async {
    final List<String>? deckList = decks?.toList();
    // 不限牌组时整张表都要数：`+profile_uid` 让 SQLite 顺序扫表，而不是沿只有 profile
    // 一列有用的复合索引逐行回表（真实库 4.4 万张卡：40 ms 对 100 ms）。限定子树时
    // (profile_uid, deck_id) 前缀有选择性，照常走索引。
    final String profileCol = deckList == null ? '+profile_uid' : 'profile_uid';
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT deck_id, COUNT(*) AS total, '
          "SUM(CASE WHEN $_liveSql AND queue NOT IN ('learning', 'relearning', 'review') "
          'THEN 1 ELSE 0 END) AS new_avail, '
          "SUM(CASE WHEN $_liveSql AND queue IN ('learning', 'relearning') "
          'AND COALESCE(due_at, 0) <= ? THEN 1 ELSE 0 END) AS learn, '
          "SUM(CASE WHEN $_liveSql AND queue = 'review' "
          'AND COALESCE(due_day, 0) <= ? THEN 1 ELSE 0 END) AS due '
          'FROM srs_cards_cache WHERE $profileCol = ? AND hidden = 0'
          '${_deckInSql(deckList)} GROUP BY deck_id',
          variables: <Variable<Object>>[
            Variable<int>(ctx.today),
            Variable<int>(ctx.today),
            Variable<int>(ctx.nowMs + 20 * 60000),
            Variable<int>(ctx.today),
            Variable<int>(ctx.today),
            Variable<String>(profileUid),
            for (final String d in deckList ?? const <String>[])
              Variable<String>(d),
          ],
        )
        .get();
    final Map<String, _DeckTally> out = <String, _DeckTally>{
      for (final QueryRow r in rows)
        r.read<String>('deck_id'): _DeckTally()
          ..total = r.read<int>('total')
          ..newAvail = r.read<int>('new_avail')
          ..learn = r.read<int>('learn')
          ..due = r.read<int>('due'),
    };
    // RWKV-Instant 的牌组：「到期」= 此刻按 R 合格的复习卡（与 [nextCard] 实际出的卡同一口径）。
    if (instant != null) {
      for (final String d in instant.decks) {
        out[d]?.due = 0;
      }
      for (final _InstantCard c in instant.eligible) {
        out[c.deckId]?.due++;
      }
    }
    // 今天已学的新卡 / 已复习的卡只有当天那几十上百张：按主键查它们所在牌组补进各自的计数。
    // `+profile_uid` 不可省：写成普通条件时 SQLite（库里没有 ANALYZE 统计）会改走
    // profile 前缀索引把整个 profile 的卡逐行回表，一百来张卡查 200 多毫秒。
    final Set<String> touched = <String>{
      ...ctx.introducedToday,
      ...ctx.reviewedToday,
    };
    for (final List<String> chunk in _chunks(touched)) {
      final List<QueryRow> cards = await db
          .customSelect(
            'SELECT id, deck_id FROM srs_cards_cache '
            'WHERE id IN (${List<String>.filled(chunk.length, '?').join(', ')}) '
            'AND +profile_uid = ? AND hidden = 0',
            variables: <Variable<Object>>[
              for (final String id in chunk) Variable<String>(id),
              Variable<String>(profileUid),
            ],
          )
          .get();
      for (final QueryRow c in cards) {
        final String id = c.read<String>('id');
        final _DeckTally? t = out[c.read<String>('deck_id')];
        if (t == null) continue;
        if (ctx.introducedToday.contains(id)) t.newDone++;
        if (ctx.reviewedToday.contains(id)) t.reviewDone++;
      }
    }
    return out;
  }

  /// 计数用的一次性上下文：牌组树、「今天」、最近 30 天每天的复习数、今天已学的新卡 / 已复习的卡。
  Future<_CountContext> _countContext() async {
    final SrsDeckTree tree = await deckTree();
    final SrsDayContext day = await dayContext();
    final (int nowMs, _) = now();
    final int today = day.dayIndexOf(nowMs);
    final Map<int, int> perDay = await _reviewsPerDay(day, today, 30);
    final (
      Set<String> introduced,
      Set<String> reviewed,
      List<(String, int)> answers,
    ) = await _todayActivity(
      day,
      today,
    );
    return _CountContext(
      tree: tree,
      day: day,
      nowMs: nowMs,
      today: today,
      answersToday: answers,
      last30: <int>[for (int d = today - 29; d <= today; d++) perDay[d] ?? 0],
      introducedToday: introduced,
      reviewedToday: reviewed,
    );
  }

  int _depthOf(SrsDeckTree tree, String id) {
    int d = 0;
    String? p = tree.parentOf(id);
    while (p != null && d < 64) {
      d++;
      p = tree.parentOf(p);
    }
    return d;
  }

  /// 牌组树计数（对齐 Anki v3 的 limit tree，rslib scheduler/queue/limits.rs）：
  ///
  /// - 每个牌组的「今日剩余上限」= 自己的每日上限（新卡另经 [srsComputeNewCardBudget] 按复习量缩减）
  ///   − 今天在**整棵子树**里已学的新卡 / 已复习的卡（Anki 把学习计数记在卡所在牌组及其全部祖先上）；
  /// - 新卡 / 到期数自底向上：min(本牌组剩余上限, 本牌组自己的卡 + Σ 子牌组**已截断后**的数)；
  /// - 学习中（learn）不受上限截断，同样逐层求和；
  /// - 只看 [root] 这棵子树（null = 全部顶层）：点子牌组复习时祖先的上限不参与，与 Anki 一致。
  ///
  /// 以前每个牌组各自拿整棵子树的卡数去比自己的上限，子牌组的上限不往上截断，
  /// 于是会出现「子牌组都是 0、父牌组却有 50」（BUG-3502）。
  Map<String, _DeckCount> _countTree(
    _CountContext ctx,
    Map<String, _DeckTally> tallies, {
    String? root,
  }) {
    final SrsDeckTree tree = ctx.tree;
    final List<String> ids = root == null
        ? <String>[for (final SrsDeckView d in tree.decks) d.id]
        : tree.subtree(root);
    final Set<String> scope = ids.toSet();
    final Map<String, _DeckTally> own = <String, _DeckTally>{
      for (final String id in ids) id: tallies[id] ?? _DeckTally(),
    };
    final Map<String, List<String>> children = <String, List<String>>{};
    final List<String> tops = <String>[];
    for (final String id in ids) {
      final String? p = tree.parentOf(id);
      if (id != root && p != null && scope.contains(p)) {
        (children[p] ??= <String>[]).add(id);
      } else {
        tops.add(id);
      }
    }
    final Map<String, _DeckCount> out = <String, _DeckCount>{};
    // 后序遍历（树已由 SrsDeckTree 打破成环）。
    _DeckCount visit(String id) {
      final _DeckTally sub = _DeckTally()..add(own[id]!);
      int newSum = own[id]!.newAvail;
      int reviewSum = own[id]!.due;
      int learnSum = own[id]!.learn;
      for (final String c in children[id] ?? const <String>[]) {
        final _DeckCount cc = visit(c);
        sub.add(cc.subtree);
        newSum += cc.newCount;
        reviewSum += cc.reviewCount;
        learnSum += cc.learnCount;
      }
      final SrsDeckView d = tree[id]!;
      final SrsNewCardBudget budget = srsComputeNewCardBudget(
        newPerDayLimit: d.newPerDay,
        dueReviews: sub.due,
        reviewsPerDayLast30: ctx.last30,
      );
      final int newRemaining = max(0, budget.allowed - sub.newDone);
      final int reviewRemaining = max(0, d.reviewsPerDay - sub.reviewDone);
      final _DeckCount r = _DeckCount(
        subtree: sub,
        budget: budget,
        newRemaining: newRemaining,
        reviewRemaining: reviewRemaining,
        newCount: min(newRemaining, newSum),
        reviewCount: min(reviewRemaining, reviewSum),
        learnCount: learnSum,
      );
      out[id] = r;
      return r;
    }

    for (final String id in tops) {
      visit(id);
    }
    return out;
  }

  SrsDeckSummary _summaryOf(
    SrsDeckView d,
    _CountContext ctx,
    _DeckCount count,
  ) => SrsDeckSummary(
    deck: d,
    fullName: ctx.tree.fullName(d.id),
    depth: _depthOf(ctx.tree, d.id),
    parentId: ctx.tree.parentOf(d.id),
    newCount: count.newCount,
    learnCount: count.learnCount,
    reviewCount: count.reviewCount,
    newBudget: count.budget,
    totalCards: count.subtree.total,
  );

  /// 牌组列表：每个牌组（含子树）的新卡 / 学习 / 到期数。计数在 SQL 里按牌组聚合。
  Future<List<SrsDeckSummary>> deckSummaries() async {
    final _CountContext ctx = await _countContext();
    final Map<String, _DeckCount> counts = _countTree(
      ctx,
      await _deckTallies(
        ctx,
        instant: await _instantReviews(ctx, <String>[
          for (final SrsDeckView d in ctx.tree.decks) d.id,
        ]),
      ),
    );
    final Map<String?, List<SrsDeckView>> children =
        <String?, List<SrsDeckView>>{};
    for (final SrsDeckView d in ctx.tree.decks) {
      (children[ctx.tree.parentOf(d.id)] ??= <SrsDeckView>[]).add(d);
    }
    // 先序（父在前、子紧跟父）；同级按手动位置、再按名字（[SrsDeckView.compareSiblings]）。
    // 没人排过时与 Anki 按名字逐层排序同一口径——直接比全名的话「Lang2」会插进「Lang」
    // 与「Lang::JP」之间，子牌组就离开了父牌组。
    final List<SrsDeckSummary> out = <SrsDeckSummary>[];
    void visit(String? parent) {
      final List<SrsDeckView> level = (children[parent] ?? <SrsDeckView>[])
        ..sort(SrsDeckView.compareSiblings);
      for (final SrsDeckView d in level) {
        out.add(_summaryOf(d, ctx, counts[d.id]!));
        visit(d.id);
      }
    }

    visit(null);
    return out;
  }

  /// 单个牌组（含子树）的计数，与 [deckSummaries] 里同一牌组的那一行相同：
  /// 一个牌组的计数只取决于它自己的子树，祖先的上限不参与（见 [_countTree]）。
  /// 复习页只要当前牌组这一行，不必把所有牌组都数一遍。
  Future<SrsDeckSummary?> deckSummary(String deckId) async {
    final _CountContext ctx = await _countContext();
    final SrsDeckView? d = ctx.tree[deckId];
    if (d == null) return null;
    final List<String> sub = ctx.tree.subtree(deckId);
    final Map<String, _DeckCount> counts = _countTree(
      ctx,
      await _deckTallies(
        ctx,
        decks: sub,
        instant: await _instantReviews(ctx, sub),
      ),
      root: deckId,
    );
    return _summaryOf(d, ctx, counts[deckId]!);
  }

  /// 牌组列表里收起 / 展开子牌组（Anki 的 deck collapsed）。走修改记录，随同步到其它设备；
  /// 并发开合不进冲突记录（[SrsFieldClass.viewState]）。
  Future<void> setDeckCollapsed(String deckId, bool collapsed) async {
    await editField(
      SrsEntityKind.deck,
      deckId,
      SrsFieldKeys.deckCollapsed,
      collapsed,
    );
  }

  /// 把牌组（连同子树）挪到 [newParentId] 下、末尾；null = 顶层（Anki 拖放牌组同语义）。
  /// 见 [placeDeck]。
  Future<SrsDeckMoveResult> moveDeck(String deckId, String? newParentId) =>
      placeDeck(deckId, parentId: newParentId);

  /// 把牌组（连同子树）放到 [parentId] 下（null = 顶层）、排在同级的 [beforeId] 前面
  /// （null = 排最后）。拖放与「上移 / 下移」都走这里。
  ///
  /// 父牌组只改父字段，ID 不变（卡、设置、同步身份都跟着走）；同级顺序给新父牌组下
  /// 的全部同级重新编排位置（[SrsFieldKeys.deckPosition]，只写变了的）。拒绝的情形返回
  /// 对应 [SrsDeckMoveResult]、不写库：挪到自己或自己的子孙下（本地成环；跨设备并发
  /// 成环由 [SrsDeckTree] 确定性打破）、目标下已有同名牌组、[beforeId] 不是目标下的同级。
  Future<SrsDeckMoveResult> placeDeck(
    String deckId, {
    required String? parentId,
    String? beforeId,
  }) => runExclusive(() async {
    final SrsDeckTree tree = await deckTree();
    final SrsDeckView? deck = tree[deckId];
    if (deck == null || (parentId != null && tree[parentId] == null)) {
      return SrsDeckMoveResult.missing;
    }
    for (String? p = parentId; p != null; p = tree.parentOf(p)) {
      if (p == deckId) return SrsDeckMoveResult.intoOwnSubtree;
    }
    final bool reparent = tree.parentOf(deckId) != parentId;
    final List<SrsDeckView> siblings = <SrsDeckView>[
      for (final SrsDeckView d in tree.decks)
        if (d.id != deckId && tree.parentOf(d.id) == parentId) d,
    ]..sort(SrsDeckView.compareSiblings);
    if (reparent && siblings.any((SrsDeckView d) => d.name == deck.name)) {
      return SrsDeckMoveResult.nameTaken;
    }
    final int at = beforeId == null
        ? siblings.length
        : siblings.indexWhere((SrsDeckView d) => d.id == beforeId);
    if (at < 0) return SrsDeckMoveResult.missing;
    final List<SrsDeckView> ordered = <SrsDeckView>[...siblings]
      ..insert(at, deck);
    final List<SrsDeckView> before = <SrsDeckView>[
      for (final SrsDeckView d in tree.decks)
        if (tree.parentOf(d.id) == parentId) d,
    ]..sort(SrsDeckView.compareSiblings);
    final bool reordered =
        before.length != ordered.length ||
        <int>[
          for (int i = 0; i < ordered.length; i++) i,
        ].any((int i) => before[i].id != ordered[i].id);
    if (!reparent && !reordered) return SrsDeckMoveResult.unchanged;
    if (reparent) {
      await editField(
        SrsEntityKind.deck,
        deckId,
        SrsFieldKeys.deckParent,
        parentId,
      );
    }
    // 只换父牌组（没指定位置）、新同级又都没手动排过：保持「按名字」的缺省排法，
    // 不给整组写位置。显式排序（[beforeId] 或同父下挪到末尾）一律写。
    final bool keepNameOrder =
        reparent &&
        beforeId == null &&
        siblings.every((SrsDeckView d) => d.position == null);
    if (reordered && !keepNameOrder) {
      for (int i = 0; i < ordered.length; i++) {
        await editField(
          SrsEntityKind.deck,
          ordered[i].id,
          SrsFieldKeys.deckPosition,
          i,
        );
      }
    }
    return SrsDeckMoveResult.moved;
  });

  /// 今天的活动：从新卡学起的卡（新卡配额）与复习了的复习卡（复习上限）。
  /// 今天已学的新卡、已复习的卡，以及今天的全部作答（卡, 时刻）按时刻升序（RWKV-Instant 的
  /// 同日间隔守卫数「这之后别的卡的作答」用）。
  Future<(Set<String>, Set<String>, List<(String, int)>)> _todayActivity(
    SrsDayContext day,
    int today,
  ) async {
    final int from = day.dayStartMs(today);
    // 只取要的列；正文 json 只有学习步那几条要看（是不是第一次学），其余行不读不解码。
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT card_id, occurred_at, review_type, '
          'CASE WHEN review_type = ? THEN json END AS j '
          'FROM srs_review_logs '
          'WHERE profile_uid = ? AND kind = ? AND occurred_at >= ? '
          'ORDER BY occurred_at',
          variables: <Variable<Object>>[
            Variable<String>(SrsReviewType.learn),
            Variable<String>(profileUid),
            Variable<String>(SrsLogKind.review),
            Variable<int>(from),
          ],
          readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
            db.srsReviewLogs,
          },
        )
        .get();
    final Set<String> introduced = <String>{};
    final Set<String> reviewed = <String>{};
    final List<(String, int)> answers = <(String, int)>[];
    for (final QueryRow r in rows) {
      final String cardId = r.read<String>('card_id');
      answers.add((cardId, r.read<int>('occurred_at')));
      final String type = r.read<String>('review_type');
      if (type == SrsReviewType.review) reviewed.add(cardId);
      final String? j = r.read<String?>('j');
      if (j == null) continue;
      final Object? res = (jsonDecode(j) as Map)['res'];
      if (res is Map && res['reps'] == 1) introduced.add(cardId);
    }
    return (introduced, reviewed, answers);
  }

  /// 新卡出卡顺序（[nextCard] 与「按词频重排新卡」共用这一处）：排过的卡在前、按位置
  /// 升序；没排过的（[SrsCardCacheRow.newPosition] 为 null）在后、按（笔记创建时刻,
  /// cardId）——从没重排过的库出卡顺序与加位置之前逐张相同。位置相同再按后者。
  static int compareNewCardOrder(SrsCardCacheRow a, SrsCardCacheRow b) {
    final int? pa = a.newPosition;
    final int? pb = b.newPosition;
    if (pa != pb) {
      if (pa == null) return 1;
      if (pb == null) return -1;
      return pa.compareTo(pb);
    }
    final int byCreated = a.noteCreatedAt.compareTo(b.noteCreatedAt);
    if (byCreated != 0) return byCreated;
    return a.id.compareTo(b.id);
  }

  /// [deckFullName]（「父::子」全名；同名牌组全部算上）及其全部子牌组里的可见新卡（含暂停 /
  /// 搁置的：位置与它们无关），按 [compareNewCardOrder] 排好。笔记已删 / 类型缺失的卡跳过。
  /// 「按词频重排新卡」的取卡步，对应 AnkiConnect 的 `deck:… is:new` + `cardsInfo`。
  Future<List<SrsNewCardEntry>> newCardsInDeck(String deckFullName) async {
    final SrsDeckTree tree = await deckTree();
    final Set<String> sub = <String>{
      for (final SrsDeckView d in tree.decks)
        if (tree.fullName(d.id) == deckFullName) ...tree.subtree(d.id),
    };
    if (sub.isEmpty) return const <SrsNewCardEntry>[];
    final List<SrsCardCacheRow> rows =
        await (db.select(db.srsCardsCache)..where(
                (c) =>
                    c.profileUid.equals(profileUid) &
                    c.deckId.isIn(sub) &
                    c.hidden.equals(false) &
                    c.queue.equals(SrsQueue.newCard.wire),
              ))
              .get()
          ..sort(compareNewCardOrder);
    if (rows.isEmpty) return const <SrsNewCardEntry>[];
    final Map<String, SrsNoteView?> notesById = await notes(<String>[
      for (final SrsCardCacheRow c in rows) c.noteId,
    ]);
    final Map<String, SrsNoteTypeView?> typesById = await noteTypesById(
      <String>{
        for (final SrsNoteView? n in notesById.values)
          if (n != null) n.noteTypeId,
      },
    );
    int next = 0;
    for (final SrsCardCacheRow c in rows) {
      final int? pos = c.newPosition;
      if (pos != null && pos > next) next = pos;
    }
    final List<SrsNewCardEntry> out = <SrsNewCardEntry>[];
    for (final SrsCardCacheRow c in rows) {
      final SrsNoteView? n = notesById[c.noteId];
      if (n == null || n.deletedAt != null) continue;
      final SrsNoteTypeView? t = typesById[n.noteTypeId];
      if (t == null) continue;
      final int ord = t.isCloze
          ? max(0, c.clozeOrd - 1)
          : (t.templates
                    .where((SrsTemplateDef x) => x.id == c.templateId)
                    .firstOrNull
                    ?.ord ??
                0);
      out.add(
        SrsNewCardEntry(
          card: c,
          note: n,
          noteType: t,
          ord: ord,
          position: c.newPosition ?? ++next,
        ),
      );
    }
    return out;
  }

  /// 写新卡位置（cardId → 位置）：一个事务、一次发件箱批次，每张卡一条 `newPos` 修改记录
  /// （值没变的不写）。**只写此刻仍是可见新卡的那些**——学过的卡位置不起作用，写了只是
  /// 无用的同步行；返回实际被接受的 cardId（含值没变而没产生记录的）。
  Future<Set<String>> setNewCardPositions(Map<String, int> positions) async {
    if (positions.isEmpty) return const <String>{};
    final Set<String> accepted = <String>{
      for (final SrsCardCacheRow c in await cardRows(positions.keys))
        if (!c.hidden && c.queue == SrsQueue.newCard.wire) c.id,
    };
    await editFieldsBatch(<SrsFieldChange>[
      for (final String id in accepted)
        SrsFieldChange(
          SrsEntityKind.card,
          id,
          SrsFieldKeys.cardNewPosition,
          positions[id],
        ),
    ]);
    return accepted;
  }

  /// [_instantReviews] 的短时缓存：同一修订号、同一组牌组，30 秒内复用（牌组计数与出卡是同一步的
  /// 两次调用；R 随时间变化很慢，作答后修订号一变就重算——上游默认每答一题刷新一次）。
  /// [untilMs] 另截在最早一张「只因间隔秒数不够被暂缓」的卡解禁的时刻：间隔秒数可调（以前写死
  /// 30 秒，恰好与 30 秒的复用期重合），短于 30 秒时不能让缓存把那张卡多挡一阵。
  ({String key, int atMs, int untilMs, _Instant value})? _instantCache;

  /// RWKV-Instant 的复习选卡（上游 kuma3 `rslib/src/scheduler/rwkv.rs` 与
  /// `scheduler/queue/builder/gathering.rs`）。[decks] 里算法是 RWKV 的牌组，其可出复习卡**不看
  /// 到期日**，按此刻的回忆率 R（即时头，以当前状态查询）选：
  /// - R ≤ 卡所在牌组的目标保留率才合格（上游 `score > target` → Blocked），R 不是有限值不合格；
  /// - 同日重复的间隔守卫（牌组的 [SrsRwkvQueueSettings]，上游默认 30 秒 / 5 次）：今天答过的卡，
  ///   距上次作答不足 `repeatMinSeconds` 秒，或这之后 [decks] 里别的卡的作答不足 `repeatMinReviews`
  ///   次 → 暂缓；
  /// - 每天最少复习数（`minReviewsPerDay`，上游默认 0 = 不启用，上游 `gather_rwkv_review_minimum_cards`）：
  ///   某牌组今天复习过的卡加上合格卡仍不到这个数时，从「只因 R 高于目标保留率被挡」的卡里按 R
  ///   升序补足（间隔守卫照样生效）。默认关：R 都高于目标时队列为空，正是模型认为都还记得（即时头
  ///   在真实间隔上校准良好，见 native/fushi_rwkv/README.md），想每天保底复习的人自己打开；
  /// - 合格的按 R 升序（上游默认排序），每日复习上限照常截断。
  /// 学习 / 重学 / 新卡照旧。存下的到期日由 FSRS-7 写，只给统计 / 同步 / RWKV 不可用时用。
  ///
  /// 返回 null = [decks] 里没有 RWKV 牌组，或 RWKV 现在用不了（没装配 / 没准备好 / 出错）：
  /// 这些牌组照旧按到期日排队。
  Future<_Instant?> _instantReviews(
    _CountContext ctx,
    Iterable<String> decks,
  ) async {
    final SrsRwkvScheduling? source = rwkv;
    if (source == null) return null;
    final Map<String, double> targets = <String, double>{
      for (final String d in decks)
        if (_schedulingConfigIn(ctx.tree, d) case final SrsSchedulingConfig c
            when c.algorithm.usesRwkv)
          d: c.desiredRetention,
    };
    if (targets.isEmpty) return null;
    // 排队设置与目标保留率同一条继承（参数归属的 own 祖先）。
    final Map<String, SrsRwkvQueueSettings> queueOf =
        <String, SrsRwkvQueueSettings>{
          for (final String d in targets.keys)
            d: ctx.tree
                .paramsOwner(
                  ctx.tree.effectiveDeckOf(d, fallback: defaultDeckId),
                )
                .rwkvQueue,
        };
    // 牌组设置的改动会改变修订号（[changeFingerprint]），不必单独进缓存键。
    final String key =
        '${await changeFingerprint()}|${ctx.today}|'
        '${(targets.entries.map((MapEntry<String, double> e) => '${e.key}=${e.value}').toList()..sort()).join(',')}';
    final ({String key, int atMs, int untilMs, _Instant value})? cached =
        _instantCache;
    if (cached != null &&
        cached.key == key &&
        ctx.nowMs >= cached.atMs &&
        ctx.nowMs < cached.untilMs) {
      return cached.value;
    }
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT id, note_id, deck_id, last_log_id, last_reviewed_at '
          'FROM srs_cards_cache WHERE profile_uid = ? AND $_liveSql'
          "${_deckInSql(targets.keys)} AND queue = 'review'",
          variables: <Variable<Object>>[
            Variable<String>(profileUid),
            Variable<int>(ctx.today),
            for (final String d in targets.keys) Variable<String>(d),
          ],
        )
        .get();
    final List<SrsRwkvCandidate> candidates = <SrsRwkvCandidate>[
      for (final QueryRow r in rows)
        SrsRwkvCandidate(
          id: r.read<String>('id'),
          noteId: r.read<String>('note_id'),
          deckId: r.read<String>('deck_id'),
          lastLogId: r.read<String?>('last_log_id'),
        ),
    ];
    final List<double>? scores = await source.instantRetrievability(
      candidates,
      nowMs: ctx.nowMs,
    );
    if (scores == null || scores.length != candidates.length) return null;

    // 间隔守卫只关心今天答过的卡；「别的卡的作答」只数 [decks] 里的卡。每天最少复习数要知道今天
    // 复习过的卡各在哪个牌组（与每日复习上限同一口径：[_CountContext.reviewedToday]）。
    final int dayStart = ctx.day.dayStartMs(ctx.today);
    final bool anyMinimum = queueOf.values.any(
      (SrsRwkvQueueSettings q) => q.minReviewsPerDay > 0,
    );
    final Map<String, String> answeredDeck = <String, String>{};
    if (anyMinimum ||
        rows.any(
          (QueryRow r) => (r.read<int?>('last_reviewed_at') ?? 0) >= dayStart,
        )) {
      final Set<String> answered = <String>{
        for (final (String id, int _) in ctx.answersToday) id,
        ...ctx.reviewedToday,
      };
      for (final List<String> chunk in _chunks(answered)) {
        final List<QueryRow> found = await db
            .customSelect(
              'SELECT id, deck_id FROM srs_cards_cache '
              'WHERE id IN (${List<String>.filled(chunk.length, '?').join(', ')}) '
              'AND +profile_uid = ?',
              variables: <Variable<Object>>[
                for (final String id in chunk) Variable<String>(id),
                Variable<String>(profileUid),
              ],
            )
            .get();
        for (final QueryRow f in found) {
          answeredDeck[f.read<String>('id')] = f.read<String>('deck_id');
        }
      }
    }
    final Set<String> deckSet = decks.toSet();
    int untilMs = ctx.nowMs + 30000;
    bool spaced(String id, int? last, SrsRwkvQueueSettings q) {
      if (last == null || last < dayStart) return true;
      final int unblockAt = last + q.repeatMinSeconds * 1000;
      if (ctx.nowMs < unblockAt) {
        if (unblockAt < untilMs) untilMs = unblockAt;
        return false;
      }
      if (q.repeatMinReviews <= 0) return true;
      int others = 0;
      for (final (String other, int at) in ctx.answersToday) {
        if (at > last &&
            other != id &&
            deckSet.contains(answeredDeck[other]) &&
            ++others >= q.repeatMinReviews) {
          return true;
        }
      }
      return false;
    }

    final List<_InstantCard> eligible = <_InstantCard>[];
    // 只因 R 高于目标保留率被挡、间隔守卫已过的卡：每天最少复习数从这里补。
    final List<_InstantCard> aboveTarget = <_InstantCard>[];
    for (int i = 0; i < candidates.length; i++) {
      final SrsRwkvCandidate c = candidates[i];
      final double r = scores[i];
      if (!r.isFinite) continue;
      final SrsRwkvQueueSettings q = queueOf[c.deckId]!;
      if (!spaced(c.id, rows[i].read<int?>('last_reviewed_at'), q)) continue;
      (r > targets[c.deckId]! ? aboveTarget : eligible).add((
        id: c.id,
        deckId: c.deckId,
        r: r,
      ));
    }
    if (anyMinimum && aboveTarget.isNotEmpty) {
      final Map<String, int> remaining = <String, int>{
        for (final MapEntry<String, SrsRwkvQueueSettings> e in queueOf.entries)
          if (e.value.minReviewsPerDay > 0) e.key: e.value.minReviewsPerDay,
      };
      void take(String deckId) {
        final int? left = remaining[deckId];
        if (left != null) remaining[deckId] = left - 1;
      }

      for (final String id in ctx.reviewedToday) {
        if (answeredDeck[id] case final String deck) take(deck);
      }
      for (final _InstantCard c in eligible) {
        take(c.deckId);
      }
      aboveTarget.sort(_compareInstant);
      for (final _InstantCard c in aboveTarget) {
        final int left = remaining[c.deckId] ?? 0;
        if (left <= 0) continue;
        eligible.add(c);
        remaining[c.deckId] = left - 1;
      }
    }
    eligible.sort(_compareInstant);
    final _Instant value = _Instant(targets.keys.toSet(), eligible);
    _instantCache = (key: key, atMs: ctx.nowMs, untilMs: untilMs, value: value);
    return value;
  }

  /// RWKV-Instant 的出卡顺序：R 升序，同 R 按 id 定序（全确定性）。
  static int _compareInstant(_InstantCard a, _InstantCard b) {
    final int byR = a.r.compareTo(b.r);
    return byR != 0 ? byR : a.id.compareTo(b.id);
  }

  /// 牌组 [deckId] 现在按 RWKV-Instant 排队：算法是 RWKV 且 RWKV 可用。这时它的复习卡没有有意义的
  /// 到期日（存下的那个只在 RWKV 不可用时排队），统计 / 浏览 / 词状态据此不按到期日解读。
  bool instantActiveFor(SrsDeckTree tree, String deckId) =>
      (rwkv?.ready ?? false) &&
      _schedulingConfigIn(tree, deckId).algorithm.usesRwkv;

  /// RWKV-Instant 此刻会出的复习卡（与 [nextCard] / 牌组计数同口径）：浏览器的 `is:due` 用。
  /// RWKV 用不了时 null——RWKV 牌组这时照旧按存下的到期日排队，调用方也按到期日算。
  Future<Set<String>?> instantDueCardIds() async {
    final _CountContext ctx = await _countContext();
    final _Instant? instant = await _instantReviews(ctx, <String>[
      for (final SrsDeckView d in ctx.tree.decks) d.id,
    ]);
    return instant == null
        ? null
        : <String>{for (final _InstantCard c in instant.eligible) c.id};
  }

  /// [rows]（RWKV 牌组的复习卡）此刻的 RWKV 回忆率：统计页的可提取度用。RWKV 用不了时 null。
  Future<Map<String, double>?> instantRetrievabilityOf(
    List<SrsCardCacheRow> rows,
  ) async {
    final SrsRwkvScheduling? source = rwkv;
    if (source == null || !source.ready) return null;
    if (rows.isEmpty) return const <String, double>{};
    final List<double>? scores = await source
        .instantRetrievability(<SrsRwkvCandidate>[
          for (final SrsCardCacheRow r in rows)
            SrsRwkvCandidate(
              id: r.id,
              noteId: r.noteId,
              deckId: r.deckId,
              lastLogId: r.lastLogId,
            ),
        ], nowMs: now().$1);
    if (scores == null || scores.length != rows.length) return null;
    return <String, double>{
      for (int i = 0; i < rows.length; i++) rows[i].id: scores[i],
    };
  }

  /// 下一张要复习的卡：到期的学习卡 → 到期复习卡（可提取度从低到高）→ 新卡（[compareNewCardOrder]
  /// 的同序 SQL：排过位置的在前按位置升序，没排过的在后按（笔记创建时刻, cardId））。
  /// 计数按牌组在 SQL 里聚合，三类候选各由一条 `LIMIT 1` 查询在 SQL 里挑出，
  /// 不把子树里几千上万张卡的行搬回 Dart。
  Future<String?> nextCard(
    String deckId, {
    Set<String> exclude = const <String>{},
  }) async {
    final _CountContext ctx = await _countContext();
    final SrsDeckView? deck = ctx.tree[deckId];
    if (deck == null) return null;
    final List<String> sub = ctx.tree.subtree(deckId);
    final _Instant? instant = await _instantReviews(ctx, sub);
    final Map<String, _DeckCount> counts = _countTree(
      ctx,
      await _deckTallies(ctx, decks: sub, instant: instant),
      root: deckId,
    );
    final _DeckCount sum = counts[deckId]!;
    // 一张卡能出，当且仅当它所在牌组到所点牌组这一路上每一层都还有剩余上限（Anki v3 的 limit tree；
    // 层层上限构成层状拟阵，按任何顺序贪心取都恰好取到 sum 的数，列表数字与实际出卡一致）。
    bool pathHasRoom(String cardDeck, int Function(_DeckCount c) remaining) {
      String? cur = cardDeck;
      int guard = 0;
      while (cur != null && guard++ < 64) {
        final _DeckCount? c = counts[cur];
        if (c == null || remaining(c) <= 0) return false;
        if (cur == deckId) return true;
        cur = ctx.tree.parentOf(cur);
      }
      return false;
    }

    final int nowMs = ctx.nowMs;
    final List<String> ex = exclude.toList();
    // 子树里一条「可出 + 条件」的候选，按 [orderBy] 取第一张。
    Future<(String, int?)?> pick(
      Iterable<String> decks,
      String condition,
      String orderBy,
      List<Variable<Object>> vars, {
      List<Variable<Object>> orderVars = const <Variable<Object>>[],
    }) async {
      final List<String> deckList = decks.toList();
      if (deckList.isEmpty) return null;
      final String notIn = ex.isEmpty
          ? ''
          : ' AND id NOT IN (${List<String>.filled(ex.length, '?').join(', ')})';
      final QueryRow? row = await db
          .customSelect(
            'SELECT id, due_at FROM srs_cards_cache '
            'WHERE profile_uid = ? AND $_liveSql${_deckInSql(deckList)} '
            'AND $condition$notIn ORDER BY $orderBy LIMIT 1',
            variables: <Variable<Object>>[
              Variable<String>(profileUid),
              Variable<int>(ctx.today),
              for (final String d in deckList) Variable<String>(d),
              ...vars,
              for (final String id in ex) Variable<String>(id),
              ...orderVars,
            ],
          )
          .getSingleOrNull();
      return row == null
          ? null
          : (row.read<String>('id'), row.read<int?>('due_at'));
    }

    final (String, int?)? learning = await pick(
      sub,
      "queue IN ('learning', 'relearning') AND COALESCE(due_at, 0) <= ?",
      'COALESCE(due_at, 0), id',
      <Variable<Object>>[Variable<int>(nowMs + 20 * 60000)],
    );
    if (learning != null && (learning.$2 ?? 0) <= nowMs) return learning.$1;
    if (sum.reviewCount > 0) {
      // RWKV-Instant 的牌组：合格的卡已按 R 升序，取第一张路径上还有上限的。
      final Set<String> byR = instant?.decks ?? const <String>{};
      _InstantCard? instantBest;
      for (final _InstantCard c
          in instant?.eligible ?? const <_InstantCard>[]) {
        if (exclude.contains(c.id)) continue;
        if (pathHasRoom(c.deckId, (_DeckCount x) => x.reviewRemaining)) {
          instantBest = c;
          break;
        }
      }
      // 其余牌组按到期日；复习排序只需单调近似：FSRS 遗忘曲线 R = (1 + t/(9S))^-1，可提取度低的先出。
      final (String, int?)? due = await pick(
        sub.where(
          (String d) =>
              !byR.contains(d) &&
              pathHasRoom(d, (_DeckCount x) => x.reviewRemaining),
        ),
        "queue = 'review' AND COALESCE(due_day, 0) <= ?",
        '1.0 / (1.0 + (CASE WHEN last_reviewed_at IS NULL THEN 0.0 '
            'ELSE (? - last_reviewed_at) / 86400000.0 END) '
            '/ (9.0 * COALESCE(stability, 1.0))), id',
        <Variable<Object>>[Variable<int>(ctx.today)],
        orderVars: <Variable<Object>>[Variable<int>(nowMs)],
      );
      if (instantBest == null) {
        if (due != null) return due.$1;
      } else if (due == null) {
        return instantBest.id;
      } else {
        // 子树里 RWKV 与 FSRS 牌组混排：两边各自的「此刻 R」比，低的先出。
        final SrsCardCacheRow? row = await cardRow(due.$1);
        final int? last = row?.lastReviewedAt;
        final double days = last == null ? 0 : (nowMs - last) / 86400000.0;
        final double fsrsR =
            1.0 / (1.0 + days / (9.0 * (row?.stability ?? 1.0)));
        return fsrsR < instantBest.r ? due.$1 : instantBest.id;
      }
    }
    if (sum.newCount > 0) {
      final (String, int?)? fresh = await pick(
        sub.where(
          (String d) => pathHasRoom(d, (_DeckCount x) => x.newRemaining),
        ),
        "queue = 'new'",
        // 与 [compareNewCardOrder] 同序：NULL 位置排在最后。
        'new_position IS NULL, new_position, note_created_at, id',
        const <Variable<Object>>[],
      );
      if (fresh != null) return fresh.$1;
    }
    return learning?.$1;
  }

  Future<SrsCardDetail?> cardDetail(String cardId) async {
    final SrsCardCacheRow? c = await cardRow(cardId);
    if (c == null) return null;
    final SrsNoteView? n = await note(c.noteId);
    if (n == null) return null;
    final SrsNoteTypeView? t = await noteType(n.noteTypeId);
    if (t == null) return null;
    final SrsTemplateDef? tpl = t.templates
        .where((SrsTemplateDef x) => x.id == c.templateId)
        .firstOrNull;
    final SrsDeckTree tree = await deckTree();
    return SrsCardDetail(
      card: c,
      note: n,
      noteType: t,
      template: tpl,
      deckName: tree.effectiveDeckNameOf(c.deckId, fallback: defaultDeckId),
    );
  }

  /// 渲染卡面（模板正文里的 fieldId 引用换回名字后交给 Anki 渲染器）。
  ///
  /// 调用方刚取过这张卡的 [cardDetail] 时传进来（[detail]），不再读第二遍（复习页出题 / 预取）。
  Future<SrsRenderedCard?> renderCard(
    String cardId, {
    SrsCardDetail? detail,
  }) async {
    assert(detail == null || detail.card.id == cardId);
    final SrsCardDetail? d = detail ?? await cardDetail(cardId);
    final SrsTemplateDef? tpl = d?.template;
    if (d == null || tpl == null) return null;
    final Map<String, String> idToName = _idToName(d.noteType);
    final String front = templateIdsToNames(tpl.front, idToName);
    final String back = templateIdsToNames(tpl.back, idToName);
    // 共享样式引用先展开回内联 `<style>`：渲染结果与去重前逐字节相同（卡面再按内容哈希
    // 只登记一次样式）。样式文件还没同步到时去掉引用行，不让 WebView 去请求相对地址。
    final Map<String, String> fields = await expandFields(
      _fieldsByName(d.note, d.noteType),
      dropMissing: true,
    );
    final AnkiCardSpecialFields specials = AnkiCardSpecialFields(
      tags: d.note.tags,
      deckName: d.deckName,
      noteTypeName: d.noteType.name,
      cardName: tpl.name,
      cardFlag: d.card.flag,
      cardId: d.card.id,
    );
    final AnkiRenderedCard r = renderAnkiCard(
      questionTemplate: front,
      answerTemplate: back,
      noteFields: fields,
      cardOrd: d.noteType.isCloze ? d.card.clozeOrd - 1 : tpl.ord,
      isCloze: d.noteType.isCloze,
      specials: specials,
    );
    // 原生卡面画不全的媒体（SVG / 远程图片、Picture 里的杂项内容）留在整面 WebView
    // （同一份模板），见 srs_fushi_card_native_media。
    final String? definitions = srsFushiCardNativeDefinitions(
      builtinKey: d.noteType.builtinKey,
      front: front,
      back: back,
      css: d.noteType.css,
      fieldsByName: fields,
      cardOrd: tpl.ord,
      specials: specials,
    );
    return SrsRenderedCard(
      question: r.question,
      answer: r.answer,
      css: d.noteType.css,
      isEmpty: r.isEmpty,
      fields: fields,
      fushiCardDefinitions: definitions,
    );
  }

  /// 词状态查询（B-3）：按 termKey（与可选读音）索引。一个词多张卡时取最需要复习的一张，带卡数。
  ///
  /// 一批词一条 JOIN（笔记缓存 × 卡片缓存，按 termKey 走 idx_srs_notes_cache_term，只取要用的列），
  /// 牌组树也只取一次（以前每个词两次查询，命中时还在循环里各取一次牌组树）。
  Future<Map<String, SrsTermStatus>> lookupTermStatus(
    List<SrsTermQuery> terms,
  ) async {
    final Map<String, SrsTermStatus> out = <String, SrsTermStatus>{};
    final Set<String> keys = <String>{
      for (final SrsTermQuery q in terms)
        if (q.termKey.isNotEmpty) q.termKey,
    };
    if (keys.isEmpty) return out;
    // termKey → 命中的可见卡（带笔记的读音键）。
    final Map<String, List<({String readingKey, QueryRow row})>> byKey =
        <String, List<({String readingKey, QueryRow row})>>{};
    for (final List<String> chunk in _chunks(keys)) {
      final List<QueryRow> rows = await db
          .customSelect(
            'SELECT n.term_key AS term_key, n.reading_key AS reading_key, '
            'c.id AS id, c.note_id AS note_id, c.queue AS queue, '
            'c.suspended AS suspended, c.deck_id AS deck_id, '
            'c.due_day AS due_day, c.due_at AS due_at '
            'FROM srs_notes_cache n '
            'JOIN srs_cards_cache c ON c.note_id = n.id '
            'WHERE n.profile_uid = ? '
            'AND n.term_key IN (SELECT value FROM json_each(?)) '
            'AND n.deleted_at IS NULL AND c.hidden = 0',
            variables: <Variable<Object>>[
              Variable<String>(profileUid),
              Variable<String>(jsonEncode(chunk)),
            ],
            readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
              db.srsNotesCache,
              db.srsCardsCache,
            },
          )
          .get();
      for (final QueryRow r in rows) {
        (byKey[r.read<String>('term_key')] ??=
                <({String readingKey, QueryRow row})>[])
            .add((readingKey: r.read<String>('reading_key'), row: r));
      }
    }
    if (byKey.isEmpty) return out;
    final SrsDeckTree tree = await deckTree();
    for (final SrsTermQuery q in terms) {
      final List<({String readingKey, QueryRow row})>? hits = byKey[q.termKey];
      if (hits == null) continue;
      final String rk = q.readingKey;
      final List<QueryRow> cards = <QueryRow>[
        for (final ({String readingKey, QueryRow row}) h in hits)
          if (rk.isEmpty || h.readingKey.isEmpty || h.readingKey == rk) h.row,
      ];
      if (cards.isEmpty) continue;
      final List<SrsTermStatus> st = <SrsTermStatus>[
        for (final QueryRow c in cards)
          SrsTermStatus(
            cardId: c.read<String>('id'),
            noteId: c.read<String>('note_id'),
            queue: SrsQueue.parse(c.read<String>('queue')),
            suspended: c.read<bool>('suspended'),
            deckId: c.read<String>('deck_id'),
            cardCount: cards.length,
            dueDay: c.read<int?>('due_day'),
            dueAt: c.read<int?>('due_at'),
            byRecall: instantActiveFor(tree, c.read<String>('deck_id')),
          ),
      ]..sort(srsTermUrgencyCompare);
      out[q.expression] = st.first;
    }
    return out;
  }

  /// 笔记缓存列表（浏览页）。
  Future<List<SrsNoteCacheRow>> listNotes({
    String? deckId,
    String? textQuery,
    int limit = 500,
    int offset = 0,
  }) async {
    final SimpleSelectStatement<$SrsNotesCacheTable, SrsNoteCacheRow> q =
        db.select(db.srsNotesCache)
          ..where((n) => n.profileUid.equals(profileUid) & n.deletedAt.isNull())
          ..orderBy(<OrderClauseGenerator<$SrsNotesCacheTable>>[
            (n) => OrderingTerm.desc(n.createdAt),
          ])
          ..limit(limit, offset: offset);
    List<SrsNoteCacheRow> rows = await q.get();
    if (deckId != null) {
      final SrsDeckTree tree = await deckTree();
      final Set<String> sub = tree.subtree(deckId).toSet();
      final Set<String> inDeck =
          (await (db.select(
                db.srsCardsCache,
              )..where((c) => c.deckId.isIn(sub))).get())
              .map((SrsCardCacheRow c) => c.noteId)
              .toSet();
      rows = rows.where((SrsNoteCacheRow n) => inDeck.contains(n.id)).toList();
    }
    final String? text = textQuery?.trim().toLowerCase();
    if (text != null && text.isNotEmpty) {
      rows = rows
          .where(
            (SrsNoteCacheRow n) => n.sortField.toLowerCase().contains(text),
          )
          .toList();
    }
    return rows;
  }

  /// 这些牌组里全部可见卡片的 ID（优化器训练范围）。
  /// 只读 id 列（以前整行读回再取 id）。
  Future<List<String>> cardIdsInDecks(Set<String> deckIds) async {
    final $SrsCardsCacheTable c = db.srsCardsCache;
    final List<String> out = <String>[];
    for (final List<String> chunk in _chunks(deckIds)) {
      final List<TypedResult> rows =
          await (db.selectOnly(c)
                ..addColumns(<Expression<Object>>[c.id])
                ..where(c.deckId.isIn(chunk) & c.hidden.equals(false)))
              .get();
      out.addAll(rows.map((TypedResult r) => r.read(c.id)!));
    }
    return out;
  }

  Future<List<SrsCardCacheRow>> cardsOfNote(String noteId) => (db.select(
    db.srsCardsCache,
  )..where((c) => c.noteId.equals(noteId))).get();

  /// 待裁决笔记数（冲突角标；走 v125 的部分索引 idx_srs_notes_cache_pending，不读回行）。
  Future<int> pendingDecisionCount() async =>
      (await db
              .customSelect(
                'SELECT COUNT(*) AS c FROM srs_notes_cache '
                'WHERE profile_uid = ? AND pending_decision = 1',
                variables: <Variable<Object>>[Variable<String>(profileUid)],
                readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
                  db.srsNotesCache,
                },
              )
              .getSingle())
          .read<int>('c');

  /// 有待裁决（内容类冲突 / 删除与并发修改）的笔记。
  Future<List<SrsNoteCacheRow>> notesPendingDecision() =>
      (db.select(db.srsNotesCache)..where(
            (n) =>
                n.profileUid.equals(profileUid) &
                n.pendingDecision.equals(true),
          ))
          .get();

  /// 标志类 / 设置类的同步冲突（被覆盖的候选），不含机器产出（第六轮审查第 10 条）与界面状态（折叠）。
  ///
  /// 被支配的记录落库时就删了，所以一个字段键上还留着 ≥ 2 条记录的才可能有冲突：先在库里
  /// （SQLite 侧 GROUP BY）挑出这些字段键，只把它们的记录读回来解析。以前把本 profile 全部修改
  /// 记录（含每条笔记的字段正文）整表读回 UI isolate 逐条 JSON 解析，牌组列表每次重读都付一遍
  /// O(全部修改记录) 的代价（BUG-3548）。
  Future<List<(SrsEntityKind, String, SrsRegister)>> syncConflicts() async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT e.json AS json FROM srs_field_edits e '
          'JOIN (SELECT entity_kind AS k, entity_id AS i, field_key AS f '
          'FROM srs_field_edits WHERE profile_uid = ? '
          'GROUP BY entity_kind, entity_id, field_key HAVING COUNT(*) > 1) m '
          'ON e.entity_kind = m.k AND e.entity_id = m.i AND e.field_key = m.f '
          'WHERE e.profile_uid = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileUid),
            Variable<String>(profileUid),
          ],
          readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
            db.srsFieldEdits,
          },
        )
        .get();
    final Map<String, List<SrsFieldEdit>> byReg =
        <String, List<SrsFieldEdit>>{};
    for (final QueryRow r in rows) {
      final SrsFieldEdit e = SrsFieldEdit.fromJson(
        (jsonDecode(r.read<String>('json')) as Map).cast<String, Object?>(),
      );
      (byReg[e.registerKey] ??= <SrsFieldEdit>[]).add(e);
    }
    final List<(SrsEntityKind, String, SrsRegister)> out =
        <(SrsEntityKind, String, SrsRegister)>[];
    for (final List<SrsFieldEdit> edits in byReg.values) {
      if (edits.length < 2) continue;
      final Map<String, int> s = await _serverTimesFor(edits.map((e) => e.id));
      final SrsRegister reg = srsResolveRegister(
        edits.first.fieldKey,
        edits,
        serverTimeOf: (String id) => s[id],
      );
      if (reg.visibleLosers.isEmpty) continue;
      final SrsFieldEdit w = reg.winner!;
      final SrsFieldClass cls = srsFieldClassOf(w.entityKind, w.fieldKey);
      if (cls == SrsFieldClass.content || cls == SrsFieldClass.viewState) {
        continue;
      }
      out.add((w.entityKind, w.entityId, reg));
    }
    return out;
  }

  /// 改回 / 确认：写一条覆盖全部候选的新修改记录。
  Future<void> resolveConflict(
    SrsEntityKind kind,
    String entityId,
    String key,
    Object? value,
  ) => runExclusive(() async {
    await _emit(
      _finalize(<SrsEventDraft>[SrsEditDraft(kind, entityId, key, value)]),
    );
  });

  // ------------------------------------------------------------------ 按时间点恢复（srs_point_in_time_restore.dart）

  /// 本机写日志用的上下文（恢复写撤销 / manual 日志时用；不需要排程内核）。
  Future<SrsLogContext> logContext() async => _logContext(await dayContext());

  /// 把本机产生的一组日志落库、进发件箱（恢复计划写出的撤销 / manual 日志）。
  Future<void> appendLocalLogs(List<SrsReviewLog> logs) =>
      runExclusive(() => _emitLogs(logs));

  /// 库的变化指纹：本机状态纪元 + 单调修订号。任何事件真正落库（本机写、对端同步来的、导入）都会改变它；
  /// 只读查询、被支配而丢弃的记录不会。不用 (行数, 最大 rowid)：修改记录落库时先删被支配的旧行再插新行，
  /// TEXT 主键表会复用最大 rowid，同一字段连改两次 (行数, 最大 rowid) 不变。自动备份据此判断「有没有变动」。
  Future<String> changeFingerprint() async => '$_epoch:$_revision';

  /// 从库里重读本机状态（写入者、因果上下文、时钟、发件箱序号、修订号），丢掉内存里的影响面。
  /// 事务回滚不回滚内存：恢复等多步写入中途失败后必须调它，否则 applied 里会留下已回滚的 dot，
  /// 之后真正同步来的同一批记录会被本机新写的记录误判为「已看见」而支配丢弃。
  Future<void> reloadLocal() => runExclusive(() async {
    _dirtyNotes.clear();
    _dirtyCards.clear();
    _dirtyNoteTypes.clear();
    _resetCacheJournal();
    await _loadLocal();
  });

  /// 本机已应用的因果上下文（测试核对回滚后状态用）。
  SrsCausalContext get appliedContext => _writer.applied;

  /// 备份清单里显示的计数：未删除的笔记、可见的卡片、有效的复习（评分且没被撤销）。
  Future<({int notes, int cards, int reviews})> backupCounts() =>
      srsBackupCounts(backupSelect, profileUid);

  /// 主连接上的只读查询（[SrsSqlSelect]）：备份读快照的几个函数在主连接与后台独立连接上共用。
  SrsSqlSelect get backupSelect =>
      (String sql, List<Object?> args) async => <Map<String, Object?>>[
        for (final QueryRow r
            in await db
                .customSelect(
                  sql,
                  variables: <Variable<Object>>[
                    for (final Object? a in args)
                      switch (a) {
                        final int v => Variable<int>(v),
                        final String v => Variable<String>(v),
                        _ => throw ArgumentError.value(a, 'args'),
                      },
                  ],
                )
                .get())
          r.data,
      ];

  /// 库文件路径（`PRAGMA database_list` 的 main）；内存库 / 临时库为 null。
  /// 备份据此在后台开一条独立只读连接读快照（srs_backup_snapshot.dart）。
  Future<String?> databaseFilePath() async {
    for (final QueryRow r
        in await db.customSelect('PRAGMA database_list').get()) {
      if (r.data['name'] != 'main') continue;
      final Object? file = r.data['file'];
      return file is String && file.isNotEmpty ? file : null;
    }
    return null;
  }

  /// 本 profile 是否有用户笔记（铁律 E：只有内置行不算有数据）。
  Future<bool> hasUserNotes() async {
    final SrsEntityRow? any =
        await (db.select(db.srsEntities)
              ..where(
                (t) =>
                    t.profileUid.equals(profileUid) &
                    t.kind.equals(SrsEntityKind.note.wire),
              )
              ..limit(1))
            .getSingleOrNull();
    return any != null;
  }

  // ------------------------------------------------------------------ SrsSyncReplica

  @override
  Future<SrsSyncLocalState> loadSyncState() async => _sync;

  @override
  Future<void> saveSyncState(SrsSyncLocalState state) => runExclusive(() async {
    if (state.writerId != _writer.writerId) {
      _writer = SrsEditWriter(
        writerId: state.writerId,
        applied: _writer.applied,
      );
      _clock = HlcClock(
        state.writerId,
        last: _rehome(_clock.last, state.writerId),
      );
    }
    _sync = state;
    await _saveLocal();
  });

  /// 发件箱里的事件，按入箱顺序。事件正文按 ID 分块从四张事件表各一次读回（以前每条事件最多
  /// 查四次，同步一次几万次往返，BUG-3543）。本机未发布的修改记录可能已被（本机更晚的）修改支配
  /// 而丢弃：它在本机已不存在，后一条记录的 ctx 覆盖它，无需再发——跳过。
  ///
  /// [limit]：按发件箱序号键集分页，凑够这么多条还在的事件为止（冻结逐批取，不把几万条一次读进内存）。
  @override
  Future<List<SrsEvent>> unpublishedEvents({int? limit}) async {
    final List<SrsEvent> out = <SrsEvent>[];
    int after = -1 << 62;
    while (true) {
      final int? want = limit == null ? null : limit - out.length;
      final SimpleSelectStatement<$SrsEventLocalTable, SrsEventLocalRow> q =
          db.select(db.srsEventLocal)
            ..where(
              (t) =>
                  t.profileUid.equals(profileUid) &
                  t.outboxSeq.isBiggerThanValue(after),
            )
            ..orderBy(<OrderClauseGenerator<$SrsEventLocalTable>>[
              (t) => OrderingTerm.asc(t.outboxSeq),
            ]);
      if (want != null) q.limit(want);
      final List<SrsEventLocalRow> rows = await q.get();
      out.addAll(
        await _eventsByIds(<String>[
          for (final SrsEventLocalRow r in rows) r.eventId,
        ]),
      );
      if (want == null || rows.length < want || out.length >= limit!) {
        return out;
      }
      after = rows.last.outboxSeq!;
    }
  }

  /// [ids] 对应的事件（按给定顺序；库里已不存在的跳过）。
  Future<List<SrsEvent>> _eventsByIds(List<String> ids) async {
    final Map<String, SrsEvent> found = <String, SrsEvent>{};
    for (final List<String> chunk in _chunks(ids)) {
      // 与逐条查找同一优先级：身份记录 → 修改记录 → 日志 → 不认识的事件。
      for (final SrsEntityRow r in await (db.select(
        db.srsEntities,
      )..where((t) => t.id.isIn(chunk))).get()) {
        found.putIfAbsent(r.id, () => SrsEntityEvent(_entityFromRow(r)));
      }
      for (final SrsFieldEditRow r in await (db.select(
        db.srsFieldEdits,
      )..where((t) => t.id.isIn(chunk))).get()) {
        found.putIfAbsent(
          r.id,
          () => SrsEditEvent(
            SrsFieldEdit.fromJson(
              (jsonDecode(r.json) as Map).cast<String, Object?>(),
            ),
          ),
        );
      }
      for (final SrsReviewLogRow r in await (db.select(
        db.srsReviewLogs,
      )..where((t) => t.id.isIn(chunk))).get()) {
        found.putIfAbsent(
          r.id,
          () => SrsLogEvent(
            SrsReviewLog.fromJson(
              (jsonDecode(r.json) as Map).cast<String, Object?>(),
            ),
          ),
        );
      }
      for (final SrsUnknownEventRow r in await (db.select(
        db.srsUnknownEvents,
      )..where((t) => t.id.isIn(chunk))).get()) {
        found.putIfAbsent(
          r.id,
          () => SrsUnknownEvent(
            (jsonDecode(r.json) as Map).cast<String, Object?>(),
          ),
        );
      }
    }
    return <SrsEvent>[
      for (final String id in ids)
        if (found[id] case final SrsEvent e) e,
    ];
  }

  @override
  Future<void> freezeBatch(
    SrsSyncLocalState state,
    int no,
    Uint8List bytes,
    List<String> eventIds,
  ) => runExclusive(
    () => _transactionOrReload(() async {
      await db
          .into(db.srsSentBatches)
          .insertOnConflictUpdate(
            SrsSentBatchesCompanion.insert(
              profileUid: profileUid,
              writerId: state.writerId,
              batchNo: no,
              bytes: bytes,
            ),
          );
      for (int i = 0; i < eventIds.length; i += 500) {
        await (db.update(db.srsEventLocal)..where(
              (t) => t.eventId.isIn(
                eventIds.sublist(i, min(i + 500, eventIds.length)),
              ),
            ))
            .write(const SrsEventLocalCompanion(outboxSeq: Value<int?>(null)));
      }
      await saveSyncState(state);
    }),
  );

  @override
  Future<Uint8List?> sentBatch(String writerId, int no) async =>
      (await (db.select(db.srsSentBatches)..where(
                (t) =>
                    t.profileUid.equals(profileUid) &
                    t.writerId.equals(writerId) &
                    t.batchNo.equals(no),
              ))
              .getSingleOrNull())
          ?.bytes;

  @override
  Future<List<int>> sentBatchNos(String writerId) async {
    final Expression<int> no = db.srsSentBatches.batchNo;
    final List<TypedResult> rows =
        await (db.selectOnly(db.srsSentBatches)
              ..addColumns(<Expression<Object>>[no])
              ..where(
                db.srsSentBatches.profileUid.equals(profileUid) &
                    db.srsSentBatches.writerId.equals(writerId),
              )
              ..orderBy(<OrderingTerm>[OrderingTerm.asc(no)]))
            .get();
    return <int>[for (final TypedResult r in rows) r.read(no)!];
  }

  @override
  Future<void> dropSentBatches(String writerId, {int? throughNo}) =>
      runExclusive(() async {
        await (db.delete(db.srsSentBatches)..where(
              (t) =>
                  t.profileUid.equals(profileUid) &
                  t.writerId.equals(writerId) &
                  (throughNo == null
                      ? const Constant<bool>(true)
                      : t.batchNo.isSmallerOrEqualValue(throughNo)),
            ))
            .go();
      });

  @override
  Future<Map<String, int>> knownServerTimes(List<String> eventIds) async {
    final Map<String, int> out = <String, int>{};
    for (final List<String> chunk in _chunks(eventIds)) {
      for (final SrsEventLocalRow r
          in await (db.select(
                db.srsEventLocal,
              )..where((t) => t.eventId.isIn(chunk) & t.serverTime.isNotNull()))
              .get()) {
        out[r.eventId] = r.serverTime!;
      }
    }
    return out;
  }

  /// 转发（见 [SrsSyncReplica.applyRemote]）：[ids] 按给定顺序进本机发件箱，随本机批次带去别的目录。
  /// 调用方在独占区与写事务里。
  Future<void> _enqueueForward(List<String> ids) async {
    if (ids.isEmpty) return;
    await _upsertEventLocal(<(String, int?, int?)>[
      for (final String id in ids) (id, null, ++_outboxSeq),
    ]);
  }

  /// 重新入队：按给定顺序续发件箱序号，一个 batch 写回（以前每条事件「先查再写」两次往返，
  /// 恢复备份后整库重新入队就是几万次往返）。
  @override
  Future<void> requeue(List<String> eventIds) => runExclusive(() async {
    final List<(String, int?, int?)> items = <(String, int?, int?)>[
      for (final String id in eventIds) (id, null, ++_outboxSeq),
    ];
    await _transactionOrReload(() async {
      await _upsertEventLocal(items);
      await _saveLocal();
    });
  });

  /// 应用一批对端事件：与逐条落库同结果（[_storeLocalBatch]：按序在内存视图上判定），服务器时刻
  /// 成批合并（[_upsertEventLocal]），一个事务、一次缓存刷新。以前每条事件「先查再写」四五次往返。
  ///
  /// [forward] 为真时，新落地的与 S 因此变小的事件进本机发件箱（多目录转发）。
  @override
  Future<void> applyRemote(
    List<SrsEvent> events, {
    int? serverTimeMs,
    bool forward = false,
  }) => runExclusive(() async {
    final (int nowMs, _) = now();
    final List<SrsEvent> mine = <SrsEvent>[
      for (final SrsEvent e in events)
        if (e is! SrsEntityEvent || e.record.profileUid == profileUid) e,
    ];
    await _transactionOrReload(() async {
      final Set<String> landed = (await _storeLocalBatch(mine)).toSet();
      // 同步合并：别的设备的作答带动了牌组 / 全局状态，RWKV 分数表整表重查（见 rwkvScoresKey）。
      if (landed.isNotEmpty) _rwkvScoresRevision++;
      final Set<String> lowered = await _upsertEventLocal(
        <(String, int?, int?)>[
          for (final SrsEvent e in mine) (e.id, serverTimeMs, null),
        ],
      );
      if (forward) {
        final Set<String> seen = <String>{};
        await _enqueueForward(<String>[
          for (final SrsEvent e in mine)
            if ((landed.contains(e.id) || lowered.contains(e.id)) &&
                seen.add(e.id))
              e.id,
        ]);
      }
      for (final SrsEvent e in mine) {
        final Hlc? h = switch (e) {
          SrsEditEvent(:final SrsFieldEdit edit) => edit.hlc,
          SrsLogEvent(:final SrsReviewLog log) => log.hlc,
          _ => null,
        };
        if (h != null) {
          _clock.receive(h, serverTimeMs: serverTimeMs, trustedNowMs: nowMs);
        }
      }
      await _flushCaches();
      await _saveLocal();
    });
  });

  /// [forward] 为真时，已在本机、S 因此变小的事件进本机发件箱（多目录转发）。
  @override
  Future<void> observeServerTimes(
    Map<String, int> times, {
    bool forward = false,
  }) => runExclusive(() async {
    await _transactionOrReload(() async {
      final Set<String> lowered = await _upsertEventLocal(
        <(String, int?, int?)>[
          for (final MapEntry<String, int> e in times.entries)
            (e.key, e.value, null),
        ],
      );
      if (forward && lowered.isNotEmpty) {
        await _enqueueForward(<String>[
          for (final String id in times.keys)
            if (lowered.contains(id)) id,
        ]);
        await _saveLocal();
      }
      // S 变化可能改变排序：相关卡片的「最后一条有效日志」要重算。
      for (final List<String> chunk in _chunks(times.keys)) {
        for (final SrsReviewLogRow r in await (db.select(
          db.srsReviewLogs,
        )..where((t) => t.id.isIn(chunk))).get()) {
          _dirtyCards.add(r.cardId);
        }
      }
      await _flushCaches();
    });
  });

  /// 一个写事务；失败（回滚）时从库里重读本机状态再抛出。事务回滚不回滚内存：落库前已分配的
  /// 序号 / 已并进因果上下文的 dot、推进过的时钟与发件箱序号、攒下的影响面都要丢掉，否则
  /// applied 里留着不存在的 dot，之后真正同步来的同 dot 记录会被误判「已看见」而丢弃（与
  /// [reloadLocal] 同一理由）。调用方已在独占区里。
  ///
  /// 抛出的永远是事务本身的错误。重读也失败（典型是连接已经关了：app 退出时同步还在跑）时，
  /// 内存状态已无从与库对齐：副本标为作废（[_unusable]），之后的写入一律明确失败，不在过期的
  /// 因果上下文 / 序号上继续写；也不拿重读的错误顶替原错误——以前日志里只剩 `_loadLocal` 上的
  /// 「connection was closed」，看不出是哪一步写失败。
  Future<void> _transactionOrReload(Future<void> Function() body) async {
    try {
      await db.transaction(body);
    } catch (error, stack) {
      _dirtyNotes.clear();
      _dirtyCards.clear();
      _dirtyNoteTypes.clear();
      _resetCacheJournal();
      try {
        await _loadLocal();
      } on Object catch (reloadError) {
        _unusable = StateError(
          'SRS store is unusable: reloading local state after a failed '
          'write failed ($reloadError); original error: $error',
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// 写失败后重读本机状态也失败时置上（见 [_transactionOrReload]）；之后进独占区的写入都抛它。
  StateError? _unusable;

  @override
  Future<List<SrsEvent>> exportAll() async {
    final List<SrsEvent> out = <SrsEvent>[];
    for (final SrsEntityRow r in await (db.select(
      db.srsEntities,
    )..where((t) => t.profileUid.equals(profileUid))).get()) {
      out.add(SrsEntityEvent(_entityFromRow(r)));
    }
    for (final SrsFieldEditRow r in await (db.select(
      db.srsFieldEdits,
    )..where((t) => t.profileUid.equals(profileUid))).get()) {
      out.add(
        SrsEditEvent(
          SrsFieldEdit.fromJson(
            (jsonDecode(r.json) as Map).cast<String, Object?>(),
          ),
        ),
      );
    }
    for (final SrsReviewLogRow r in await (db.select(
      db.srsReviewLogs,
    )..where((t) => t.profileUid.equals(profileUid))).get()) {
      out.add(
        SrsLogEvent(
          SrsReviewLog.fromJson(
            (jsonDecode(r.json) as Map).cast<String, Object?>(),
          ),
        ),
      );
    }
    for (final SrsUnknownEventRow r in await (db.select(
      db.srsUnknownEvents,
    )..where((t) => t.profileUid.equals(profileUid))).get()) {
      out.add(
        SrsUnknownEvent((jsonDecode(r.json) as Map).cast<String, Object?>()),
      );
    }
    return out;
  }

  /// 全部事件的 ID，与 [exportAll] 同序（身份记录 → 修改记录 → 日志 → 不认识的事件，表内按 rowid）。
  /// 全量重新发布只要 ID：只读 id 列，不把正文读回来解析。
  @override
  Future<List<String>> exportAllIds() async {
    final List<String> out = <String>[];
    for (final String table in const <String>[
      'srs_entities',
      'srs_field_edits',
      'srs_review_logs',
      'srs_unknown_events',
    ]) {
      await _pageRows(table, 'id', 20000, (List<QueryRow> rows) async {
        for (final QueryRow r in rows) {
          out.add(r.read<String>('id'));
        }
      });
    }
    return out;
  }

  /// 写快照用的分页导出（[SrsSyncReplica.exportSnapshotPages]）：事件规范行与服务器时间在同一个
  /// 事务里按页读（中间插不进别的写入，两者是同一份状态），与备份同一套分页设施。
  @override
  Future<void> exportSnapshotPages({
    required Future<void> Function(List<String> canonicalLines) onEvents,
    required Future<void> Function(List<(String, int)> serverTimes)
    onServerTimes,
  }) => db.transaction(() async {
    await forEachCanonicalLinePage(onEvents);
    await forEachServerTimePage(onServerTimes);
  });

  /// 全部事件的规范 JSON 行（与 `SrsEvent.canonical()` 逐字节相同；按表、表内按 rowid 排）。
  /// 一次全进内存，只给测试 / 小规模调用；备份走分页的 [forEachCanonicalLinePage]。
  Future<List<String>> exportCanonicalLines() async {
    final List<String> out = <String>[];
    await forEachCanonicalLinePage(
      (List<String> page) async => out.addAll(page),
    );
    return out;
  }

  /// 按页导出全部事件的规范 JSON 行（备份用，见 [srsForEachCanonicalLinePage]）。
  /// 要一致快照就在同一个事务里调用（各页之间插不进别的写入）。
  Future<void> forEachCanonicalLinePage(
    Future<void> Function(List<String> lines) onPage, {
    int pageSize = 2000,
  }) => srsForEachCanonicalLinePage(
    backupSelect,
    profileUid,
    onPage,
    pageSize: pageSize,
  );

  /// 按页导出已知的「事件 ID → 服务器时间 S」（备份用，同 [exportServerTimes] 的内容）。
  Future<void> forEachServerTimePage(
    Future<void> Function(List<(String, int)> page) onPage, {
    int pageSize = 5000,
  }) => srsForEachServerTimePage(
    backupSelect,
    profileUid,
    onPage,
    pageSize: pageSize,
  );

  /// 本 profile 在 [table] 里的行，按 rowid 键集分页（不用 OFFSET：深页不退化成 O(n²)）。
  ///
  /// `+profile_uid` 的一元加号让 SQLite 不走 profile_uid 前缀索引：走那条索引时每页都要
  /// 从该 profile 的第一行扫起再按 rowid 过滤，整体随数据量平方增长（实测 20 万行日志
  /// 慢 26–58 倍）；去掉后按 rowid 主键做范围扫描，每页只读本页的行。
  Future<void> _pageRows(
    String table,
    String columns,
    int pageSize,
    Future<void> Function(List<QueryRow> rows) onPage, {
    String? extraWhere,
  }) async {
    int after = -1 << 62;
    while (true) {
      final List<QueryRow> rows = await db
          .customSelect(
            'SELECT rowid AS rid_, $columns FROM $table '
            'WHERE +profile_uid = ? AND rowid > ?'
            '${extraWhere == null ? '' : ' AND $extraWhere'} '
            'ORDER BY rowid LIMIT ?',
            variables: <Variable<Object>>[
              Variable<String>(profileUid),
              Variable<int>(after),
              Variable<int>(pageSize),
            ],
          )
          .get();
      if (rows.isEmpty) return;
      await onPage(rows);
      if (rows.length < pageSize) return;
      after = rows.last.read<int>('rid_');
    }
  }

  @override
  Future<Map<String, int>> exportServerTimes() async {
    final List<SrsEventLocalRow> rows =
        await (db.select(db.srsEventLocal)..where(
              (t) => t.profileUid.equals(profileUid) & t.serverTime.isNotNull(),
            ))
            .get();
    return <String, int>{
      for (final SrsEventLocalRow r in rows) r.eventId: r.serverTime!,
    };
  }

  @override
  String newIncarnationWriterId() {
    _incarnation += 1;
    return '$deviceId#$_incarnation';
  }

  /// 同步成功拿到服务器时间后校时。
  Future<void> anchorTime(int serverTimeMs) => runExclusive(() async {
    _trusted.anchor(serverTimeMs: serverTimeMs);
    await _saveLocal();
  });

  /// 恢复备份后调用：本机换新化身号（不复用旧 writerId），重新起步读快照。
  ///
  /// 本机发布元信息（srs_event_local）不进备份，恢复后不知道备份里哪些事件已经发布过：
  /// 一律由新化身重新发布（事件不可变、按 ID 取并集，重复发布无害；代价相当于写一次快照）。
  ///
  /// [freshIncarnation]：化身号跳到「当前秒数」量级而不只是 +1——本机状态是新建的（例如新装设备
  /// 采用了别处的 profile 身份）时，`设备ID#2` 这类小号可能这台设备以前在同一个 profile 下用过。
  Future<void> afterRestore({bool freshIncarnation = false}) =>
      runExclusive(() => _afterRestore(freshIncarnation: freshIncarnation));

  Future<void> _afterRestore({required bool freshIncarnation}) async {
    _incarnation = freshIncarnation
        ? max(_incarnation + 1, DateTime.now().millisecondsSinceEpoch ~/ 1000)
        : _incarnation + 1;
    _sync = SrsSyncLocalState(writerId: '$deviceId#$_incarnation');
    _writer = SrsEditWriter(writerId: _sync.writerId);
    // 因果上下文只由修改记录决定：按页读修改记录，不把整库事件一次物化。
    await _pageRows('srs_field_edits', 'json', 2000, (
      List<QueryRow> rows,
    ) async {
      for (final QueryRow r in rows) {
        _writer.apply(
          SrsFieldEdit.fromJson(
            (jsonDecode(r.read<String>('json')) as Map).cast<String, Object?>(),
          ),
        );
      }
    });
    _clock = HlcClock(
      _sync.writerId,
      last: _rehome(_clock.last, _sync.writerId),
    );
    // 恢复进来的行可能还是内联样式：存量去重从头再查一遍。
    _styleCursor = 0;
    await (db.delete(
      db.srsEventLocal,
    )..where((t) => t.profileUid.equals(profileUid))).go();
    // 旧写入者的批次流随恢复作废（新化身全部重新发布），留存的旧批次不再传。
    await (db.delete(
      db.srsSentBatches,
    )..where((t) => t.profileUid.equals(profileUid))).go();
    await requeue(await exportAllIds());
    await rebuildCaches();
  }

  // ------------------------------------------------------------------ AnkiConnect 兼容层（只读）

  /// 本 profile 的全部笔记（含已删除，调用方自行过滤），批量物化：
  /// 三次查询（身份记录 / 修改记录 / 服务器时间）而不是每条笔记各查一遍。
  Future<List<SrsNoteView>> allNoteViews() async {
    final List<SrsEntityRow> rows =
        await (db.select(db.srsEntities)..where(
              (t) =>
                  t.profileUid.equals(profileUid) &
                  t.kind.equals(SrsEntityKind.note.wire),
            ))
            .get();
    final List<SrsFieldEditRow> editRows =
        await (db.select(db.srsFieldEdits)..where(
              (t) =>
                  t.profileUid.equals(profileUid) &
                  t.entityKind.equals(SrsEntityKind.note.wire),
            ))
            .get();
    final Map<String, List<SrsFieldEdit>> byEntity =
        <String, List<SrsFieldEdit>>{};
    for (final SrsFieldEditRow r in editRows) {
      (byEntity[r.entityId] ??= <SrsFieldEdit>[]).add(
        SrsFieldEdit.fromJson(
          (jsonDecode(r.json) as Map).cast<String, Object?>(),
        ),
      );
    }
    final Map<String, int> serverTimes = await exportServerTimes();
    return <SrsNoteView>[
      for (final SrsEntityRow r in rows)
        SrsNoteView.materialize(
          _entityFromRow(r),
          SrsEntityEdits.build(
            byEntity[r.id] ?? const <SrsFieldEdit>[],
            serverTimeOf: (String id) => serverTimes[id],
          ),
        ),
    ];
  }

  /// 笔记字段（`f/` 键）的值，按页交出（媒体引用扫描用）：直接按 rowid 分页读修改记录，
  /// 不物化笔记——以前每轮同步后都经 [allNoteViews] 把整库笔记连同每条修改记录、整张服务器时间表
  /// 一次读进调用方 isolate（大库上单段阻塞数百毫秒、每轮都来一次，反馈 OMWOurRQKb）。
  ///
  /// 只看有身份记录的笔记（与 [allNoteViews] 同一范围）。被支配的修改记录落库时就删了，一个字段键上
  /// 留下的每一条都是生效候选（[SrsRegister.live]）。
  ///
  /// - [currentOnly] 为假（回收媒体前的保守口径）：已删未清的笔记也算，每个字段的全部候选值都交出；
  /// - 为真（同步口径，与 [allNoteViews] 物化后 `deletedAt == null` 的笔记的 `fields` 同值）：跳过已删
  ///   笔记（删除键上有任一候选值是时刻，见 [srsEffectiveDeletedAt]），每个字段只交生效值——只有一条
  ///   候选的直接取它，有并发候选的（少数）按 [srsResolveRegister] 裁决后取胜者。
  Future<void> forEachNoteFieldValuePage(
    Future<void> Function(List<String> values) onPage, {
    required bool currentOnly,
    int pageSize = 1000,
  }) async {
    final String noteKind = SrsEntityKind.note.wire;
    final String scope =
        "entity_kind = '$noteKind' AND EXISTS (SELECT 1 FROM srs_entities n "
        "WHERE n.id = srs_field_edits.entity_id AND n.kind = '$noteKind')";
    final Set<String> deleted = <String>{};
    final Set<String> contested = <String>{};
    String reg(String noteId, String key) => '$noteId\u0000$key';
    if (currentOnly) {
      await _pageRows('srs_field_edits', 'entity_id, json', pageSize, (
        List<QueryRow> rows,
      ) async {
        for (final QueryRow r in rows) {
          final Object? v = (jsonDecode(r.read<String>('json')) as Map)['v'];
          if (v is int) deleted.add(r.read<String>('entity_id'));
        }
      }, extraWhere: "$scope AND field_key = '${SrsFieldKeys.deleted}'");
      for (final QueryRow r
          in await db
              .customSelect(
                'SELECT entity_id, field_key FROM srs_field_edits '
                "WHERE profile_uid = ? AND entity_kind = '$noteKind' "
                "AND substr(field_key, 1, 2) = 'f/' "
                'GROUP BY entity_id, field_key HAVING COUNT(*) > 1',
                variables: <Variable<Object>>[Variable<String>(profileUid)],
              )
              .get()) {
        contested.add(
          reg(r.read<String>('entity_id'), r.read<String>('field_key')),
        );
      }
    }
    await _pageRows('srs_field_edits', 'entity_id, field_key, json', pageSize, (
      List<QueryRow> rows,
    ) async {
      final List<String> values = <String>[];
      for (final QueryRow r in rows) {
        final String id = r.read<String>('entity_id');
        if (currentOnly &&
            (deleted.contains(id) ||
                contested.contains(reg(id, r.read<String>('field_key'))))) {
          continue;
        }
        final Object? v = (jsonDecode(r.read<String>('json')) as Map)['v'];
        if (v is String) values.add(v);
      }
      await onPage(values);
    }, extraWhere: "$scope AND substr(field_key, 1, 2) = 'f/'");
    if (contested.isEmpty) return;
    // 有并发候选的字段：读回这些笔记的候选、按服务器时间裁决（与物化同一规则）。
    final Set<String> notes = <String>{
      for (final String k in contested)
        if (!deleted.contains(k.substring(0, k.indexOf('\u0000'))))
          k.substring(0, k.indexOf('\u0000')),
    };
    for (final List<String> chunk in _chunks(notes)) {
      final Map<String, List<SrsFieldEdit>> byReg =
          <String, List<SrsFieldEdit>>{};
      for (final SrsFieldEditRow r
          in await (db.select(db.srsFieldEdits)..where(
                (t) =>
                    t.profileUid.equals(profileUid) &
                    t.entityKind.equals(noteKind) &
                    t.entityId.isIn(chunk),
              ))
              .get()) {
        final String k = reg(r.entityId, r.fieldKey);
        if (!contested.contains(k)) continue;
        (byReg[k] ??= <SrsFieldEdit>[]).add(
          SrsFieldEdit.fromJson(
            (jsonDecode(r.json) as Map).cast<String, Object?>(),
          ),
        );
      }
      final List<String> values = <String>[];
      for (final List<SrsFieldEdit> edits in byReg.values) {
        final Map<String, int> s = await _serverTimesFor(
          edits.map((SrsFieldEdit e) => e.id),
        );
        final Object? v = srsResolveRegister(
          edits.first.fieldKey,
          edits,
          serverTimeOf: (String id) => s[id],
        ).value;
        if (v is String) values.add(v);
      }
      await onPage(values);
    }
  }

  /// 本 profile 的全部卡片缓存行（含隐藏）。
  Future<List<SrsCardCacheRow>> allCardRows() => (db.select(
    db.srsCardsCache,
  )..where((c) => c.profileUid.equals(profileUid))).get();

  /// 笔记缓存的变化戳：(行数, 最大 updatedAt)。笔记内容 / 笔记类型变化都会刷新笔记缓存行。
  Future<(int, int)> notesCacheStamp() async {
    final Expression<int> count = db.srsNotesCache.id.count();
    final Expression<int> maxUpdated = db.srsNotesCache.updatedAt.max();
    final TypedResult row =
        await (db.selectOnly(db.srsNotesCache)
              ..addColumns(<Expression<Object>>[count, maxUpdated])
              ..where(db.srsNotesCache.profileUid.equals(profileUid)))
            .getSingle();
    return (row.read(count) ?? 0, row.read(maxUpdated) ?? 0);
  }

  /// AnkiConnect 整数 id → UUID 的本机索引（不同步）。null = 还没回填（或缓存行被整体换掉，
  /// 要重新回填）；回填之后由 [_writeCache] 在写缓存行的同一个独占区 / 事务里随写随增，未命中即
  /// 「不存在」——不再每次未命中都整表重建（HBK-AUDIT-017）。
  ///
  /// 缓存行只经 [_writeCache] 写入（导入、同步、更改笔记类型、编辑都走缓存刷新）；绕过它整体
  /// 删 / 换缓存行的路径（[rebuildCaches]、事务回滚后的 [_loadLocal] 重读）调
  /// [_resetCacheJournal] 把索引置回 null，下次查时重新回填。被删掉的实体在索引里留着无害：
  /// 它映射到的 UUID 查不到行，调用方照常报「不存在」。
  Map<int, String>? _ankiNoteIndex;
  Map<int, String>? _ankiCardIndex;

  /// 整表回填数字索引（在独占区里跑：回填期间不会有写入插进来、让新行既不在回填结果里、
  /// 又因为索引还是 null 没被 [_writeCache] 记上）。
  Future<void> _ensureAnkiNumericIndex() async {
    if (_ankiNoteIndex != null && _ankiCardIndex != null) return;
    await runExclusive(() async {
      if (_ankiNoteIndex != null && _ankiCardIndex != null) return;
      final List<SrsNoteCacheRow> notes = await (db.select(
        db.srsNotesCache,
      )..where((n) => n.profileUid.equals(profileUid))).get();
      final List<SrsCardCacheRow> cards = await allCardRows();
      // 整表一次批量派生（hash53 在 native/fushi_compute 里算）。
      final List<String> noteIds = <String>[
        for (final SrsNoteCacheRow n in notes) n.id,
      ];
      final List<String> cardIds = <String>[
        for (final SrsCardCacheRow c in cards) c.id,
      ];
      final List<int> noteNums = SrsIds.ankiNumericIds(noteIds);
      final List<int> cardNums = SrsIds.ankiNumericIds(cardIds);
      _ankiNoteIndex = <int, String>{
        for (int i = 0; i < noteIds.length; i++) noteNums[i]: noteIds[i],
      };
      _ankiCardIndex = <int, String>{
        for (int i = 0; i < cardIds.length; i++) cardNums[i]: cardIds[i],
      };
    });
  }

  /// 一批刚写的缓存行登记进数字索引（索引还没回填时什么也不做：回填会读到它们）。
  void _indexCacheRows(List<String> noteIds, List<String> cardIds) {
    final Map<int, String>? notes = _ankiNoteIndex;
    if (notes != null && noteIds.isNotEmpty) {
      final List<int> nums = SrsIds.ankiNumericIds(noteIds);
      for (int i = 0; i < noteIds.length; i++) {
        notes[nums[i]] = noteIds[i];
      }
    }
    final Map<int, String>? cards = _ankiCardIndex;
    if (cards != null && cardIds.isNotEmpty) {
      final List<int> nums = SrsIds.ankiNumericIds(cardIds);
      for (int i = 0; i < cardIds.length; i++) {
        cards[nums[i]] = cardIds[i];
      }
    }
  }

  /// AnkiConnect 整数笔记 id（[SrsIds.ankiNumericId]）→ noteId；没有这条笔记为 null。
  Future<String?> noteIdForAnkiNumericId(int ankiId) async {
    await _ensureAnkiNumericIndex();
    return _ankiNoteIndex![ankiId];
  }

  /// AnkiConnect 整数卡片 id → cardId（同 [noteIdForAnkiNumericId]）。
  Future<String?> cardIdForAnkiNumericId(int ankiId) async {
    await _ensureAnkiNumericIndex();
    return _ankiCardIndex![ankiId];
  }

  /// [noteIdForAnkiNumericId] 的成批版本（按输入顺序）。
  Future<List<String?>> noteIdsForAnkiNumericIds(List<int> ankiIds) async {
    await _ensureAnkiNumericIndex();
    final Map<int, String> index = _ankiNoteIndex!;
    return <String?>[for (final int n in ankiIds) index[n]];
  }

  /// [cardIdForAnkiNumericId] 的成批版本（按输入顺序）。
  Future<List<String?>> cardIdsForAnkiNumericIds(List<int> ankiIds) async {
    await _ensureAnkiNumericIndex();
    final Map<int, String> index = _ankiCardIndex!;
    return <String?>[for (final int n in ankiIds) index[n]];
  }

  // ------------------------------------------------------------------ 缓存变更日志

  /// 缓存行的变化代号：每次 [_writeCache] 写入 +1，缓存被整体换掉（[_resetCacheJournal]）也 +1。
  /// 只在本对象内单调；跨对象 / 跨进程不可比。
  int _cacheGeneration = 0;

  /// [_cacheJournal] 还能完整回答的最小代号：比它旧的代号问 [cacheChangesSince] 得 null。
  int _cacheJournalFloor = 0;

  /// (代号, 写过缓存行的笔记, 写过缓存行的卡)，按代号升序。
  final List<(int, List<String>, List<String>)> _cacheJournal =
      <(int, List<String>, List<String>)>[];
  int _cacheJournalIds = 0;

  /// 日志最多留多少个 ID（超了丢最旧的，更旧的代号只能整份重读）。
  static const int _kCacheJournalMaxIds = 100000;

  /// 缓存行的当前变化代号（见 [cacheChangesSince]）。
  int get cacheGeneration => _cacheGeneration;

  /// 代号 [generation] 之后写过缓存行的笔记与卡（同一实体可能出现在两边）。null = 日志已经答不了
  /// （缓存整体换过、事务回滚重读过本机状态，或日志滚掉了这段）：调用方要整份重读。
  ///
  /// 常驻视图（AnkiConnect 兼容层）据此只重读变了的那些笔记 / 卡，不再每次请求整库重物化。
  /// 缓存行只经 [_writeCache] 写，所以导入、同步、编辑、复习、更改笔记类型都在这里留痕。
  ({Set<String> notes, Set<String> cards})? cacheChangesSince(int generation) {
    if (generation > _cacheGeneration || generation < _cacheJournalFloor) {
      return null;
    }
    final Set<String> notes = <String>{};
    final Set<String> cards = <String>{};
    for (int i = _cacheJournal.length - 1; i >= 0; i--) {
      final (int gen, List<String> n, List<String> c) = _cacheJournal[i];
      if (gen <= generation) break;
      notes.addAll(n);
      cards.addAll(c);
    }
    return (notes: notes, cards: cards);
  }

  void _journalCacheWrite(List<String> noteIds, List<String> cardIds) {
    _cacheGeneration++;
    _cacheJournal.add((_cacheGeneration, noteIds, cardIds));
    _cacheJournalIds += noteIds.length + cardIds.length;
    while (_cacheJournalIds > _kCacheJournalMaxIds &&
        _cacheJournal.isNotEmpty) {
      final (int gen, List<String> n, List<String> c) = _cacheJournal.removeAt(
        0,
      );
      _cacheJournalIds -= n.length + c.length;
      _cacheJournalFloor = gen;
    }
  }

  /// 缓存行被整体换掉 / 内存与库可能不一致：日志作废（旧代号一律答 null）、数字索引待重新回填。
  void _resetCacheJournal() {
    _cacheGeneration++;
    _cacheJournal.clear();
    _cacheJournalIds = 0;
    _cacheJournalFloor = _cacheGeneration;
    _ankiNoteIndex = null;
    _ankiCardIndex = null;
  }
}

/// [SrsDbStore] 计数用的一次性上下文。
/// 一个牌组自己（或整棵子树）的原始卡数与今天的学习量。
class _DeckTally {
  int total = 0;
  int newAvail = 0;
  int learn = 0;
  int due = 0;
  int newDone = 0;
  int reviewDone = 0;

  void add(_DeckTally o) {
    total += o.total;
    newAvail += o.newAvail;
    learn += o.learn;
    due += o.due;
    newDone += o.newDone;
    reviewDone += o.reviewDone;
  }
}

/// 牌组树里一个节点的计数（见 `SrsDbStore._countTree`）。
class _DeckCount {
  const _DeckCount({
    required this.subtree,
    required this.budget,
    required this.newRemaining,
    required this.reviewRemaining,
    required this.newCount,
    required this.reviewCount,
    required this.learnCount,
  });

  /// 整棵子树的原始数（未截断）。
  final _DeckTally subtree;
  final SrsNewCardBudget budget;

  /// 本牌组今天还能出的新卡 / 复习卡（只看自己的上限与子树已学量）。
  final int newRemaining;
  final int reviewRemaining;

  /// 自底向上截断后的数（列表显示的数，也是点本牌组能出的卡数）。
  final int newCount;
  final int reviewCount;
  final int learnCount;
}

class _CountContext {
  const _CountContext({
    required this.tree,
    required this.day,
    required this.nowMs,
    required this.today,
    required this.last30,
    required this.introducedToday,
    required this.reviewedToday,
    required this.answersToday,
  });

  final SrsDeckTree tree;
  final SrsDayContext day;
  final int nowMs;
  final int today;
  final List<int> last30;
  final Set<String> introducedToday;
  final Set<String> reviewedToday;

  /// 今天的全部作答（卡, 时刻），按时刻升序。
  final List<(String, int)> answersToday;
}

/// RWKV-Instant 一张合格的复习卡（见 `SrsDbStore._instantReviews`）。
typedef _InstantCard = ({String id, String deckId, double r});

/// RWKV-Instant 在一组牌组上的选卡结果：[decks] 是其中按 R 排队的 RWKV 牌组（它们的复习卡不看
/// 到期日），[eligible] 是合格的卡，按 R 升序。
class _Instant {
  const _Instant(this.decks, this.eligible);

  final Set<String> decks;
  final List<_InstantCard> eligible;
}

/// 缓存刷新的一块笔记的预读（见 [SrsDbStore._flushCaches]）：只在那次刷新的 Zone 里可见。
/// 各 Map 里「有键」= 已预读（值可能为空 / null）；没键的照常查库。
class _RefreshPrefetch {
  static final Object zoneKey = Object();

  static _RefreshPrefetch? get current =>
      Zone.current[zoneKey] as _RefreshPrefetch?;

  final Map<String, SrsEntityRow?> entities = <String, SrsEntityRow?>{};

  /// `<kind>/<entityId>` → 修改记录行。
  final Map<String, List<SrsFieldEditRow>> edits =
      <String, List<SrsFieldEditRow>>{};
  final Map<String, List<SrsReviewLogRow>> logsByCard =
      <String, List<SrsReviewLogRow>>{};
  final Map<String, List<SrsCardCacheRow>> cardsByNote =
      <String, List<SrsCardCacheRow>>{};
  final Map<String, int> serverTimes = <String, int>{};
  final Set<String> serverTimesKnown = <String>{};
}

/// 一块缓存刷新攒下的写入（见 `SrsDbStore._writeCache`）。
class _CacheWrites {
  final List<SrsNotesCacheCompanion> notes = <SrsNotesCacheCompanion>[];

  /// 不再应有的旧卡（只改 hidden）。
  final List<String> hide = <String>[];
  final List<SrsCardsCacheCompanion> cards = <SrsCardsCacheCompanion>[];

  /// 重算过的卡：它们名下的有效复习投影整卡替换成 [stats]。
  final List<String> statCards = <String>[];
  final List<SrsStatReviewsCompanion> stats = <SrsStatReviewsCompanion>[];

  bool get isEmpty => notes.isEmpty && hide.isEmpty && cards.isEmpty;

  /// 一张卡重算的结果：缓存行 + 它名下的有效复习投影。
  void addCard(
    (SrsCardsCacheCompanion, List<SrsStatReviewsCompanion>) row,
    String cardId,
  ) {
    cards.add(row.$1);
    statCards.add(cardId);
    stats.addAll(row.$2);
  }
}

/// [SrsDbStore._planNote] 的结果。
class _NotePlan {
  const _NotePlan({
    required this.note,
    required this.noteType,
    required this.term,
    required this.reading,
    required this.sortField,
    required this.expected,
    required this.noteGone,
  });

  final SrsNoteView note;
  final SrsNoteTypeView? noteType;
  final String term;
  final String reading;
  final String sortField;

  /// cardId → (templateId, clozeOrd, empty)。
  final Map<String, (String, int, bool)> expected;
  final bool noteGone;
}

/// [SrsDbStore.bulkWrites] 在一条数据库连接上的嵌套深度与要恢复的阈值。
class _BulkWriteState {
  int depth = 0;
  int restore = 1000;
}
