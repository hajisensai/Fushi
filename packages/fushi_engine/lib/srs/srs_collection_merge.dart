/// 手动「合并进共享库」的内核命令（拍板台 design-srs-shared-library 方案 a，组合阶段 5；设计
/// `docs/specs/2026-11-23-combo-settings-tree-design.md` §4.3）。
///
/// 合并本身全在 Rust 里（native/fushi_fsrs/src/store/gen4/cmd/collection_merge.rs）：一个写事务里把独立库的集合并进共享库
/// 的集合（`Join` + 操作并集，随同步发布、对端重放），同 guid 笔记的复习日志全部保留，字段 / 笔记类型 / 删除状态不同的列成
/// 冲突、按调用方的选择写回（默认保留共享库）。这里只是后台 isolate 里的薄封装与回包的类型。
library;

import 'package:fushi_srs/fushi_srs.dart' show SrsCore;

import 'package:fushi_engine/srs/srs_profile_data.dart'
    show srsRunLibraryCommand;

/// 一条冲突笔记保留哪一边。
enum SrsMergeChoice {
  /// 共享库那份（默认）。
  shared('into'),

  /// 被并入的独立库那份。
  merged('from');

  const SrsMergeChoice(this.wire);

  /// 命令里的值。
  final String wire;
}

/// 冲突笔记的一边：并入之前那个库里这条笔记的现状。
class SrsMergeSide {
  const SrsMergeSide({
    required this.noteType,
    required this.noteTypeName,
    required this.deleted,
    required this.sortField,
    required this.updatedAt,
  });

  factory SrsMergeSide.fromJson(Map<String, Object?> m) => SrsMergeSide(
    noteType: m['type']! as String,
    noteTypeName: m['typeName'] as String?,
    deleted: m['deleted'] == true,
    sortField: (m['sort'] as String?) ?? '',
    updatedAt: (m['updated'] as int?) ?? 0,
  );

  /// 当前笔记类型（规范 ID）与它在这个库里的名字（读不到为 null）。
  final String noteType;
  final String? noteTypeName;

  /// 这一边已删除。
  final bool deleted;

  /// 排序字段（列表里认笔记用；截断过）。
  final String sortField;

  /// 最后修改时刻（毫秒）。
  final int updatedAt;
}

/// 冲突笔记里值不同的一个字段。
class SrsMergeFieldDiff {
  const SrsMergeFieldDiff({
    required this.field,
    required this.name,
    required this.shared,
    required this.merged,
  });

  factory SrsMergeFieldDiff.fromJson(Map<String, Object?> m) =>
      SrsMergeFieldDiff(
        field: m['field']! as String,
        name: m['name'] as String?,
        shared: (m['into'] as String?) ?? '',
        merged: (m['from'] as String?) ?? '',
      );

  /// 字段 ID（规范形）与名字（读不到为 null）。
  final String field;
  final String? name;

  /// 共享库 / 被并入库里的值（截断过；没写过 = 空串）。
  final String shared;
  final String merged;
}

/// 一条冲突笔记（两边都有、内容不同）。
class SrsMergeConflict {
  const SrsMergeConflict({
    required this.note,
    required this.guid,
    required this.mergedIsNewer,
    required this.noteTypeDiffers,
    required this.deletedDiffers,
    required this.shared,
    required this.merged,
    required this.fields,
  });

  factory SrsMergeConflict.fromJson(Map<String, Object?> m) => SrsMergeConflict(
    note: m['note']! as String,
    guid: m['guid']! as String,
    mergedIsNewer: m['newer'] == 'from',
    noteTypeDiffers: m['typeDiffers'] == true,
    deletedDiffers: m['deletedDiffers'] == true,
    shared: SrsMergeSide.fromJson(
      (m['into']! as Map<Object?, Object?>).cast<String, Object?>(),
    ),
    merged: SrsMergeSide.fromJson(
      (m['from']! as Map<Object?, Object?>).cast<String, Object?>(),
    ),
    fields: <SrsMergeFieldDiff>[
      for (final Object? f in (m['fields'] as List<Object?>?) ?? const [])
        SrsMergeFieldDiff.fromJson(
          (f! as Map<Object?, Object?>).cast<String, Object?>(),
        ),
    ],
  );

  /// 笔记 ID（规范形）与 guid。
  final String note;
  final String guid;

  /// 被并入库那份改得更晚（只是提示：默认仍保留共享库）。
  final bool mergedIsNewer;

  final bool noteTypeDiffers;
  final bool deletedDiffers;
  final SrsMergeSide shared;
  final SrsMergeSide merged;

  /// 值不同的字段。
  final List<SrsMergeFieldDiff> fields;
}

/// 合并前的预览：规模与冲突表。
class SrsMergePreview {
  const SrsMergePreview({
    required this.bound,
    required this.notes,
    required this.cards,
    required this.reviews,
    required this.shared,
    required this.added,
    required this.conflicts,
  });

  factory SrsMergePreview.fromJson(Map<String, Object?> m) {
    final Map<String, Object?> from =
        ((m['from'] as Map<Object?, Object?>?) ?? const <Object?, Object?>{})
            .cast<String, Object?>();
    return SrsMergePreview(
      bound: m['bound'] == true,
      notes: (from['notes'] as int?) ?? 0,
      cards: (from['cards'] as int?) ?? 0,
      reviews: (from['reviews'] as int?) ?? 0,
      shared: (m['shared'] as int?) ?? 0,
      added: (m['added'] as int?) ?? 0,
      conflicts: <SrsMergeConflict>[
        for (final Object? c in (m['conflicts'] as List<Object?>?) ?? const [])
          SrsMergeConflict.fromJson(
            (c! as Map<Object?, Object?>).cast<String, Object?>(),
          ),
      ],
    );
  }

  /// 独立库在本机有集合（false = 从没在这台设备上打开过，没有可并的东西）。
  final bool bound;

  /// 独立库的规模：未删除的笔记、卡、复习记录。
  final int notes;
  final int cards;
  final int reviews;

  /// 两边都有的笔记数 / 只在独立库里、会新进共享库的笔记数。
  final int shared;
  final int added;

  final List<SrsMergeConflict> conflicts;
}

/// 合并结果。
class SrsMergeResult {
  const SrsMergeResult({
    required this.merged,
    required this.conflicts,
    required this.rewritten,
    required this.keptMerged,
  });

  factory SrsMergeResult.fromJson(Map<String, Object?> m) => SrsMergeResult(
    merged: m['merged'] == true,
    conflicts: (m['conflicts'] as int?) ?? 0,
    rewritten: (m['rewritten'] as int?) ?? 0,
    keptMerged: (m['keptFrom'] as int?) ?? 0,
  );

  /// 内核真的并了（false = 独立库在本机没有集合，什么都没写，也没有墓碑）。
  final bool merged;

  /// 冲突笔记数、按选择写回了的笔记数、其中保留独立库那份的笔记数。
  final int conflicts;
  final int rewritten;
  final int keptMerged;
}

/// 内核已并完、app 还没把组合的 `srs.library` 恢复继承的一次合并（墓碑 `collection_merged/<from>`）。
class SrsPendingCollectionMerge {
  const SrsPendingCollectionMerge({required this.from, this.into, this.at});

  /// 被并入的独立库（= 拆出它的组合的 uid）、共享库的 uid、并入时刻（读不懂为 null）。
  final String from;
  final String? into;
  final int? at;
}

/// 把独立库 [from] 并进共享库 [into] 之前的预览（读快照）。
Future<SrsMergePreview> srsCollectionMergePreview(
  SrsCore core, {
  required String from,
  required String into,
}) async => SrsMergePreview.fromJson(
  await srsRunLibraryCommand(core, <String, Object?>{
    'op': 'collection_merge_preview',
    'profile': into,
    'from': from,
    'into': into,
  }),
);

/// `collection_merge` 的请求（[srsCollectionMerge] 经核心句柄直发；共享库的副本开着时 app 经它的 `sync2Command` 发同一份，
/// 回包里的 `bindingChanged` 让那份副本的缓存整份作废、重取身份）。
Map<String, Object?> srsCollectionMergeRequest({
  required String from,
  required String into,
  required int nowMs,
  Map<String, SrsMergeChoice> resolutions = const <String, SrsMergeChoice>{},
}) => <String, Object?>{
  'op': 'collection_merge',
  'profile': into,
  'from': from,
  'into': into,
  'now': nowMs,
  'resolutions': <String, String>{
    for (final MapEntry<String, SrsMergeChoice> e in resolutions.entries)
      e.key: e.value.wire,
  },
};

/// 把独立库 [from] 整个并进共享库 [into]（内核一个写事务）。[resolutions]：冲突笔记 ID → 保留哪一边；没列的保留共享库。
/// 调用方先作废 [from] 的副本（之后再写它的都会报错），之后把组合的 `srs.library` 恢复继承、再
/// [srsFinishCollectionMerge] 删墓碑。
Future<SrsMergeResult> srsCollectionMerge(
  SrsCore core, {
  required String from,
  required String into,
  required int nowMs,
  Map<String, SrsMergeChoice> resolutions = const <String, SrsMergeChoice>{},
}) async => SrsMergeResult.fromJson(
  await srsRunLibraryCommand(
    core,
    srsCollectionMergeRequest(
      from: from,
      into: into,
      nowMs: nowMs,
      resolutions: resolutions,
    ),
  ),
);

/// 本机还没收尾的合并（墓碑）。
Future<List<SrsPendingCollectionMerge>> srsPendingCollectionMerges(
  SrsCore core,
) async {
  final Map<String, Object?> r = await srsRunLibraryCommand(
    core,
    const <String, Object?>{'op': 'collection_merges'},
  );
  return <SrsPendingCollectionMerge>[
    for (final Object? m in (r['merges'] as List<Object?>?) ?? const [])
      if (m case final Map<Object?, Object?> x)
        SrsPendingCollectionMerge(
          from: x['from']! as String,
          into: x['into'] as String?,
          at: x['at'] as int?,
        ),
  ];
}

/// 删掉 [from] 的墓碑（组合已恢复继承）。没有也不报错。
Future<void> srsFinishCollectionMerge(SrsCore core, String from) =>
    srsRunLibraryCommand(core, <String, Object?>{
      'op': 'collection_merge_done',
      'from': from,
    });
