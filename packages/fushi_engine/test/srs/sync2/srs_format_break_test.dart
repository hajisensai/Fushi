// 2026-10-30 同步 v2 格式断代（协议 2，sync2/srs_location_migration.dart）：
// - 旧版本（冻结在 v1_client/ 的 develop@d407ae22ca 代码，真实跑一轮）碰到新版本用过的位置：在写任何东西之前报错
//   停下，位置目录逐字节不变——明文 / 加密文件夹位置、只做媒体 / 归档的文件夹位置、云盘 / 互联通道；同步工具只带过来
//   一部分变化的每种中间态同样安全；
// - 新版本把旧版本写的 v1 位置一次性迁进新根：内容核对过才删旧文件，按名字的旧媒体等绑定发布后才删，归档只复制；
// - 迁移中断后接着做、两台新版本设备同时迁移同一个位置、读失败、新根上有半截副本，都不丢数据；
// - 迁移完成的判据持久在位置上：之后的进程不再拉旧段、不再重新封。
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
import 'v1_client/srs_profile_link.dart' as v1;
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

  /// 目录树的逐字节快照：相对路径 → 「d」（目录）或文件内容的 sha256。
  Map<String, String> snapshot(Directory root) {
    final Map<String, String> out = <String, String>{};
    if (!root.existsSync()) return out;
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

  Set<String> filesOf(Directory root) => <String>{
    for (final MapEntry<String, String> e in snapshot(root).entries)
      if (e.value != 'd') e.key,
  };

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

  /// 旧版本跑一轮文件夹位置；抛出的 [FileSystemException] 当结果交回。
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

  /// 旧版本在握手就报错返回（围栏 meta 解析不了）——不是 needsUpgrade：旧文件夹位置在 needsUpgrade 时仍会跑明文
  /// 媒体对账。
  bool oldStoppedAtMeta(Object r) =>
      r is v1.SrsFolderSyncReport &&
      r.crypto?.error == kSrsSync2MetaUnavailable &&
      r.media == null;

  File mediaFile(Directory root, String name, List<int> bytes) =>
      File(p.join(root.path, name))..writeAsBytesSync(bytes);

  Directory v3Root(SrsFolderLocation loc) =>
      srsFolderCollectionRoot(loc, kProfile);
  Directory v2Root(SrsFolderLocation loc) =>
      srsFolderV1CollectionRoot(loc, kProfile);

  void expectFence(Directory v2) {
    final Uint8List bytes = File(
      p.join(v2.path, 'meta.json'),
    ).readAsBytesSync();
    final Map<String, Object?>? fence = srsDecodeV1Fence(bytes);
    expect(fence, isNotNull);
    expect(fence!['minReader'], 2);
    expect(fence[kSrsV1MovedToKey], kSrsSync2Folder);
    expect(
      () => jsonDecode(utf8.decode(bytes)),
      throwsFormatException,
      reason: '旧版本的握手必须解析失败',
    );
  }

  /// 旧根上迁移之后只该剩下的：围栏与「已处理」标记。
  void expectOnlyFence(Directory v2) {
    expect(filesOf(v2).difference(<String>{kSrsV1SweepMarker}), <String>{
      'meta.json',
    });
    expectFence(v2);
  }

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
      expectFence(v2Root(loc));
      final Map<String, String> before = snapshot(Directory(loc.path));

      final SrsDbStore old = await device('old');
      final Directory mediaOld = dir('media_old');
      mediaFile(mediaOld, 'dog.png', <int>[7, 7, 7]);
      await addNote(old, '犬', picture: '<img src="dog.png">');
      for (int i = 0; i < 2; i++) {
        expect(
          oldStoppedAtMeta(await runOld(loc, old, media: mediaOld)),
          isTrue,
        );
      }
      expect(snapshot(Directory(loc.path)), before);
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
        final v1.SrsLocationKey oldKey = v1.SrsLocationKey(
          keyHex: ka.keyHex,
          kdf: v1.SrsKdf.fromJson(ka.kdf.toJson()),
        );
        expect(
          oldStoppedAtMeta(
            await runOld(loc, old, media: mediaOld, key: oldKey),
          ),
          isTrue,
        );
        expect(
          oldStoppedAtMeta(await runOld(loc, old, media: mediaOld)),
          isTrue,
        );
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
          oldStoppedAtMeta(await runOld(loc, old, media: mediaOld)),
          isTrue,
          reason: loc.id,
        );
        expect(snapshot(Directory(loc.path)), before, reason: loc.id);
      }
    });

    test(
      'a fresh location the new version only touched once is fenced too',
      () async {
        final SrsFolderLocation loc = SrsFolderLocation(
          id: 'fresh',
          path: dir('fresh').path,
          sync: false,
        );
        final SrsDbStore a = await device('a');
        await runNew(loc, a, media: dir('media_a'));
        final Map<String, String> before = snapshot(Directory(loc.path));
        expectFence(v2Root(loc));
        final SrsDbStore old = await device('old');
        expect(
          oldStoppedAtMeta(await runOld(loc, old, media: dir('mo'))),
          isTrue,
        );
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
      await addNote(old, '犬');
      final v1.SrsSync2Report r = await v1.srsSync2Round(
        host: old,
        location: v1.SrsAssetLocationStore(
          store: backend,
          profileUid: kProfile,
        ),
        locationId: 'cloud',
        nowMs: () => t,
      );
      // 旧调度器（d407ae22ca srs_sync_scheduler.dart:778）有错误就不跑媒体、不发布 profile 说明。
      expect(r.error, kSrsSync2MetaUnavailable);
      expect(snapshot(backendRoot), before);

      // 旧版 profile 关联：同一个 uid 下的 `v3` 被当成「别的写入者」→ 判为已关联、保持不动，不会走到「采用别的
      // uid → 删掉本 uid 的 v2 目录」那一支（围栏不会被旧版本删掉）。
      final List<v1.SrsRemoteProfile> remote = await v1.srsListRemoteProfiles(
        backend,
      );
      final v1.SrsProfileLinkDecision d = v1.srsDecideProfileLink(
        localUid: kProfile,
        localName: 'Default',
        deviceId: 'old',
        localHasNotes: true,
        localProfileCount: 1,
        remote: remote,
      );
      expect(d, isA<v1.SrsProfileLinkKeep>());
      expect((d as v1.SrsProfileLinkKeep).linked, isTrue);
      expect(snapshot(backendRoot), before);
    });

    test(
      'a sync tool delivering only part of the migration: every intermediate state is safe',
      () async {
        // Syncthing 等工具跨文件到达顺序不保证。迁移的变化分三类：旧根 meta 换成围栏、新根的文件、旧根文件的删除。
        // 在另一台机器上任何一个子集先到，旧版本要么照 v1 的规矩只碰旧根（加密位置不写明文）、要么在握手就停。
        final SrsFolderLocation src = SrsFolderLocation(
          id: 'st',
          path: dir('st').path,
        );
        final SrsDbStore old = await device('old');
        final SrsLocationKey k = SrsLocationKey(
          keyHex: _kV1Key,
          kdf: SrsKdf.fresh(),
        );
        final v1.SrsLocationKey oldPending = v1.SrsLocationKey(
          keyHex: k.keyHex,
          kdf: v1.SrsKdf.fromJson(k.kdf.toJson()),
          pendingEnable: true,
        );
        final v1.SrsLocationKey oldKey = v1.SrsLocationKey(
          keyHex: k.keyHex,
          kdf: v1.SrsKdf.fromJson(k.kdf.toJson()),
        );
        final Directory mediaOld = dir('media_old');
        mediaFile(mediaOld, 'cat.png', <int>[1, 2, 3]);
        await addNote(old, '猫', picture: '<img src="cat.png">');
        await runOld(src, old, media: mediaOld, key: oldPending);
        await runOld(src, old, media: mediaOld, key: oldKey);
        final Map<String, String> initial = snapshot(Directory(src.path));
        final Directory initialCopy = dir('initial');
        _copyTree(Directory(src.path), initialCopy);

        final SrsDbStore b = await device('b');
        final SrsLocationKey kb = SrsLocationKey(keyHex: k.keyHex, kdf: k.kdf);
        for (int i = 0; i < 2; i++) {
          final SrsFolderSyncReport r = await runNew(
            src,
            b,
            media: dir('media_b'),
            key: kb,
          );
          expect(r.ops?.error, isNull);
        }
        final Map<String, String> fin = snapshot(Directory(src.path));
        final String fenceRel = 'fushi-srs/$kProfile/v2/meta.json';
        final Set<String> added = <String>{
          for (final MapEntry<String, String> e in fin.entries)
            if (e.value != 'd' &&
                initial[e.key] != e.value &&
                e.key != fenceRel)
              e.key,
        };
        final Set<String> removed = <String>{
          for (final MapEntry<String, String> e in initial.entries)
            if (e.value != 'd' && !fin.containsKey(e.key)) e.key,
        };
        expect(removed, isNotEmpty);
        expect(added, isNotEmpty);

        // 每种中间态：围栏到没到 × 新根文件到没到 × 旧根删除到没到。
        int state = 0;
        for (final bool fence in <bool>[false, true]) {
          for (final bool adds in <bool>[false, true]) {
            for (final bool dels in <bool>[false, true]) {
              final Directory replica = dir('replica_${state++}');
              _copyTree(initialCopy, replica);
              void take(String rel) {
                final File to = File(p.join(replica.path, rel))
                  ..parent.createSync(recursive: true);
                File(p.join(src.path, rel)).copySync(to.path);
              }

              if (fence) take(fenceRel);
              if (adds) added.forEach(take);
              if (dels) {
                for (final String rel in removed) {
                  File(p.join(replica.path, rel)).deleteSync();
                }
              }
              final SrsFolderLocation at = SrsFolderLocation(
                id: 'st',
                path: replica.path,
              );
              final Map<String, String> v3Before = snapshot(v3Root(at));
              final SrsDbStore other = await device('old-r$state');
              final Directory mo = dir('media_or$state');
              mediaFile(mo, 'dog.png', <int>[9, 9]);
              await addNote(other, '犬', picture: '<img src="dog.png">');
              for (final v1.SrsLocationKey? kk in <v1.SrsLocationKey?>[
                null,
                oldKey,
              ]) {
                final Map<String, String> before = snapshot(replica);
                final Object r = await runOld(at, other, media: mo, key: kk);
                final String why =
                    'fence=$fence adds=$adds dels=$dels key=${kk != null}';
                if (fence) {
                  expect(oldStoppedAtMeta(r), isTrue, reason: why);
                  expect(snapshot(replica), before, reason: why);
                }
                // 无论如何：新根一个字节不动，旧根上不出现明文媒体（位置是加密的）。
                expect(snapshot(v3Root(at)), v3Before, reason: why);
                expect(
                  filesOf(
                    v2Root(at),
                  ).where((String f) => f.startsWith('$kSrsMediaFolder/')),
                  isEmpty,
                  reason: why,
                );
              }
            }
          }
        }
      },
    );
  });

  group('v1 locations migrate once into the protocol 2 root', () {
    /// 旧版本（真实 v1 代码）写出一个 v1 文件夹位置：两条笔记、一个按名字存的明文媒体文件。
    Future<({SrsFolderLocation loc, SrsDbStore old, String note})> v1Location(
      String id, {
      bool archive = false,
      bool sync = true,
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
      final Set<String> s = filesOf(v2Root(loc));
      expect(s, contains('media/cat.png'));
      expect(s.where((String k) => k.startsWith('devices/')), isNotEmpty);
      return (
        loc: sync ? loc : loc.copyWith(sync: false),
        old: old,
        note: note,
      );
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
        ).readAsBytesSync(),
        <int>[1, 2, 3],
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
      expect(rb.prepared?.bound, 1);
      expect(rb.ops?.error, isNull);
      await runNew(v.loc, b, media: mediaB);
      await expectMigrated(v.loc, b, mediaB, v.note);
      final Map<String, String> v3 = snapshot(v3Root(v.loc));
      for (final MapEntry<String, String> e in v1Segments.entries) {
        expect(v3[e.key], e.value, reason: e.key);
      }
      expectOnlyFence(v2Root(v.loc));

      final Map<String, String> before = snapshot(Directory(v.loc.path));
      expect(
        oldStoppedAtMeta(await runOld(v.loc, v.old, media: dir('mo2'))),
        isTrue,
      );
      expect(snapshot(Directory(v.loc.path)), before);

      // 旧设备升级成新版本：照常在新根上同步，看得到 b 写的。
      final String fromB = await addNote(b, '犬');
      await runNew(v.loc, b, media: mediaB);
      await runNew(v.loc, v.old, media: dir('mo3'));
      expect((await v.old.note(fromB))!.field(expr(v.old)), '犬');
    });

    test(
      'by-name v1 media is deleted only after its binding is published',
      () async {
        final ({SrsFolderLocation loc, SrsDbStore old, String note}) v =
            await v1Location('defer');
        final SrsDbStore b = await device('b');
        final Directory v1Dir = v2Root(v.loc);
        final SrsLocationPrepared prep = await srsPrepareLocation(
          host: b,
          v1: SrsDirectoryLocationStore(v1Dir),
          current: SrsDirectoryLocationStore(v3Root(v.loc)),
          locationId: v.loc.locationId,
          key: null,
          nowMs: () => t,
          removeEmptyDirs: () => srsRemoveEmptyV1FolderDirs(v1Dir),
        );
        expect(prep.error, isNull);
        expect(prep.bound, 1);
        expect(prep.deferred.keys, <String>['media/cat.png']);
        expect(filesOf(v1Dir), contains('media/cat.png'));
        expect(
          filesOf(v1Dir).where((String f) => f.startsWith('devices/')),
          isEmpty,
          reason: '内容核对过的段立刻删',
        );
        // 绑定还在本机发件箱里：不删。
        expect(
          await srsFinishLocationMigration(
            host: b,
            v1: SrsDirectoryLocationStore(v1Dir),
            prepared: prep,
            progressId: v.loc.locationId,
          ),
          0,
        );
        expect(filesOf(v1Dir), contains('media/cat.png'));
        // 一轮同步把绑定发出去之后才删。
        final SrsSync2Report r = await srsSync2Round(
          host: b,
          location: SrsDirectoryLocationStore(v3Root(v.loc)),
          locationId: v.loc.locationId,
          nowMs: () => t,
        );
        expect(r.error, isNull);
        expect(
          await srsFinishLocationMigration(
            host: b,
            v1: SrsDirectoryLocationStore(v1Dir),
            prepared: prep,
            progressId: v.loc.locationId,
            removeEmptyDirs: () => srsRemoveEmptyV1FolderDirs(v1Dir),
          ),
          1,
        );
        expectOnlyFence(v1Dir);
        // 第三台设备只从新根拿得到这张图（绑定在位置上）。
        final SrsDbStore c = await device('c');
        final Directory mediaC = dir('media_c');
        await runNew(v.loc, c, media: mediaC);
        await runNew(v.loc, c, media: mediaC);
        await expectMigrated(v.loc, c, mediaC, v.note);
      },
    );

    test('an interrupted migration resumes to the same result', () async {
      for (final bool failOld in <bool>[false, true]) {
        final ({SrsFolderLocation loc, SrsDbStore old, String note}) v =
            await v1Location('resume-$failOld');
        final SrsDbStore b = await device('b-$failOld');
        final Directory mediaB = dir('media_b_$failOld');
        final Directory v1Dir = v2Root(v.loc);
        // 依次在第 1、2、3……次写（新根或旧根）时断掉，每次断完都重新来，直到一次跑通。
        for (int failAt = 1; ; failAt++) {
          final SrsLocationStore oldStore = SrsDirectoryLocationStore(v1Dir);
          final SrsLocationStore newStore = SrsDirectoryLocationStore(
            v3Root(v.loc),
          );
          try {
            t += 1000;
            final SrsLocationPrepared r = await srsPrepareLocation(
              host: b,
              v1: failOld ? _FailingStore(oldStore, failAt) : oldStore,
              current: failOld ? newStore : _FailingStore(newStore, failAt),
              locationId: v.loc.locationId,
              key: null,
              nowMs: () => t,
              removeEmptyDirs: () => srsRemoveEmptyV1FolderDirs(v1Dir),
            );
            expect(r.error, isNull);
            break;
          } on _Interrupted {
            // 任何一个中断点上：旧版本要么还看到完整的 v1（围栏还没写），要么被挡住。
            final Map<String, String> before = snapshot(Directory(v.loc.path));
            final Object o = await runOld(
              v.loc,
              v.old,
              media: dir('mo$failOld$failAt'),
            );
            if (srsDecodeV1Fence(
                  File(p.join(v1Dir.path, 'meta.json')).readAsBytesSync(),
                ) !=
                null) {
              expect(oldStoppedAtMeta(o), isTrue);
              expect(snapshot(Directory(v.loc.path)), before);
            }
          }
          expect(failAt, lessThan(60));
        }
        await runNew(v.loc, b, media: mediaB);
        await runNew(v.loc, b, media: mediaB);
        await expectMigrated(v.loc, b, mediaB, v.note);
        expectOnlyFence(v1Dir);
      }
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
      expectOnlyFence(v2Root(v.loc));
    });

    test('an archive location copies but never deletes the v1 files', () async {
      final ({SrsFolderLocation loc, SrsDbStore old, String note}) v =
          await v1Location('arch', archive: true);
      final Map<String, String> v1Files = <String, String>{
        for (final MapEntry<String, String> e in snapshot(
          v2Root(v.loc),
        ).entries)
          if (e.value != 'd' && e.key != 'meta.json') e.key: e.value,
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
      expectFence(v2Root(v.loc));
    });

    test(
      'once migrated, later processes neither pull the v1 root nor reseal',
      () async {
        for (final bool archive in <bool>[false, true]) {
          final ({SrsFolderLocation loc, SrsDbStore old, String note}) v =
              await v1Location('done-$archive', archive: archive);
          final SrsDbStore b = await device('b-$archive');
          final SrsLocationKey k = SrsLocationKey(
            keyHex: _kV1Key,
            kdf: SrsKdf.fresh(),
            pendingEnable: true,
          );
          final Directory mediaB = dir('media_b_$archive');
          await runNew(v.loc, b, media: mediaB, key: k);
          final SrsLocationKey kb = SrsLocationKey(
            keyHex: k.keyHex,
            kdf: k.kdf,
          );
          await runNew(v.loc, b, media: mediaB, key: kb);
          await runNew(v.loc, b, media: mediaB, key: kb);
          final Map<String, String> before = snapshot(Directory(v.loc.path));
          // 新进程（新的 memo）：只列目录比清单指纹。
          final _CountingHost counting = _CountingHost(b);
          final Directory v1Dir = v2Root(v.loc);
          final SrsLocationPrepared r = await srsPrepareLocation(
            host: counting,
            v1: SrsDirectoryLocationStore(v1Dir),
            current: SrsDirectoryLocationStore(v3Root(v.loc)),
            locationId: v.loc.locationId,
            key: kb,
            nowMs: () => t,
            memo: SrsLocationMigrationMemo(),
            archive: archive,
          );
          expect(r.error, isNull, reason: 'archive=$archive');
          expect(r.migrated, isFalse, reason: 'archive=$archive');
          expect(
            counting.ops,
            isNot(contains('plan')),
            reason: 'archive=$archive',
          );
          expect(counting.ops, isNot(contains('seal_file')));
          expect(snapshot(Directory(v.loc.path)), before);
        }
      },
    );

    test(
      'a by-name v1 file replaced after migration is not deleted on cleanup',
      () async {
        final ({SrsFolderLocation loc, SrsDbStore old, String note}) v =
            await v1Location('swap');
        final SrsDbStore b = await device('b');
        final Directory v1Dir = v2Root(v.loc);
        final SrsLocationPrepared prep = await srsPrepareLocation(
          host: b,
          v1: SrsDirectoryLocationStore(v1Dir),
          current: SrsDirectoryLocationStore(v3Root(v.loc)),
          locationId: v.loc.locationId,
          key: null,
          nowMs: () => t,
        );
        expect(prep.deferred, <String, String>{
          'media/cat.png': srsMediaSha256(<int>[1, 2, 3]),
        });
        // 收尾之前，同步工具把同名文件换成了别的内容：搬进新根的是旧内容，这份没人搬过。
        File(
          p.join(v1Dir.path, 'media', 'cat.png'),
        ).writeAsBytesSync(<int>[4, 4]);
        final SrsSync2Report r = await srsSync2Round(
          host: b,
          location: SrsDirectoryLocationStore(v3Root(v.loc)),
          locationId: v.loc.locationId,
          nowMs: () => t,
        );
        expect(r.error, isNull);
        expect(
          await srsFinishLocationMigration(
            host: b,
            v1: SrsDirectoryLocationStore(v1Dir),
            prepared: prep,
            progressId: v.loc.locationId,
          ),
          0,
        );
        expect(
          File(p.join(v1Dir.path, 'media', 'cat.png')).readAsBytesSync(),
          <int>[4, 4],
        );
        expect(prep.skipped, contains('media/cat.png'));
        expect(prep.deferred, isEmpty);
        // 下一次准备把新内容当成新文件重新搬（按它自己的 sha 排删）。
        final SrsLocationPrepared again = await srsPrepareLocation(
          host: b,
          v1: SrsDirectoryLocationStore(v1Dir),
          current: SrsDirectoryLocationStore(v3Root(v.loc)),
          locationId: v.loc.locationId,
          key: null,
          nowMs: () => t,
        );
        expect(again.deferred, <String, String>{
          'media/cat.png': srsMediaSha256(<int>[4, 4]),
        });
      },
    );

    test(
      'a process that already swept a location still re-erects a missing fence every round',
      () async {
        final ({SrsFolderLocation loc, SrsDbStore old, String note}) v =
            await v1Location('refence');
        final SrsDbStore b = await device('b');
        final Directory mediaB = dir('media_b');
        final SrsLocationMigrationMemo memo = SrsLocationMigrationMemo();
        await runNew(v.loc, b, media: mediaB, memo: memo);
        await runNew(v.loc, b, media: mediaB, memo: memo);
        await runNew(v.loc, b, media: mediaB, memo: memo);
        expectOnlyFence(v2Root(v.loc));
        expect(memo.swept(kProfile, v.loc.locationId), isTrue);
        // 围栏被删（用户清理 / 同步工具回滚）：旧版本下一轮就会在旧根上新建 v1 集合。
        File(p.join(v2Root(v.loc).path, 'meta.json')).deleteSync();
        final SrsFolderSyncReport r = await runNew(
          v.loc,
          b,
          media: mediaB,
          memo: memo,
        );
        expect(r.ops?.error, isNull);
        expectFence(v2Root(v.loc));
        expect(
          oldStoppedAtMeta(await runOld(v.loc, v.old, media: dir('mo4'))),
          isTrue,
        );
      },
    );

    test(
      'by-name v1 media is neither bound nor queued when the v1 pull is incomplete',
      () async {
        final ({SrsFolderLocation loc, SrsDbStore old, String note}) v =
            await v1Location('partial');
        final Directory v1Dir = v2Root(v.loc);
        // head 指向的一个段读不到（最终一致 / 别的设备正在删）：看不全已有的绑定。
        final String seg = filesOf(
          v1Dir,
        ).firstWhere((String f) => p.posix.basename(f).startsWith('seg-'));
        File(p.join(v1Dir.path, seg)).deleteSync();
        final SrsDbStore b = await device('b');
        final SrsLocationPrepared r = await srsPrepareLocation(
          host: b,
          v1: SrsDirectoryLocationStore(v1Dir),
          current: SrsDirectoryLocationStore(v3Root(v.loc)),
          locationId: v.loc.locationId,
          key: null,
          nowMs: () => t,
        );
        expect(r.error, isNull);
        expect(r.errors, isNotEmpty);
        expect(r.bound, 0);
        expect(r.deferred, isEmpty);
        expect(r.publishSeq, isNull);
        expect(r.skipped, contains('media/cat.png'));
        expect(filesOf(v1Dir), contains('media/cat.png'));
        expect(filesOf(v1Dir), isNot(contains(kSrsV1SweepMarker)));
      },
    );
  });

  group('migration failure modes', () {
    test(
      'a v3 copy with different bytes is never trusted: the v1 original stays',
      () async {
        final SrsFolderLocation loc = SrsFolderLocation(
          id: 'half',
          path: dir('half').path,
        );
        final SrsDbStore old = await device('old');
        final Directory mediaOld = dir('media_old');
        mediaFile(mediaOld, 'cat.png', <int>[1, 2, 3]);
        await addNote(old, '猫', picture: '<img src="cat.png">');
        await runOld(loc, old, media: mediaOld);
        final String seg = filesOf(
          v2Root(loc),
        ).firstWhere((String f) => p.posix.basename(f).startsWith('seg-'));
        final Uint8List original = File(
          p.join(v2Root(loc).path, seg),
        ).readAsBytesSync();
        // 互联 host 以前的非原子 PUT / 被打断的上传：新根上同名的半截副本。
        File(p.join(v3Root(loc).path, seg))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(original.sublist(0, original.length ~/ 2));
        // 内容目录里一个坏对象（名字是 cat.png 的 sha，内容不对）：按内容覆盖修好。
        final File badObject =
            File(
                p.join(
                  v3Root(loc).path,
                  srsMediaContentPath(
                    kSrsMediaFolder,
                    srsMediaSha256(<int>[1, 2, 3]),
                  ),
                ),
              )
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync(<int>[0]);
        final SrsDbStore b = await device('b');
        final Directory v1Dir = v2Root(loc);
        final SrsLocationPrepared r = await srsPrepareLocation(
          host: b,
          v1: SrsDirectoryLocationStore(v1Dir),
          current: SrsDirectoryLocationStore(v3Root(loc)),
          locationId: loc.locationId,
          key: null,
          nowMs: () => t,
        );
        expect(r.skipped, contains(seg));
        expect(File(p.join(v1Dir.path, seg)).readAsBytesSync(), original);
        expect(badObject.readAsBytesSync(), <int>[1, 2, 3]);
        expect(r.deferred.keys, <String>['media/cat.png']);
      },
    );

    test(
      'a file another device holds open is neither clobbered nor lost (Windows)',
      () async {
        final SrsDirectoryLocationStore store = SrsDirectoryLocationStore(
          dir('held'),
        );
        await store.put('a.bin', Uint8List.fromList(<int>[1, 2, 3]));
        final File target = File(p.join(tmp.path, 'held', 'a.bin'));
        final File same = File(p.join(tmp.path, 'same.bin'))
          ..writeAsBytesSync(<int>[1, 2, 3]);
        final File other = File(p.join(tmp.path, 'other.bin'))
          ..writeAsBytesSync(<int>[9]);
        // 另一台设备正开着它读：Windows 上改名盖不上去。
        final RandomAccessFile held = await target.open();
        try {
          // 只在不在时创建：已经在了就是约定的结果。
          await store.putNewFile('a.bin', other);
          await store.putNew('a.bin', Uint8List.fromList(<int>[9]));
          // 覆盖写：目标已经是这份字节 = 结果正确；不是这份字节 = 照抛，不假装写成了。
          await store.putFile('a.bin', same);
          await expectLater(
            store.putFile('a.bin', other),
            throwsA(isA<FileSystemException>()),
          );
          expect(await store.list(''), hasLength(1), reason: '临时文件不留');
        } finally {
          await held.close();
        }
        expect(target.readAsBytesSync(), <int>[1, 2, 3]);

        // 迁移删一个核对过、但别的设备正开着的旧段：这次不删（留着、不写完成标记），下次删。
        final SrsFolderLocation loc = SrsFolderLocation(
          id: 'busy',
          path: dir('busy').path,
        );
        final SrsDbStore old = await device('old');
        await addNote(old, '鳥');
        await runOld(loc, old, media: dir('mo'));
        final String seg = filesOf(
          v2Root(loc),
        ).firstWhere((String f) => p.posix.basename(f).startsWith('seg-'));
        final SrsDbStore b = await device('b');
        final RandomAccessFile busy = await File(
          p.join(v2Root(loc).path, seg),
        ).open();
        SrsLocationPrepared r;
        try {
          r = await srsPrepareLocation(
            host: b,
            v1: SrsDirectoryLocationStore(v2Root(loc)),
            current: SrsDirectoryLocationStore(v3Root(loc)),
            locationId: loc.locationId,
            key: null,
            nowMs: () => t,
          );
        } finally {
          await busy.close();
        }
        expect(r.error, isNull);
        expect(r.skipped, contains(seg));
        expect(filesOf(v2Root(loc)), contains(seg));
        expect(filesOf(v2Root(loc)), isNot(contains(kSrsV1SweepMarker)));
        await runNew(loc, b, media: dir('mb'));
        expectOnlyFence(v2Root(loc));
      },
      testOn: 'windows',
    );

    test(
      'a writer-dir read failure fails the migration and deletes nothing',
      () async {
        final Directory remote = dir('remote');
        final _FlakyBackend backend = _FlakyBackend(remote, 'two.png');
        for (final String n in <String>['one.png', 'two.png']) {
          File(
              p.join(
                remote.path,
                kSrsSync2Namespace,
                kProfile,
                'a#1',
                kSrsMediaFolder,
                n,
              ),
            )
            ..createSync(recursive: true)
            ..writeAsBytesSync(utf8.encode(n));
        }
        final SrsDbStore b = await device('b');
        await addNote(
          b,
          '古',
          picture: '<img src="one.png"><img src="two.png">',
        );
        final SrsLocationStore v3 = SrsAssetLocationStore(
          store: backend,
          profileUid: kProfile,
        );
        SrsLocationStore v1Store() => SrsAssetLocationStore(
          store: backend,
          profileUid: kProfile,
          folder: kSrsSync2V1Folder,
        );
        // 新根还没在用：迁移是前提，读失败整轮失败。
        await expectLater(
          srsPrepareLocation(
            host: b,
            v1: v1Store(),
            current: v3,
            locationId: 'remote',
            key: null,
            nowMs: () => t,
            recordPresence: true,
            writers: SrsAssetV1Writers(backend, kProfile),
          ),
          throwsA(isA<FileSystemException>()),
        );
        Set<String> writerFiles() => filesOf(
          Directory(p.join(remote.path, kSrsSync2Namespace, kProfile, 'a#1')),
        );
        expect(writerFiles(), <String>{'media/one.png', 'media/two.png'});
        // 新根在用之后：同样的读失败只记成残留错误，不挡新根的一轮。
        backend.broken = null;
        final SrsSync2Report round = await srsSync2Round(
          host: b,
          location: v3,
          locationId: 'remote',
          nowMs: () => t,
        );
        expect(round.error, isNull);
        backend.broken = 'two.png';
        final SrsLocationPrepared ready = await srsPrepareLocation(
          host: b,
          v1: v1Store(),
          current: v3,
          locationId: 'remote',
          key: null,
          nowMs: () => t,
          recordPresence: true,
          writers: SrsAssetV1Writers(backend, kProfile),
        );
        expect(ready.error, isNull);
        expect(ready.leftoverError, isNotNull);
        // 不吞：原始错误与栈交给调用方记日志。
        expect(ready.leftoverCause, isA<FileSystemException>());
        expect(ready.leftoverStack, isNotNull);
        expect(writerFiles(), <String>{'media/one.png', 'media/two.png'});
        // 读好了：搬完、绑定发布之后逐个文件删，目录里别的东西（这里没有）不碰。
        backend.broken = null;
        final SrsLocationPrepared ok = await srsPrepareLocation(
          host: b,
          v1: v1Store(),
          current: v3,
          locationId: 'remote',
          key: null,
          nowMs: () => t,
          recordPresence: true,
          writers: SrsAssetV1Writers(backend, kProfile),
        );
        expect(ok.leftoverError, isNull);
        expect(ok.deferredWriters.length, 2);
        expect(writerFiles().length, 2);
        await srsSync2Round(
          host: b,
          location: v3,
          locationId: 'remote',
          nowMs: () => t,
        );
        expect(
          await srsFinishLocationMigration(
            host: b,
            v1: v1Store(),
            prepared: ok,
            progressId: 'remote',
            // 新实例：收尾自己列目录。
            writers: SrsAssetV1Writers(backend, kProfile),
          ),
          2,
        );
        expect(writerFiles(), isEmpty);
      },
    );

    test(
      'leftovers found after v3 turned encrypted are sealed with the v3 key, never written in plaintext',
      () async {
        final ({SrsFolderLocation loc, SrsDbStore old, String note}) v =
            await () async {
              final SrsFolderLocation loc = SrsFolderLocation(
                id: 'late',
                path: dir('late').path,
              );
              final SrsDbStore old = await device('old');
              await addNote(old, '鳥');
              await runOld(loc, old, media: dir('mo'));
              return (loc: loc, old: old, note: '');
            }();
        final SrsDbStore b = await device('b');
        final Directory mediaB = dir('media_b');
        await runNew(v.loc, b, media: mediaB);
        // 迁移之后才在新根开加密。
        final SrsLocationKey k = SrsLocationKey(
          keyHex: _kV1Key,
          kdf: SrsKdf.fresh(),
          pendingEnable: true,
        );
        final SrsFolderSyncReport on = await runNew(
          v.loc,
          b,
          media: mediaB,
          key: k,
        );
        expect(on.ops?.encryptionEnabled, isTrue);
        final SrsLocationKey kb = SrsLocationKey(keyHex: k.keyHex, kdf: k.kdf);
        // 同步工具晚带来的旧版本明文媒体。
        File(p.join(v2Root(v.loc).path, kSrsMediaFolder, 'late.png'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[5, 5]);
        await addNote(b, '晚', picture: '<img src="late.png">');
        // 没口令的设备：新根握手要口令，残留一个字节都不写。
        final SrsDbStore c = await device('c');
        final Map<String, String> v3Before = snapshot(v3Root(v.loc));
        final SrsFolderSyncReport rc = await runNew(
          v.loc,
          c,
          media: dir('media_c'),
          memo: SrsLocationMigrationMemo(),
        );
        expect(rc.ops?.error, kSrsSync2NeedsKey);
        expect(snapshot(v3Root(v.loc)), v3Before);
        // 有口令的设备：按新根的密钥封进去。
        await runNew(
          v.loc,
          b,
          media: mediaB,
          key: kb,
          memo: SrsLocationMigrationMemo(),
        );
        final String sha = srsMediaSha256(<int>[5, 5]);
        final File sealed = File(
          p.join(
            v3Root(v.loc).path,
            srsMediaContentPath(SrsMediaCipher(b, kb.keyHex).folder, sha),
          ),
        );
        expect(sealed.existsSync(), isTrue);
        expect(sealed.readAsBytesSync(), isNot(<int>[5, 5]));
        expect(
          File(
            p.join(
              v3Root(v.loc).path,
              srsMediaContentPath(kSrsMediaFolder, sha),
            ),
          ).existsSync(),
          isFalse,
        );
      },
    );

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
        expect(filesOf(v2Root(loc)), isNot(contains('media/cat.png')));
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
        // 没口令：不围栏、不迁移、不碰。
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
        expect(
          filesOf(
            v3Root(loc),
          ).where((String k) => k.startsWith('$kSrsMediaFolder/')),
          isEmpty,
        );
        expectOnlyFence(v2Root(loc));
      },
    );

    test(
      'a v1 file landing mid-migration is not swallowed by the done marker',
      () async {
        // 回归：完成标记的指纹以前由「删完之后重新列出的旧根」算，迁移期间同步工具带来的文件被当成「已处理」，之后的
        // 进程只比指纹、永远不搬它。
        final SrsFolderLocation loc = SrsFolderLocation(
          id: 'late-arrival',
          path: dir('late-arrival').path,
        );
        final SrsDbStore old = await device('old');
        await addNote(old, '鳥');
        await runOld(loc, old, media: dir('mo'));
        final Directory v1Dir = v2Root(loc);
        final List<int> lateBytes = <int>[9, 8, 7, 6];
        final String latePath = srsMediaContentPath(
          kSrsMediaFolder,
          srsMediaSha256(lateBytes),
        );
        final SrsDbStore b = await device('b');
        final SrsLocationPrepared first = await srsPrepareLocation(
          host: b,
          v1: _OnFirstDeleteStore(SrsDirectoryLocationStore(v1Dir), () {
            File(p.join(v1Dir.path, latePath))
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync(lateBytes);
          }),
          current: SrsDirectoryLocationStore(v3Root(loc)),
          locationId: loc.locationId,
          key: null,
          nowMs: () => t,
          memo: SrsLocationMigrationMemo(),
        );
        expect(first.error, isNull);
        expect(first.migrated, isTrue);
        expect(first.deleted, greaterThan(0));
        expect(filesOf(v1Dir), contains(latePath));
        // 新进程：完成标记不能挡住它。
        final SrsLocationPrepared second = await srsPrepareLocation(
          host: b,
          v1: SrsDirectoryLocationStore(v1Dir),
          current: SrsDirectoryLocationStore(v3Root(loc)),
          locationId: loc.locationId,
          key: null,
          nowMs: () => t,
          memo: SrsLocationMigrationMemo(),
        );
        expect(second.error, isNull);
        expect(second.migrated, isTrue);
        expect(
          File(p.join(v3Root(loc).path, latePath)).readAsBytesSync(),
          lateBytes,
        );
        expectOnlyFence(v1Dir);
      },
    );

    test(
      'writer-dir cleanup errors keep the file and never fail the round; a renamed-over file is not deleted',
      () async {
        final _MemWriters ws = _MemWriters(<String, Map<String, List<int>>>{
          'a#1': <String, List<int>>{
            'one.png': <int>[1, 1],
            'two.png': <int>[2, 2],
          },
        });
        final SrsDbStore b = await device('b');
        final SrsLocationStore v1Store = SrsDirectoryLocationStore(dir('w1'));
        final SrsLocationStore v3 = SrsDirectoryLocationStore(dir('w3'));
        final SrsLocationPrepared prep = await srsPrepareLocation(
          host: b,
          v1: v1Store,
          current: v3,
          locationId: 'w',
          key: null,
          nowMs: () => t,
          recordPresence: true,
          writers: ws,
        );
        expect(prep.error, isNull);
        expect(prep.deferredWriters.keys.toSet(), <(String, String)>{
          ('a#1', 'one.png'),
          ('a#1', 'two.png'),
        });
        final SrsSync2Report round = await srsSync2Round(
          host: b,
          location: v3,
          locationId: 'w',
          nowMs: () => t,
        );
        expect(round.error, isNull);
        // 迁移之后 two.png 被换成了别的内容：搬过、绑上的是旧内容，新内容不能删。
        ws.files['a#1']!['two.png'] = <int>[7, 7, 7];
        ws.failDelete = true;
        expect(
          await srsFinishLocationMigration(
            host: b,
            v1: v1Store,
            prepared: prep,
            progressId: 'w',
            writers: ws,
          ),
          0,
        );
        expect(prep.cleanupErrors, hasLength(1));
        expect(prep.deferredWriters.keys, <(String, String)>[
          ('a#1', 'one.png'),
        ]);
        expect(prep.skipped, contains('a#1/media/two.png'));
        expect(ws.files['a#1']!.keys.toSet(), <String>{'one.png', 'two.png'});
        ws.failDelete = false;
        expect(
          await srsFinishLocationMigration(
            host: b,
            v1: v1Store,
            prepared: prep,
            progressId: 'w',
            writers: ws,
          ),
          1,
        );
        expect(ws.files['a#1']!.keys, <String>['two.png']);
        expect(ws.files['a#1']!['two.png'], <int>[7, 7, 7]);
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

void _copyTree(Directory from, Directory to) {
  for (final FileSystemEntity e in from.listSync(recursive: true)) {
    final String rel = p.relative(e.path, from: from.path);
    if (e is Directory) {
      Directory(p.join(to.path, rel)).createSync(recursive: true);
    } else if (e is File) {
      final File dst = File(p.join(to.path, rel))
        ..parent.createSync(recursive: true);
      e.copySync(dst.path);
    }
  }
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

/// 第一次删文件之前调一次 [hook]（模拟迁移期间同步工具带来新文件）。
class _OnFirstDeleteStore implements SrsLocationStore {
  _OnFirstDeleteStore(this.inner, this.hook);

  final SrsLocationStore inner;
  final void Function() hook;
  bool _fired = false;

  @override
  Future<List<SrsLocationEntry>> list(String dir) => inner.list(dir);

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
  Future<void> delete(String path) async {
    if (!_fired) {
      _fired = true;
      hook();
    }
    await inner.delete(path);
  }
}

/// 内存里的旧写入者目录；[failDelete] 时删除抛（限流 / 断网）。
class _MemWriters implements SrsV1Writers {
  _MemWriters(this.files);

  final Map<String, Map<String, List<int>>> files;
  bool failDelete = false;

  @override
  Future<List<String>> writers() async => files.keys.toList()..sort();

  @override
  Future<List<String>> mediaNames(String writer) async =>
      (files[writer]?.keys.toList() ?? <String>[])..sort();

  @override
  Future<bool> getMedia(String writer, String name, File dst) async {
    final List<int>? bytes = files[writer]?[name];
    if (bytes == null) return false;
    await dst.writeAsBytes(bytes, flush: true);
    return true;
  }

  @override
  Future<void> deleteMedia(String writer, String name) async {
    if (failDelete) throw const FileSystemException('rate limited');
    files[writer]?.remove(name);
  }
}

/// 名字是 [broken] 的资产下载时抛（限流 / 断网），文件本身还在。
class _FlakyBackend extends LocalDirectoryAssetStore {
  _FlakyBackend(super.root, this.broken);

  String? broken;

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    final String? b = broken;
    if (b != null && assetId.endsWith(b)) {
      throw FileSystemException('429 too many requests', assetId);
    }
    return super.getAsset(assetId, destination, onProgress: onProgress);
  }
}

/// 记下每条内核命令的宿主。
class _CountingHost implements SrsSync2Host {
  _CountingHost(this.inner);

  final SrsDbStore inner;
  final List<String> ops = <String>[];

  @override
  String get profileUid => inner.profileUid;

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) {
    ops.add('${request['op']}');
    return inner.sync2Command(request, blobs: blobs);
  }

  @override
  Future<void> sync2IngestBegin() {
    ops.add('ingest');
    return inner.sync2IngestBegin();
  }

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  }) => inner.sync2IngestBatch(segments, keyHex: keyHex);

  @override
  Future<Map<String, Object?>> sync2IngestFinish() => inner.sync2IngestFinish();
}

/// 协议 1 整份封装的固定样本：密钥 0x11×32，nonce 0x22×24，AAD `fushi-srs-media:cat.png`（旧内核 `seal` 的 AAD），
/// 明文 [4, 5, 6]（`nonce || 密文+tag`，由 chacha20poly1305 0.11 的 XChaCha20Poly1305 生成，与 d407ae22ca 的
/// `CollectionKey::seal` 同一构造）。
const String _kV1Key =
    '1111111111111111111111111111111111111111111111111111111111111111';
const String _kV1CatEnvelope =
    '2222222222222222222222222222222222222222222222228762e122044e47b1d89c13c3d4760efc0c54e3';

Uint8List _unhex(String h) => Uint8List.fromList(<int>[
  for (int i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);
