/// 一个 profile 在 srs.db 里的本机数据：规模、整体删除、库里出现过的 uid（反馈 8TaOy2i-lL 现象 3）。
///
/// 状态归 Rust（native/fushi_fsrs/src/store/profile_data.rs）：表清单在内核里现查，删除是一个 savepoint 里的
/// 一条命令；这里只是后台 isolate 里的薄封装（数万行的删除超过 1 ms，不放 UI isolate）。
library;

import 'dart:isolate';

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

Future<Map<String, Object?>> _run(SrsCore core, Map<String, Object?> request) {
  final int address = core.address;
  final String? libraryPath = core.libraryPath;
  return Isolate.run<Map<String, Object?>>(
    () => SrsCore.fromAddress(
      address,
      libraryPath: libraryPath,
    ).sync2(request).map,
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

/// 记下一次性存量无主数据扫描已完成。
Future<void> srsMarkOrphanSweepDone(SrsCore core, int nowMs) =>
    _run(core, <String, Object?>{'op': 'orphan_sweep_done', 'now': nowMs});
