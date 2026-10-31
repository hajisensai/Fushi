// 集成审查【中】：旧段 / 旧转发件删除两段式（内核 transport.rs `pending_deletes` / `sync2_obsolete_ack`）。Dart 只确认
// 真删成功的那些；删除中途抛错时已删的照样确认、错误原样抛出，没删成的留在内核待删表里下一轮再给。
import 'dart:typed_data';

import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

void main() {
  test('删到一半失败：只确认删成功的，错误照抛；下一轮删剩下的', () async {
    final _Host host = _Host();
    final _FailingStore loc = _FailingStore()
      ..files['devices/a/seg-1'] = Uint8List(1)
      ..files['devices/a/seg-2'] = Uint8List(1)
      ..failOn.add('devices/a/seg-2');
    final List<String> paths = <String>['devices/a/seg-1', 'devices/a/seg-2'];
    await expectLater(
      srsDeleteAndAck(
        host: host,
        location: loc,
        progressId: 'loc',
        paths: paths,
        archive: false,
      ),
      throwsA(isA<StateError>()),
    );
    expect(host.acked, <List<String>>[
      <String>['devices/a/seg-1'],
    ]);
    expect(loc.files.keys, <String>['devices/a/seg-2']);

    // 下一轮：内核照样给出没确认的那一个（这里直接重给整张清单：已删的再删一次是幂等的）。
    loc.failOn.clear();
    await srsDeleteAndAck(
      host: host,
      location: loc,
      progressId: 'loc',
      paths: paths,
      archive: false,
    );
    expect(loc.files, isEmpty);
    expect(host.acked.last, unorderedEquals(paths));
  });

  test('归档位置：一个不删，直接确认（不然待删记录永远攒着）', () async {
    final _Host host = _Host();
    final _FailingStore loc = _FailingStore()
      ..files['devices/a/seg-1'] = Uint8List(1);
    await srsDeleteAndAck(
      host: host,
      location: loc,
      progressId: 'loc',
      paths: <String>['devices/a/seg-1'],
      archive: true,
    );
    expect(loc.files.keys, <String>['devices/a/seg-1']);
    expect(host.acked, <List<String>>[
      <String>['devices/a/seg-1'],
    ]);
  });

  test('清单为空：不发命令', () async {
    final _Host host = _Host();
    await srsDeleteAndAck(
      host: host,
      location: _FailingStore(),
      progressId: 'loc',
      paths: const <String>[],
      archive: false,
    );
    expect(host.acked, isEmpty);
  });
}

/// 只认 `obsolete_ack`，记下每次确认的路径。
class _Host implements SrsSync2Host {
  final List<List<String>> acked = <List<String>>[];

  @override
  String get profileUid => 'p';

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) async {
    expect(request['op'], 'obsolete_ack');
    expect(request['location'], 'loc');
    acked.add(<String>[
      ...(request['deleted']! as List<Object?>).cast<String>(),
    ]);
    return const SrsSync2Result(<String, Object?>{
      'removed': 0,
    }, <(String, Uint8List)>[]);
  }

  @override
  Future<void> sync2IngestBegin() => throw UnimplementedError();

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  }) => throw UnimplementedError();

  @override
  Future<Map<String, Object?>> sync2IngestFinish() =>
      throw UnimplementedError();
}

/// [failOn] 里的路径删除时抛错（模拟云盘删除失败）。
class _FailingStore extends SrsMemoryLocationStore {
  final Set<String> failOn = <String>{};

  @override
  Future<void> delete(String path) async {
    if (failOn.contains(path)) throw StateError('delete failed: $path');
    await super.delete(path);
  }
}
