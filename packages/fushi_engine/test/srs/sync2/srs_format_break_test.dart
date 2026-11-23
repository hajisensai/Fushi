// 同步位置的格式断代（新代 G8-7 / G8-7b，sync2/srs_sync2_round.dart `srsSync4LocationRoot`，内核 `gen4/oldroot.rs`）：
// - 协议 1 的旧版本（冻结在 v1_client/ 的 develop@d407ae22ca 代码，真实跑一轮）碰到新版本用过的位置：在写任何东西
//   之前报错停下，位置目录逐字节不变——明文 / 加密文件夹位置、只做媒体 / 归档的文件夹位置、云盘 / 互联通道。新版本
//   在 `v2/` 立一份协议 1 解析不了的围栏（新根 `v4/`、旧根 `v3/` 的围栏立住之后），协议 3 的版本由 `v3/` 的围栏
//   （`minReader` 4、`moved: v4`）挡住；
// - 只有协议 1 旧根 `v2/` 的位置：新版本明确拒绝（机读码 `srs_location_protocol1_root`，提示在另一台装 3.3.0 的设备上同步一次、本机别降级），
//   一个字节都不写，本机已有的笔记照旧在；旧版本在那个位置上照常同步（以前的一次性迁移 `srsPrepareLocation` /
//   `srsMigrateV1Media` 新代不再走，交接说明「G8-7b 同步补全」）。
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
import 'package:fushi_engine/srs/sync2/srs_v1_fence.dart';
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
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(wallClockMs: () => t, bootClockMs: () => t),
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

  Future<SrsFolderSyncReport> runNew(
    SrsFolderLocation loc,
    SrsDbStore s, {
    Directory? media,
    SrsLocationKey? key,
  }) {
    t += 1000;
    return srsSyncFolderLocation(
      location: loc,
      store: s,
      mediaRoot: media,
      key: key,
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

  /// 协议 1 的围栏：旧版本的握手解析不了（不是 JSON），里面记着数据挪到了新根。
  void expectFenceBytes(Uint8List bytes) {
    final Map<String, Object?>? fence = srsDecodeV1Fence(bytes);
    expect(fence, isNotNull);
    expect(fence!['minReader'], kSrsSync2MinReader);
    expect(fence[kSrsV1MovedToKey], kSrs4Root);
    expect(
      () => jsonDecode(utf8.decode(bytes)),
      throwsFormatException,
      reason: '旧版本的握手必须解析失败',
    );
  }

  void expectFence(Directory v2) =>
      expectFenceBytes(File(p.join(v2.path, 'meta.json')).readAsBytesSync());

  /// 协议 3 的围栏：旧根 `v3/meta.json` 改写成 `minReader` 4、`moved: v4`。
  void expectV3Fence(SrsFolderLocation loc) {
    final Map<String, Object?> meta =
        (jsonDecode(
                  File(
                    p.join(v3Root(loc).path, 'meta.json'),
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>();
    expect(meta['minReader'], kSrsSync2MinReader);
    expect(meta['moved'], kSrs4Root);
  }

  group(
    'old clients stop on a new-format location without changing a byte',
    () {
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
        expectV3Fence(loc);
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
        SrsLocationStore at(String folder) => SrsAssetLocationStore(
          store: backend,
          profileUid: kProfile,
          folder: folder,
        );
        final SrsSync2Report ra = await srsSync2Round(
          host: a,
          location: at(kSrs4Root),
          oldRoot: at(kSrsSync2Folder),
          protocol1Root: at(kSrsSync2V1Folder),
          locationId: 'cloud',
          nowMs: () => t,
        );
        expect(ra.error, isNull);
        expectFenceBytes((await at(kSrsSync2V1Folder).get('meta.json'))!);
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

        // 旧版 profile 关联：同一个 uid 下的 `v3` / `v4` 被当成「别的写入者」→ 判为已关联、保持不动，不会走到「采用
        // 别的 uid → 删掉本 uid 的 v2 目录」那一支（围栏不会被旧版本删掉）。
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
        'a protocol 3 location the new version takes over is fenced at v2 too',
        () async {
          // 协议 3 时代的位置（`v3/` 有本集合的 meta、`v2/` 没有）：新版本接手后 `v2/` 同样立围栏。
          final SrsFolderLocation loc = SrsFolderLocation(
            id: 'p3',
            path: dir('p3').path,
            media: false,
          );
          final SrsDbStore a = await device('a');
          await addNote(a, '猫');
          final Object? collection = (await a.sync2Command(<String, Object?>{
            'op': 'identity',
            'now': t,
          })).map['collection'];
          final Directory v3 = v3Root(loc)..createSync(recursive: true);
          File(p.join(v3.path, 'meta.json')).writeAsStringSync(
            jsonEncode(<String, Object?>{
              'v': 3,
              'minReader': 3,
              'collection': collection,
            }),
          );
          final SrsFolderSyncReport ra = await runNew(loc, a);
          expect(ra.ops?.error, isNull);
          expect(ra.ops?.mediaRoot, kSrsSync2Folder);
          expectFence(v2Root(loc));
          expectV3Fence(loc);
          final Map<String, String> before = snapshot(Directory(loc.path));
          final SrsDbStore old = await device('old');
          await addNote(old, '犬');
          expect(oldStoppedAtMeta(await runOld(loc, old)), isTrue);
          expect(snapshot(Directory(loc.path)), before);
        },
      );
    },
  );

  group(
    'a location with only the protocol 1 root is refused, nothing written',
    () {
      /// 协议 1 的旧版本写出的文件夹位置的样子：`v2/` 下的 meta、一个设备段、一个按名字存的明文媒体。内容由旧版本的
      /// 格式决定，新版本在读到任何一个之前就停下，所以这里不必是能解开的段。
      SrsFolderLocation v1Location(
        String id, {
        bool sync = true,
        bool archive = false,
      }) {
        final SrsFolderLocation loc = SrsFolderLocation(
          id: id,
          path: dir(id).path,
          sync: sync,
          archive: archive,
        );
        final Directory v2 = v2Root(loc)..createSync(recursive: true);
        File(p.join(v2.path, 'meta.json')).writeAsStringSync(
          jsonEncode(<String, Object?>{
            'v': 1,
            'minReader': 1,
            'collection': 'v1-collection',
            'createdAt': t,
          }),
        );
        File(
            p.join(
              v2.path,
              'devices',
              'old',
              'seg-000000000001-000000000002.bin',
            ),
          )
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(<int>[1, 2, 3, 4]);
        File(p.join(v2.path, kSrsMediaFolder, 'cat.png'))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(<int>[1, 2, 3]);
        return loc;
      }

      test('sync, media-only and archive folder locations', () async {
        for (final SrsFolderLocation loc in <SrsFolderLocation>[
          v1Location('sync'),
          v1Location('media', sync: false),
          v1Location('archive', archive: true),
        ]) {
          final SrsDbStore b = await device('b-${loc.id}');
          final Directory mediaB = dir('media_b_${loc.id}');
          mediaFile(mediaB, 'dog.png', <int>[7]);
          final String note = await addNote(
            b,
            '犬',
            picture: '<img src="dog.png">',
          );
          final Map<String, String> before = snapshot(Directory(loc.path));
          for (int i = 0; i < 2; i++) {
            final SrsFolderSyncReport r = await runNew(loc, b, media: mediaB);
            expect(
              r.ops?.error,
              contains('srs_location_protocol1_root'),
              reason: loc.id,
            );
            expect(r.media, isNull, reason: loc.id);
            expect(snapshot(Directory(loc.path)), before, reason: loc.id);
          }
          // 本机的笔记与媒体照旧在。
          expect(await b.userNoteCount(), 1, reason: note);
          expect(File(p.join(mediaB.path, 'dog.png')).readAsBytesSync(), <int>[
            7,
          ]);
        }
      });

      test('encrypted: a passphrase does not change the answer', () async {
        final SrsFolderLocation loc = v1Location('enc');
        final SrsDbStore b = await device('b');
        await addNote(b, '犬');
        final SrsLocationKey kb = await srsDeriveLocationKey(
          b,
          'pass',
          pendingEnable: true,
        );
        final Map<String, String> before = snapshot(Directory(loc.path));
        final SrsFolderSyncReport r = await runNew(loc, b, key: kb);
        expect(r.ops?.error, contains('srs_location_protocol1_root'));
        expect(snapshot(Directory(loc.path)), before);
      });

      test(
        'the old version keeps syncing there; a v2 fence alone is not a protocol 1 collection',
        () async {
          final SrsFolderLocation loc = v1Location('keep');
          final SrsDbStore b = await device('b');
          await addNote(b, '犬');
          expect(
            (await runNew(loc, b)).ops?.error,
            contains('srs_location_protocol1_root'),
          );
          // 旧版本在这个位置上没被挡：新版本什么都没写，`v2/meta.json` 仍是它认得的 JSON。
          final Map<String, Object?> meta =
              (jsonDecode(
                        File(
                          p.join(v2Root(loc).path, 'meta.json'),
                        ).readAsStringSync(),
                      )
                      as Map)
                  .cast<String, Object?>();
          expect(meta['v'], 1);
          expect(Directory(v3Root(loc).path).existsSync(), isFalse);
          expect(
            Directory(
              p.join(loc.path, kSrsSync2Namespace, kProfile, kSrs4Root),
            ).existsSync(),
            isFalse,
          );

          // `v2/` 上只剩协议 2 迁移留下的围栏（`v3/` 被用户删了）：不是协议 1 的集合，按全新位置立根。
          final SrsFolderLocation fenced = SrsFolderLocation(
            id: 'fenced',
            path: dir('fenced').path,
            media: false,
          );
          final Directory v2 = v2Root(fenced)..createSync(recursive: true);
          File(p.join(v2.path, 'meta.json')).writeAsBytesSync(
            srsEncodeV1Fence(<String, Object?>{
              'v': 2,
              'minReader': 2,
              kSrsV1MovedToKey: kSrsSync2Folder,
            }),
          );
          final SrsFolderSyncReport rf = await runNew(fenced, b);
          expect(rf.ops?.error, isNull);
          expect(rf.ops?.mediaRoot, kSrs4Root);
          expectV3Fence(fenced);
        },
      );
    },
  );

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
    // b 自己的操作（开库时的内置实体）要回到 a，两边才在同一个版本向量上。
    await runNew(loc, a);
    expect(
      (await a.sync2Digest())['digest'],
      (await b.sync2Digest())['digest'],
    );
    int seg = 0;
    for (final FileSystemEntity f in Directory(
      p.join(loc.path, kSrsSync2Namespace, kProfile, kSrs4Root),
    ).listSync(recursive: true)) {
      if (f is File && p.basename(f.path).startsWith('seg-')) {
        seg += f.lengthSync();
      }
    }
    expect(seg, greaterThan(0));
  });
}
