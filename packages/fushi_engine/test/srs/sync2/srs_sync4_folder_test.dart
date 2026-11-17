// 文件夹位置上的新代一轮（sync2/srs_folder_location.dart → srs_sync2_round.dart → 内核 `gen4/cmd/sync.rs`，G8-7），
// 真内核：位置的根一律由内核 `location_root` 立。判「新集合」只看旧根 `v3/meta.json` 在不在，所以这一轮在它之前
// 不能有任何东西往旧根写 meta（以前文件夹路径先跑协议 3 的 `srsPrepareLocation`，往 `v3/` 写了一份 meta，全新位置
// 因此被判成存量集合：新根 meta 的 `media` 永久记成 v3、墓碑 head 也不立）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_folder_location.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show SrsAssetLocationStore, kSrsSync2Folder, kSrsSync2Namespace;
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/srs_fake_engine.dart';
import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000f4';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  int t = DateTime.utc(2026, 11, 17, 9).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 11, 17, 9).millisecondsSinceEpoch;
    tmp = Directory.systemTemp.createTempSync('srs_sync4_folder_');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄滞后（Windows）：留给系统清理。
    }
  });

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    // 新库先立本机身份与集合绑定（内核 `identity`，G9-4）：`SrsDbStore.open` 在没绑定的 profile 上报
    // SrsProfileUnboundException（open 段的现状，不归本模块）。
    st.core.sync2(<String, Object?>{
      'op': 'identity',
      'profile': kProfile,
      'now': t,
    });
    return SrsDbStore.open(
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        bootClockMs: () => t,
        bootId: 'boot-$id',
      ),
    );
  }

  String expr(SrsDbStore s) => srsLapisFieldId(s.profileUid, 'Expression');

  Future<String> addNote(SrsDbStore s, String text) {
    t += 1000;
    return s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{expr(s): text},
    );
  }

  Future<SrsFolderSyncReport> run(SrsFolderLocation loc, SrsDbStore s) {
    t += 1000;
    return srsSyncFolderLocation(location: loc, store: s);
  }

  Map<String, Object?> readJson(Directory root, String name) =>
      (jsonDecode(File(p.join(root.path, name)).readAsStringSync()) as Map)
          .cast<String, Object?>();

  SrsFolderLocation folder() {
    final Directory d = Directory(p.join(tmp.path, 'usb'))..createSync();
    return SrsFolderLocation(id: 'usb', path: d.path, media: false);
  }

  test('全新文件夹位置：新根 meta 的媒体在 v4、旧根有围栏与墓碑、v2 只立协议 1 的围栏；两台设备经它收敛', () async {
    final SrsFolderLocation loc = folder();
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    await addNote(a, '猫');
    await addNote(b, '犬');
    for (int i = 0; i < 2; i++) {
      for (final SrsDbStore s in <SrsDbStore>[a, b]) {
        final SrsFolderSyncReport r = await run(loc, s);
        expect(r.ops?.error, isNull);
        expect(r.ops?.needsUpgrade, isFalse);
        expect(r.ops?.mediaRoot, kSrs4Root);
        expect(r.prepared, isNull);
      }
    }
    final String dir = await srsFolderLocationDir(a);
    final Map<String, Object?> meta4 = readJson(
      srsFolderNewRoot(loc, dir),
      'meta.json',
    );
    expect(meta4['media'], kSrs4Root);
    final Directory old = srsFolderCollectionRoot(loc, dir);
    final Map<String, Object?> fence = readJson(old, 'meta.json');
    expect(fence['moved'], kSrs4Root);
    expect(fence['minReader'], 4);
    // 墓碑 head：旧根 devices/ 下有一份 head。
    expect(
      Directory(p.join(old.path, 'devices'))
          .listSync(recursive: true)
          .whereType<File>()
          .any((File f) => p.basename(f.path).startsWith('head-')),
      isTrue,
    );
    // 协议 1 的旧根 `v2/` 只有一份让协议 1 的版本在握手就停下的围栏（不是 JSON），别的什么都不写。
    final Directory v2 = srsFolderV1CollectionRoot(loc, dir);
    expect(
      v2
          .listSync(recursive: true)
          .whereType<File>()
          .map((File f) => p.basename(f.path)),
      <String>['meta.json'],
    );
    expect(
      () => jsonDecode(File(p.join(v2.path, 'meta.json')).readAsStringSync()),
      throwsFormatException,
    );
    // 收敛：两边各自应用了对方的全部操作，语义摘要（head 带的那一份）相同。按笔记读回来核对不了：
    // `SrsDbStore.note` 在新代库上读修改记录时崩（`_prefetchEdits` 的 Null check，读路径不归本模块，交接 §11.6）。
    Future<Map<String, Object?>> status(SrsDbStore s) async =>
        (await s.sync2Command(<String, Object?>{'op': 'status'})).map;
    for (final SrsDbStore s in <SrsDbStore>[a, b]) {
      final List<Object?> devices = (await status(s))['devices']! as List;
      expect(devices.length, 2);
      for (final Object? d in devices) {
        expect((d! as Map)['behind'], 0, reason: '$d');
        expect((d as Map)['applied'], greaterThan(0), reason: '$d');
      }
    }
    Future<Object?> digest(SrsDbStore s) async => (await s.sync2Command(
      <String, Object?>{'op': 'digest', 'now': t},
    )).map['digest'];
    expect(await digest(a), await digest(b));
  });

  test('云端位置实例直接用 identity 给的目录名，不再按 profile uid 映射一次', () async {
    final SrsAssetLocationStore loc = SrsAssetLocationStore(
      store: LocalDirectoryAssetStore(tmp),
      profileUid: kProfile,
      locationDir: 'dir-from-identity',
      folder: kSrs4Root,
    );
    await loc.put('meta.json', Uint8List.fromList(utf8.encode('{}')));
    expect(
      File(
        p.join(
          tmp.path,
          kSrsSync2Namespace,
          'dir-from-identity',
          kSrs4Root,
          'meta.json',
        ),
      ).existsSync(),
      isTrue,
    );
    expect(
      Directory(p.join(tmp.path, kSrsSync2Namespace, kProfile)).existsSync(),
      isFalse,
    );
  });

  test('存量集合（旧根已有协议 3 的 meta）：媒体留在 v3，旧 meta 改写成围栏', () async {
    final SrsFolderLocation loc = folder();
    final SrsDbStore a = await device('a');
    await addNote(a, '猫');
    final String dir = await srsFolderLocationDir(a);
    final Object? collection = (await a.sync2Command(<String, Object?>{
      'op': 'identity',
      'now': t,
    })).map['collection'];
    final Directory old = srsFolderCollectionRoot(loc, dir)
      ..createSync(recursive: true);
    File(p.join(old.path, 'meta.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'v': 3,
        'minReader': 3,
        'collection': collection,
      }),
    );
    final SrsFolderSyncReport r = await run(loc, a);
    expect(r.ops?.error, isNull);
    expect(r.ops?.mediaRoot, kSrsSync2Folder);
    expect(readJson(srsFolderNewRoot(loc, dir), 'meta.json')['media'], 'v3');
    expect(readJson(old, 'meta.json')['moved'], kSrs4Root);
  });
}
