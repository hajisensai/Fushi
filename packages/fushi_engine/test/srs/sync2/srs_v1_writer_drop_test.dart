// BUG-4908（所有者 2026-11-21 拍板放弃 v3.0.x 客户端）：v3.0.x 旧事件同步留在云盘 / 互联位置上的写入者目录
// `fushi-srs/<uid>/<写入者>/`（batch-* / snapshot-* / profile.json / media/），在旧根媒体迁移收尾时整目录删——
// 只在四个条件同时成立时：旧根 `v2/meta.json` 是围栏、新根 `v3/meta.json` 在用、旧根完成标记的指纹等于当前清单、
// 每个写入者的 `media/` 都空了。任何一个不成立都一个字节不删；`v2/` 围栏本身永远不删。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/sync2/srs_location_migration.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsTrustedClock;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/srs_fake_engine.dart';
import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000c9';
const String kWriterA = '2RIr94DPav6kxb5RWSGciWgE4LNKvGBCRtT4wT2iGSc=#1';
const String kWriterB = 'Zm9vYmFyYmF6cXV4cXV1eHF1dXhxdXV4cXV1eHF1dXg=#3';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  late Directory remote;
  late LocalDirectoryAssetStore backend;
  late SrsDbStore b;
  int t = 0;

  String profileDir() => p.join(remote.path, kSrsSync2Namespace, kProfile);
  Directory writerDir(String w) => Directory(p.join(profileDir(), w));
  File v2Meta() => File(p.join(profileDir(), kSrsSync2V1Folder, 'meta.json'));
  File v3Meta() => File(p.join(profileDir(), kSrsSync2Folder, 'meta.json'));

  void write(String rel, List<int> bytes) {
    File(p.join(profileDir(), rel))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }

  SrsLocationStore v3() =>
      SrsAssetLocationStore(store: backend, profileUid: kProfile);
  SrsLocationStore v1() => SrsAssetLocationStore(
    store: backend,
    profileUid: kProfile,
    folder: kSrsSync2V1Folder,
  );

  Future<SrsLocationPrepared> prepare() => srsPrepareLocation(
    host: b,
    v1: v1(),
    current: v3(),
    locationId: 'remote',
    key: null,
    nowMs: () => t += 1000,
    writers: SrsAssetV1Writers(backend, kProfile),
  );

  Future<void> round() async {
    final SrsSync2Report r = await srsSync2Round(
      host: b,
      location: v3(),
      locationId: 'remote',
      nowMs: () => t += 1000,
    );
    expect(r.error, isNull);
  }

  // 每次都是新实例、不带 memo：等同下一个进程。
  Future<SrsV1MediaReport> migrate() => srsMigrateV1Media(
    host: b,
    v1: v1(),
    current: v3(),
    locationId: 'remote',
    key: null,
    nowMs: () => t += 1000,
    canBind: true,
    progressId: 'remote',
    recordPresence: true,
    writers: SrsAssetV1Writers(backend, kProfile),
  );

  setUp(() async {
    t = DateTime.utc(2026, 11, 21, 9).millisecondsSinceEpoch;
    tmp = Directory.systemTemp.createTempSync('srs_writer_drop_');
    remote = Directory(p.join(tmp.path, 'remote'))..createSync();
    backend = LocalDirectoryAssetStore(remote);
    final st = await openTestSrsStorage();
    b = await SrsDbStore.open(
      core: st.core,
      profileUid: kProfile,
      deviceId: 'b',
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        bootClockMs: () => t,
        bootId: 'boot-b',
      ),
    );
    t += 1000;
    await b.createNote(
      noteTypeId: b.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '古',
        srsLapisFieldId(kProfile, 'Picture'): '<img src="one.png">',
      },
    );
    // v3.0.x 两台设备留下的写入者目录：一台带一个按名字存的媒体，一台只有批次。
    write('$kWriterA/$kSrsMediaFolder/one.png', utf8.encode('one'));
    write('$kWriterA/batch-0000000001', utf8.encode('batch'));
    write('$kWriterA/snapshot-0000000001', utf8.encode('snap'));
    write('$kWriterA/profile.json', utf8.encode('{"name":"Default"}'));
    write('$kWriterB/batch-0000000007', utf8.encode('batch'));
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄滞后（Windows）：留给系统清理。
    }
  });

  /// 迁移到「旧根已处理到头」：围栏、新根 meta、写入者媒体搬完删掉、完成标记写下。返回最后一次迁移的结论。
  Future<SrsV1MediaReport> migrateToSettled() async {
    expect((await prepare()).error, isNull);
    await round();
    final SrsV1MediaReport bound = await migrate();
    expect(bound.bound, 1);
    await round(); // 发布迁移补的绑定，按名字的旧文件才能删。
    final SrsV1MediaReport cleaned = await migrate();
    expect(cleaned.deleted, 1);
    expect(cleaned.finished, isTrue);
    return cleaned;
  }

  test('四个条件都成立：整目录删掉全部写入者目录，围栏与新根原样', () async {
    final SrsV1MediaReport cleaned = await migrateToSettled();
    // 写下完成标记的这一次只搬媒体，不删目录（指纹要在下一次比过才算「确认处理到头」）。
    expect(cleaned.droppedWriters, isEmpty);
    expect(writerDir(kWriterA).existsSync(), isTrue);
    final List<int> fence = v2Meta().readAsBytesSync();
    final List<int> v3MetaBytes = v3Meta().readAsBytesSync();

    final SrsV1MediaReport next = await migrate();
    expect(next.droppedWriters.toSet(), <String>{kWriterA, kWriterB});
    expect(next.cleanupErrors, isEmpty);
    expect(writerDir(kWriterA).existsSync(), isFalse);
    expect(writerDir(kWriterB).existsSync(), isFalse);
    // 围栏不删、不改；新根不动。
    expect(v2Meta().readAsBytesSync(), fence);
    expect(srsDecodeV1Fence(v2Meta().readAsBytesSync()), isNotNull);
    expect(v3Meta().readAsBytesSync(), v3MetaBytes);
    // 幂等：再来一次什么都不删。
    expect((await migrate()).droppedWriters, isEmpty);
  });

  test('新根 v3/meta.json 不在：不删', () async {
    final SrsV1MediaReport r = await migrate();
    expect(r.droppedWriters, isEmpty);
    expect(writerDir(kWriterA).existsSync(), isTrue);
    expect(writerDir(kWriterB).existsSync(), isTrue);
  });

  test('旧根 v2/meta.json 不是围栏：不删', () async {
    await migrateToSettled();
    v2Meta().writeAsStringSync(jsonEncode(<String, Object?>{'version': 1}));
    final SrsV1MediaReport r = await migrate();
    expect(r.droppedWriters, isEmpty);
    expect(writerDir(kWriterA).existsSync(), isTrue);
    expect(writerDir(kWriterB).existsSync(), isTrue);
  });

  test('完成标记的指纹与当前清单不符（旧根多了文件）：这一次不删', () async {
    await migrateToSettled();
    write('$kSrsSync2V1Folder/late-arrival.bin', utf8.encode('late'));
    final SrsV1MediaReport r = await migrate();
    expect(r.droppedWriters, isEmpty);
    expect(writerDir(kWriterA).existsSync(), isTrue);
    expect(writerDir(kWriterB).existsSync(), isTrue);
  });

  test('完成标记不在：不删', () async {
    await migrateToSettled();
    File(
      p.join(profileDir(), kSrsSync2V1Folder, kSrsV1SweepMarker),
    ).deleteSync();
    final SrsV1MediaReport r = await migrate();
    expect(r.droppedWriters, isEmpty);
    expect(writerDir(kWriterA).existsSync(), isTrue);
  });

  test('写入者的 media/ 还有文件（晚到的旧媒体）：这一次不删，先搬', () async {
    await migrateToSettled();
    write('$kWriterB/$kSrsMediaFolder/late.png', utf8.encode('late'));
    final SrsV1MediaReport r = await migrate();
    expect(r.droppedWriters, isEmpty);
    expect(writerDir(kWriterA).existsSync(), isTrue);
    expect(
      File(
        p.join(writerDir(kWriterB).path, kSrsMediaFolder, 'late.png'),
      ).existsSync(),
      isTrue,
    );
  });
}
