// 旧根媒体后台迁移的收手（PR #2768 审查）：quiesce / 切 profile / 位置被关掉之后
// - [SrsV1MediaMigrations] 不再起排着的下一次、也不接新的（那一次开头就要把旧根、新根内容目录整树列一遍）；
// - 已经在跑的 [srsMigrateV1Media] 在整树列目录之前 / 之后都看一眼收手判据，不为一次马上要扔掉的迁移把两棵树列完。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/srs/sync2/srs_location_migration.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:test/test.dart';

void main() {
  group('SrsV1MediaMigrations', () {
    test('收手之后：排着的下一次丢掉，不再起', () async {
      final Set<String> stopped = <String>{};
      final List<SrsV1MediaProgress?> progress = <SrsV1MediaProgress?>[];
      final SrsV1MediaMigrations m = SrsV1MediaMigrations(
        shouldStop: stopped.contains,
        onProgress: progress.add,
      );
      final Completer<void> gate = Completer<void>();
      int ran = 0;
      expect(
        m.start('a', (void Function(int, int) p) async {
          ran++;
          await gate.future;
          return SrsV1MediaReport();
        }),
        isTrue,
      );
      expect(
        m.start('a', (void Function(int, int) p) async {
          ran++;
          return SrsV1MediaReport();
        }),
        isFalse,
        reason: '在跑：记下，跑完接着跑',
      );
      stopped.add('a');
      gate.complete();
      await m.idle();
      expect(ran, 1, reason: '排着的那一次不再起');
      expect(m.isRunning('a'), isFalse);
      expect(m.progress, isNull);
      expect(progress.last, isNull);
    });

    test('收手时交来的不起不记；只管那一个位置', () async {
      final Set<String> stopped = <String>{'a'};
      final SrsV1MediaMigrations m = SrsV1MediaMigrations(
        shouldStop: stopped.contains,
      );
      int ran = 0;
      Future<SrsV1MediaReport> job(void Function(int, int) p) async {
        ran++;
        return SrsV1MediaReport();
      }

      expect(m.start('a', job), isFalse);
      expect(m.isRunning('a'), isFalse);
      expect(m.start('b', job), isTrue, reason: '别的位置照常');
      await m.idle();
      expect(ran, 1);
      stopped.clear();
      expect(m.start('a', job), isTrue, reason: '重新打开后照常');
      await m.idle();
      expect(ran, 2);
    });
  });

  group('srsMigrateV1Media', () {
    late _CountingLocation v1;
    late _CountingLocation current;

    setUp(() {
      v1 = _CountingLocation();
      current = _CountingLocation();
      final Map<String, Object?> meta = <String, Object?>{
        'v': 1,
        'minReader': 1,
        'collection': 'c1',
        'createdAt': 1,
      };
      v1.inner.files['meta.json'] = srsEncodeV1Fence(srsV1FenceMeta(meta, 2));
      v1.inner.files['media/old.png'] = Uint8List.fromList(<int>[1, 2]);
      current.inner.files['meta.json'] = Uint8List.fromList(
        utf8.encode(jsonEncode(srsV2MetaFromV1(meta, 'c1', 2))),
      );
    });

    Future<SrsV1MediaReport> migrate(bool Function() shouldStop) =>
        srsMigrateV1Media(
          host: _NoHost(),
          v1: v1,
          current: current,
          locationId: 'loc',
          key: null,
          nowMs: () => 3,
          canBind: false,
          shouldStop: shouldStop,
        );

    test('一开始就该收手：旧根、新根一个目录都不列', () async {
      final SrsV1MediaReport r = await migrate(() => true);
      expect(v1.lists, 0);
      expect(current.lists, 0);
      expect(r.finished, isFalse);
      expect(v1.inner.files.keys, contains('media/old.png'), reason: '什么都没动');
    });

    test('列完旧根才该收手：不再列新根内容目录', () async {
      bool stop = false;
      v1.onList = () => stop = true;
      await migrate(() => stop);
      expect(v1.lists, greaterThan(0));
      expect(current.lists, 0);
      expect(v1.inner.files.keys, contains('media/old.png'));
    });

    test('对照：不收手时照常列两棵树', () async {
      await migrate(() => false);
      expect(v1.lists, greaterThan(0));
      expect(current.lists, greaterThan(0));
    });
  });
}

/// 数 [list] 调用次数的内存位置。
class _CountingLocation implements SrsLocationStore {
  final SrsMemoryLocationStore inner = SrsMemoryLocationStore();
  int lists = 0;
  void Function()? onList;

  @override
  Future<List<SrsLocationEntry>> list(String dir) async {
    lists++;
    final List<SrsLocationEntry> out = await inner.list(dir);
    onList?.call();
    return out;
  }

  @override
  Future<Uint8List?> get(String path) => inner.get(path);
  @override
  Future<bool> exists(String path) => inner.exists(path);
  @override
  Future<void> put(String path, Uint8List bytes) => inner.put(path, bytes);
  @override
  Future<void> putNew(String path, Uint8List bytes) =>
      inner.putNew(path, bytes);
  @override
  Future<void> delete(String path) => inner.delete(path);
}

/// 收手的路径上不该碰到本机库。
class _NoHost implements SrsSync2Host {
  @override
  String get profileUid => 'p';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}
