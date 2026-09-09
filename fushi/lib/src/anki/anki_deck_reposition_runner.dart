/// Anki 卡组新卡按词频重排——**编排层**：取卡 → 算 rank → 快照 → 写回 → 撤销。
///
/// 只碰新卡（查询串限定 `is:new`，仓储层再按 `type == 0` 二次校验）；写回前把
/// 旧位置落到 `<supportRoot>/backups/anki_reposition/`，AnkiConnect 的写入不进
/// Anki 自己的撤销栈，这份快照是唯一的后悔药。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/anki/anki_deck_reposition.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 进度阶段。
enum AnkiRepositionStage { fetch, rank, write }

class AnkiRepositionProgress {
  const AnkiRepositionProgress({
    required this.stage,
    this.done = 0,
    this.total = 0,
  });

  final AnkiRepositionStage stage;
  final int done;
  final int total;
}

typedef AnkiRepositionOnProgress = void Function(AnkiRepositionProgress p);

/// 一次写回的结果。
class AnkiRepositionOutcome {
  const AnkiRepositionOutcome({
    required this.written,
    required this.failures,
    required this.snapshot,
    this.skipped = 0,
  });

  final int written;
  final Map<int, String> failures;

  /// 计划里、但写回那一刻已经不是新卡的卡数（用户在预览期间去 Anki 学了几张）。
  /// 它们的位置**没有**被写，见 [AnkiDeckRepositionRunner.apply]。
  final int skipped;

  /// 落盘的快照文件（写回前的旧位置）。
  final File? snapshot;
}

/// 写回前落盘的旧位置。
class AnkiRepositionSnapshot {
  const AnkiRepositionSnapshot({
    required this.file,
    required this.deckName,
    required this.createdAt,
    required this.positions,
  });

  final File file;
  final String deckName;
  final DateTime createdAt;
  final List<AnkiCardDueUpdate> positions;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'deckName': deckName,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'positions':
            positions.map((AnkiCardDueUpdate u) => u.toJson()).toList(),
      };

  static AnkiRepositionSnapshot? fromJson(File file, Object? raw) {
    if (raw is! Map) return null;
    final Object? deck = raw['deckName'];
    final DateTime? createdAt =
        DateTime.tryParse(raw['createdAt']?.toString() ?? '');
    final Object? rawPositions = raw['positions'];
    if (deck is! String || createdAt == null || rawPositions is! List) {
      return null;
    }
    return AnkiRepositionSnapshot(
      file: file,
      deckName: deck,
      createdAt: createdAt,
      positions: <AnkiCardDueUpdate>[
        for (final Object? item in rawPositions)
          if (AnkiCardDueUpdate.fromJson(item) case final AnkiCardDueUpdate u)
            u,
      ],
    );
  }
}

/// 撤销结果。
class AnkiRepositionUndoOutcome {
  const AnkiRepositionUndoOutcome({
    required this.restored,
    required this.skipped,
    required this.failures,
  });

  /// 恢复到旧位置的卡数。
  final int restored;

  /// 快照里有、但现在已不是新卡（学过了 / 删了 / 移出卡组）的卡数——不碰。
  final int skipped;
  final Map<int, String> failures;
}

/// 取消信号。
class AnkiRepositionCancelled implements Exception {
  const AnkiRepositionCancelled();
}

/// 生产用的引擎查询：引擎没装载时返回空（当作没有词频，而不是崩）。
List<FushiTermResult> defaultAnkiFrequencyLookup(String expression) {
  if (!FushiDicts.isInitialized) return const <FushiTermResult>[];
  return FushiDicts.instance.query(expression);
}

class AnkiDeckRepositionRunner {
  AnkiDeckRepositionRunner(
    this._repository, {
    AnkiFrequencyLookup lookup = defaultAnkiFrequencyLookup,
    Future<Directory> Function()? snapshotDirectory,
  })  : _lookup = lookup,
        _snapshotDirectory = snapshotDirectory ?? _defaultSnapshotDirectory;

  final BaseAnkiRepository _repository;
  final AnkiFrequencyLookup _lookup;
  final Future<Directory> Function() _snapshotDirectory;

  /// 每查这么多张卡让出一次事件循环：FFI 查询是同步的，不让出进度条不会动、
  /// 取消按钮也点不到。
  static const int kYieldEvery = 32;

  bool get isSupported => _repository.supportsDeckReposition;

  static Future<Directory> _defaultSnapshotDirectory() async {
    final Directory support = await AppPaths.supportRootDirectory();
    final Directory dir =
        Directory(p.join(support.path, 'backups', 'anki_reposition'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 取 [deckName] 的新卡并算出计划；不写任何东西。
  ///
  /// 取消抛 [AnkiRepositionCancelled]；后端不支持返回 null。
  Future<AnkiRepositionPlan?> plan({
    required String deckName,
    required AnkiSettings settings,
    required AnkiRepositionRankOptions options,
    AnkiRepositionOnProgress? onProgress,
    bool Function()? shouldCancel,
  }) async {
    if (!isSupported) return null;
    onProgress?.call(
      const AnkiRepositionProgress(stage: AnkiRepositionStage.fetch),
    );
    final List<AnkiCardInfo> cards = await _repository.listNewCards(deckName);
    if (shouldCancel?.call() ?? false) throw const AnkiRepositionCancelled();
    // 按旧位置升序传入：同 rank 的卡保持用户原有次序。
    cards.sort((AnkiCardInfo a, AnkiCardInfo b) {
      final int byDue = a.due.compareTo(b.due);
      return byDue != 0 ? byDue : a.cardId.compareTo(b.cardId);
    });

    final Map<int, AnkiRepositionCard> byNote = <int, AnkiRepositionCard>{};
    final Map<String, AnkiNoteFieldRoles> rolesByModel =
        <String, AnkiNoteFieldRoles>{};
    final List<AnkiRepositionCard> ranked = <AnkiRepositionCard>[];
    int done = 0;
    for (final AnkiCardInfo card in cards) {
      final AnkiRepositionCard? cached = byNote[card.noteId];
      if (cached != null) {
        ranked.add(AnkiRepositionCard(
          card: card,
          expression: cached.expression,
          rank: cached.rank,
        ));
      } else {
        final AnkiNoteFieldRoles roles = rolesByModel.putIfAbsent(
          card.modelName,
          () => resolveNoteFieldRoles(
            modelName: card.modelName,
            fieldNames: card.fields.keys,
            settings: settings,
          ),
        );
        final AnkiRepositionCard entry = AnkiRepositionCard(
          card: card,
          expression: _plain(card.fields, roles.expression),
          rank: _rankFor(card, roles, options),
        );
        byNote[card.noteId] = entry;
        ranked.add(entry);
      }
      done++;
      if (done % kYieldEvery == 0) {
        onProgress?.call(AnkiRepositionProgress(
          stage: AnkiRepositionStage.rank,
          done: done,
          total: cards.length,
        ));
        await Future<void>.delayed(Duration.zero);
        if (shouldCancel?.call() ?? false) {
          throw const AnkiRepositionCancelled();
        }
      }
    }
    onProgress?.call(AnkiRepositionProgress(
      stage: AnkiRepositionStage.rank,
      done: cards.length,
      total: cards.length,
    ));
    return planCardPositions(deckName, ranked, rareFirst: options.rareFirst);
  }

  int? _rankFor(
    AnkiCardInfo card,
    AnkiNoteFieldRoles roles,
    AnkiRepositionRankOptions options,
  ) {
    switch (options.source) {
      case AnkiRepositionSource.field:
        final String? name = roles.rank;
        if (name == null) return null;
        return parseFieldRank(card.fields[name] ?? '');
      case AnkiRepositionSource.dictionaries:
        return dictionaryRankFor(
          expression: _plain(card.fields, roles.expression),
          reading: _plain(card.fields, roles.reading),
          options: options,
          lookup: _lookup,
        );
    }
  }

  static String _plain(Map<String, String> fields, String? name) =>
      name == null ? '' : ankiFieldPlainText(fields[name] ?? '');

  /// 写回 [plan]：先按当前新卡集合重新过滤，再落快照，再批量写位置。
  ///
  /// 为什么要重新过滤：plan 是**预览之前**算的，而预览弹窗可以开任意久，这条链路
  /// 的前提又正是「Anki 正开着」——用户完全可能在这期间去学几张。卡一旦离开新卡
  /// 队列，`due` 的语义就从「队列位置」变成「到期日」，把位置写进去等于把复习卡
  /// 打成 1970 年代到期，进度被毁；而 [undo] 也救不回来（它同样只恢复「此刻仍是
  /// 新卡」的那些）。仓储层在 `listNewCards` 里为几百毫秒的窗口做了 `type == 0`
  /// 二次校验，真正长的这个窗口反而不能不设防。
  Future<AnkiRepositionOutcome> apply(
    AnkiRepositionPlan plan, {
    AnkiRepositionOnProgress? onProgress,
  }) async {
    onProgress?.call(AnkiRepositionProgress(
      stage: AnkiRepositionStage.fetch,
      total: plan.updates.length,
    ));
    final List<AnkiCardInfo> current =
        await _repository.listNewCards(plan.deckName);
    final Set<int> stillNew = <int>{
      for (final AnkiCardInfo c in current) c.cardId,
    };
    final List<AnkiCardDueUpdate> updates = <AnkiCardDueUpdate>[
      for (final AnkiCardDueUpdate u in plan.updates)
        if (stillNew.contains(u.cardId)) u,
    ];
    final int skipped = plan.updates.length - updates.length;
    // 快照只存真的会被写的那些：撤销要回到的是「我们动过的卡」的旧位置，
    // 没动过的卡不该出现在里面。
    final List<AnkiCardDueUpdate> previous = <AnkiCardDueUpdate>[
      for (final AnkiCardDueUpdate u in plan.previous)
        if (stillNew.contains(u.cardId)) u,
    ];
    onProgress?.call(AnkiRepositionProgress(
      stage: AnkiRepositionStage.write,
      total: updates.length,
    ));
    final File snapshot = await _writeSnapshot(plan, previous);
    final AnkiCardDueWriteResult result =
        await _repository.setNewCardPositions(updates);
    return AnkiRepositionOutcome(
      written: result.written,
      failures: result.failures,
      snapshot: snapshot,
      skipped: skipped,
    );
  }

  Future<File> _writeSnapshot(
    AnkiRepositionPlan plan,
    List<AnkiCardDueUpdate> previous,
  ) async {
    final Directory dir = await _snapshotDirectory();
    final DateTime now = DateTime.now();
    final String stamp = now.toUtc().toIso8601String().replaceAll(':', '-');
    final File file = File(p.join(dir.path, 'reposition-$stamp.json'));
    final AnkiRepositionSnapshot snapshot = AnkiRepositionSnapshot(
      file: file,
      deckName: plan.deckName,
      createdAt: now,
      positions: previous,
    );
    // 先 encode 再 open：encode 抛异常时文件不会被截成零字节。
    final String body = jsonEncode(snapshot.toJson());
    await file.writeAsString(body, flush: true);
    return file;
  }

  /// [deckName] 最近一次重排的快照；没有返回 null。坏文件跳过。
  Future<AnkiRepositionSnapshot?> latestSnapshot(String deckName) async {
    final Directory dir = await _snapshotDirectory();
    AnkiRepositionSnapshot? best;
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      AnkiRepositionSnapshot? parsed;
      try {
        parsed = AnkiRepositionSnapshot.fromJson(
          entity,
          jsonDecode(await entity.readAsString()),
        );
      } catch (e) {
        debugPrint('AnkiDeckRepositionRunner: bad snapshot ${entity.path}: $e');
        continue;
      }
      if (parsed == null || parsed.deckName != deckName) continue;
      if (best == null || parsed.createdAt.isAfter(best.createdAt)) {
        best = parsed;
      }
    }
    return best;
  }

  /// 每个牌组最多保留几份快照（[pruneSnapshots] 的默认值）。
  static const int kDefaultSnapshotsPerDeck = 10;

  /// 按**牌组**各保留最近 [keep] 份快照，其余删除；返回删掉的份数。
  ///
  /// 手动重排一次写一份快照，用户点一次撤销就消耗掉；自动重排则是每批新卡
  /// 写一份、没人消费，目录会无界增长——而 [latestSnapshot] 每次都要读完整个
  /// 目录才能挑出最新的一份，于是「撤销」会随使用越来越慢。
  ///
  /// 为什么按牌组分组而不是全局留最近 N 份：全局策略下，在牌组 B 上自动重排
  /// N 次就会把牌组 A 手动重排的快照挤掉，用户在 A 上的撤销按钮**静默失效**。
  /// 解析失败的坏文件一律不删（宁可留着占位，也不让一次解析 bug 变成删数据）。
  Future<int> pruneSnapshots({int keep = kDefaultSnapshotsPerDeck}) async {
    if (keep < 0) return 0;
    final Directory dir = await _snapshotDirectory();
    final Map<String, List<AnkiRepositionSnapshot>> byDeck =
        <String, List<AnkiRepositionSnapshot>>{};
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      AnkiRepositionSnapshot? parsed;
      try {
        parsed = AnkiRepositionSnapshot.fromJson(
          entity,
          jsonDecode(await entity.readAsString()),
        );
      } catch (e) {
        debugPrint('AnkiDeckRepositionRunner: bad snapshot ${entity.path}: $e');
        continue;
      }
      if (parsed == null) continue;
      byDeck
          .putIfAbsent(parsed.deckName, () => <AnkiRepositionSnapshot>[])
          .add(parsed);
    }
    int deleted = 0;
    for (final List<AnkiRepositionSnapshot> snaps in byDeck.values) {
      if (snaps.length <= keep) continue;
      snaps.sort((AnkiRepositionSnapshot a, AnkiRepositionSnapshot b) =>
          b.createdAt.compareTo(a.createdAt));
      for (final AnkiRepositionSnapshot old in snaps.sublist(keep)) {
        try {
          await old.file.delete();
          deleted++;
        } catch (e) {
          debugPrint(
              'AnkiDeckRepositionRunner: cannot delete ${old.file.path}: $e');
        }
      }
    }
    return deleted;
  }

  /// 把 [snapshot] 里的旧位置写回去——**只恢复此刻仍是新卡的那些**（快照之后
  /// 学过的卡 `due` 已经是日期，写位置进去就是毁进度）。成功后删掉快照文件。
  Future<AnkiRepositionUndoOutcome> undo(
      AnkiRepositionSnapshot snapshot) async {
    final List<AnkiCardInfo> current =
        await _repository.listNewCards(snapshot.deckName);
    final Set<int> stillNew = <int>{
      for (final AnkiCardInfo c in current) c.cardId,
    };
    final List<AnkiCardDueUpdate> restorable = <AnkiCardDueUpdate>[
      for (final AnkiCardDueUpdate u in snapshot.positions)
        if (stillNew.contains(u.cardId)) u,
    ];
    final AnkiCardDueWriteResult result =
        await _repository.setNewCardPositions(restorable);
    // 一张都没恢复就删快照 = 把唯一的后悔药静默销毁。restorable 为空时仓储层
    // 直接 early return（written=0, failures={}），hasFailures 是 false —— 只要
    // listNewCards 这一刻因为任何原因（卡组改名、连接抖动、用户手动动过）没返回
    // 这些卡，快照就没了。必须真的写成功过才删。
    if (result.written > 0 && !result.hasFailures) {
      try {
        await snapshot.file.delete();
      } on FileSystemException catch (e) {
        debugPrint('AnkiDeckRepositionRunner: delete snapshot failed: $e');
      }
    }
    return AnkiRepositionUndoOutcome(
      restored: result.written,
      skipped: snapshot.positions.length - restorable.length,
      failures: result.failures,
    );
  }
}
