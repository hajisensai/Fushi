/// AI 管库 v3 的批量变更集（spec `docs/specs/2026-11-22-ai-library-agent-design.md`
/// §2.1 / §2.2 / §3.3）：长程整理模式下，模型一次提交一整份「合集归属 + 关系网」改动，
/// 这里解析、逐条校验、以 **AI 身份**落库，并给出一份可撤销的载荷。
///
/// - 合集部分转成 [OrganizeAction] 交 [applyOrganizeActions] 执行，整份变更集记**一条**
///   `library_organize_runs`（trigger = [kLibraryChangesetTrigger]），撤销走
///   [undoLibraryOrganizeRun]；
/// - 关系部分：`link` / `relink` 走 [FushiDatabase.setAiMediaLinkRelation]（改关系时旧行
///   标成「被取代」而不是否决），`unlink` 走 [FushiDatabase.removeMediaLink]（AI 判定
///   这一对不相关 = 否决墓碑），各自收回执；
/// - 每条独立校验，不过的进 `skipped`（原因码见 [LibraryChangeSkip]），其余照常执行；
/// - 条目级问题（某个条目钉住 / 跨域 / 被用户移出过 / 与权威作品身份矛盾）只丢那一个
///   条目，记在这一条的 `itemsSkipped` 里；整条都没有可做的才进 `skipped`。
///
/// 顺序语义：变更集按下标顺序执行，后一条看到的是前一条执行后的库（真执行时每条落库后
/// 重读受影响的合集；`dryRun` 时在内存模型里推演合集部分）。`dryRun` 不写库；关系部分的
/// 预演只看库的当前状态，不推演本批前面的关系改动。
library;

import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_facts.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';

/// 变更集那条整理记录的 `trigger`（与 `manual` / `auto` 并列；`library_organize_runs`
/// 是设备本地表，开放文本，不同步）。
const String kLibraryChangesetTrigger = 'agent';

/// 新建合集的类型（与整理器新建的同一种）。
const String kLibraryChangesetCollectionType = 'playlist';

/// `skipped` 的原因码（spec §3.3）。
abstract final class LibraryChangeSkip {
  /// 引用不存在（条目 / 合集 / 端点 / 要改的连接）。
  static const String unknownRef = 'unknown_ref';

  /// 条目与目标合集不在同一个库页域（书 / 漫画 / 视频 / 游戏）。
  static const String crossDomain = 'cross_domain';

  /// 目录合集（成员与名字由磁盘目录决定）。
  static const String folderCollection = 'folder_collection';

  /// 用户钉住的成员（亲手放进来 / 否决过 AI 的移出）。
  static const String pinnedByUser = 'pinned_by_user';

  /// 新名字已被别的合集占着（或是用户删过的分组）。
  static const String nameTaken = 'name_taken';

  /// 用户否决过（移出过这个成员 / 拒绝过这个分组 / 否决过这一对关系）。
  static const String vetoed = 'vetoed';

  /// 用户确认过的连接，AI 不改。
  static const String userConfirmed = 'user_confirmed';

  /// 已经是这个样子（没有要做的）。
  static const String exists = 'exists';

  /// 格式 / 取值不对。
  static const String invalid = 'invalid';

  /// 与条目的权威作品身份矛盾（BUG-5460，`organize_work_identity.dart`）：把它从
  /// 同一部作品的合集里拆出来，或放进来源（媒体服务器 / 在线源）给的另一部剧的合集。
  static const String workIdentity = 'work_identity';
}

// ── 契约：解析 ──────────────────────────────────────────────────────────────

/// 变更种类（`op` 的线上值 = [name]）。
enum LibraryChangeOp { move, merge, rename, dissolve, link, unlink, relink }

/// 一条变更。[index] 是它在 `changes` 里的下标，[why] 是模型给的理由（记进整理记录）。
sealed class LibraryChange {
  const LibraryChange({required this.index, this.why});

  final int index;
  final String? why;

  /// 线上 `op`（解析失败的条目原样带回模型写的值）。
  String get opName;
}

/// `move`：[items] 移进 [to]（`C<id>` / `new:<名字>` / `standalone`）；[from] 省略 = 从
/// 条目当前所在的全部非目录合集移出。
final class LibraryMoveChange extends LibraryChange {
  const LibraryMoveChange({
    required super.index,
    required this.items,
    required this.to,
    this.from,
    super.why,
  });

  final List<String> items;
  final String to;
  final String? from;

  @override
  String get opName => LibraryChangeOp.move.name;
}

/// `merge`：[from] 的合集并进 [into]。
final class LibraryMergeChange extends LibraryChange {
  const LibraryMergeChange({
    required super.index,
    required this.into,
    required this.from,
    super.why,
  });

  final String into;
  final List<String> from;

  @override
  String get opName => LibraryChangeOp.merge.name;
}

/// `rename`：合集 [collection] 改名为 [name]。
final class LibraryRenameChange extends LibraryChange {
  const LibraryRenameChange({
    required super.index,
    required this.collection,
    required this.name,
    super.why,
  });

  final String collection;
  final String name;

  @override
  String get opName => LibraryChangeOp.rename.name;
}

/// `dissolve`：移出合集 [collection] 里全部未钉住的成员（移空的合集随之删除）。
final class LibraryDissolveChange extends LibraryChange {
  const LibraryDissolveChange({
    required super.index,
    required this.collection,
    super.why,
  });

  final String collection;

  @override
  String get opName => LibraryChangeOp.dissolve.name;
}

/// `link` / `unlink` / `relink`：端点引用 `<MediaLinkKind.dbValue>:<key>`。[relation]
/// 在 `unlink` 里可省略（= 这一对之间全部非用户确认的连接）。
final class LibraryLinkChange extends LibraryChange {
  const LibraryLinkChange({
    required super.index,
    required this.op,
    required this.from,
    required this.to,
    this.relation,
    super.why,
  });

  final LibraryChangeOp op;
  final String from;
  final String to;
  final String? relation;

  @override
  String get opName => op.name;
}

/// 一条结构不对的变更：不执行，进 `skipped`（[LibraryChangeSkip.invalid]）。
final class LibraryInvalidChange extends LibraryChange {
  const LibraryInvalidChange({
    required super.index,
    required this.rawOp,
    required this.detail,
  });

  final String rawOp;
  final String detail;

  @override
  String get opName => rawOp;
}

/// 一份变更集。
class LibraryChangeset {
  const LibraryChangeset({required this.changes, this.dryRun = false});

  final List<LibraryChange> changes;
  final bool dryRun;
}

/// 理由的上限（码点，同整理器 `reason`）。
const int _kMaxWhyLength = 200;

/// 解析 spec §3.3 的 JSON。顶层结构不对（没有 `changes` 数组、`dryRun` 不是布尔）抛
/// [FormatException]；单条变更的问题不抛，解析成 [LibraryInvalidChange]（执行时进
/// `skipped`，不整批作废）。
LibraryChangeset parseLibraryChangeset(Map<String, Object?> json) {
  final Object? rawChanges = json['changes'];
  if (rawChanges is! List) {
    throw const FormatException('changes must be an array');
  }
  final Object? rawDry = json['dryRun'];
  if (rawDry != null && rawDry is! bool) {
    throw const FormatException('dryRun must be a boolean');
  }
  return LibraryChangeset(
    dryRun: rawDry == true,
    changes: <LibraryChange>[
      for (int i = 0; i < rawChanges.length; i++)
        _parseChange(i, rawChanges[i]),
    ],
  );
}

LibraryChange _parseChange(int i, Object? raw) {
  if (raw is! Map) {
    return LibraryInvalidChange(index: i, rawOp: '', detail: 'not_an_object');
  }
  final Map<Object?, Object?> m = raw;
  final Object? rawOp = m['op'];
  final String opText = rawOp is String ? rawOp : '';
  final LibraryChangeOp? op = LibraryChangeOp.values
      .where((LibraryChangeOp o) => o.name == opText)
      .firstOrNull;
  LibraryChange invalid(String detail) =>
      LibraryInvalidChange(index: i, rawOp: opText, detail: detail);
  if (op == null) return invalid('unknown_op');
  final String? why = switch (m['why']) {
    final String w when w.trim().isNotEmpty => clampOrganizeCodePoints(
      w.trim(),
      _kMaxWhyLength,
    ),
    _ => null,
  };
  String? str(String key) => switch (m[key]) {
    final String s when s.trim().isNotEmpty => s.trim(),
    _ => null,
  };
  List<String>? strList(String key) {
    final Object? v = m[key];
    if (v is! List || v.isEmpty) return null;
    final List<String> out = <String>[];
    for (final Object? e in v) {
      if (e is! String || e.trim().isEmpty) return null;
      out.add(e.trim());
    }
    return out;
  }

  switch (op) {
    case LibraryChangeOp.move:
      final List<String>? items = strList('items');
      final String? to = str('to');
      if (items == null) return invalid('items_required');
      if (to == null) return invalid('to_required');
      if (m['from'] != null && str('from') == null) {
        return invalid('from_invalid');
      }
      return LibraryMoveChange(
        index: i,
        items: items,
        to: to,
        from: str('from'),
        why: why,
      );
    case LibraryChangeOp.merge:
      final String? into = str('into');
      // `from` 也接受单个字符串（模型常写成 "C5"）。
      final List<String> from =
          strList('from') ?? <String>[if (str('from') case final String f) f];
      if (into == null) return invalid('into_required');
      if (from.isEmpty) return invalid('from_required');
      return LibraryMergeChange(index: i, into: into, from: from, why: why);
    case LibraryChangeOp.rename:
      final String? collection = str('collection');
      final String? name = str('name');
      if (collection == null) return invalid('collection_required');
      if (name == null) return invalid('name_required');
      return LibraryRenameChange(
        index: i,
        collection: collection,
        name: name,
        why: why,
      );
    case LibraryChangeOp.dissolve:
      final String? collection = str('collection');
      if (collection == null) return invalid('collection_required');
      return LibraryDissolveChange(index: i, collection: collection, why: why);
    case LibraryChangeOp.link:
    case LibraryChangeOp.unlink:
    case LibraryChangeOp.relink:
      final String? from = str('from');
      final String? to = str('to');
      final String? relation = str('relation');
      if (from == null || to == null) return invalid('endpoints_required');
      if (op != LibraryChangeOp.unlink && relation == null) {
        return invalid('relation_required');
      }
      if (m['relation'] != null && relation == null) {
        return invalid('relation_invalid');
      }
      return LibraryLinkChange(
        index: i,
        op: op,
        from: from,
        to: to,
        relation: relation,
        why: why,
      );
  }
}

// ── 结果与撤销载荷 ──────────────────────────────────────────────────────────

/// 一次执行（或预演）的结论。
class LibraryChangesetOutcome {
  LibraryChangesetOutcome({required this.dryRun});

  final bool dryRun;

  /// 这份变更集的整理记录（没有合集改动落库、或 [dryRun] 时为 null）。
  int? runId;

  final List<Map<String, Object?>> applied = <Map<String, Object?>>[];
  final List<Map<String, Object?>> skipped = <Map<String, Object?>>[];

  /// 关系部分的回执（撤销用，JSON 形状见 [undoLibraryChangeset]）。
  final List<Map<String, Object?>> linkReceipts = <Map<String, Object?>>[];

  /// 撤销载荷（可 JSON 序列化），交给操作记录；[undoLibraryChangeset] 用。
  Map<String, Object?> get undo => <String, Object?>{
    'runId': runId,
    'links': linkReceipts,
  };

  /// 有没有任何可撤销的东西落了库。
  bool get hasWrites => runId != null || linkReceipts.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'runId': runId,
    if (dryRun) 'dryRun': true,
    'applied': applied,
    'skipped': skipped,
    if (!dryRun) 'undo': undo,
  };
}

/// 执行中途出了意外：已落库的部分在 [partial] 里（含撤销载荷），调用方照样登记撤销。
class LibraryChangesetFailure implements Exception {
  const LibraryChangesetFailure(this.partial, this.error, this.stackTrace);

  final LibraryChangesetOutcome partial;
  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => 'LibraryChangesetFailure: $error';
}

// ── 执行 ────────────────────────────────────────────────────────────────────

/// 执行（或 [dryRun] 预演）一份变更集。合集改动以 AI 身份（`userIntent: false`）落库、
/// 记一条整理记录；关系改动以 `confirmed_by = ai` 落库。中途抛意外时把已完成的部分
/// 包进 [LibraryChangesetFailure] 抛出（撤销载荷不丢）。
Future<LibraryChangesetOutcome> applyLibraryChangeset(
  FushiDatabase db,
  LibraryChangeset changeset, {
  bool dryRun = false,
}) async {
  final bool dry = dryRun || changeset.dryRun;
  final _Executor x = _Executor(db, dry);
  try {
    for (final LibraryChange c in changeset.changes) {
      await x.run(c);
    }
    await x.finish(failed: false);
  } on Object catch (e, stack) {
    await x.finish(failed: true);
    throw LibraryChangesetFailure(x.out, e, stack);
  }
  return x.out;
}

/// 一条变更的结论：落了（[details]）或跳过（[reason]）。
class _Result {
  const _Result.applied(this.details) : reason = null, detail = null;
  const _Result.skipped(this.reason, [this.detail]) : details = null;

  final Map<String, Object?>? details;
  final String? reason;
  final String? detail;
}

/// 内存里的一个合集（校验与预演用；真执行时每条变更后从库里重读受影响的）。
class _Coll {
  _Coll({
    required this.id,
    required this.name,
    required this.type,
    required this.origin,
    required this.folder,
    required this.organizeKey,
    required this.members,
  });

  final int id;
  String name;
  final String type;
  final CollectionOrigin origin;
  final bool folder;
  final String? organizeKey;

  /// 成员行键（`mediaType NUL entryKey`）→ pinned_by_user。
  final Map<String, bool> members;

  String get ref => 'C$id';
}

typedef _Resolved = ({OrganizeEntry entry, CollectionShelfDomain domain});

class _Executor {
  _Executor(this.db, this.dry);

  final FushiDatabase db;
  final bool dry;
  late final LibraryChangesetOutcome out = LibraryChangesetOutcome(dryRun: dry);

  // 合集模型：首次用到时整表读一次。
  Map<int, _Coll>? _colls;
  int _nextFakeId = -1;

  // 条目索引：按库页域懒加载（一个域一次 [loadLibraryOrganizeFacts]）。
  final Set<CollectionShelfDomain> _loadedDomains = <CollectionShelfDomain>{};
  final Map<String, _Resolved> _byRow = <String, _Resolved>{};

  // 整理记录（真执行时第一条合集改动前才建）。
  int? _runId;
  final Set<CollectionShelfDomain> _touchedDomains = <CollectionShelfDomain>{};

  Future<void> run(LibraryChange c) async {
    final _Result r = await switch (c) {
      final LibraryInvalidChange v => Future<_Result>.value(
        _Result.skipped(LibraryChangeSkip.invalid, v.detail),
      ),
      final LibraryMoveChange m => _move(m),
      final LibraryMergeChange m => _merge(m),
      final LibraryRenameChange m => _rename(m),
      final LibraryDissolveChange m => _dissolve(m),
      final LibraryLinkChange m => switch (m.op) {
        LibraryChangeOp.unlink => _unlink(m),
        _ => _link(m),
      },
    };
    if (r.details case final Map<String, Object?> d) {
      out.applied.add(<String, Object?>{'i': c.index, 'op': c.opName, ...d});
    } else {
      out.skipped.add(<String, Object?>{
        'i': c.index,
        'op': c.opName,
        'reason': r.reason,
        if (r.detail != null) 'detail': r.detail,
      });
    }
  }

  Future<void> finish({required bool failed}) async {
    final int? runId = _runId;
    if (runId == null) return;
    final int changes = (await (db.select(
      db.libraryOrganizeChanges,
    )..where((t) => t.runId.equals(runId))).get()).length;
    if (changes == 0 && !failed) {
      // 一处也没落：不留空记录。
      await (db.delete(
        db.libraryOrganizeRuns,
      )..where((t) => t.id.equals(runId))).go();
      out.runId = null;
      return;
    }
    await (db.update(
      db.libraryOrganizeRuns,
    )..where((t) => t.id.equals(runId))).write(
      LibraryOrganizeRunsCompanion(
        domain: Value<String>(
          _touchedDomains.length == 1 ? _touchedDomains.single.name : 'all',
        ),
        finishedAt: Value<int?>(DateTime.now().millisecondsSinceEpoch),
        status: Value<String>(failed ? 'failed' : 'done'),
        error: Value<String?>(failed ? 'internal_error' : null),
      ),
    );
    out.runId = runId;
  }

  // ── 模型与索引 ────────────────────────────────────────────────────────────

  Future<Map<int, _Coll>> _collections() async {
    final Map<int, _Coll>? cached = _colls;
    if (cached != null) return cached;
    final Map<int, _Coll> m = <int, _Coll>{
      for (final MediaCollectionRow r in await db.getAllMediaCollections())
        r.id: _collOf(r, const <MediaCollectionItemRow>[]),
    };
    for (final MediaCollectionItemRow i in await db.getAllCollectionItems()) {
      m[i.collectionId]?.members['${i.mediaType}\u0000${i.entryKey}'] =
          i.pinnedByUser;
    }
    return _colls = m;
  }

  _Coll _collOf(MediaCollectionRow r, List<MediaCollectionItemRow> items) =>
      _Coll(
        id: r.id,
        name: r.name,
        type: r.collectionType,
        origin: CollectionOrigin.parse(r.origin),
        folder:
            r.sourceFolderPath != null ||
            CollectionOrigin.parse(r.origin) == CollectionOrigin.folder,
        organizeKey: r.organizeKey,
        members: <String, bool>{
          for (final MediaCollectionItemRow i in items)
            '${i.mediaType}\u0000${i.entryKey}': i.pinnedByUser,
        },
      );

  /// 真执行后从库里重读这些合集（被删的从模型里拿掉）。
  Future<void> _refresh(Iterable<int> ids) async {
    final Map<int, _Coll> m = await _collections();
    for (final int id in ids.toSet()) {
      final MediaCollectionRow? r = await db.getMediaCollectionById(id);
      if (r == null) {
        m.remove(id);
      } else {
        m[id] = _collOf(r, await db.getCollectionItems(id));
      }
    }
  }

  Future<_Coll?> _collectionRef(String ref) async {
    final RegExpMatch? match = RegExp(r'^C(-?\d+)$').firstMatch(ref);
    if (match == null) return null;
    return (await _collections())[int.parse(match.group(1)!)];
  }

  Future<_Coll?> _byNatural(String name, String type) async {
    for (final _Coll c in (await _collections()).values) {
      if (c.name == name && c.type == type) return c;
    }
    return null;
  }

  static List<CollectionShelfDomain> _domainsOfMediaType(String mediaType) =>
      switch (MediaKind.tryParse(mediaType)) {
        MediaKind.epub => const <CollectionShelfDomain>[
          CollectionShelfDomain.books,
          CollectionShelfDomain.manga,
        ],
        MediaKind.srt => const <CollectionShelfDomain>[
          CollectionShelfDomain.books,
        ],
        MediaKind.video => const <CollectionShelfDomain>[
          CollectionShelfDomain.video,
        ],
        MediaKind.game => const <CollectionShelfDomain>[
          CollectionShelfDomain.games,
        ],
        null => const <CollectionShelfDomain>[],
      };

  /// 成员行 → 它所在的那一卷（EPUB 带配对的 SRT 有声书）与库页域。与整理器同一份
  /// 事实（[loadLibraryOrganizeFacts]，含目录合集里的条目）。
  Future<_Resolved?> _resolveRow(String mediaType, String entryKey) async {
    final String key = '$mediaType\u0000$entryKey';
    for (final CollectionShelfDomain d in _domainsOfMediaType(mediaType)) {
      if (_byRow[key] != null) break;
      if (!_loadedDomains.add(d)) continue;
      final LibraryOrganizeFacts facts = await loadLibraryOrganizeFacts(
        db,
        d,
        includeFolderMembers: true,
      );
      for (final OrganizeEntry e in facts.entries) {
        for (final OrganizeMemberRow r in e.rows) {
          _byRow.putIfAbsent(
            '${r.mediaType}\u0000${r.entryKey}',
            () => (entry: e, domain: d),
          );
        }
      }
    }
    return _byRow[key];
  }

  Future<_Resolved?> _resolveItemRef(String ref) async {
    final int colon = ref.indexOf(':');
    if (colon <= 0 || colon == ref.length - 1) return null;
    return _resolveRow(ref.substring(0, colon), ref.substring(colon + 1));
  }

  /// 合集成员 → 权威作品身份（只含带身份的成员；认不出的成员不算），BUG-5460。
  Future<Map<String, OrganizeWorkIdentity>> _identitiesOf(_Coll c) async =>
      <String, OrganizeWorkIdentity>{
        for (final String k in c.members.keys)
          if (await _resolveRow(
                k.substring(0, k.indexOf('\u0000')),
                k.substring(k.indexOf('\u0000') + 1),
              )
              case final _Resolved r when !r.entry.identity.isEmpty)
            k: r.entry.identity,
      };

  /// 合集里成员所属的库页域（认不出的成员不算）；空合集为空集（哪个域都能放）。
  Future<Set<CollectionShelfDomain>> _domainsOf(_Coll c) async =>
      <CollectionShelfDomain>{
        for (final String k in c.members.keys)
          if (await _resolveRow(
                k.substring(0, k.indexOf('\u0000')),
                k.substring(k.indexOf('\u0000') + 1),
              )
              case final _Resolved r)
            r.domain,
      };

  // ── 合集部分的落库 ────────────────────────────────────────────────────────

  Future<int> _ensureRun() async => _runId ??= await db
      .into(db.libraryOrganizeRuns)
      .insert(
        LibraryOrganizeRunsCompanion.insert(
          domain: 'all',
          trigger: kLibraryChangesetTrigger,
          startedAt: DateTime.now().millisecondsSinceEpoch,
          status: 'running',
        ),
      );

  /// 执行一条变更转出来的动作；返回这次记下的改动处数与动过的合集。
  Future<({int recorded, Set<int> touched})> _execute(
    List<OrganizeAction> actions,
  ) async {
    final int runId = await _ensureRun();
    Future<int> count() async => (await (db.select(
      db.libraryOrganizeChanges,
    )..where((t) => t.runId.equals(runId))).get()).length;
    final int before = await count();
    final Set<int> touched = await applyOrganizeActions(
      db,
      runId: runId,
      actions: actions,
    );
    return (recorded: await count() - before, touched: touched);
  }

  OrganizeAction _action(
    OrganizeActionKind kind,
    String? why, {
    int? target,
    int? from,
    List<int> sources = const <int>[],
    List<OrganizeEntry> entries = const <OrganizeEntry>[],
    String? name,
    String collectionType = kLibraryChangesetCollectionType,
    String? organizeKey,
  }) => OrganizeAction(
    kind: kind,
    source: 'ai',
    confidence: AiOrganizeConfidence.high,
    targetCollectionId: target,
    fromCollectionId: from,
    sourceCollectionIds: sources,
    entries: entries,
    name: name,
    collectionType: collectionType,
    organizeKey: organizeKey,
    reason: why,
  );

  // ── move ─────────────────────────────────────────────────────────────────

  Future<_Result> _move(LibraryMoveChange c) async {
    // 去处。
    _Coll? target;
    String? newName;
    final bool standalone = c.to == 'standalone';
    if (c.to.startsWith('new:')) {
      final String name = clampOrganizeName(c.to.substring(4));
      if (name.isEmpty) {
        return const _Result.skipped(LibraryChangeSkip.invalid, 'empty_name');
      }
      target = await _byNatural(name, kLibraryChangesetCollectionType);
      if (target == null) newName = name;
    } else if (!standalone) {
      target = await _collectionRef(c.to);
      if (target == null) {
        return _Result.skipped(LibraryChangeSkip.unknownRef, c.to);
      }
    }
    if (target != null && target.folder) {
      return _Result.skipped(LibraryChangeSkip.folderCollection, target.ref);
    }
    // 来处。
    _Coll? from;
    if (c.from != null) {
      from = await _collectionRef(c.from!);
      if (from == null) {
        return _Result.skipped(LibraryChangeSkip.unknownRef, c.from);
      }
      if (from.folder) {
        return _Result.skipped(LibraryChangeSkip.folderCollection, from.ref);
      }
      if (from.id == target?.id) {
        return const _Result.skipped(LibraryChangeSkip.invalid, 'from_is_to');
      }
    }
    final Set<CollectionShelfDomain>? targetDomains = target == null
        ? null
        : await _domainsOf(target);
    final Set<String> targetVetoes = target == null || target.id < 0
        ? const <String>{}
        : await db.collectionMemberTombstoneKeysFor(target.name, target.type);
    // 权威作品身份（BUG-5460）：去处现有成员的身份（剧身份闸门的起点、归拢判据），
    // 来处的成员身份按需读一次。
    final List<OrganizeWorkIdentity> targetIdentities = target == null
        ? const <OrganizeWorkIdentity>[]
        : (await _identitiesOf(target)).values.toList(growable: false);
    final bool gated = target != null || newName != null;
    final Map<int, Map<String, OrganizeWorkIdentity>> sourceIdentities =
        <int, Map<String, OrganizeWorkIdentity>>{};

    CollectionShelfDomain? newDomain;
    final List<Map<String, Object?>> itemSkips = <Map<String, Object?>>[];
    void skipItem(String ref, String reason) =>
        itemSkips.add(<String, Object?>{'ref': ref, 'reason': reason});
    // 通过逐条校验的条目 → 要移出的来处（作品身份按整批再判一次，见循环后）。
    final List<({String ref, OrganizeEntry entry, List<_Coll> sources})>
    passed = <({String ref, OrganizeEntry entry, List<_Coll> sources})>[];
    final Set<String> seen = <String>{};
    for (final String ref in c.items) {
      final _Resolved? r = await _resolveItemRef(ref);
      if (r == null) {
        skipItem(ref, LibraryChangeSkip.unknownRef);
        continue;
      }
      if (!seen.add(r.entry.memberKey)) continue;
      // 跨域：去处已有成员的看成员的域；新建的以第一个条目的域为准。
      if (targetDomains != null &&
          targetDomains.isNotEmpty &&
          !targetDomains.contains(r.domain)) {
        skipItem(ref, LibraryChangeSkip.crossDomain);
        continue;
      }
      if (newName != null) {
        newDomain ??= r.domain;
        if (newDomain != r.domain) {
          skipItem(ref, LibraryChangeSkip.crossDomain);
          continue;
        }
      }
      final String key = r.entry.memberKey;
      final List<_Coll> sources;
      if (from != null) {
        if (!from.members.containsKey(key)) {
          skipItem(ref, LibraryChangeSkip.invalid);
          continue;
        }
        sources = <_Coll>[from];
      } else {
        sources = <_Coll>[
          for (final _Coll k in (await _collections()).values)
            if (!k.folder && k.id != target?.id && k.members.containsKey(key))
              k,
        ]..sort((_Coll a, _Coll b) => a.id.compareTo(b.id));
      }
      // 钉住 = 用户亲手放进来 / 否决过 AI 的移出：一个来处钉着就整个条目不动。
      if (sources.any((_Coll k) => k.members[key] == true)) {
        skipItem(ref, LibraryChangeSkip.pinnedByUser);
        continue;
      }
      final bool inTarget = target?.members.containsKey(key) ?? false;
      if (target != null &&
          !inTarget &&
          targetVetoes.contains(r.entry.tombstoneKey)) {
        skipItem(ref, LibraryChangeSkip.vetoed);
        continue;
      }
      if (sources.isEmpty && (standalone || inTarget)) {
        skipItem(ref, LibraryChangeSkip.exists);
        continue;
      }
      for (final _Coll k in sources) {
        sourceIdentities[k.id] ??= await _identitiesOf(k);
      }
      passed.add((ref: ref, entry: r.entry, sources: sources));
    }
    // 作品身份（BUG-5460）按整批判：同一条 move 里一起离开同一个来处的同一部作品不算
    // 拆散；去处是另一部来源剧的不放进去。被剔掉的条目留在原处，又可能让同批别的条目
    // 变成「拆散」，所以两步交替到不变为止。
    final Map<String, OrganizeWorkIdentity> movingIdentity =
        <String, OrganizeWorkIdentity>{
          for (final ({String ref, OrganizeEntry entry, List<_Coll> sources}) o
              in passed)
            o.entry.memberKey: o.entry.identity,
        };
    List<({String ref, OrganizeEntry entry, List<_Coll> sources})> ok = passed;
    while (true) {
      ok = organizeReleasableTogether(
        ok,
        (({String ref, OrganizeEntry entry, List<_Coll> sources}) o) =>
            o.entry.memberKey,
        (
          ({String ref, OrganizeEntry entry, List<_Coll> sources}) o,
          Set<String> leaving,
        ) => o.sources.every(
          (_Coll k) => !organizeIdentityForbidsRelease(
            sourceIdentities[k.id]!,
            o.entry.memberKey,
            leaving: leaving,
            destination: <OrganizeWorkIdentity>[
              ...targetIdentities,
              for (final String other in leaving)
                if (!k.members.containsKey(other)) movingIdentity[other]!,
            ],
          ),
        ),
      );
      final OrganizeSeriesGate gate = OrganizeSeriesGate(targetIdentities);
      final List<({String ref, OrganizeEntry entry, List<_Coll> sources})>
      admitted = <({String ref, OrganizeEntry entry, List<_Coll> sources})>[
        for (final ({String ref, OrganizeEntry entry, List<_Coll> sources}) o
            in ok)
          if (!gated ||
              (target?.members.containsKey(o.entry.memberKey) ?? false) ||
              gate.admit(o.entry.identity))
            o,
      ];
      if (admitted.length == ok.length) break;
      ok = admitted;
    }
    for (final ({String ref, OrganizeEntry entry, List<_Coll> sources}) o
        in passed) {
      if (!ok.contains(o)) skipItem(o.ref, LibraryChangeSkip.workIdentity);
    }
    if (ok.isEmpty) return _allItemsSkipped(itemSkips);

    // 新建合集：分组键按折叠标题（与整理器同口径）；用户拒绝过的分组不建。
    String? organizeKey;
    if (newName != null) {
      organizeKey = titleOrganizeKey(newDomain!.name, newName);
      if (organizeKey != null &&
          (await db.getRejectedOrganizeGroups()).containsKey(organizeKey)) {
        return _Result.skipped(LibraryChangeSkip.vetoed, 'rejected_group');
      }
    }

    // 转成整理动作：来处移出（去处已有 / 单独放 / 新建）或「挪走」（去处是已有合集时
    // 第一个来处挪过去，其余来处移出）；散条目放进已有去处是「加入」。
    final Map<int, List<OrganizeEntry>> evicts = <int, List<OrganizeEntry>>{};
    final Map<int, List<OrganizeEntry>> moves = <int, List<OrganizeEntry>>{};
    final List<OrganizeEntry> adds = <OrganizeEntry>[];
    for (final ({String ref, OrganizeEntry entry, List<_Coll> sources}) o
        in ok) {
      final bool movable = target != null && target.id > 0;
      final bool inTarget =
          target?.members.containsKey(o.entry.memberKey) ?? false;
      if (!movable || inTarget) {
        for (final _Coll s in o.sources) {
          (evicts[s.id] ??= <OrganizeEntry>[]).add(o.entry);
        }
        continue;
      }
      if (o.sources.isEmpty) {
        adds.add(o.entry);
        continue;
      }
      (moves[o.sources.first.id] ??= <OrganizeEntry>[]).add(o.entry);
      for (final _Coll s in o.sources.skip(1)) {
        (evicts[s.id] ??= <OrganizeEntry>[]).add(o.entry);
      }
    }
    final List<OrganizeAction> actions = <OrganizeAction>[
      for (final int id in evicts.keys.toList()..sort())
        _action(
          OrganizeActionKind.evict,
          c.why,
          target: id,
          entries: evicts[id]!,
        ),
      for (final int id in moves.keys.toList()..sort())
        _action(
          OrganizeActionKind.move,
          c.why,
          from: id,
          target: target!.id,
          organizeKey: target.organizeKey,
          entries: moves[id]!,
        ),
      if (adds.isNotEmpty)
        _action(
          OrganizeActionKind.add,
          c.why,
          target: target!.id,
          organizeKey: target.organizeKey,
          entries: adds,
        ),
      if (newName != null)
        _action(
          OrganizeActionKind.create,
          c.why,
          name: newName,
          organizeKey: organizeKey,
          entries: <OrganizeEntry>[
            for (final ({String ref, OrganizeEntry entry, List<_Coll> sources})
                o
                in ok)
              o.entry,
          ],
        ),
    ];

    final Set<CollectionShelfDomain> domains = <CollectionShelfDomain>{
      for (final ({String ref, OrganizeEntry entry, List<_Coll> sources}) o
          in ok)
        if (_byRow[o.entry.memberKey] case final _Resolved r) r.domain,
    };
    String? targetRef = target?.ref;
    if (dry) {
      final Map<int, _Coll> m = await _collections();
      _Coll? dest = target;
      if (newName != null) {
        dest = _Coll(
          id: _nextFakeId--,
          name: newName,
          type: kLibraryChangesetCollectionType,
          origin: CollectionOrigin.ai,
          folder: false,
          organizeKey: organizeKey,
          members: <String, bool>{},
        );
        m[dest.id] = dest;
        targetRef = 'new:$newName';
      }
      for (final ({String ref, OrganizeEntry entry, List<_Coll> sources}) o
          in ok) {
        for (final _Coll s in o.sources) {
          for (final OrganizeMemberRow row in o.entry.rows) {
            s.members.remove('${row.mediaType}\u0000${row.entryKey}');
          }
          if (s.members.isEmpty) m.remove(s.id);
        }
        if (dest != null) {
          for (final OrganizeMemberRow row in o.entry.rows) {
            dest.members.putIfAbsent(
              '${row.mediaType}\u0000${row.entryKey}',
              () => false,
            );
          }
        }
      }
    } else {
      final ({int recorded, Set<int> touched}) done = await _execute(actions);
      await _refresh(<int>{
        ...done.touched,
        for (final ({String ref, OrganizeEntry entry, List<_Coll> sources}) o
            in ok)
          for (final _Coll s in o.sources) s.id,
        if (target != null) target.id,
      });
      if (newName != null) {
        final _Coll? made = await _reloadByNatural(
          newName,
          kLibraryChangesetCollectionType,
        );
        targetRef = made?.ref;
      }
      if (done.recorded == 0) {
        return _Result.skipped(LibraryChangeSkip.exists, 'no_effect');
      }
      _touchedDomains.addAll(domains);
    }
    return _Result.applied(<String, Object?>{
      'to': standalone ? 'standalone' : targetRef,
      'items': <String>[
        for (final ({String ref, OrganizeEntry entry, List<_Coll> sources}) o
            in ok)
          o.ref,
      ],
      if (itemSkips.isNotEmpty) 'itemsSkipped': itemSkips,
    });
  }

  Future<_Coll?> _reloadByNatural(String name, String type) async {
    final MediaCollectionRow? r = await db.getMediaCollectionByNaturalKey(
      name,
      type,
    );
    if (r == null) return null;
    await _refresh(<int>[r.id]);
    return (await _collections())[r.id];
  }

  /// 全部条目都没过：这一条进 `skipped`，原因取条目里最多的那种。
  _Result _allItemsSkipped(List<Map<String, Object?>> itemSkips) {
    if (itemSkips.isEmpty) {
      return const _Result.skipped(LibraryChangeSkip.invalid, 'no_items');
    }
    final Map<String, int> counts = <String, int>{};
    for (final Map<String, Object?> s in itemSkips) {
      final String r = s['reason']! as String;
      counts[r] = (counts[r] ?? 0) + 1;
    }
    final String top =
        (counts.entries.toList()..sort(
              (MapEntry<String, int> a, MapEntry<String, int> b) =>
                  b.value.compareTo(a.value),
            ))
            .first
            .key;
    return _Result.skipped(
      top,
      itemSkips.map((Map<String, Object?> s) => s['ref']).join(','),
    );
  }

  // ── merge ────────────────────────────────────────────────────────────────

  Future<_Result> _merge(LibraryMergeChange c) async {
    final _Coll? into = await _collectionRef(c.into);
    if (into == null) {
      return _Result.skipped(LibraryChangeSkip.unknownRef, c.into);
    }
    if (into.folder) {
      return _Result.skipped(LibraryChangeSkip.folderCollection, into.ref);
    }
    final Set<CollectionShelfDomain> intoDomains = await _domainsOf(into);
    // 败方成员与胜方里已有的来源剧不是同一部：那个败方不并（BUG-5460）。
    final OrganizeSeriesGate gate = OrganizeSeriesGate(
      (await _identitiesOf(into)).values,
    );
    final List<Map<String, Object?>> sourceSkips = <Map<String, Object?>>[];
    final List<_Coll> sources = <_Coll>[];
    for (final String ref in c.from) {
      final _Coll? s = await _collectionRef(ref);
      String? reason;
      if (s == null) {
        reason = LibraryChangeSkip.unknownRef;
      } else if (s.folder) {
        reason = LibraryChangeSkip.folderCollection;
      } else if (s.id == into.id || sources.any((_Coll k) => k.id == s.id)) {
        reason = LibraryChangeSkip.invalid;
      } else {
        final Set<CollectionShelfDomain> d = await _domainsOf(s);
        if (intoDomains.isNotEmpty &&
            d.isNotEmpty &&
            d.intersection(intoDomains).isEmpty) {
          reason = LibraryChangeSkip.crossDomain;
        } else if (!gate.admitAll((await _identitiesOf(s)).values)) {
          reason = LibraryChangeSkip.workIdentity;
        }
      }
      if (reason != null) {
        sourceSkips.add(<String, Object?>{'ref': ref, 'reason': reason});
        continue;
      }
      sources.add(s!);
    }
    if (sources.isEmpty) return _allItemsSkipped(sourceSkips);
    if (dry) {
      final Map<int, _Coll> m = await _collections();
      final Set<String> vetoes = into.id < 0
          ? const <String>{}
          : await db.collectionMemberTombstoneKeysFor(into.name, into.type);
      for (final _Coll s in sources) {
        for (final MapEntry<String, bool> e in s.members.entries) {
          final int sep = e.key.indexOf('\u0000');
          final String tomb = await db.collectionMemberTombstoneKeyOf(
            e.key.substring(0, sep),
            e.key.substring(sep + 1),
          );
          if (vetoes.contains(tomb)) continue;
          into.members[e.key] = (into.members[e.key] ?? false) || e.value;
        }
        m.remove(s.id);
      }
    } else {
      final Set<CollectionShelfDomain> domains = <CollectionShelfDomain>{
        ...intoDomains,
        for (final _Coll s in sources) ...await _domainsOf(s),
      };
      final ({int recorded, Set<int> touched}) done = await _execute(
        <OrganizeAction>[
          _action(
            OrganizeActionKind.merge,
            c.why,
            target: into.id,
            sources: <int>[for (final _Coll s in sources) s.id],
            collectionType: into.type,
            organizeKey: into.organizeKey,
          ),
        ],
      );
      await _refresh(<int>[into.id, for (final _Coll s in sources) s.id]);
      if (done.recorded == 0) {
        return _Result.skipped(LibraryChangeSkip.exists, 'no_effect');
      }
      _touchedDomains.addAll(domains);
    }
    return _Result.applied(<String, Object?>{
      'into': into.ref,
      'from': <String>[for (final _Coll s in sources) s.ref],
      if (sourceSkips.isNotEmpty) 'fromSkipped': sourceSkips,
    });
  }

  // ── rename ───────────────────────────────────────────────────────────────

  Future<_Result> _rename(LibraryRenameChange c) async {
    final _Coll? col = await _collectionRef(c.collection);
    if (col == null) {
      return _Result.skipped(LibraryChangeSkip.unknownRef, c.collection);
    }
    if (col.folder) {
      return _Result.skipped(LibraryChangeSkip.folderCollection, col.ref);
    }
    final String name = clampOrganizeName(c.name);
    if (name.isEmpty) {
      return const _Result.skipped(LibraryChangeSkip.invalid, 'empty_name');
    }
    if (name == col.name) {
      return const _Result.skipped(LibraryChangeSkip.exists);
    }
    final _Coll? holder = await _byNatural(name, col.type);
    if (holder != null) {
      return _Result.skipped(LibraryChangeSkip.nameTaken, holder.ref);
    }
    // 用户删过的分组（删除哨兵上记着被拒绝的分组键）：改到这个名字会清掉哨兵、把
    // 拒绝记录一起抹掉。
    if (await _nameRejected(name, col.type)) {
      return const _Result.skipped(LibraryChangeSkip.nameTaken, 'rejected');
    }
    final String oldName = col.name;
    if (dry) {
      col.name = name;
    } else {
      final Set<CollectionShelfDomain> domains = await _domainsOf(col);
      final ({int recorded, Set<int> touched}) done =
          await _execute(<OrganizeAction>[
            _action(
              OrganizeActionKind.rename,
              c.why,
              target: col.id,
              name: name,
              collectionType: col.type,
              organizeKey: col.organizeKey,
            ),
          ]);
      await _refresh(<int>[col.id]);
      if (done.recorded == 0) {
        return _Result.skipped(LibraryChangeSkip.nameTaken, 'no_effect');
      }
      _touchedDomains.addAll(domains);
    }
    return _Result.applied(<String, Object?>{
      'collection': col.ref,
      'from': oldName,
      'name': name,
    });
  }

  Future<bool> _nameRejected(String name, String type) async {
    final List<CollectionMemberTombstoneRow> rows =
        await (db.select(db.collectionMemberTombstones)..where(
              (t) =>
                  t.collectionName.equals(name) &
                  t.collectionType.equals(type) &
                  t.mediaType.equals(
                    FushiDatabase.collectionTombstoneSentinel,
                  ) &
                  t.entryKey.equals(FushiDatabase.collectionTombstoneSentinel),
            ))
            .get();
    if (rows.isEmpty) return false;
    final Set<String> rejected = (await db.getRejectedOrganizeGroups()).keys
        .toSet();
    return rows.any(
      (CollectionMemberTombstoneRow r) =>
          !r.organizeMerged &&
          decodeOrganizeAliases(r.organizeKey).any(rejected.contains),
    );
  }

  // ── dissolve ─────────────────────────────────────────────────────────────

  Future<_Result> _dissolve(LibraryDissolveChange c) async {
    final _Coll? col = await _collectionRef(c.collection);
    if (col == null) {
      return _Result.skipped(LibraryChangeSkip.unknownRef, c.collection);
    }
    if (col.folder) {
      return _Result.skipped(LibraryChangeSkip.folderCollection, col.ref);
    }
    if (col.members.isEmpty) {
      return const _Result.skipped(LibraryChangeSkip.exists, 'empty');
    }
    // 每一行成员各自移出（配对的 SRT 有声书行也在合集里，各是一行）；钉住的留下，
    // 与权威作品身份矛盾的也留下（BUG-5460，[organizeIdentityForbidsRelease]）。
    final Map<String, OrganizeWorkIdentity> identities = await _identitiesOf(
      col,
    );
    final List<String> unpinned = <String>[
      for (final MapEntry<String, bool> e in col.members.entries)
        if (!e.value) e.key,
    ];
    final int pinned = col.members.length - unpinned.length;
    // 一起移出的成员按整批判（拆散 / 把一部剧从它自己的合集里移空都不行）。
    final List<String> released = organizeReleasableTogether(
      unpinned,
      (String k) => k,
      (String k, Set<String> leaving) =>
          !organizeIdentityForbidsRelease(identities, k, leaving: leaving),
    );
    final int sameWork = unpinned.length - released.length;
    final List<OrganizeEntry> evict = <OrganizeEntry>[];
    for (final String key in released) {
      final int sep = key.indexOf('\u0000');
      final String mediaType = key.substring(0, sep);
      final String entryKey = key.substring(sep + 1);
      evict.add(
        OrganizeEntry(
          mediaType: mediaType,
          entryKey: entryKey,
          tombstoneKey: key,
          item: AiOrganizeItem(title: entryKey),
        ),
      );
    }
    if (evict.isEmpty) {
      return _Result.skipped(
        sameWork > 0
            ? LibraryChangeSkip.workIdentity
            : LibraryChangeSkip.pinnedByUser,
        col.ref,
      );
    }
    if (dry) {
      for (final OrganizeEntry e in evict) {
        col.members.remove(e.memberKey);
      }
      if (col.members.isEmpty) (await _collections()).remove(col.id);
    } else {
      final Set<CollectionShelfDomain> domains = await _domainsOf(col);
      final ({int recorded, Set<int> touched}) done = await _execute(
        <OrganizeAction>[
          _action(
            OrganizeActionKind.evict,
            c.why,
            target: col.id,
            entries: evict,
          ),
        ],
      );
      await _refresh(<int>[col.id]);
      if (done.recorded == 0) {
        return _Result.skipped(LibraryChangeSkip.exists, 'no_effect');
      }
      _touchedDomains.addAll(domains);
    }
    return _Result.applied(<String, Object?>{
      'collection': col.ref,
      'evicted': evict.length,
      if (pinned > 0) 'keptPinned': pinned,
      if (sameWork > 0) 'keptSameWork': sameWork,
    });
  }

  // ── 关系 ─────────────────────────────────────────────────────────────────

  Future<_Result> _link(LibraryLinkChange c) async {
    final MediaLinkRelation? relation = MediaLinkRelation.tryParse(c.relation);
    if (relation == null) {
      return _Result.skipped(LibraryChangeSkip.invalid, 'relation');
    }
    final _Result? bad = await _checkEndpoints(c);
    if (bad != null) return bad;
    final ({MediaLinkEndpoint from, MediaLinkEndpoint to}) ends = _oriented(
      relation,
      _endpoint(c.from)!,
      _endpoint(c.to)!,
    );
    final MediaLinkId id = mediaLinkIdFor(relation, ends.from, ends.to);
    final List<MediaLinkRow> rows = await db.mediaLinksBetween(
      ends.from,
      ends.to,
    );
    final List<MediaLinkRow> live = <MediaLinkRow>[
      for (final MediaLinkRow r in rows)
        if (r.deletedAt == null) r,
    ];
    if (live.any(
      (MediaLinkRow r) => mediaLinkConfirmerOf(r) == MediaLinkConfirmer.user,
    )) {
      return const _Result.skipped(LibraryChangeSkip.userConfirmed);
    }
    if (rows.any(mediaLinkIsVetoTombstone)) {
      return const _Result.skipped(LibraryChangeSkip.vetoed);
    }
    final List<MediaLinkRow> others = <MediaLinkRow>[
      for (final MediaLinkRow r in live)
        if (mediaLinkIdOf(r) != id) r,
    ];
    final MediaLinkRow? current = live
        .where((MediaLinkRow r) => mediaLinkIdOf(r) == id)
        .firstOrNull;
    if (c.op == LibraryChangeOp.link) {
      // 这一对之间已有别的关系：改类型 / 方向是 relink 的事，link 不顺手取代它。
      if (others.isNotEmpty) {
        return const _Result.skipped(LibraryChangeSkip.exists, 'use_relink');
      }
    } else if (live.isEmpty) {
      return const _Result.skipped(LibraryChangeSkip.unknownRef, 'no_link');
    }
    if (others.isEmpty &&
        current != null &&
        mediaLinkConfirmerOf(current) == MediaLinkConfirmer.ai) {
      return const _Result.skipped(LibraryChangeSkip.exists);
    }
    int superseded = others.length;
    if (!dry) {
      final ({
        MediaLinkAiRelationStatus status,
        MediaLinkAiRelationWrite? write,
      })
      w = await db.setAiMediaLinkRelation(
        relation: relation,
        from: ends.from,
        to: ends.to,
        source: MediaLinkSource.ai,
        reason: c.why,
      );
      switch (w.status) {
        case MediaLinkAiRelationStatus.userConfirmed:
          return const _Result.skipped(LibraryChangeSkip.userConfirmed);
        case MediaLinkAiRelationStatus.vetoed:
          return const _Result.skipped(LibraryChangeSkip.vetoed);
        case MediaLinkAiRelationStatus.unchanged:
          return const _Result.skipped(LibraryChangeSkip.exists);
        case MediaLinkAiRelationStatus.written:
          out.linkReceipts.add(_relationReceiptJson(w.write!));
          superseded = w.write!.superseded.length;
      }
    }
    return _Result.applied(<String, Object?>{
      'from': _endpointRef(ends.from),
      'to': _endpointRef(ends.to),
      'relation': relation.dbValue,
      if (superseded > 0) 'superseded': superseded,
    });
  }

  Future<_Result> _unlink(LibraryLinkChange c) async {
    MediaLinkRelation? relation;
    if (c.relation != null) {
      relation = MediaLinkRelation.tryParse(c.relation);
      if (relation == null) {
        return _Result.skipped(LibraryChangeSkip.invalid, 'relation');
      }
    }
    final _Result? bad = await _checkEndpoints(c);
    if (bad != null) return bad;
    final MediaLinkEndpoint a = _endpoint(c.from)!;
    final MediaLinkEndpoint b = _endpoint(c.to)!;
    final List<MediaLinkRow> before = await db.mediaLinksBetween(a, b);
    // 指定了关系就只断这种关系（两个方向都算：模型写反方向也认得出）。
    final List<MediaLinkRow> candidates = <MediaLinkRow>[
      for (final MediaLinkRow r in before)
        if (r.deletedAt == null &&
            (relation == null || r.relation == relation.dbValue))
          r,
    ];
    if (candidates.isEmpty) {
      return const _Result.skipped(LibraryChangeSkip.unknownRef, 'no_link');
    }
    final List<MediaLinkRow> targets = <MediaLinkRow>[
      for (final MediaLinkRow r in candidates)
        if (mediaLinkConfirmerOf(r) != MediaLinkConfirmer.user) r,
    ];
    if (targets.isEmpty) {
      return const _Result.skipped(LibraryChangeSkip.userConfirmed);
    }
    final int keptUser = candidates.length - targets.length;
    if (!dry) {
      // AI 判定「这一对不是这种关系」= 否决墓碑（建议 = 拒绝；AI 生效 = 撤掉）。
      // removeMediaLink 会按否决不变量顺带收掉同一对上别的 AI 生效行：前后对比把
      // 所有变了的行都记进回执，撤销时逐行还原。
      for (final MediaLinkRow r in targets) {
        await db.removeMediaLink(mediaLinkIdOf(r));
      }
      final Map<MediaLinkId, MediaLinkRow> prior = <MediaLinkId, MediaLinkRow>{
        for (final MediaLinkRow r in before) mediaLinkIdOf(r): r,
      };
      final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
      for (final MediaLinkRow after in await db.mediaLinksBetween(a, b)) {
        final MediaLinkRow? was = prior[mediaLinkIdOf(after)];
        if (was == null || was == after) continue;
        rows.add(<String, Object?>{
          'id': _idJson(mediaLinkIdOf(after)),
          'previous': was.toJson(),
          'writtenAt': after.updatedAt,
        });
      }
      if (rows.isNotEmpty) {
        out.linkReceipts.add(<String, Object?>{'kind': 'unlink', 'rows': rows});
      }
    }
    return _Result.applied(<String, Object?>{
      'from': _endpointRef(a),
      'to': _endpointRef(b),
      'removed': targets.length,
      if (keptUser > 0) 'keptUserConfirmed': keptUser,
    });
  }

  Future<_Result?> _checkEndpoints(LibraryLinkChange c) async {
    final MediaLinkEndpoint? a = _endpoint(c.from);
    final MediaLinkEndpoint? b = _endpoint(c.to);
    if (a == null) return _Result.skipped(LibraryChangeSkip.unknownRef, c.from);
    if (b == null) return _Result.skipped(LibraryChangeSkip.unknownRef, c.to);
    if (a.kind == b.kind && a.key == b.key) {
      return const _Result.skipped(LibraryChangeSkip.invalid, 'same_endpoint');
    }
    if (!await _endpointExists(a)) {
      return _Result.skipped(LibraryChangeSkip.unknownRef, c.from);
    }
    if (!await _endpointExists(b)) {
      return _Result.skipped(LibraryChangeSkip.unknownRef, c.to);
    }
    return null;
  }

  Future<bool> _endpointExists(MediaLinkEndpoint e) async {
    final String k = e.key;
    switch (e.kind) {
      case MediaLinkKind.videoCollection:
        final int? id = int.tryParse(k);
        return id != null && await db.getMediaCollectionById(id) != null;
      case MediaLinkKind.videoEpisode:
        return await (db.select(db.videoBooks)
                  ..where((t) => t.bookUid.equals(k))
                  ..limit(1))
                .getSingleOrNull() !=
            null;
      case MediaLinkKind.book:
        return await (db.select(db.epubBooks)
                  ..where((t) => t.bookKey.equals(k))
                  ..limit(1))
                .getSingleOrNull() !=
            null;
      case MediaLinkKind.game:
        return await (db.select(db.galgames)
                  ..where((t) => t.id.equals(k))
                  ..limit(1))
                .getSingleOrNull() !=
            null;
      case MediaLinkKind.musicAlbum:
        return await (db.select(db.musicAlbums)
                  ..where((t) => t.albumUid.equals(k))
                  ..limit(1))
                .getSingleOrNull() !=
            null;
      case MediaLinkKind.musicTrack:
        return await (db.select(db.musicTracks)
                  ..where((t) => t.trackUid.equals(k))
                  ..limit(1))
                .getSingleOrNull() !=
            null;
      case MediaLinkKind.audiobook:
        return await (db.select(db.audiobooks)
                  ..where((t) => t.bookKey.equals(k))
                  ..limit(1))
                .getSingleOrNull() !=
            null;
    }
  }
}

/// 端点引用 `<MediaLinkKind.dbValue>:<key>` → 端点；认不出返回 null。
MediaLinkEndpoint? _endpoint(String ref) {
  final int colon = ref.indexOf(':');
  if (colon <= 0 || colon == ref.length - 1) return null;
  final MediaLinkKind? kind = MediaLinkKind.tryParse(ref.substring(0, colon));
  if (kind == null) return null;
  return (kind: kind, key: ref.substring(colon + 1));
}

String _endpointRef(MediaLinkEndpoint e) => '${e.kind.dbValue}:${e.key}';

/// 主题曲 / 配乐的方向按端点种类定（库里的约定是 音乐 → 作品，见
/// [MediaLinkRelation]）：模型把作品写在 `from`、音乐写在 `to` 时换过来。其余关系原样。
({MediaLinkEndpoint from, MediaLinkEndpoint to}) _oriented(
  MediaLinkRelation relation,
  MediaLinkEndpoint from,
  MediaLinkEndpoint to,
) {
  bool music(MediaLinkEndpoint e) =>
      e.kind == MediaLinkKind.musicAlbum || e.kind == MediaLinkKind.musicTrack;
  if ((relation == MediaLinkRelation.themeSong ||
          relation == MediaLinkRelation.soundtrack) &&
      !music(from) &&
      music(to)) {
    return (from: to, to: from);
  }
  return (from: from, to: to);
}

Map<String, Object?> _idJson(MediaLinkId id) => <String, Object?>{
  'fromKind': id.fromKind,
  'fromKey': id.fromKey,
  'relation': id.relation,
  'toKind': id.toKind,
  'toKey': id.toKey,
};

MediaLinkId _idFromJson(Object? raw) {
  if (raw is! Map) throw const FormatException('link id must be an object');
  String part(String k) => switch (raw[k]) {
    final String s => s,
    _ => throw FormatException('link id.$k must be a string'),
  };
  return (
    fromKind: part('fromKind'),
    fromKey: part('fromKey'),
    relation: part('relation'),
    toKind: part('toKind'),
    toKey: part('toKey'),
  );
}

MediaLinkRow _rowFromJson(Object? raw) {
  if (raw is! Map) throw const FormatException('link row must be an object');
  return MediaLinkRow.fromJson(Map<String, dynamic>.from(raw));
}

Map<String, Object?> _relationReceiptJson(MediaLinkAiRelationWrite w) =>
    <String, Object?>{
      'kind': 'set',
      'id': _idJson(w.id),
      if (w.previous != null) 'previous': w.previous!.toJson(),
      'superseded': <Object?>[
        for (final MediaLinkRow r in w.superseded) r.toJson(),
      ],
    };

/// 撤销一份变更集（[LibraryChangesetOutcome.undo]）：先撤销整理记录里这次的全部合集
/// 改动（[undoLibraryOrganizeRun]），再把关系回执倒序退回。后来被用户改过的那一处
/// 跳过（「已被后续修改覆盖」）。返回实际撤销的处数；载荷形状不对抛 [FormatException]。
///
/// 合集在前：关系只能连在当时还在的合集上，这次又把它移空 / 并掉的话，删合集会连带
/// 删掉它的连接（BUG-5462）、身份快照里记的是连上之后的样子。先按快照把合集原 id
/// 还原（连接随之回来），关系回执才找得到那一行、退回连之前的状态（BUG-5461）；反过来
/// 先退关系会扑空，随后还原的合集又把 AI 连上的那条带回来。
///
/// 载荷：`{runId: int?, links: [{kind: "set", id, previous?, superseded: [row]} |
/// {kind: "unlink", rows: [{id, previous, writtenAt}]}]}`（行是 `MediaLinkRow.toJson`）。
Future<int> undoLibraryChangeset(
  FushiDatabase db,
  Map<String, Object?> undoPayload,
) async {
  final Object? rawRun = undoPayload['runId'];
  if (rawRun != null && rawRun is! int) {
    throw const FormatException('runId must be an int');
  }
  final Object rawLinks = undoPayload['links'] ?? const <Object?>[];
  if (rawLinks is! List) throw const FormatException('links must be an array');
  int undone = 0;
  if (rawRun is int) undone += await undoLibraryOrganizeRun(db, rawRun);
  for (final Object? receipt in rawLinks.reversed) {
    if (receipt is! Map) throw const FormatException('bad link receipt');
    switch (receipt['kind']) {
      case 'set':
        final Object? sup = receipt['superseded'] ?? const <Object?>[];
        if (sup is! List) throw const FormatException('bad superseded');
        final bool ok = await db.revertAiMediaLinkRelation((
          id: _idFromJson(receipt['id']),
          previous: receipt['previous'] == null
              ? null
              : _rowFromJson(receipt['previous']),
          superseded: <MediaLinkRow>[
            for (final Object? r in sup) _rowFromJson(r),
          ],
        ));
        if (ok) undone++;
      case 'unlink':
        final Object? rows = receipt['rows'];
        if (rows is! List) throw const FormatException('bad unlink rows');
        bool any = false;
        for (final Object? r in rows.reversed) {
          if (r is! Map || r['writtenAt'] is! int) {
            throw const FormatException('bad unlink row');
          }
          if (await db.restoreMediaLinkSnapshot(
            _idFromJson(r['id']),
            writtenAt: r['writtenAt']! as int,
            previous: _rowFromJson(r['previous']),
          )) {
            any = true;
          }
        }
        if (any) undone++;
      default:
        throw const FormatException('unknown link receipt kind');
    }
  }
  return undone;
}
