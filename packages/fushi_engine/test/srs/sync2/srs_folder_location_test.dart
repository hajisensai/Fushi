// 用户自己加的「文件夹」存储位置（sync2/srs_folder_location.dart，docs/specs/2026-10-25-srs-sync-v2-design.md
// §6.5、§10.3）：两台设备经同一个文件夹（U 盘 / NAS / Syncthing 目录）收敛；归档用途只写不删——不清旧 head、
// 不清过期媒体；文件夹不在时明确报错；一个用途都没勾时什么也不做。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_folder_location.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/srs_fake_engine.dart';
import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000f3';
const int kDay = 24 * 60 * 60 * 1000;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  int t = DateTime.utc(2026, 10, 25, 9).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 25, 9).millisecondsSinceEpoch;
    tmp = Directory.systemTemp.createTempSync('srs_folder_loc_');
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
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(wallClockMs: () => t, bootId: 'boot-$id'),
    );
  }

  Directory dir(String name) =>
      Directory(p.join(tmp.path, name))..createSync(recursive: true);

  String expr(SrsDbStore s) => srsLapisFieldId(s.profileUid, 'Expression');

  Future<String> addNote(SrsDbStore s, String text, {String picture = ''}) {
    t += 1000;
    return s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        expr(s): text,
        srsLapisFieldId(s.profileUid, 'Picture'): picture,
      },
    );
  }

  Future<SrsFolderSyncReport> run(
    SrsFolderLocation loc,
    SrsDbStore s, {
    Directory? media,
  }) {
    t += 1000;
    return srsSyncFolderLocation(location: loc, store: s, mediaRoot: media);
  }

  /// 本机在位置上的 head 文件数。
  Future<int> headsOf(SrsFolderLocation loc, SrsDbStore s) async {
    final SrsLocationStore root = SrsDirectoryLocationStore(
      srsFolderCollectionRoot(loc, kProfile),
    );
    final String self = (await s.sync2Status())['device']! as String;
    return <SrsLocationEntry>[
      for (final SrsLocationEntry e in await root.list('devices/$self'))
        if (e.name.startsWith('head-')) e,
    ].length;
  }

  test('两台设备经同一个文件夹收敛：操作双向、媒体镜像；目录布局与云盘的集合根相同', () async {
    final SrsFolderLocation loc = SrsFolderLocation(
      id: 'usb',
      path: dir('usb').path,
    );
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final Directory mediaA = dir('media_a');
    final Directory mediaB = dir('media_b');
    File(p.join(mediaA.path, 'cat.png')).writeAsBytesSync(<int>[1, 2]);
    final String fromA = await addNote(a, '猫', picture: '<img src="cat.png">');
    final String fromB = await addNote(b, '犬');
    for (int i = 0; i < 2; i++) {
      await run(loc, a, media: mediaA);
      await run(loc, b, media: mediaB);
    }
    expect((await b.note(fromA))!.field(expr(b)), '猫');
    expect((await a.note(fromB))!.field(expr(a)), '犬');
    expect(File(p.join(mediaB.path, 'cat.png')).readAsBytesSync(), <int>[1, 2]);
    expect(
      (await a.sync2Digest())['digest'],
      (await b.sync2Digest())['digest'],
    );
    final Directory root = srsFolderCollectionRoot(loc, kProfile);
    expect(
      root.path,
      p.join(loc.path, kSrsSync2Namespace, kProfile, kSrsSync2Folder),
    );
    expect(File(p.join(root.path, 'meta.json')).existsSync(), isTrue);
    expect(
      File(
        p.join(
          root.path,
          srsMediaContentPath(kSrsMediaFolder, srsMediaSha256(<int>[1, 2])),
        ),
      ).existsSync(),
      isTrue,
    );
    // 本机按 `folder:<id>` 记传到了哪。
    final List<Object?> locs = (await a.sync2Status())['locations']! as List;
    expect(<Object?>[
      for (final Object? l in locs) (l! as Map)['location'],
    ], contains(loc.locationId));
  });

  test('同步用途清两代以前的旧 head；归档用途一个旧 head 也不删', () async {
    final SrsDbStore a = await device('a');
    await addNote(a, '雪');
    final SrsFolderLocation sync = SrsFolderLocation(
      id: 'sync',
      path: dir('sync').path,
      media: false,
    );
    final SrsFolderLocation archive = SrsFolderLocation(
      id: 'arch',
      path: dir('arch').path,
      sync: false,
      media: false,
      archive: true,
    );
    // head 的代号是本机全局递增的（不分位置），所以两个位置分开各跑 6 轮。每轮先有新操作：内容没变的一轮
    // 不写 head（空 head 会唤醒连着同一位置的全部设备，见 srs_sync2_round.dart）。
    for (int i = 0; i < 6; i++) {
      await addNote(a, '雨$i');
      await run(sync, a);
    }
    for (int i = 0; i < 6; i++) {
      await addNote(a, '風$i');
      await run(archive, a);
    }
    expect(await headsOf(sync, a), 3, reason: '本代 + 前两代');
    expect(await headsOf(archive, a), 6, reason: '归档永不删除');
  });

  test('归档用途不删过期媒体；同样的状态下媒体用途会清', () async {
    final SrsDbStore a = await device('a');
    final Directory mediaA = dir('media_a');
    File(p.join(mediaA.path, 'only.png')).writeAsBytesSync(<int>[1]);
    final String gone = await addNote(a, '雪', picture: '<img src="only.png">');
    final SrsFolderLocation archive = SrsFolderLocation(
      id: 'arch',
      path: dir('arch').path,
      sync: false,
      media: false,
      archive: true,
    );
    final SrsFolderLocation media = SrsFolderLocation(
      id: 'media',
      path: dir('media').path,
      sync: false,
    );
    expect((await run(archive, a, media: mediaA)).media!.uploaded, 1);
    expect((await run(media, a, media: mediaA)).media!.uploaded, 1);
    t += 1000;
    await a.deleteNote(gone);
    t += kSrsMediaRetention.inMilliseconds + kDay;

    final SrsFolderSyncReport ra = await run(archive, a, media: mediaA);
    expect(ra.media!.deleted, 0);
    expect(
      File(
        p.join(
          srsFolderCollectionRoot(archive, kProfile).path,
          srsMediaContentPath(kSrsMediaFolder, srsMediaSha256(<int>[1])),
        ),
      ).existsSync(),
      isTrue,
    );
    final SrsFolderSyncReport rm = await run(media, a, media: mediaA);
    expect(rm.ops, isNull, reason: '只勾了媒体：不跑操作同步');
    expect(rm.media!.deleted, 1);
  });

  test('文件夹不在（U 盘没插）：明确报错；一个用途都没勾：什么也不做', () async {
    final SrsDbStore a = await device('a');
    final SrsFolderLocation gone = SrsFolderLocation(
      id: 'usb',
      path: p.join(tmp.path, 'not-mounted'),
    );
    await expectLater(
      srsSyncFolderLocation(location: gone, store: a),
      throwsA(isA<FileSystemException>()),
    );
    expect(Directory(gone.path).existsSync(), isFalse, reason: '不替用户建目录');

    final SrsFolderLocation idle = gone.copyWith(sync: false, media: false);
    expect(idle.idle, isTrue);
    final SrsFolderSyncReport r = await srsSyncFolderLocation(
      location: idle,
      store: a,
    );
    expect(r.ops, isNull);
    expect(r.media, isNull);

    // 配置的 JSON 往返。
    final SrsFolderLocation back = SrsFolderLocation.fromJson(
      SrsFolderLocation(
        id: 'x',
        path: '/mnt/nas',
        media: false,
        archive: true,
      ).toJson(),
    );
    expect(back.id, 'x');
    expect(back.path, '/mnt/nas');
    expect(back.sync, isTrue);
    expect(back.media, isFalse);
    expect(back.archive, isTrue);
    expect(back.locationId, 'folder:x');
  });

  /// 位置下全部文件 → 字节（比对「一个字节都没动」）。
  Map<String, List<int>> snapshot(Directory d) => <String, List<int>>{
    for (final File f in d.listSync(recursive: true).whereType<File>())
      p.relative(f.path, from: d.path): f.readAsBytesSync(),
  };

  test('最低读者版本门控：位置来自更新版本时，同步 / 归档 / 只做媒体三种用途都整体停下，一个文件都不写不删', () async {
    for (final (String tag, bool sync, bool media, bool archive)
        in <(String, bool, bool, bool)>[
          ('sync+media', true, true, false),
          ('archive', false, false, true),
          ('media-only', false, true, false),
        ]) {
      final SrsFolderLocation loc = SrsFolderLocation(
        id: 'new-$tag',
        path: dir('new-$tag').path,
        sync: sync,
        media: media,
        archive: archive,
      );
      final SrsDbStore a = await device('a-$tag');
      final Directory mediaA = dir('media-$tag');
      File(p.join(mediaA.path, 'cat.png')).writeAsBytesSync(<int>[1, 2]);
      await addNote(a, '猫', picture: '<img src="cat.png">');
      final Directory root = srsFolderCollectionRoot(loc, kProfile)
        ..createSync(recursive: true);
      File(p.join(root.path, 'meta.json')).writeAsStringSync(
        '{"v":${kSrsSync2Protocol + 1},"minReader":${kSrsSync2Protocol + 1}}',
      );
      // 更新版本写的、本机读不懂的文件：媒体按名字目录里一个会被旧逻辑「过期清掉 / 覆盖」的名字。
      File(p.join(root.path, kSrsMediaFolder, 'cat.png'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(<int>[9, 9, 9]);
      final Map<String, List<int>> before = snapshot(root);
      final SrsFolderSyncReport r = await run(loc, a, media: mediaA);
      expect(r.crypto?.needsUpgrade, isTrue, reason: tag);
      expect(r.media, isNull, reason: '$tag: media must not run');
      expect(
        snapshot(root),
        before,
        reason: '$tag: nothing written or deleted',
      );
    }
  });

  test('最低读者版本门控：旧版本写的 meta（minReader 不高于本机 / 缺省）照常读写', () async {
    for (final String meta in <String>['{"v":1,"minReader":1}', '{"v":1}']) {
      final SrsFolderLocation loc = SrsFolderLocation(
        id: 'old-${meta.length}',
        path: dir('old-${meta.length}').path,
      );
      final SrsDbStore a = await device('o-${meta.length}');
      await addNote(a, '犬');
      final Directory root = srsFolderCollectionRoot(loc, kProfile)
        ..createSync(recursive: true);
      File(p.join(root.path, 'meta.json')).writeAsStringSync(meta);
      final SrsFolderSyncReport r = await run(loc, a);
      expect(r.crypto?.needsUpgrade, isFalse, reason: meta);
      expect(r.crypto?.error, isNull, reason: meta);
      expect(await headsOf(loc, a), 1, reason: meta);
    }
  });
}
