/// 一个 profile 在 srs.db 里的本机数据：规模、整体删除、库里出现过的 uid（反馈 8TaOy2i-lL 现象 3）。
///
/// 状态归 Rust（native/fushi_fsrs/src/store/profile_data.rs）：表清单在内核里现查，删除是一个 savepoint 里的
/// 一条命令；这里只是后台 isolate 里的薄封装（数万行的删除超过 1 ms，不放 UI isolate）。并入的标记 / 收尾
/// （[srsMarkProfileMerge] / [srsCommitProfileMerge]）与 profile 链接记的集合（[srsEditMetaSet]）也在这里：
/// 都是不针对单个副本的库级命令。
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_srs/fushi_srs.dart' show SrsCore;

/// 一个 profile 在本机 srs.db 里的规模。
class SrsProfileFootprint {
  const SrsProfileFootprint({
    required this.notes,
    required this.cards,
    required this.reviews,
    required this.rows,
  });

  const SrsProfileFootprint.empty()
    : notes = 0,
      cards = 0,
      reviews = 0,
      rows = 0;

  factory SrsProfileFootprint.fromJson(Map<String, Object?> m) =>
      SrsProfileFootprint(
        notes: (m['notes'] as int?) ?? 0,
        cards: (m['cards'] as int?) ?? 0,
        reviews: (m['reviews'] as int?) ?? 0,
        rows: (m['rows'] as int?) ?? 0,
      );

  /// 未删除的笔记数。
  final int notes;

  /// 未删除笔记下的卡数。
  final int cards;

  /// 复习记录数（全部日志）。
  final int reviews;

  /// 这个 uid 在各按 profile 分的表里的总行数（0 = 库里没有它的任何东西）。
  final int rows;

  bool get isEmpty => rows == 0;

  @override
  bool operator ==(Object other) =>
      other is SrsProfileFootprint &&
      other.notes == notes &&
      other.cards == cards &&
      other.reviews == reviews &&
      other.rows == rows;

  @override
  int get hashCode => Object.hash(notes, cards, reviews, rows);

  @override
  String toString() =>
      'SrsProfileFootprint(notes: $notes, cards: $cards, reviews: $reviews, rows: $rows)';
}

/// srs.db 里出现过数据的 uid，与一次性存量扫描的完成时刻（毫秒；null = 还没扫过）。
typedef SrsStoredProfiles = ({List<String> uids, int? orphanSweptAt});

Future<Map<String, Object?>> _run(
  SrsCore core,
  Map<String, Object?> request, {
  List<Uint8List> blobs = const <Uint8List>[],
}) {
  final int address = core.address;
  final String? libraryPath = core.libraryPath;
  return Isolate.run<Map<String, Object?>>(
    () => SrsCore.fromAddress(
      address,
      libraryPath: libraryPath,
    ).sync2(request, blobs: blobs).map,
  );
}

/// [profileUid] 的规模（确认框用）。
Future<SrsProfileFootprint> srsProfileFootprint(
  SrsCore core,
  String profileUid,
) async => SrsProfileFootprint.fromJson(
  await _run(core, <String, Object?>{
    'op': 'profile_footprint',
    'profile': profileUid,
  }),
);

/// 一个事务里删掉 [profileUid] 在本机 srs.db 里的全部行（只动本机，远端已同步的集合不碰）。返回删之前的规模。
/// 调用方负责先备份、并保证没有这个 uid 的副本还在写（见 `SrsDbStore.retire`）。
Future<SrsProfileFootprint> srsPurgeProfileRows(
  SrsCore core,
  String profileUid,
) async => SrsProfileFootprint.fromJson(
  await _run(core, <String, Object?>{
    'op': 'profile_purge',
    'profile': profileUid,
  }),
);

/// srs.db 里出现过数据的全部 uid（找无主数据用）。
Future<SrsStoredProfiles> srsStoredProfiles(SrsCore core) async {
  final Map<String, Object?> m = await _run(core, const <String, Object?>{
    'op': 'profile_uids',
  });
  return (
    uids: <String>[
      for (final Object? u
          in (m['uids'] as List<Object?>?) ?? const <Object?>[])
        u! as String,
    ],
    orphanSweptAt: m['orphanSweptAt'] as int?,
  );
}

/// [srsFinishOrphanSweep] 清掉的东西：只剩 `srs_meta` 键的无主 uid（[metaUids]）、它们名下的键数、回收的
/// `sync2_deps` 行数。
typedef SrsOrphanSweepRest = ({List<String> metaUids, int metaKeys, int deps});

/// 一次性存量无主数据扫描的收尾（内核一个 savepoint，profile_data.rs `orphan_sweep_done`）：表里已经没有任何行、
/// 只剩 `srs_meta` 键的 uid 里不在 [keep] 中的，删掉它名下的键；回收没有任何操作引用的 `sync2_deps`；[mark] 为真
/// 时记下扫描已完成（之后不再扫）。
///
/// [keep]：不许当成无主的 uid——主库现存 profile 的 uid 加进行中并入涉及的 uid。调用方在当前副本的独占区里调
/// （同 [srsPurgeProfileRows]）。
Future<SrsOrphanSweepRest> srsFinishOrphanSweep(
  SrsCore core,
  int nowMs, {
  required Iterable<String> keep,
  required bool mark,
}) async {
  final Map<String, Object?> m = await _run(core, <String, Object?>{
    'op': 'orphan_sweep_done',
    'now': nowMs,
    'keep': keep.toList(),
    'mark': mark,
  });
  return (
    metaUids: <String>[
      for (final Object? u
          in (m['metaUids'] as List<Object?>?) ?? const <Object?>[])
        u! as String,
    ],
    metaKeys: (m['meta'] as int?) ?? 0,
    deps: (m['deps'] as int?) ?? 0,
  );
}

/// 记下「旧 uid [oldUid]（主库 profile [profileId]）正在并入 [newUid]」（`srs_meta` 的 `profile_merge/<旧 uid>`，
/// srs_profile_merge.dart 的第一步）。并入提交（[srsCommitProfileMerge]）时随旧 uid 的元数据键一起删掉。
Future<void> srsMarkProfileMerge(
  SrsCore core, {
  required int profileId,
  required String oldUid,
  required String newUid,
}) => _run(core, <String, Object?>{
  'op': 'profile_merge_mark',
  'from': oldUid,
  'profileId': profileId,
  'to': newUid,
});

/// 并入的收尾：内核在一次持写锁、一个 savepoint 里核对并删掉旧 uid（`profile_merge_commit`）。
///
/// - `done`：旧 uid 此刻的每条事件都在 [oldToNew] 里、映射过去的都已在 [newUid] 下，旧 uid 已整个删掉；
/// - `missing > 0`：有这么多条映射过去的事件不在 [newUid] 下，什么都没删（调用方报错）；
/// - 都不是：旧 uid 在计划之后又被写了，什么都没删（调用方重新计划再来）。
///
/// [debugFailAfterCheck]（测试）：核对通过之后让内核报错，验证整笔回滚。
Future<({bool done, int missing})> srsCommitProfileMerge(
  SrsCore core, {
  required String oldUid,
  required String newUid,
  required Map<String, String> oldToNew,
  bool debugFailAfterCheck = false,
}) async {
  final Map<String, Object?> r = await _run(
    core,
    <String, Object?>{
      'op': 'profile_merge_commit',
      'from': oldUid,
      'to': newUid,
      if (debugFailAfterCheck) 'failAfter': 'check',
    },
    blobs: <Uint8List>[utf8.encode(jsonEncode(oldToNew))],
  );
  return (done: r['done'] == true, missing: (r['missing'] as int?) ?? 0);
}

/// profile 链接在 `srs_meta` 里记的字符串集合（srs_profile_link.dart）。
enum SrsMetaSet {
  /// 本设备退役的 v2 设备身份（`srs_retired_v2_devices`）。
  retiredDevices('retiredDevices'),

  /// 本设备换 uid 时离开的旧 uid（`srs_retired_profile_uids`）。
  retiredUids('retiredUids');

  const SrsMetaSet(this.wire);

  /// 命令里的名字。
  final String wire;
}

/// 集合 [set] 的原子增删（`meta_set_edit`：读、改、写在内核的一次持写锁里；并发的增删不互相覆盖）。[add] /
/// [remove] 都不给 = 只读。返回改完之后的集合。
Future<Set<String>> srsEditMetaSet(
  SrsCore core,
  SrsMetaSet set, {
  String? add,
  String? remove,
}) async {
  final Map<String, Object?> r = await _run(core, <String, Object?>{
    'op': 'meta_set_edit',
    'set': set.wire,
    'add': ?add,
    'remove': ?remove,
  });
  return <String>{
    for (final Object? v
        in (r['values'] as List<Object?>?) ?? const <Object?>[])
      v! as String,
  };
}
