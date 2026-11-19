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
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart'
    show kSrsSync2MetaUnavailable;
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show SrsAssetLocationStore, kSrsSync2Folder, kSrsSync2Namespace;
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/srs/sync2/srs_sync4_steps.dart';
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

  test(
    '移除位置（location_forget，G8-7c）：内核忘掉它的同步状态，位置上的文件与本机卡片不动；再同步一轮照常',
    () async {
      final SrsFolderLocation loc = folder();
      final SrsDbStore a = await device('a');
      await addNote(a, '猫');
      expect((await run(loc, a)).ops?.error, isNull);
      Future<List<Object?>> locations() async =>
          ((await a.sync2Command(<String, Object?>{
                'op': 'status',
              })).map['locations']
              as List?) ??
          const <Object?>[];
      bool listed(List<Object?> ls) =>
          ls.any((Object? l) => (l! as Map)['location'] == loc.locationId);
      expect(listed(await locations()), isTrue);
      final List<String> before = <String>[
        for (final FileSystemEntity f in Directory(
          loc.path,
        ).listSync(recursive: true))
          if (f is File) f.path,
      ]..sort();
      final Map<String, Object?> r = await srsSync4ForgetLocation(
        a,
        loc.locationId,
      );
      expect(r['forgotten'], greaterThan(0));
      expect(listed(await locations()), isFalse);
      // 位置上的文件一个不碰；本机卡片照旧。
      expect(
        <String>[
          for (final FileSystemEntity f in Directory(
            loc.path,
          ).listSync(recursive: true))
            if (f is File) f.path,
        ]..sort(),
        before,
      );
      expect(
        (await a.sync2Command(<String, Object?>{
          'op': 'status',
        })).map['devices'],
        isNotEmpty,
      );
      // 幂等；把位置加回来照常同步。
      expect((await srsSync4ForgetLocation(a, loc.locationId))['forgotten'], 0);
      expect((await run(loc, a)).ops?.error, isNull);
      expect(listed(await locations()), isTrue);
    },
  );

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

  // 审计 R10：新根 `v4/meta.json` 一时读不到（最终一致的网盘 / 被删）而旧根围栏读得到时，以前把围栏当 meta 交给握手、
  // 内核按围栏重建新根 meta——新集合的媒体根被从 v4 改成 v3（围栏不带 `media`）。现在报 meta 读不到、什么都不写。
  test('新集合的新根 meta 读不到：不按围栏重写、不算一轮；放回后照常、媒体根仍是 v4', () async {
    final SrsFolderLocation loc = folder();
    final SrsDbStore a = await device('a');
    await addNote(a, '猫');
    expect((await run(loc, a)).ops?.error, isNull);
    final String dir = await srsFolderLocationDir(a);
    final File meta4 = File(
      p.join(srsFolderNewRoot(loc, dir).path, 'meta.json'),
    );
    final File fence = File(
      p.join(srsFolderCollectionRoot(loc, dir).path, 'meta.json'),
    );
    final List<int> original = meta4.readAsBytesSync();
    final List<int> fenceBytes = fence.readAsBytesSync();
    meta4.deleteSync();
    await addNote(a, '犬');
    final SrsFolderSyncReport r = await run(loc, a);
    expect(r.ops?.error, kSrsSync2MetaUnavailable);
    expect(r.ops?.uploaded ?? 0, 0);
    expect(meta4.existsSync(), isFalse, reason: '新根 meta 不重写');
    expect(fence.readAsBytesSync(), fenceBytes, reason: '围栏不动');
    // 放回后照常：媒体根仍是 v4，新根 meta 逐字节没变。
    meta4.writeAsBytesSync(original);
    final SrsFolderSyncReport back = await run(loc, a);
    expect(back.ops?.error, isNull);
    expect(back.ops?.mediaRoot, kSrs4Root);
    expect(meta4.readAsBytesSync(), original);
    expect(
      readJson(srsFolderNewRoot(loc, dir), 'meta.json')['media'],
      kSrs4Root,
    );
  });

  // 复核：没有围栏这条证据时，新根立过的证据是新根下的数据 / loc 标记。新根 meta 与旧根围栏都读不到时不能按「新集合」
  // 重建（加密位置会丢 `kdf`、媒体根推不出来）；只剩 loc 标记（设备目录也列不到）时同样不重建。
  test('新根 meta 与围栏都读不到、新根下还有数据或 loc 标记：不重建；放回后照常', () async {
    final SrsFolderLocation loc = folder();
    final SrsDbStore a = await device('a');
    await addNote(a, '猫');
    expect((await run(loc, a)).ops?.error, isNull);
    final String dir = await srsFolderLocationDir(a);
    final Directory v4 = srsFolderNewRoot(loc, dir);
    final File meta4 = File(p.join(v4.path, 'meta.json'));
    final File fence = File(
      p.join(srsFolderCollectionRoot(loc, dir).path, 'meta.json'),
    );
    final List<int> original = meta4.readAsBytesSync();
    final List<int> fenceBytes = fence.readAsBytesSync();
    meta4.deleteSync();
    fence.deleteSync();
    await addNote(a, '犬');
    SrsFolderSyncReport r = await run(loc, a);
    expect(r.ops?.error, kSrsSync2MetaUnavailable);
    expect(meta4.existsSync(), isFalse, reason: '新根 meta 不重建');
    expect(fence.existsSync(), isFalse, reason: '围栏也不在这一轮补');
    // 设备目录也列不到、只剩 loc 标记：照样认得新根立过。
    final Directory devices = Directory(p.join(v4.path, 'devices'));
    final Directory parked = Directory(p.join(tmp.path, 'parked_devices'));
    devices.renameSync(parked.path);
    expect(Directory(p.join(v4.path, 'loc')).listSync(), isNotEmpty);
    r = await run(loc, a);
    expect(r.ops?.error, kSrsSync2MetaUnavailable);
    expect(meta4.existsSync(), isFalse);
    expect(devices.existsSync(), isFalse, reason: '这一轮什么都没传');
    // 放回后照常：媒体根仍是 v4。
    parked.renameSync(devices.path);
    meta4.writeAsBytesSync(original);
    fence.writeAsBytesSync(fenceBytes);
    final SrsFolderSyncReport back = await run(loc, a);
    expect(back.ops?.error, isNull);
    expect(back.ops?.mediaRoot, kSrs4Root);
    expect(meta4.readAsBytesSync(), original);
  });

  // 复核：新根 `v4/` 整个被删、只剩围栏时，等下去不会自己好——报专门的码（界面给出恢复办法），不重建；照提示删掉
  // 旧根的 `meta.json` 后，下一轮按新集合重建，媒体根是 v4，本机的数据重新传上去。
  test('新根整个被删、只剩围栏：报新根不见了、不重建；删掉围栏后按新集合重建', () async {
    final SrsFolderLocation loc = folder();
    final SrsDbStore a = await device('a');
    await addNote(a, '猫');
    expect((await run(loc, a)).ops?.error, isNull);
    final String dir = await srsFolderLocationDir(a);
    final Directory v4 = srsFolderNewRoot(loc, dir);
    final File fence = File(
      p.join(srsFolderCollectionRoot(loc, dir).path, 'meta.json'),
    );
    final List<int> fenceBytes = fence.readAsBytesSync();
    v4.deleteSync(recursive: true);
    final SrsFolderSyncReport r = await run(loc, a);
    expect(r.ops?.error, kSrsLocationNewRootMissing);
    // 报告带着这一轮的集合目录名：界面据此写出要删的围栏的真实路径（第六波，以前写成 `<集合>`）。
    expect(r.ops?.locationDir, dir);
    expect(
      p.join(
        loc.path,
        kSrsSync2Namespace,
        r.ops!.locationDir!,
        kSrsSync2Folder,
        'meta.json',
      ),
      fence.path,
    );
    expect(v4.existsSync(), isFalse, reason: '不重建新根');
    expect(fence.readAsBytesSync(), fenceBytes, reason: '围栏不动');
    // 用户按提示删掉围栏：按新集合重建。
    fence.deleteSync();
    final SrsFolderSyncReport rebuilt = await run(loc, a);
    expect(rebuilt.ops?.error, isNull);
    expect(rebuilt.ops?.mediaRoot, kSrs4Root);
    expect(readJson(v4, 'meta.json')['media'], kSrs4Root);
    expect(rebuilt.ops?.uploaded ?? 0, greaterThan(0), reason: '本机的数据重新传上去');
    expect(
      srsIsOldRootFence(Uint8List.fromList(fence.readAsBytesSync())),
      isTrue,
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
