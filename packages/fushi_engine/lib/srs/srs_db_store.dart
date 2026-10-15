/// Fushi SRS 的数据库副本：事件落 Drift（schema v117 的 srs_* 表），行为与
/// fushi_srs 的 SrsMemoryReplica / SrsEventStore 一致（同一套合并函数），外加本机缓存与 app 用的查询 / 操作 API。
///
/// - 同步的只有三种事件：身份记录、修改记录、复习日志（另有不认识的事件原样保留）。
/// - 卡片行与笔记缓存只在本机，可随时由事件重建（[rebuildCaches]）。
/// - 事件创建即不可变；任何环节都不改事件内容。
library;

import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_builtin.dart';

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
  });

  final SrsDeckView deck;
  final String fullName;
  final int depth;
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
  });

  final String question;
  final String answer;
  final String css;
  final bool isEmpty;
}

class SrsDbStore implements SrsSyncReplica {
  SrsDbStore._({
    required this.db,
    required this.profileUid,
    required this.deviceId,
    required this.engine,
    required SrsTrustedClock trustedClock,
    required int Function() fallbackRolloverHour,
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
  }) async {
    final SrsDbStore s = SrsDbStore._(
      db: db,
      profileUid: profileUid,
      deviceId: deviceId,
      engine: engine,
      trustedClock: trustedClock ?? srsProcessTrustedClock(),
      fallbackRolloverHour:
          fallbackRolloverHour ?? () => SrsDayContext.defaultRolloverHour,
    );
    final bool hadLocalState = await s._loadLocal();
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
  final SrsTrustedClock _trusted;
  final int Function() _fallbackRollover;

  late SrsSyncLocalState _sync;
  late SrsEditWriter _writer;
  late HlcClock _clock;
  int _incarnation = 1;
  int _outboxSeq = 0;

  String get writerId => _sync.writerId;
  SrsTrustedClock get trustedClock => _trusted;
  bool get canSchedule => engine != null;

  // ------------------------------------------------------------------ 本机状态

  Future<bool> _hasAnyEvent() async =>
      await (db.select(db.srsEntities)
            ..where((t) => t.profileUid.equals(profileUid))
            ..limit(1))
          .getSingleOrNull() !=
      null;

  /// 读本机状态；返回之前是否存过。
  Future<bool> _loadLocal() async {
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
    _sync = SrsSyncLocalState(
      writerId: writer,
      nextBatchNo: (sync['next'] as int?) ?? 1,
      cursors: Map<String, int>.of(
        ((sync['cursors'] as Map?) ?? const <String, int>{})
            .cast<String, int>(),
      ),
      frozenBatch: sync['frozen'] is String
          ? base64Decode(sync['frozen']! as String)
          : null,
      frozenEventIds: List<String>.of(
        ((sync['frozenIds'] as List?) ?? const <String>[]).cast<String>(),
      ),
      lastSnapshotBatch: (sync['snap'] as int?) ?? 0,
      bootstrapped: sync['boot'] == true,
      lastBatchServerTime: Map<String, int>.of(
        ((sync['lastS'] as Map?) ?? const <String, int>{}).cast<String, int>(),
      ),
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

  Future<void> _saveLocal() async {
    final Map<String, Object?> j = <String, Object?>{
      'incarnation': _incarnation,
      'writerId': _sync.writerId,
      'lastSeq': _writer.lastSeq,
      'applied': _writer.applied.toJson(),
      'hlc': _clock.last.encode(),
      'outboxSeq': _outboxSeq,
      'sync': <String, Object?>{
        'next': _sync.nextBatchNo,
        'cursors': _sync.cursors,
        if (_sync.frozenBatch != null)
          'frozen': base64Encode(_sync.frozenBatch!),
        'frozenIds': _sync.frozenEventIds,
        'snap': _sync.lastSnapshotBatch,
        'boot': _sync.bootstrapped,
        'lastS': _sync.lastBatchServerTime,
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
  Future<SrsDayContext> dayContext() async {
    final SrsEntityEdits p = await _entityEdits(
      SrsEntityKind.profile,
      profileUid,
    );
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
    final List<String> list = ids.toList();
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

  Future<SrsEntityEdits> _entityEdits(SrsEntityKind kind, String id) async {
    final List<SrsFieldEditRow> rows =
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

  Future<void> _upsertServerTime(
    String eventId,
    int? s, {
    int? outboxSeq,
  }) async {
    final SrsEventLocalRow? old = await (db.select(
      db.srsEventLocal,
    )..where((t) => t.eventId.equals(eventId))).getSingleOrNull();
    final int? merged = srsMergeServerTime(old?.serverTime, s);
    if (old == null) {
      await db
          .into(db.srsEventLocal)
          .insert(
            SrsEventLocalCompanion.insert(
              eventId: eventId,
              profileUid: profileUid,
              outboxSeq: Value<int?>(outboxSeq),
              serverTime: Value<int?>(merged),
              receivedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
            ),
          );
    } else if (merged != old.serverTime || outboxSeq != null) {
      await (db.update(
        db.srsEventLocal,
      )..where((t) => t.eventId.equals(eventId))).write(
        SrsEventLocalCompanion(
          serverTime: Value<int?>(merged),
          outboxSeq: outboxSeq != null
              ? Value<int?>(outboxSeq)
              : const Value<int?>.absent(),
        ),
      );
    }
  }

  /// 落一条事件（幂等）。返回是否新落（本机产生的事件据此决定进不进发件箱）。
  Future<bool> _store(SrsEvent e) async {
    switch (e) {
      case SrsEntityEvent(:final SrsEntityRecord record):
        final SrsEntityRow? old = await (db.select(
          db.srsEntities,
        )..where((t) => t.id.equals(record.id))).getSingleOrNull();
        if (old != null) {
          final SrsEntityRecord existing = _entityFromRow(old);
          if (existing.canonical() == record.canonical()) return false;
          // 同 ID 异内容：取规范编码较小的一份（确定性兜底，只可能是 bug 或损坏）。
          if (SrsEntityRecord.pick(existing, record) == existing) return false;
        }
        await db
            .into(db.srsEntities)
            .insertOnConflictUpdate(
              SrsEntitiesCompanion.insert(
                id: record.id,
                profileUid: record.profileUid,
                kind: record.kind.wire,
                payloadJson: srsCanonicalJson(record.payload),
                createdAt: Value<int>(record.createdAt),
              ),
            );
        _markEntity(record.kind, record.id);
        return true;
      case SrsEditEvent(:final SrsFieldEdit edit):
        _writer.apply(edit);
        final SrsFieldEditRow? same = await (db.select(
          db.srsFieldEdits,
        )..where((t) => t.id.equals(edit.id))).getSingleOrNull();
        if (same != null) return false;
        final List<SrsFieldEditRow> reg =
            await (db.select(db.srsFieldEdits)..where(
                  (t) =>
                      t.entityKind.equals(edit.entityKind.wire) &
                      t.entityId.equals(edit.entityId) &
                      t.fieldKey.equals(edit.fieldKey),
                ))
                .get();
        final List<SrsFieldEdit> existing = <SrsFieldEdit>[
          for (final SrsFieldEditRow r in reg)
            SrsFieldEdit.fromJson(
              (jsonDecode(r.json) as Map).cast<String, Object?>(),
            ),
        ];
        // 被同一字段键上已有记录支配：丢掉（支配可传递，见 fushi_srs causal_context.dart）。
        if (existing.any((SrsFieldEdit b) => b.dominates(edit))) return false;
        final List<String> dominated = <String>[
          for (final SrsFieldEdit a in existing)
            if (edit.dominates(a)) a.id,
        ];
        if (dominated.isNotEmpty) {
          await (db.delete(
            db.srsFieldEdits,
          )..where((t) => t.id.isIn(dominated))).go();
        }
        await db
            .into(db.srsFieldEdits)
            .insert(
              SrsFieldEditsCompanion.insert(
                id: edit.id,
                profileUid: edit.profileUid,
                entityKind: edit.entityKind.wire,
                entityId: edit.entityId,
                fieldKey: edit.fieldKey,
                writerId: edit.dot.writerId,
                seq: edit.dot.seq,
                json: edit.canonical(),
              ),
            );
        _markEntity(edit.entityKind, edit.entityId);
        return true;
      case SrsLogEvent(:final SrsReviewLog log):
        final SrsReviewLogRow? old = await (db.select(
          db.srsReviewLogs,
        )..where((t) => t.id.equals(log.id))).getSingleOrNull();
        if (old != null) {
          if (old.json == log.canonical()) return false;
          if (log.canonical().compareTo(old.json) >= 0) return false;
        }
        await db
            .into(db.srsReviewLogs)
            .insertOnConflictUpdate(
              SrsReviewLogsCompanion.insert(
                id: log.id,
                profileUid: log.profileUid,
                cardId: log.cardId,
                kind: log.kind,
                rating: Value<int?>(log.rating),
                occurredAt: log.occurredAt,
                reviewType: log.reviewType,
                origin: log.origin,
                durationMs: Value<int>(log.durationMs),
                json: log.canonical(),
              ),
            );
        _dirtyCards.add(log.cardId);
        return true;
      case SrsUnknownEvent():
        await db
            .into(db.srsUnknownEvents)
            .insert(
              SrsUnknownEventsCompanion.insert(
                id: e.id,
                profileUid: profileUid,
                json: e.canonical(),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        return true;
    }
  }

  void _markEntity(SrsEntityKind kind, String id) {
    switch (kind) {
      case SrsEntityKind.note:
        _dirtyNotes.add(id);
      case SrsEntityKind.card:
        _dirtyCards.add(id);
      case SrsEntityKind.noteType:
        _dirtyNoteTypes.add(id);
      case SrsEntityKind.deck:
      case SrsEntityKind.profile:
        break;
    }
  }

  /// 本机产生事件：落库、进发件箱、刷新缓存。
  Future<void> _emit(List<SrsEvent> events) async {
    await db.transaction(() async {
      for (final SrsEvent e in events) {
        if (await _store(e)) {
          _outboxSeq += 1;
          await _upsertServerTime(e.id, null, outboxSeq: _outboxSeq);
        }
      }
      await _flushCaches();
      await _saveLocal();
    });
  }

  /// 导入（Anki 包 / fushi-ext）批量落一组事件：视同本机产生（进发件箱）、刷新缓存。幂等。
  ///
  /// 事件内容由调用方按铁律 C 只从来源算出（身份记录 / 复习日志）；本机 HLC 按收到对端事件的规则推进（先钳位）。
  Future<void> importEvents(List<SrsEvent> events) async {
    if (events.isEmpty) return;
    final (int nowMs, _) = now();
    for (final SrsEvent e in events) {
      final Hlc? h = switch (e) {
        SrsEditEvent(:final SrsFieldEdit edit) => edit.hlc,
        SrsLogEvent(:final SrsReviewLog log) => log.hlc,
        _ => null,
      };
      if (h != null) _clock.receive(h, trustedNowMs: nowMs);
    }
    await _emit(events);
  }

  SrsEntityRecord _entityFromRow(SrsEntityRow r) => SrsEntityRecord(
    id: r.id,
    profileUid: r.profileUid,
    kind: SrsEntityKind.tryParse(r.kind) ?? SrsEntityKind.note,
    payload: (jsonDecode(r.payloadJson) as Map).cast<String, Object?>(),
  );

  // ------------------------------------------------------------------ 内置

  /// 内置默认牌组与 Lapis（确定性 ID，每台设备都生成同一份；没改过的内置定义不写修改记录）。
  Future<void> ensureBuiltins() async {
    final List<SrsEvent> missing = <SrsEvent>[];
    for (final SrsEntityRecord r in srsBuiltinEntities(profileUid)) {
      final SrsEntityRow? row = await (db.select(
        db.srsEntities,
      )..where((t) => t.id.equals(r.id))).getSingleOrNull();
      if (row == null) missing.add(SrsEntityEvent(r));
    }
    if (missing.isNotEmpty) await _emit(missing);
  }

  String get defaultDeckId => SrsIds.builtinDefaultDeck(profileUid);
  String get lapisNoteTypeId => srsLapisNoteTypeId(profileUid);

  // ------------------------------------------------------------------ 物化

  Future<SrsNoteTypeView?> noteType(String id) async {
    final SrsEntityRow? row = await (db.select(
      db.srsEntities,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    final SrsEntityRecord rec = _entityFromRow(row);
    return SrsNoteTypeView.materialize(
      rec,
      await _entityEdits(SrsEntityKind.noteType, id),
      builtin: rec.payload['builtin'] == kSrsBuiltinLapisKey
          ? srsBuiltinLapis(profileUid)
          : null,
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
    final List<SrsNoteTypeView> out = <SrsNoteTypeView>[];
    for (final SrsEntityRow r in rows) {
      final SrsNoteTypeView? v = await noteType(r.id);
      if (v != null && v.deletedAt == null) out.add(v);
    }
    out.sort(
      (SrsNoteTypeView a, SrsNoteTypeView b) => a.name.compareTo(b.name),
    );
    return out;
  }

  Future<SrsNoteView?> note(String id) async {
    final SrsEntityRow? row = await (db.select(
      db.srsEntities,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    return SrsNoteView.materialize(
      _entityFromRow(row),
      await _entityEdits(SrsEntityKind.note, id),
    );
  }

  Future<SrsDeckTree> deckTree() async {
    final List<SrsEntityRow> rows =
        await (db.select(db.srsEntities)..where(
              (t) =>
                  t.profileUid.equals(profileUid) &
                  t.kind.equals(SrsEntityKind.deck.wire),
            ))
            .get();
    final List<SrsDeckView> decks = <SrsDeckView>[];
    for (final SrsEntityRow r in rows) {
      final SrsEntityRecord rec = _entityFromRow(r);
      final SrsDeckView v = SrsDeckView.materialize(
        rec,
        await _entityEdits(SrsEntityKind.deck, r.id),
      );
      decks.add(v);
    }
    return SrsDeckTree(decks);
  }

  // ------------------------------------------------------------------ 缓存

  Future<void> _flushCaches() async {
    if (_dirtyNoteTypes.isNotEmpty) {
      final List<String> types = _dirtyNoteTypes.toList();
      _dirtyNoteTypes.clear();
      final List<SrsEntityRow> notes =
          await (db.select(db.srsEntities)..where(
                (t) =>
                    t.profileUid.equals(profileUid) &
                    t.kind.equals(SrsEntityKind.note.wire),
              ))
              .get();
      for (final SrsEntityRow n in notes) {
        final Object? nt = (jsonDecode(n.payloadJson) as Map)['noteTypeId'];
        if (types.contains(nt)) _dirtyNotes.add(n.id);
      }
    }
    final List<String> notes = _dirtyNotes.toList();
    _dirtyNotes.clear();
    for (final String n in notes) {
      await _refreshNote(n);
    }
    final List<String> cards = _dirtyCards.toList();
    _dirtyCards.clear();
    for (final String c in cards) {
      await _refreshCardById(c);
    }
  }

  /// 丢掉全部缓存，由事件重建（缓存不同步，随时可重建）。
  Future<void> rebuildCaches() async {
    await db.transaction(() async {
      await (db.delete(
        db.srsCardsCache,
      )..where((t) => t.profileUid.equals(profileUid))).go();
      await (db.delete(
        db.srsNotesCache,
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
  }

  Map<String, String> _fieldsByName(SrsNoteView n, SrsNoteTypeView t) =>
      <String, String>{
        for (final SrsFieldDef f in t.fields) f.name: n.field(f.id),
      };

  Map<String, String> _idToName(SrsNoteTypeView t) => <String, String>{
    for (final SrsFieldDef f in t.fields) f.id: f.name,
  };

  Future<void> _refreshNote(String noteId) async {
    final SrsNoteView? n = await note(noteId);
    if (n == null) return;
    final SrsNoteTypeView? t = await noteType(n.noteTypeId);
    final String term = t?.termFieldId == null
        ? ''
        : srsTermKey(n.field(t!.termFieldId!));
    final String reading = t?.builtinKey == kSrsBuiltinLapisKey
        ? srsReadingKey(n.field(srsLapisReadingFieldId(profileUid)))
        : '';
    final String sortField = t == null || t.fields.isEmpty
        ? ''
        : ankiStripHtml(n.field(t.fields.first.id)).trim();
    await db
        .into(db.srsNotesCache)
        .insertOnConflictUpdate(
          SrsNotesCacheCompanion.insert(
            id: n.id,
            profileUid: profileUid,
            noteTypeId: n.noteTypeId,
            guid: n.guid,
            createdAt: n.createdAt,
            deckId: Value<String?>(n.deckId),
            deletedAt: Value<int?>(n.deletedAt),
            termKey: Value<String>(term),
            readingKey: Value<String>(reading),
            sortField: Value<String>(
              sortField.length > 200 ? sortField.substring(0, 200) : sortField,
            ),
            tagsJson: Value<String>(jsonEncode(n.tags)),
            pendingDecision: Value<bool>(n.hasPendingDecision),
            updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
          ),
        );

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
    final List<SrsCardCacheRow> existing = await (db.select(
      db.srsCardsCache,
    )..where((c) => c.noteId.equals(noteId))).get();
    for (final SrsCardCacheRow c in existing) {
      if (!expected.containsKey(c.id)) {
        await (db.update(db.srsCardsCache)..where((x) => x.id.equals(c.id)))
            .write(const SrsCardsCacheCompanion(hidden: Value<bool>(true)));
      }
    }
    for (final MapEntry<String, (String, int, bool)> e in expected.entries) {
      final (String tplId, int ord, bool empty) = e.value;
      await _refreshCard(
        cardId: e.key,
        noteId: n.id,
        templateId: tplId,
        clozeOrd: ord,
        noteDeckId: n.deckId,
        noteCreatedAt: n.createdAt,
        hidden: noteGone || empty,
      );
    }
  }

  Future<void> _refreshCardById(String cardId) async {
    final SrsCardCacheRow? c = await (db.select(
      db.srsCardsCache,
    )..where((x) => x.id.equals(cardId))).getSingleOrNull();
    if (c == null) return; // 日志先于笔记到达：笔记到时一起生成。
    final SrsNoteCacheRow? n = await (db.select(
      db.srsNotesCache,
    )..where((x) => x.id.equals(c.noteId))).getSingleOrNull();
    await _refreshCard(
      cardId: cardId,
      noteId: c.noteId,
      templateId: c.templateId,
      clozeOrd: c.clozeOrd,
      noteDeckId: n?.deckId,
      noteCreatedAt: n?.createdAt ?? c.noteCreatedAt,
      hidden: c.hidden,
    );
  }

  Future<SrsCardHistory> history(String cardId) async {
    final List<SrsReviewLogRow> rows = await (db.select(
      db.srsReviewLogs,
    )..where((t) => t.cardId.equals(cardId))).get();
    final List<SrsReviewLog> logs = <SrsReviewLog>[
      for (final SrsReviewLogRow r in rows)
        SrsReviewLog.fromJson(
          (jsonDecode(r.json) as Map).cast<String, Object?>(),
        ),
    ];
    final Map<String, int> s = await _serverTimesFor(logs.map((l) => l.id));
    return SrsCardHistory(logs, serverTimeOf: (String id) => s[id]);
  }

  Future<void> _refreshCard({
    required String cardId,
    required String noteId,
    required String templateId,
    required int clozeOrd,
    required String? noteDeckId,
    required int noteCreatedAt,
    required bool hidden,
  }) async {
    final SrsCardFlags flags = SrsCardFlags.materialize(
      await _entityEdits(SrsEntityKind.card, cardId),
      noteDeckId: noteDeckId,
      fallbackDeckId: defaultDeckId,
    );
    final SrsCardHistory h = await history(cardId);
    final SrsScheduleResult s = h.state;
    await db
        .into(db.srsCardsCache)
        .insertOnConflictUpdate(
          SrsCardsCacheCompanion.insert(
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
          ),
        );
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
  }) async {
    final SrsEntityEdits current = await _entityEdits(kind, entityId);
    final (int nowMs, SrsTimeSource src) = now();
    final List<SrsFieldEdit> out = <SrsFieldEdit>[];
    for (final MapEntry<String, Object?> e in values.entries) {
      final SrsRegister? reg = current[e.key];
      if (reg != null && srsEditIsNoop(reg, e.value)) continue;
      out.add(
        _writer.create(
          profileUid: profileUid,
          entityKind: kind,
          entityId: entityId,
          fieldKey: e.key,
          value: e.value,
          hlc: _clock.tick(nowMs),
          timeSource: src,
          machine: machine,
        ),
      );
    }
    if (out.isNotEmpty) {
      await _emit(<SrsEvent>[
        for (final SrsFieldEdit e in out) SrsEditEvent(e),
      ]);
    }
    return out;
  }

  // ------------------------------------------------------------------ 牌组

  /// 新建牌组。ID 由「父::子」全名确定性派生（SrsIds.deck）：多台设备离线各建同名牌组不会出重复；
  /// 同名牌组已存在（含已删除的）时复活并沿用它。身份记录不含本机时刻（createdAt = 0），同 ID 同内容。
  Future<String> createDeck(String name, {String? parentId}) async {
    final SrsDeckTree tree = await deckTree();
    final String parentPath = parentId == null || tree[parentId] == null
        ? ''
        : '${tree.fullName(parentId)}::';
    final String id = SrsIds.deck(profileUid, '$parentPath$name');
    await _emit(<SrsEvent>[
      SrsEntityEvent(
        SrsEntityRecord(
          id: id,
          profileUid: profileUid,
          kind: SrsEntityKind.deck,
          payload: const <String, Object?>{'createdAt': 0},
        ),
      ),
    ]);
    final SrsEntityEdits current = await _entityEdits(SrsEntityKind.deck, id);
    await editFields(SrsEntityKind.deck, id, <String, Object?>{
      SrsFieldKeys.name: name.trim(),
      if (parentId != null) SrsFieldKeys.deckParent: parentId,
      if (current.deletedAt != null) SrsFieldKeys.deleted: null,
    });
    return id;
  }

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

  Future<void> deleteDeck(String deckId) async {
    if (deckId == defaultDeckId) {
      throw StateError('the default deck cannot be deleted');
    }
    final SrsDeckTree tree = await deckTree();
    final List<String> sub = tree.subtree(deckId);
    // 子树里的卡片移到被删牌组的父牌组（没有父牌组则到默认牌组），每张卡一条修改记录。
    final String target = tree.parentOf(deckId) ?? defaultDeckId;
    final List<SrsCardCacheRow> cards = await (db.select(
      db.srsCardsCache,
    )..where((c) => c.deckId.isIn(sub))).get();
    for (final SrsCardCacheRow c in cards) {
      await editField(SrsEntityKind.card, c.id, SrsFieldKeys.cardDeck, target);
    }
    final (int nowMs, _) = now();
    for (final String id in sub) {
      await editField(SrsEntityKind.deck, id, SrsFieldKeys.deleted, nowMs);
    }
  }

  Future<SrsSchedulingConfig> schedulingConfigFor(String deckId) async {
    final SrsDeckTree tree = await deckTree();
    final String id = tree[deckId] == null ? defaultDeckId : deckId;
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
  }) async {
    final (int nowMs, _) = now();
    final String g = guid ?? newNoteGuid();
    final String id = SrsIds.note(profileUid, g);
    await _emit(<SrsEvent>[
      SrsEntityEvent(
        SrsEntityRecord(
          id: id,
          profileUid: profileUid,
          kind: SrsEntityKind.note,
          payload: <String, Object?>{
            'noteTypeId': noteTypeId,
            'guid': g,
            'createdAt': createdAt ?? nowMs,
          },
        ),
      ),
    ]);
    await editFields(SrsEntityKind.note, id, <String, Object?>{
      for (final MapEntry<String, String> f in fieldsById.entries)
        if (f.value.isNotEmpty) SrsFieldKeys.noteField(f.key): f.value,
      if (tags.isNotEmpty) SrsFieldKeys.noteTags: tags,
      if (source != null) SrsFieldKeys.noteSource: source.toJson(),
      SrsFieldKeys.noteDeck: deckId ?? defaultDeckId,
    });
    return id;
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

  Future<void> deleteNote(String noteId) async {
    final (int nowMs, _) = now();
    await editField(SrsEntityKind.note, noteId, SrsFieldKeys.deleted, nowMs);
  }

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
    return _ops.preview(
      cardId: cardId,
      history: await history(cardId),
      config: await schedulingConfigFor(c.deckId),
      ctx: _logContext(day),
    );
  }

  /// 评分 = 一个事务：算新状态 → 写日志 → 更新卡片缓存。返回日志（撤销栈用）。
  Future<SrsReviewLog> answer(
    String cardId,
    int rating, {
    int durationMs = 0,
  }) async {
    final SrsCardCacheRow c = (await cardRow(cardId))!;
    final SrsDayContext day = await dayContext();
    final SrsReviewLog log = _ops.answer(
      cardId: cardId,
      history: await history(cardId),
      rating: rating,
      config: await schedulingConfigFor(c.deckId),
      ctx: _logContext(day),
      durationMs: durationMs,
    );
    await _emit(<SrsEvent>[SrsLogEvent(log)]);
    return log;
  }

  /// 撤销一条评分；它已不是该卡最后一条有效日志（别的设备同步来了更新的复习）时返回 false。
  Future<bool> undo(String cardId, String logId) async {
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
  }

  Future<void> resetCard(String cardId) async {
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
  }

  Future<void> setDueDay(String cardId, int dueDay) async {
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
  }

  /// 「立即重排整组」：给子树里每张复习卡写一条 reschedule 日志。
  Future<int> rescheduleDeck(String deckId) async {
    final SrsDeckTree tree = await deckTree();
    final List<String> sub = tree.subtree(deckId);
    final SrsDayContext day = await dayContext();
    final List<SrsCardCacheRow> cards =
        await (db.select(db.srsCardsCache)..where(
              (c) => c.deckId.isIn(sub) & c.queue.equals(SrsQueue.review.wire),
            ))
            .get();
    final List<SrsEvent> logs = <SrsEvent>[];
    for (final SrsCardCacheRow c in cards) {
      final SrsReviewLog? l = _ops.reschedule(
        cardId: c.id,
        history: await history(c.id),
        config: await schedulingConfigFor(c.deckId),
        ctx: _logContext(day),
      );
      if (l != null) logs.add(SrsLogEvent(l));
    }
    if (logs.isNotEmpty) await _emit(logs);
    return logs.length;
  }

  // ------------------------------------------------------------------ 查询

  Future<Map<int, int>> _reviewsPerDay(
    SrsDayContext day,
    int today,
    int days,
  ) async {
    final int from = day.dayStartMs(today - days + 1);
    final List<SrsReviewLogRow> rows =
        await (db.select(db.srsReviewLogs)..where(
              (t) =>
                  t.profileUid.equals(profileUid) &
                  t.kind.equals(SrsLogKind.review) &
                  t.occurredAt.isBiggerOrEqualValue(from),
            ))
            .get();
    final Map<int, int> out = <int, int>{};
    for (final SrsReviewLogRow r in rows) {
      final int d = day.dayIndexOf(r.occurredAt);
      out[d] = (out[d] ?? 0) + 1;
    }
    return out;
  }

  bool _isLive(SrsCardCacheRow c, int today) =>
      !c.hidden &&
      !c.suspended &&
      c.scheduler == SrsScheduler.fushi &&
      (c.buriedUntilDay == null || c.buriedUntilDay! <= today);

  /// 计数用的一次性上下文：牌组树、「今天」、最近 30 天每天的复习数、今天已学的新卡 / 已复习的卡。
  Future<_CountContext> _countContext() async {
    final SrsDeckTree tree = await deckTree();
    final SrsDayContext day = await dayContext();
    final (int nowMs, _) = now();
    final int today = day.dayIndexOf(nowMs);
    final Map<int, int> perDay = await _reviewsPerDay(day, today, 30);
    final (Set<String> introduced, Set<String> reviewed) = await _todayActivity(
      day,
      today,
    );
    return _CountContext(
      tree: tree,
      nowMs: nowMs,
      today: today,
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

  /// 一个牌组（含子树）的计数。[cards] 至少包含该子树的全部卡片。
  SrsDeckSummary _summarize(
    SrsDeckView d,
    _CountContext ctx,
    Iterable<SrsCardCacheRow> cards,
  ) {
    final Set<String> sub = ctx.tree.subtree(d.id).toSet();
    int newAvail = 0,
        learn = 0,
        due = 0,
        total = 0,
        newDone = 0,
        reviewDone = 0;
    for (final SrsCardCacheRow c in cards) {
      if (!sub.contains(c.deckId) || c.hidden) continue;
      total++;
      if (ctx.introducedToday.contains(c.id)) newDone++;
      if (ctx.reviewedToday.contains(c.id)) reviewDone++;
      if (!_isLive(c, ctx.today)) continue;
      switch (SrsQueue.parse(c.queue)) {
        case SrsQueue.newCard:
          newAvail++;
        case SrsQueue.learning:
        case SrsQueue.relearning:
          if ((c.dueAt ?? 0) <= ctx.nowMs + 20 * 60000) learn++;
        case SrsQueue.review:
          if ((c.dueDay ?? 0) <= ctx.today) due++;
      }
    }
    final SrsNewCardBudget budget = srsComputeNewCardBudget(
      newPerDayLimit: d.newPerDay,
      dueReviews: due,
      reviewsPerDayLast30: ctx.last30,
    );
    return SrsDeckSummary(
      deck: d,
      fullName: ctx.tree.fullName(d.id),
      depth: _depthOf(ctx.tree, d.id),
      newCount: min(newAvail, max(0, budget.allowed - newDone)),
      learnCount: learn,
      reviewCount: min(due, max(0, d.reviewsPerDay - reviewDone)),
      newBudget: budget,
      totalCards: total,
    );
  }

  /// 牌组列表：每个牌组（含子树）的新卡 / 学习 / 到期数。卡片缓存只读一次。
  Future<List<SrsDeckSummary>> deckSummaries() async {
    final _CountContext ctx = await _countContext();
    final List<SrsCardCacheRow> cards = await (db.select(
      db.srsCardsCache,
    )..where((c) => c.profileUid.equals(profileUid))).get();
    final List<SrsDeckSummary> out =
        <SrsDeckSummary>[
          for (final SrsDeckView d in ctx.tree.decks) _summarize(d, ctx, cards),
        ]..sort(
          (SrsDeckSummary a, SrsDeckSummary b) =>
              a.fullName.compareTo(b.fullName),
        );
    return out;
  }

  /// 今天的活动：从新卡学起的卡（新卡配额）与复习了的复习卡（复习上限）。
  Future<(Set<String>, Set<String>)> _todayActivity(
    SrsDayContext day,
    int today,
  ) async {
    final int from = day.dayStartMs(today);
    final List<SrsReviewLogRow> rows =
        await (db.select(db.srsReviewLogs)..where(
              (t) =>
                  t.profileUid.equals(profileUid) &
                  t.kind.equals(SrsLogKind.review) &
                  t.occurredAt.isBiggerOrEqualValue(from),
            ))
            .get();
    final Set<String> introduced = <String>{};
    final Set<String> reviewed = <String>{};
    for (final SrsReviewLogRow r in rows) {
      if (r.reviewType == SrsReviewType.review) reviewed.add(r.cardId);
      if (r.reviewType != SrsReviewType.learn) continue;
      final Object? res = (jsonDecode(r.json) as Map)['res'];
      if (res is Map && res['reps'] == 1) introduced.add(r.cardId);
    }
    return (introduced, reviewed);
  }

  /// 下一张要复习的卡：到期的学习卡 → 到期复习卡（可提取度从低到高）→ 新卡（笔记创建时刻, cardId）。
  /// 只查目标子树里可见的卡（一次过滤查询），不扫全表。
  Future<String?> nextCard(
    String deckId, {
    Set<String> exclude = const <String>{},
  }) async {
    final _CountContext ctx = await _countContext();
    final SrsDeckView? deck = ctx.tree[deckId];
    if (deck == null) return null;
    final Set<String> sub = ctx.tree.subtree(deckId).toSet();
    final List<SrsCardCacheRow> inSubtree =
        await (db.select(db.srsCardsCache)..where(
              (c) =>
                  c.profileUid.equals(profileUid) &
                  c.deckId.isIn(sub) &
                  c.hidden.equals(false),
            ))
            .get();
    final SrsDeckSummary sum = _summarize(deck, ctx, inSubtree);
    final int nowMs = ctx.nowMs;
    final List<SrsCardCacheRow> cards = <SrsCardCacheRow>[
      for (final SrsCardCacheRow c in inSubtree)
        if (_isLive(c, ctx.today) && !exclude.contains(c.id)) c,
    ];
    final List<SrsCardCacheRow> learning =
        cards
            .where(
              (SrsCardCacheRow c) =>
                  (c.queue == SrsQueue.learning.wire ||
                      c.queue == SrsQueue.relearning.wire) &&
                  (c.dueAt ?? 0) <= nowMs + 20 * 60000,
            )
            .toList()
          ..sort(
            (SrsCardCacheRow a, SrsCardCacheRow b) =>
                (a.dueAt ?? 0).compareTo(b.dueAt ?? 0),
          );
    if (learning.isNotEmpty && (learning.first.dueAt ?? 0) <= nowMs) {
      return learning.first.id;
    }
    if (sum.reviewCount > 0) {
      final List<SrsCardCacheRow> due = cards
          .where(
            (SrsCardCacheRow c) =>
                c.queue == SrsQueue.review.wire && (c.dueDay ?? 0) <= ctx.today,
          )
          .toList();
      double r(SrsCardCacheRow c) {
        final double s = c.stability ?? 1;
        final double elapsed = c.lastReviewedAt == null
            ? 0
            : (nowMs - c.lastReviewedAt!) / 86400000;
        // 复习排序只需单调近似：FSRS 遗忘曲线 R = (1 + t/(9S))^-1。
        return 1 / (1 + elapsed / (9 * s));
      }

      due.sort((SrsCardCacheRow a, SrsCardCacheRow b) => r(a).compareTo(r(b)));
      if (due.isNotEmpty) return due.first.id;
    }
    if (sum.newCount > 0) {
      SrsCardCacheRow? first;
      for (final SrsCardCacheRow c in cards) {
        if (c.queue != SrsQueue.newCard.wire) continue;
        if (first == null ||
            c.noteCreatedAt < first.noteCreatedAt ||
            (c.noteCreatedAt == first.noteCreatedAt &&
                c.id.compareTo(first.id) < 0)) {
          first = c;
        }
      }
      if (first != null) return first.id;
    }
    if (learning.isNotEmpty) return learning.first.id;
    return null;
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
      deckName: tree[c.deckId] == null ? '' : tree.fullName(c.deckId),
    );
  }

  /// 渲染卡面（模板正文里的 fieldId 引用换回名字后交给 Anki 渲染器）。
  Future<SrsRenderedCard?> renderCard(String cardId) async {
    final SrsCardDetail? d = await cardDetail(cardId);
    final SrsTemplateDef? tpl = d?.template;
    if (d == null || tpl == null) return null;
    final Map<String, String> idToName = _idToName(d.noteType);
    final AnkiRenderedCard r = renderAnkiCard(
      questionTemplate: templateIdsToNames(tpl.front, idToName),
      answerTemplate: templateIdsToNames(tpl.back, idToName),
      noteFields: _fieldsByName(d.note, d.noteType),
      cardOrd: d.noteType.isCloze ? d.card.clozeOrd - 1 : tpl.ord,
      isCloze: d.noteType.isCloze,
      specials: AnkiCardSpecialFields(
        tags: d.note.tags,
        deckName: d.deckName,
        noteTypeName: d.noteType.name,
        cardName: tpl.name,
        cardFlag: d.card.flag,
        cardId: d.card.id,
      ),
    );
    return SrsRenderedCard(
      question: r.question,
      answer: r.answer,
      css: d.noteType.css,
      isEmpty: r.isEmpty,
    );
  }

  /// 词状态查询（B-3）：按 termKey（与可选读音）索引。一个词多张卡时取最需要复习的一张，带卡数。
  Future<Map<String, SrsTermStatus>> lookupTermStatus(
    List<SrsTermQuery> terms,
  ) async {
    final Map<String, SrsTermStatus> out = <String, SrsTermStatus>{};
    for (final SrsTermQuery q in terms) {
      final String key = q.termKey;
      if (key.isEmpty) continue;
      final List<SrsNoteCacheRow> notes =
          await (db.select(db.srsNotesCache)..where(
                (n) =>
                    n.profileUid.equals(profileUid) &
                    n.termKey.equals(key) &
                    n.deletedAt.isNull(),
              ))
              .get();
      final String rk = q.readingKey;
      final List<SrsNoteCacheRow> matched = rk.isEmpty
          ? notes
          : notes
                .where(
                  (SrsNoteCacheRow n) =>
                      n.readingKey.isEmpty || n.readingKey == rk,
                )
                .toList();
      if (matched.isEmpty) continue;
      final List<SrsCardCacheRow> cards =
          await (db.select(db.srsCardsCache)..where(
                (c) =>
                    c.noteId.isIn(matched.map((SrsNoteCacheRow n) => n.id)) &
                    c.hidden.equals(false),
              ))
              .get();
      if (cards.isEmpty) continue;
      final List<SrsTermStatus> st = <SrsTermStatus>[
        for (final SrsCardCacheRow c in cards)
          SrsTermStatus(
            cardId: c.id,
            noteId: c.noteId,
            queue: SrsQueue.parse(c.queue),
            suspended: c.suspended,
            deckId: c.deckId,
            cardCount: cards.length,
            dueDay: c.dueDay,
            dueAt: c.dueAt,
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
  Future<List<String>> cardIdsInDecks(Set<String> deckIds) async =>
      (await (db.select(db.srsCardsCache)
                ..where((c) => c.deckId.isIn(deckIds) & c.hidden.equals(false)))
              .get())
          .map((SrsCardCacheRow c) => c.id)
          .toList();

  Future<List<SrsCardCacheRow>> cardsOfNote(String noteId) => (db.select(
    db.srsCardsCache,
  )..where((c) => c.noteId.equals(noteId))).get();

  /// 有待裁决（内容类冲突 / 删除与并发修改）的笔记。
  Future<List<SrsNoteCacheRow>> notesPendingDecision() =>
      (db.select(db.srsNotesCache)..where(
            (n) =>
                n.profileUid.equals(profileUid) &
                n.pendingDecision.equals(true),
          ))
          .get();

  /// 标志类 / 设置类的同步冲突（被覆盖的候选），不含机器产出（第六轮审查第 10 条）。
  Future<List<(SrsEntityKind, String, SrsRegister)>> syncConflicts() async {
    final List<SrsFieldEditRow> rows = await (db.select(
      db.srsFieldEdits,
    )..where((t) => t.profileUid.equals(profileUid))).get();
    final Map<String, List<SrsFieldEdit>> byReg =
        <String, List<SrsFieldEdit>>{};
    for (final SrsFieldEditRow r in rows) {
      final SrsFieldEdit e = SrsFieldEdit.fromJson(
        (jsonDecode(r.json) as Map).cast<String, Object?>(),
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
      if (srsFieldClassOf(w.entityKind, w.fieldKey) == SrsFieldClass.content) {
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
  ) async {
    final (int nowMs, SrsTimeSource src) = now();
    final SrsFieldEdit e = _writer.create(
      profileUid: profileUid,
      entityKind: kind,
      entityId: entityId,
      fieldKey: key,
      value: value,
      hlc: _clock.tick(nowMs),
      timeSource: src,
    );
    await _emit(<SrsEvent>[SrsEditEvent(e)]);
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
  Future<void> saveSyncState(SrsSyncLocalState state) async {
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
  }

  @override
  Future<List<SrsEvent>> unpublishedEvents() async {
    final List<SrsEventLocalRow> rows =
        await (db.select(db.srsEventLocal)
              ..where(
                (t) =>
                    t.profileUid.equals(profileUid) & t.outboxSeq.isNotNull(),
              )
              ..orderBy(<OrderClauseGenerator<$SrsEventLocalTable>>[
                (t) => OrderingTerm.asc(t.outboxSeq),
              ]))
            .get();
    final List<SrsEvent> out = <SrsEvent>[];
    for (final SrsEventLocalRow r in rows) {
      final SrsEvent? e = await _loadEvent(r.eventId);
      if (e != null) out.add(e);
    }
    return out;
  }

  Future<SrsEvent?> _loadEvent(String id) async {
    final SrsEntityRow? ent = await (db.select(
      db.srsEntities,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (ent != null) return SrsEntityEvent(_entityFromRow(ent));
    final SrsFieldEditRow? ed = await (db.select(
      db.srsFieldEdits,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (ed != null) {
      return SrsEditEvent(
        SrsFieldEdit.fromJson(
          (jsonDecode(ed.json) as Map).cast<String, Object?>(),
        ),
      );
    }
    final SrsReviewLogRow? lg = await (db.select(
      db.srsReviewLogs,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (lg != null) {
      return SrsLogEvent(
        SrsReviewLog.fromJson(
          (jsonDecode(lg.json) as Map).cast<String, Object?>(),
        ),
      );
    }
    final SrsUnknownEventRow? u = await (db.select(
      db.srsUnknownEvents,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (u != null) {
      return SrsUnknownEvent(
        (jsonDecode(u.json) as Map).cast<String, Object?>(),
      );
    }
    // 本机未发布的修改记录可能已被（本机更晚的）修改支配而丢弃：
    // 它在本机已不存在，后一条记录的 ctx 覆盖它，无需再发。
    return null;
  }

  @override
  Future<void> markPublished(List<String> eventIds) async {
    for (int i = 0; i < eventIds.length; i += 500) {
      await (db.update(db.srsEventLocal)..where(
            (t) => t.eventId.isIn(
              eventIds.sublist(i, min(i + 500, eventIds.length)),
            ),
          ))
          .write(const SrsEventLocalCompanion(outboxSeq: Value<int?>(null)));
    }
  }

  @override
  Future<void> requeue(List<String> eventIds) async {
    for (final String id in eventIds) {
      _outboxSeq += 1;
      await _upsertServerTime(id, null, outboxSeq: _outboxSeq);
    }
    await _saveLocal();
  }

  @override
  Future<void> applyRemote(List<SrsEvent> events, {int? serverTimeMs}) async {
    final (int nowMs, _) = now();
    await db.transaction(() async {
      for (final SrsEvent e in events) {
        if (e is SrsEntityEvent && e.record.profileUid != profileUid) continue;
        await _store(e);
        await _upsertServerTime(e.id, serverTimeMs);
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
  }

  @override
  Future<void> observeServerTimes(Map<String, int> times) async {
    await db.transaction(() async {
      for (final MapEntry<String, int> e in times.entries) {
        await _upsertServerTime(e.key, e.value);
      }
      // S 变化可能改变排序：相关卡片的「最后一条有效日志」要重算。
      final List<SrsReviewLogRow> logs = await (db.select(
        db.srsReviewLogs,
      )..where((t) => t.id.isIn(times.keys))).get();
      _dirtyCards.addAll(logs.map((SrsReviewLogRow r) => r.cardId));
      await _flushCaches();
    });
  }

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
  Future<void> anchorTime(int serverTimeMs) async {
    _trusted.anchor(serverTimeMs: serverTimeMs);
    await _saveLocal();
  }

  /// 恢复备份后调用：本机换新化身号（不复用旧 writerId），重新起步读快照。
  ///
  /// 本机发布元信息（srs_event_local）不进备份，恢复后不知道备份里哪些事件已经发布过：
  /// 一律由新化身重新发布（事件不可变、按 ID 取并集，重复发布无害；代价相当于写一次快照）。
  Future<void> afterRestore() async {
    _incarnation += 1;
    _sync = SrsSyncLocalState(writerId: '$deviceId#$_incarnation');
    _writer = SrsEditWriter(writerId: _sync.writerId);
    for (final SrsEvent e in await exportAll()) {
      if (e is SrsEditEvent) _writer.apply(e.edit);
    }
    _clock = HlcClock(
      _sync.writerId,
      last: _rehome(_clock.last, _sync.writerId),
    );
    await (db.delete(
      db.srsEventLocal,
    )..where((t) => t.profileUid.equals(profileUid))).go();
    await requeue(<String>[for (final SrsEvent e in await exportAll()) e.id]);
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

  Map<int, String>? _ankiNoteIndex;
  Map<int, String>? _ankiCardIndex;

  Future<void> _rebuildAnkiNumericIndex() async {
    final List<SrsNoteCacheRow> notes = await (db.select(
      db.srsNotesCache,
    )..where((n) => n.profileUid.equals(profileUid))).get();
    final List<SrsCardCacheRow> cards = await allCardRows();
    _ankiNoteIndex = <int, String>{
      for (final SrsNoteCacheRow n in notes) SrsIds.ankiNumericId(n.id): n.id,
    };
    _ankiCardIndex = <int, String>{
      for (final SrsCardCacheRow c in cards) SrsIds.ankiNumericId(c.id): c.id,
    };
  }

  /// AnkiConnect 整数笔记 id（[SrsIds.ankiNumericId]）→ noteId。本机索引，不同步；
  /// 未命中时重建一次（id 由 UUID 确定性派生，旧索引只会缺新条目、不会映错）。
  Future<String?> noteIdForAnkiNumericId(int ankiId) async {
    String? hit = _ankiNoteIndex?[ankiId];
    if (hit != null) return hit;
    await _rebuildAnkiNumericIndex();
    hit = _ankiNoteIndex![ankiId];
    return hit;
  }

  /// AnkiConnect 整数卡片 id → cardId（同 [noteIdForAnkiNumericId]）。
  Future<String?> cardIdForAnkiNumericId(int ankiId) async {
    String? hit = _ankiCardIndex?[ankiId];
    if (hit != null) return hit;
    await _rebuildAnkiNumericIndex();
    hit = _ankiCardIndex![ankiId];
    return hit;
  }
}

/// [SrsDbStore] 计数用的一次性上下文。
class _CountContext {
  const _CountContext({
    required this.tree,
    required this.nowMs,
    required this.today,
    required this.last30,
    required this.introducedToday,
    required this.reviewedToday,
  });

  final SrsDeckTree tree;
  final int nowMs;
  final int today;
  final List<int> last30;
  final Set<String> introducedToday;
  final Set<String> reviewedToday;
}
