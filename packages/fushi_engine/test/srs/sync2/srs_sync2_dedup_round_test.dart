// BUG-4005：一轮同步在收完段之后、发件之前推进重复流收敛作业（内核 store/sync2/dedup.rs），`done` 明确为假才再发；
// 发件带上位置是不是归档（归档位置不同名重写副本收敛换下的段）。同一个脚本宿主也钉住摘要之后的自动重建
// （`digest_heal`，内核 store/sync2/heal.rs）的接线。

import 'dart:typed_data';

import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

const SrsSync2Result _empty = SrsSync2Result(
  <String, Object?>{},
  <(String, Uint8List)>[],
);

class _Host implements SrsSync2Host {
  _Host(this.dedupSteps);

  /// 作业还要几步才做完（每步回 `done: false`）；null = 内核不认识这条命令（回空对象）。
  int? dedupSteps;

  /// `digest_heal` 的回复；null = 回空对象（内核不认识这条命令）。
  Map<String, Object?>? heal;
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  @override
  String get profileUid => 'p';

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) async {
    requests.add(request);
    switch (request['op']) {
      case 'identity':
        return const SrsSync2Result(<String, Object?>{
          'collection': 'c1',
          'device': 'SELF',
        }, <(String, Uint8List)>[]);
      case 'plan':
        return const SrsSync2Result(<String, Object?>{
          'fetch': <Object?>[],
        }, <(String, Uint8List)>[]);
      case 'dedup':
        final int? left = dedupSteps;
        if (left == null) return _empty;
        dedupSteps = left - 1;
        return SrsSync2Result(<String, Object?>{
          'done': left <= 0,
        }, const <(String, Uint8List)>[]);
      case 'digest_heal':
        final Map<String, Object?>? h = heal;
        if (h == null) return _empty;
        return SrsSync2Result(h, const <(String, Uint8List)>[]);
      case 'outbox':
        return const SrsSync2Result(<String, Object?>{
          'upto': 0,
        }, <(String, Uint8List)>[]);
      case 'head':
        return const SrsSync2Result(<String, Object?>{
          'gen': 0,
          'delete': <Object?>[],
        }, <(String, Uint8List)>[]);
    }
    return _empty;
  }

  @override
  Future<void> sync2IngestBegin() async {}

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  }) async => <String, Object?>{'applied': 0, 'fork': false};

  @override
  Future<Map<String, Object?>> sync2IngestFinish() async => <String, Object?>{
    'applied': 0,
    'fork': false,
  };

  @override
  Future<void> sync2IngestEnd() async {}

  List<String> get ops => <String>[
    for (final Map<String, Object?> r in requests) r['op']! as String,
  ];
}

void main() {
  test('收完段之后、发件之前把作业推进到做完；发件带归档标记', () async {
    for (final bool archive in <bool>[false, true]) {
      final _Host host = _Host(3);
      final SrsSync2Report r = await srsSync2Round(
        host: host,
        location: SrsMemoryLocationStore(),
        locationId: 'loc',
        nowMs: () => 0,
        archive: archive,
      );
      expect(r.error, isNull);
      final List<String> ops = host.ops;
      expect(ops.where((String o) => o == 'dedup').length, 4);
      expect(ops.indexOf('dedup'), greaterThan(ops.indexOf('plan')));
      expect(ops.lastIndexOf('dedup'), lessThan(ops.indexOf('outbox')));
      final Map<String, Object?> outbox = host.requests.firstWhere(
        (Map<String, Object?> q) => q['op'] == 'outbox',
      );
      expect(outbox['archive'], archive);
    }
  });

  test('内核没回 `done: false`（不认识 / 没有作业）就只发一次', () async {
    final _Host host = _Host(null);
    final SrsSync2Report r = await srsSync2Round(
      host: host,
      location: SrsMemoryLocationStore(),
      locationId: 'loc',
      nowMs: () => 0,
    );
    expect(r.error, isNull);
    expect(host.ops.where((String o) => o == 'dedup').length, 1);
  });

  test('作业一步步推进时 shouldStop 照样能让这一轮收手（已提交的步骤留着，下一轮续做）', () async {
    final _Host host = _Host(1 << 30);
    final Stopwatch clock = Stopwatch()..start();
    final SrsSync2Report r = await srsSync2Round(
      host: host,
      location: SrsMemoryLocationStore(),
      locationId: 'loc',
      nowMs: () => 0,
      shouldStop: () => host.ops.where((String o) => o == 'dedup').length >= 5,
    );
    expect(r.error, kSrsSync2Stopped);
    expect(clock.elapsed, lessThan(kSrsSync2DedupBudget));
  });

  test('摘要之后、写 head 之前调自动重建：修不好的交给 report.healFailed，重放过就算 changed', () async {
    final _Host host = _Host(null)
      ..heal = <String, Object?>{
        'replayed': <Object?>['C'],
        'healed': <Object?>[
          <String, Object?>{
            'device': 'D1',
            'groups': <Object?>[3],
            'cards': 1,
          },
        ],
        'healFailed': <Object?>[
          <String, Object?>{
            'device': 'D2',
            'groups': <Object?>[7],
            'reason': 'replayChangedNothing',
          },
        ],
      };
    final SrsSync2Report r = await srsSync2Round(
      host: host,
      location: SrsMemoryLocationStore(),
      locationId: 'loc',
      nowMs: () => 0,
    );
    expect(r.error, isNull);
    final List<String> ops = host.ops;
    expect(ops.where((String o) => o == 'digest_heal').length, 1);
    expect(ops.indexOf('digest_heal'), greaterThan(ops.indexOf('digest')));
    expect(ops.indexOf('digest_heal'), lessThan(ops.indexOf('head')));
    expect(r.healFailed, hasLength(1));
    expect(r.healFailed.single['device'], 'D2');
    expect(r.healFailed.single['reason'], 'replayChangedNothing');
    expect(r.changed, isTrue);
  });

  test('内核不认识 `digest_heal`（回空对象）：什么都不报、不算 changed', () async {
    final _Host host = _Host(null);
    final SrsSync2Report r = await srsSync2Round(
      host: host,
      location: SrsMemoryLocationStore(),
      locationId: 'loc',
      nowMs: () => 0,
    );
    expect(r.error, isNull);
    expect(host.ops, contains('digest_heal'));
    expect(r.healFailed, isEmpty);
    expect(r.changed, isFalse);
  });
}
