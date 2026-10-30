// 2026-10-30 同步 v2 格式断代（协议 2，sync2/srs_location_migration.dart）：
// - 旧版本（冻结在 v1_client/ 的 develop@d407ae22ca 代码，真实跑一轮）碰到新版本用过的位置：停下、报需要升级，
//   位置目录逐字节不变——明文 / 加密文件夹位置、只做媒体的文件夹位置、云盘 / 互联通道（SyncAssetStore）；
// - 新版本把旧版本写的 v1 位置一次性迁进新根：段 / 媒体 / 绑定都在，旧格式文件删掉（归档位置只复制不删）；
// - 迁移中断后接着做、两台新版本设备同时迁移同一个位置，都不丢数据、不互删。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_folder_location.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_migration.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/srs_fake_engine.dart';
import '../support/srs_test_storage.dart';
import 'v1_client/srs_folder_location.dart' as v1;
import 'v1_client/srs_location_crypto.dart' as v1;
import 'v1_client/srs_location_store.dart' as v1;
import 'v1_client/srs_sync2_round.dart' as v1;

const String kProfile = '01928c3e-0000-7000-8000-0000000000b7';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  int t = DateTime.utc(2026, 10, 30, 9).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 30, 9).millisecondsSinceEpoch;
    tmp = Directory.systemTemp.createTempSync('srs_break_');
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
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        monotonicMs: () => t,
        bootId: 'boot-$id',
      ),
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

  /// 目录树的逐字节快照：相对路径 → 「d」（目录）或文件内容的 sha256。
  Map<String, String> snapshot(Directory root) {
    final Map<String, String> out = <String, String>{};
    for (final FileSystemEntity e in root.listSync(
      recursive: true,
      followLinks: false,
    )) {
      final String rel = p
          .relative(e.path, from: root.path)
          .replaceAll(r'\', '/');
      out[rel] = e is Directory
          ? 'd'
          : sha256.convert(File(e.path).readAsBytesSync()).toString();
    }
    return out;
  }

  Future<SrsFolderSyncReport> runNew(
    SrsFolderLocation loc,
    SrsDbStore s, {
    Directory? media,
    SrsLocationKey? key,
    SrsLocationMigrationMemo? memo,
  }) {
    t += 1000;
    return srsSyncFolderLocation(
      location: loc,
      store: s,
      mediaRoot: media,
      key: key,
      migrationMemo: memo,
    );
  }

  /// 旧版本跑一轮文件夹位置。旧版本的媒体对账在需要升级时照样跑，碰到 `media` 普通文件会在建目录那一步抛
  /// [FileSystemException]（旧 UI 显示「位置不可用」）——两种结局都算停下，交回报告或那个异常。
  Future<Object> runOld(
    SrsFolderLocation loc,
    SrsDbStore s, {
    Directory? media,
    v1.SrsLocationKey? key,
  }) async {
    t += 1000;
    try {
      return await v1.srsSyncFolderLocation(
        location: v1.SrsFolderLocation.fromJson(loc.toJson()),
        store: s,
        mediaRoot: media,
        key: key,
      );
    } on FileSystemException catch (e) {
      return e;
    }
  }

  bool oldStopped(Object r) =>
      r is FileSystemException ||
      (r is v1.SrsFolderSyncReport && (r.crypto?.needsUpgrade ?? false));

  File mediaFile(Directory root, String name, List<int> bytes) =>
      File(p.join(root.path, name))..writeAsBytesSync(bytes);

  Directory v3Root(SrsFolderLocation loc) =>
      srsFolderCollectionRoot(loc, kProfile);
  Directory v2Root(SrsFolderLocation loc) =>
      srsFolderV1CollectionRoot(loc, kProfile);

  group('old clients stop on a new-format location without changing a byte', () {
    test('plaintext folder location (sync + media)', () async {
      final SrsFolderLocation loc = SrsFolderLocation(
        id: 'usb',
        path: dir('usb').path,
      );
      final SrsDbStore a = await device('a');
      final Directory mediaA = dir('media_a');
      mediaFile(mediaA, 'cat.png', <int>[1, 2]);
      await addNote(a, '猫', picture: '<img src="cat.png">');
      final SrsFolderSyncReport ra = await runNew(loc, a, media: mediaA);
      expect(ra.ops?.error, isNull);
      expect(
        File(p.join(v2Root(loc).path, kSrsMediaFolder)).existsSync(),
        isTrue,
        reason: 'the v1 root carries the media sentinel file',
      );
      final Map<String, String> before = snapshot(Directory(loc.path));

      final SrsDbStore old = await device('old');
      final Directory mediaOld = dir('media_old');
      mediaFile(mediaOld, 'dog.png', <int>[7, 7, 7]);
      await addNote(old, '犬', picture: '<img src="dog.png">');
      for (int i = 0; i < 2; i++) {
        expect(oldStopped(await runOld(loc, old, media: mediaOld)), isTrue);
      }
      expect(snapshot(Directory(loc.path)), before);
      // 旧版本只读文件夹（新根与旧根都没碰）：它本地照旧没收到任何东西。
      expect(await old.sync2Digest(), isNot(await a.sync2Digest()));
    });

    test(
      'encrypted folder location: no plaintext lands, nothing changes',
      () async {
        final SrsFolderLocation loc = SrsFolderLocation(
          id: 'nas',
          path: dir('nas').path,
        );
        final SrsDbStore a = await device('a');
        final SrsLocationKey ka = await srsDeriveLocationKey(
          a,
          'pass',
          pendingEnable: true,
        );
        final Directory mediaA = dir('media_a');
        mediaFile(mediaA, 'cat.png', <int>[1, 2]);
        await addNote(a, '猫', picture: '<img src="cat.png">');
        final SrsFolderSyncReport ra = await runNew(
          loc,
          a,
          media: mediaA,
          key: ka,
        );
        expect(ra.ops?.error, isNull);
        expect(ra.ops?.encryptionEnabled, isTrue);
        final Map<String, String> before = snapshot(Directory(loc.path));

        final SrsDbStore old = await device('old');
        final Directory mediaOld = dir('media_old');
        mediaFile(mediaOld, 'dog.png', <int>[7, 7, 7]);
        await addNote(old, '犬', picture: '<img src="dog.png">');
        // 旧版本拿着正确口令、不拿口令，都停下。
        final v1.SrsLocationKey oldKey = v1.SrsLocationKey(
          keyHex: ka.keyHex,
          kdf: v1.SrsKdf.fromJson(ka.kdf.toJson()),
        );
        expect(
          oldStopped(await runOld(loc, old, media: mediaOld, key: oldKey)),
          isTrue,
        );
        expect(oldStopped(await runOld(loc, old, media: mediaOld)), isTrue);
        expect(snapshot(Directory(loc.path)), before);
      },
    );

    test('media-only and archive folder locations', () async {
      for (final SrsFolderLocation loc in <SrsFolderLocation>[
        SrsFolderLocation(id: 'm', path: dir('m').path, sync: false),
        SrsFolderLocation(id: 'ar', path: dir('ar').path, archive: true),
      ]) {
        final SrsDbStore a = await device('a-${loc.id}');
        final Directory mediaA = dir('media_a_${loc.id}');
        mediaFile(mediaA, 'cat.png', <int>[1, 2]);
        await addNote(a, '猫', picture: '<img src="cat.png">');
        await runNew(loc, a, media: mediaA);
        final Map<String, String> before = snapshot(Directory(loc.path));
        final SrsDbStore old = await device('old-${loc.id}');
        final Directory mediaOld = dir('media_old_${loc.id}');
        mediaFile(mediaOld, 'dog.png', <int>[7]);
        await addNote(old, '犬', picture: '<img src="dog.png">');
        expect(
          oldStopped(await runOld(loc, old, media: mediaOld)),
          isTrue,
          reason: loc.id,
        );
        expect(snapshot(Directory(loc.path)), before, reason: loc.id);
      }
    });

    test(
      'a fresh location the new version only touched once is fenced too',
      () async {
        // 新版本第一次碰到一个空位置也立围栏：旧版本不能在旧根上新建一个 v1 集合。
        final SrsFolderLocation loc = SrsFolderLocation(
          id: 'fresh',
          path: dir('fresh').path,
          sync: false,
        );
        final SrsDbStore a = await device('a');
        await runNew(loc, a, media: dir('media_a'));
        final Map<String, String> before = snapshot(Directory(loc.path));
        expect(before.keys, contains('fushi-srs/$kProfile/v2/meta.json'));
        final SrsDbStore old = await device('old');
        expect(oldStopped(await runOld(loc, old, media: dir('mo'))), isTrue);
        expect(snapshot(Directory(loc.path)), before);
      },
    );

    test('cloud / interconnect channel (SyncAssetStore)', () async {
      final Directory backendRoot = dir('cloud');
      final LocalDirectoryAssetStore backend = LocalDirectoryAssetStore(
        backendRoot,
      );
      final SrsDbStore a = await device('a');
      await addNote(a, '猫');
      final SrsLocationStore v3 = SrsAssetLocationStore(
        store: backend,
        profileUid: kProfile,
      );
      final SrsLocationPrepared prepared = await srsPrepareLocation(
        host: a,
        v1: SrsAssetLocationStore(
          store: backend,
          profileUid: kProfile,
          folder: kSrsSync2V1Folder,
        ),
        current: v3,
        locationId: 'cloud',
        key: null,
        nowMs: () => t,
        recordPresence: true,
        writers: SrsAssetV1Writers(backend, kProfile),
      );
      expect(prepared.error, isNull);
      final SrsSync2Report ra = await srsSync2Round(
        host: a,
        location: v3,
        locationId: 'cloud',
        nowMs: () => t,
      );
      expect(ra.error, isNull);
      final Map<String, String> before = snapshot(backendRoot);

      final SrsDbStore old = await device('old');
      final Directory mediaOld = dir('media_old');
      mediaFile(mediaOld, 'dog.png', <int>[7]);
      await addNote(old, '犬', picture: '<img src="dog.png">');
      final v1.SrsSync2Report r = await v1.srsSync2Round(
        host: old,
        location: v1.SrsAssetLocationStore(
          store: backend,
          profileUid: kProfile,
        ),
        locationId: 'cloud',
        nowMs: () => t,
      );
      // 旧调度器（d407ae22ca srs_sync_scheduler.dart:155 / :778）把 needsUpgrade 记成错误，有错误就不跑媒体、
      // 不发布 profile 说明——通道上整轮停在握手。
      expect(r.needsUpgrade, isTrue);
      expect(snapshot(backendRoot), before);
    });
  });

  group('v1 locations migrate once into the protocol 2 root', () {
    /// 旧版本（真实 v1 代码）写出一个 v1 文件夹位置：两条笔记、一个按名字存的明文媒体文件。
    Future<({SrsFolderLocation loc, SrsDbStore old, String note})> v1Location(
      String id, {
      bool archive = false,
    }) async {
      final SrsFolderLocation loc = SrsFolderLocation(
        id: id,
        path: dir(id).path,
        archive: archive,
      );
      final SrsDbStore old = await device('old-$id');
      final Directory mediaOld = dir('media_old_$id');
      mediaFile(mediaOld, 'cat.png', <int>[1, 2, 3]);
      final String note = await addNote(
        old,
        '猫',
        picture: '<img src="cat.png">',
      );
      await addNote(old, '鳥');
      final Object r = await runOld(loc, old, media: mediaOld);
      expect(r, isA<v1.SrsFolderSyncReport>());
      expect((r as v1.SrsFolderSyncReport).ops?.error, isNull);
      final Map<String, String> s = snapshot(v2Root(loc));
      expect(s.keys, contains('media/cat.png'));
      expect(s.keys.where((String k) => k.startsWith('devices/')), isNotEmpty);
      return (loc: loc, old: old, note: note);
    }

    Future<void> expectMigrated(
      SrsFolderLocation loc,
      SrsDbStore s,
      Directory media,
      String note,
    ) async {
      expect((await s.note(note))!.field(expr(s)), '猫');
      expect(File(p.join(media.path, 'cat.png')).readAsBytesSync(), <int>[
        1,
        2,
        3,
      ]);
      final Map<String, Object?> meta =
          jsonDecode(
                File(p.join(v3Root(loc).path, 'meta.json')).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(meta['minReader'], kSrsSync2MinReader);
      expect(meta['v'], kSrsSync2Protocol);
      expect(
        File(
          p.join(
            v3Root(loc).path,
            srsMediaContentPath(
              kSrsMediaFolder,
              srsMediaSha256(<int>[1, 2, 3]),
            ),
          ),
        ).existsSync(),
        isTrue,
      );
    }

    test('a new device migrates, the old device is then fenced out', () async {
      final ({SrsFolderLocation loc, SrsDbStore old, String note}) v =
          await v1Location('mig');
      final Map<String, String> v1Segments = <String, String>{
        for (final MapEntry<String, String> e in snapshot(
          v2Root(v.loc),
        ).entries)
          if (e.key.startsWith('devices/') && e.value != 'd') e.key: e.value,
      };
      final SrsDbStore b = await device('b');
      final Directory mediaB = dir('media_b');
      final SrsFolderSyncReport rb = await runNew(v.loc, b, media: mediaB);
      expect(rb.prepared?.migrated, isTrue);
      expect(rb.ops?.error, isNull);
      // 媒体那一轮在同一轮里把迁过来的内容拉下来（绑定已补上）。
      await runNew(v.loc, b, media: mediaB);
      await expectMigrated(v.loc, b, mediaB, v.note);
      // 段 / head 原样搬进新根。
      final Map<String, String> v3 = snapshot(v3Root(v.loc));
      for (final MapEntry<String, String> e in v1Segments.entries) {
        expect(v3[e.key], e.value, reason: e.key);
      }
      // 旧根只剩围栏。
      final Map<String, String> left = snapshot(v2Root(v.loc));
      expect(left.keys.toSet(), <String>{'meta.json', kSrsMediaFolder});
      final Map<String, Object?> fence =
          jsonDecode(
                File(
                  p.join(v2Root(v.loc).path, 'meta.json'),
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(fence['minReader'], 2);
      expect(fence[kSrsV1MovedToKey], kSrsSync2Folder);

      final Map<String, String> before = snapshot(Directory(v.loc.path));
      expect(oldStopped(await runOld(v.loc, v.old, media: dir('mo2'))), isTrue);
      expect(snapshot(Directory(v.loc.path)), before);

      // 旧设备升级成新版本：照常在新根上同步，看得到 b 写的。
      final String fromB = await addNote(b, '犬');
      await runNew(v.loc, b, media: mediaB);
      await runNew(v.loc, v.old, media: dir('mo3'));
      expect((await v.old.note(fromB))!.field(expr(v.old)), '犬');
    });

    test('an interrupted migration resumes to the same result', () async {
      final ({SrsFolderLocation loc, SrsDbStore old, String note}) v =
          await v1Location('resume');
      final SrsDbStore b = await device('b');
      final Directory mediaB = dir('media_b');
      final Directory v1Dir = v2Root(v.loc);
      // 依次在第 1、2、3……次写新根时断掉，每次断完都重新来，直到一次跑通。
      for (int failAt = 1; ; failAt++) {
        final _FailingStore current = _FailingStore(
          SrsDirectoryLocationStore(v3Root(v.loc)),
          failAt,
        );
        try {
          t += 1000;
          final SrsLocationPrepared r = await srsPrepareLocation(
            host: b,
            v1: SrsDirectoryLocationStore(v1Dir),
            current: current,
            locationId: v.loc.locationId,
            key: null,
            nowMs: () => t,
            v1PlainMediaFolder: kSrsV1FolderMediaMoved,
            fenceFolderMedia: () => srsFenceV1FolderMedia(v1Dir),
            removeEmptyDirs: () => srsRemoveEmptyV1FolderDirs(v1Dir),
          );
          expect(r.error, isNull);
          break;
        } on _Interrupted {
          // 旧版本在任何一个中断点上都被挡在外面。
          final Map<String, String> before = snapshot(Directory(v.loc.path));
          expect(
            oldStopped(await runOld(v.loc, v.old, media: dir('mo$failAt'))),
            isTrue,
          );
          expect(snapshot(Directory(v.loc.path)), before);
        }
        expect(failAt, lessThan(50));
      }
      await runNew(v.loc, b, media: mediaB);
      await runNew(v.loc, b, media: mediaB);
      await expectMigrated(v.loc, b, mediaB, v.note);
      expect(snapshot(v1Dir).keys.toSet(), <String>{
        'meta.json',
        kSrsMediaFolder,
      });
    });

    test('two new devices migrating the same location at once', () async {
      final ({SrsFolderLocation loc, SrsDbStore old, String note}) v =
          await v1Location('race');
      final SrsDbStore b = await device('b');
      final SrsDbStore c = await device('c');
      final Directory mediaB = dir('media_b');
      final Directory mediaC = dir('media_c');
      final String fromB = await addNote(b, '犬');
      final String fromC = await addNote(c, '魚');
      t += 1000;
      final List<SrsFolderSyncReport> rs =
          await Future.wait(<Future<SrsFolderSyncReport>>[
            srsSyncFolderLocation(location: v.loc, store: b, mediaRoot: mediaB),
            srsSyncFolderLocation(location: v.loc, store: c, mediaRoot: mediaC),
          ]);
      for (final SrsFolderSyncReport r in rs) {
        expect(r.ops?.error, isNull);
      }
      for (int i = 0; i < 2; i++) {
        await runNew(v.loc, b, media: mediaB);
        await runNew(v.loc, c, media: mediaC);
      }
      await expectMigrated(v.loc, b, mediaB, v.note);
      await expectMigrated(v.loc, c, mediaC, v.note);
      expect((await b.note(fromC))!.field(expr(b)), '魚');
      expect((await c.note(fromB))!.field(expr(c)), '犬');
      expect(
        (await b.sync2Digest())['digest'],
        (await c.sync2Digest())['digest'],
      );
      expect(snapshot(v2Root(v.loc)).keys.toSet(), <String>{
        'meta.json',
        kSrsMediaFolder,
      });
    });

    test('an archive location copies but never deletes the v1 files', () async {
      final ({SrsFolderLocation loc, SrsDbStore old, String note}) v =
          await v1Location('arch', archive: true);
      final Map<String, String> v1Files = <String, String>{
        for (final MapEntry<String, String> e in snapshot(
          v2Root(v.loc),
        ).entries)
          if (e.value != 'd' && e.key != 'meta.json')
            e.key.replaceFirst(
              RegExp('^$kSrsMediaFolder/'),
              '$kSrsV1FolderMediaMoved/',
            ): e.value,
      };
      final SrsDbStore b = await device('b');
      final Directory mediaB = dir('media_b');
      await runNew(v.loc, b, media: mediaB);
      await runNew(v.loc, b, media: mediaB);
      await expectMigrated(v.loc, b, mediaB, v.note);
      final Map<String, String> left = snapshot(v2Root(v.loc));
      for (final MapEntry<String, String> e in v1Files.entries) {
        expect(left[e.key], e.value, reason: e.key);
      }
    });

    test(
      'v1 sealed media in an encrypted location is resealed by content',
      () async {
        final SrsFolderLocation loc = SrsFolderLocation(
          id: 'enc',
          path: dir('enc').path,
        );
        final SrsDbStore old = await device('old');
        // 固定密钥：下面要换进一份真实的协议 1 整份封装样本（同一把密钥封的）。
        final SrsLocationKey k = SrsLocationKey(
          keyHex: _kV1Key,
          kdf: SrsKdf.fresh(),
        );
        final Directory mediaOld = dir('media_old');
        mediaFile(mediaOld, 'cat.png', <int>[4, 5, 6]);
        final String note = await addNote(
          old,
          '猫',
          picture: '<img src="cat.png">',
        );
        // 旧版本开加密：第一轮写 kdf，第二轮按密钥封媒体。
        final v1.SrsLocationKey oldPending = v1.SrsLocationKey(
          keyHex: k.keyHex,
          kdf: v1.SrsKdf.fromJson(k.kdf.toJson()),
          pendingEnable: true,
        );
        final v1.SrsLocationKey oldKey = v1.SrsLocationKey(
          keyHex: k.keyHex,
          kdf: v1.SrsKdf.fromJson(k.kdf.toJson()),
        );
        await runOld(loc, old, media: mediaOld, key: oldPending);
        final Object r = await runOld(loc, old, media: mediaOld, key: oldKey);
        expect((r as v1.SrsFolderSyncReport).ops?.error, isNull);
        expect(
          snapshot(
            v2Root(loc),
          ).keys.where((String k) => k.startsWith('$kSrsSealedMediaFolder/')),
          isNotEmpty,
        );
        expect(snapshot(v2Root(loc)).keys, isNot(contains('media/cat.png')));
        // 冻结的旧 Dart 跑在本版本内核上，内核的 `seal` 已经是分块格式；真实的旧版本（d407ae22ca 内核
        // `CollectionKey::seal`）写的是整份封装。把按名字存的那份换成同一密钥、同一 AAD 的真实整份封装样本。
        final File byName = File(
          p.join(
            v2Root(loc).path,
            SrsMediaCipher(old, _kV1Key).folder,
            'cat.png',
          ),
        );
        expect(byName.existsSync(), isTrue);
        byName.writeAsBytesSync(_unhex(_kV1CatEnvelope));

        final SrsDbStore b = await device('b');
        final Directory mediaB = dir('media_b');
        final SrsLocationKey kb = SrsLocationKey(keyHex: k.keyHex, kdf: k.kdf);
        // 没口令：不迁移、不碰。
        final Map<String, String> before = snapshot(Directory(loc.path));
        final SrsFolderSyncReport noKey = await runNew(loc, b, media: mediaB);
        expect(noKey.ops?.error, kSrsSync2NeedsKey);
        expect(snapshot(Directory(loc.path)), before);
        final SrsFolderSyncReport rb = await runNew(
          loc,
          b,
          media: mediaB,
          key: kb,
        );
        expect(rb.prepared?.migrated, isTrue);
        expect(rb.ops?.error, isNull);
        await runNew(loc, b, media: mediaB, key: kb);
        expect((await b.note(note))!.field(expr(b)), '猫');
        expect(File(p.join(mediaB.path, 'cat.png')).readAsBytesSync(), <int>[
          4,
          5,
          6,
        ]);
        final SrsMediaCipher cipher = SrsMediaCipher(b, k.keyHex);
        final String sha = srsMediaSha256(<int>[4, 5, 6]);
        final File sealed = File(
          p.join(v3Root(loc).path, srsMediaContentPath(cipher.folder, sha)),
        );
        expect(sealed.existsSync(), isTrue);
        // 新根上没有任何明文媒体。
        expect(
          snapshot(
            v3Root(loc),
          ).keys.where((String k) => k.startsWith('$kSrsMediaFolder/')),
          isEmpty,
        );
        expect(sealed.readAsBytesSync(), isNot(<int>[4, 5, 6]));
        expect(snapshot(v2Root(loc)).keys.toSet(), <String>{
          'meta.json',
          kSrsMediaFolder,
        });
      },
    );
  });

  test('segment bodies round-trip through the level 3 encoder', () async {
    // 内核压缩改成 C zstd 3 级（解压仍是 ruzstd）：两台设备经一个位置收发几百条操作后摘要一致。
    final SrsFolderLocation loc = SrsFolderLocation(
      id: 'z',
      path: dir('z').path,
      media: false,
    );
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    for (int i = 0; i < 300; i++) {
      await addNote(a, '語$i' * 3);
    }
    await runNew(loc, a);
    await runNew(loc, b);
    expect(
      (await a.sync2Digest())['digest'],
      (await b.sync2Digest())['digest'],
    );
    int seg = 0;
    for (final FileSystemEntity f in v3Root(loc).listSync(recursive: true)) {
      if (f is File && p.basename(f.path).startsWith('seg-')) {
        seg += f.lengthSync();
      }
    }
    expect(seg, greaterThan(0));
  });
}

class _Interrupted implements Exception {}

/// 第 [failAt] 次写时抛 [_Interrupted]（模拟断网 / 杀进程），之前的写照常落盘。
class _FailingStore implements SrsLocationStore {
  _FailingStore(this.inner, this.failAt);

  final SrsLocationStore inner;
  final int failAt;
  int _writes = 0;

  void _tick() {
    if (++_writes == failAt) throw _Interrupted();
  }

  @override
  Future<List<SrsLocationEntry>> list(String dir) => inner.list(dir);

  @override
  Future<Uint8List?> get(String path) => inner.get(path);

  @override
  Future<bool> exists(String path) => inner.exists(path);

  @override
  Future<void> put(String path, Uint8List bytes) async {
    _tick();
    await inner.put(path, bytes);
  }

  @override
  Future<void> putNew(String path, Uint8List bytes) async {
    _tick();
    await inner.putNew(path, bytes);
  }

  @override
  Future<void> delete(String path) async {
    _tick();
    await inner.delete(path);
  }
}

/// 协议 1 整份封装的固定样本：密钥 0x11×32，nonce 0x22×24，AAD `fushi-srs-media:cat.png`（旧内核 `seal` 的 AAD），明文 [4, 5, 6]（`nonce || 密文+tag`，
/// 由 chacha20poly1305 0.11 的 XChaCha20Poly1305 生成，与 d407ae22ca 的 `CollectionKey::seal` 同一构造）。
const String _kV1Key =
    '1111111111111111111111111111111111111111111111111111111111111111';
const String _kV1CatEnvelope =
    '2222222222222222222222222222222222222222222222228762e122044e47b1d89c13c3d4760efc0c54e3';

Uint8List _unhex(String h) => Uint8List.fromList(<int>[
  for (int i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);
