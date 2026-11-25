import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_folder_access.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_platform.dart';
import 'package:fushi/src/sync/auto_backup/cloud_backup_mirror.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart' show AssetEntry;
import 'package:path/path.dart' as p;

import 'fake_asset_store.dart';

/// 用户文件夹里的定时还原点副本（spec 第三期）：`dart:io` 实现的往返、被打断后重写、iCloud 占位、
/// 只修剪本机写的副本，以及 Android SAF / iOS 书签两条平台半边的 Dart 契约。
RestorePoint _localPoint(String root, String id, DateTime at, {int size = 4}) {
  final Directory dir = Directory(p.join(root, id))
    ..createSync(recursive: true);
  File(
    p.join(dir.path, kRestorePointArchiveFileName),
  ).writeAsStringSync('z' * size);
  final RestorePoint point = RestorePoint(
    id: id,
    directory: dir.path,
    kind: RestorePointKind.scheduled,
    database: RestorePointDatabase.fushi,
    createdAtMs: at.millisecondsSinceEpoch,
    fromSchema: kFushiDbSchemaVersion,
    toSchema: kFushiDbSchemaVersion,
    files: <RestorePointFile>[
      RestorePointFile(name: kRestorePointArchiveFileName, size: size),
    ],
    fullDatabase: true,
  );
  File(
    p.join(dir.path, kRestorePointMetaFileName),
  ).writeAsStringSync(jsonEncode(point.toJson()));
  return point;
}

MirroredRestorePoint _copy(String id, DateTime at, String? device) {
  final RestorePoint point = RestorePoint(
    id: id,
    directory: id,
    kind: RestorePointKind.scheduled,
    database: RestorePointDatabase.fushi,
    createdAtMs: at.millisecondsSinceEpoch,
    fromSchema: 1,
    toSchema: 1,
    files: const <RestorePointFile>[
      RestorePointFile(name: kRestorePointArchiveFileName, size: 10),
    ],
    deviceId: device,
  );
  return MirroredRestorePoint(point: point, metaText: '{}');
}

/// 指定的目录 / 资产读的时候抛错（模拟云端这一步出错：限流、某个目录读失败）。
class _FlakyStore extends FakeAssetStore {
  _FlakyStore() : super(reportNullSizes: true);

  final Set<String> failList = <String>{};
  final Set<String> failGet = <String>{};

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) {
    if (failList.contains(namespaceId)) {
      throw StateError('list failed: $namespaceId');
    }
    return super.listChildren(namespaceId);
  }

  @override
  Future<Uint8List?> getBytesAsset(String assetId) {
    if (failGet.contains(assetId)) throw StateError('get failed: $assetId');
    return super.getBytesAsset(assetId);
  }
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fushi_mirror_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('元数据带写入设备：往返解析，本地存储读同一份格式', () {
    final RestorePoint local = _localPoint(
      tmp.path,
      '20261125-010000-000-fushi-scheduled',
      DateTime.utc(2026, 11, 25, 1),
    );
    final String text = mirrorMetaText(
      local,
      deviceId: 'dev-1',
      deviceName: 'Pixel',
    );
    final RestorePoint parsed = RestorePoint.tryParse(
      text,
      id: local.id,
      directory: 'tree/x',
    )!;
    expect(parsed.deviceId, 'dev-1');
    expect(parsed.deviceName, 'Pixel');
    expect(parsed.fullDatabase, isTrue);
    expect(parsed.directory, 'tree/x');
    expect(RestorePoint.tryParse('not json', id: 'a', directory: 'b'), isNull);
    // 文件名带路径的元数据（文件夹副本不完全可信）整份当作不完整：取回时不会写到目录外。
    for (final String bad in <String>['../evil', 'a/b', r'a\b', '..']) {
      final Map<String, Object?> json =
          jsonDecode(text) as Map<String, Object?>;
      json['files'] = <Object?>[
        <String, Object?>{'name': bad, 'size': 1},
      ];
      expect(
        RestorePoint.tryParse(jsonEncode(json), id: 'a', directory: 'b'),
        isNull,
        reason: bad,
      );
    }
    // 本地点没有设备字段，也不写出来。
    expect(local.toJson().containsKey('deviceId'), isFalse);
  });

  test('IoBackupFolderMirror：上传 → 列出 → 取回 → 删除；被打断的上一次覆盖重写', () async {
    final String store = p.join(tmp.path, 'store');
    final String folder = p.join(tmp.path, 'folder');
    Directory(folder).createSync();
    final RestorePoint local = _localPoint(
      store,
      '20261125-010000-000-fushi-scheduled',
      DateTime.utc(2026, 11, 25, 1),
    );
    final IoBackupFolderMirror mirror = IoBackupFolderMirror(folder);
    // 上一次复制到一半：有半截 zip、也有一份旧元数据。
    final Directory half = Directory(p.join(folder, local.id))..createSync();
    File(
      p.join(half.path, kRestorePointArchiveFileName),
    ).writeAsStringSync('zz');
    expect((await mirror.list()).points, isEmpty);

    await mirror.upload(
      local,
      metaText: mirrorMetaText(local, deviceId: 'd', deviceName: 'n'),
    );
    final MirrorFolderListing listing = await mirror.list();
    expect(listing.points.single.id, local.id);
    expect(
      File(p.join(half.path, kRestorePointArchiveFileName)).readAsStringSync(),
      'zzzz',
    );

    final String dest = p.join(tmp.path, 'dest');
    Directory(dest).createSync();
    await mirror.download(listing.points.single, dest);
    expect(
      File(p.join(dest, kRestorePointArchiveFileName)).readAsStringSync(),
      'zzzz',
    );

    await mirror.delete(local.id);
    expect(half.existsSync(), isFalse);
    await mirror.delete(local.id); // 不存在不算错
  });

  test('IoBackupFolderMirror：iCloud 没下载的副本计数，别的目录忽略，文件夹没了报不可用', () async {
    final String folder = p.join(tmp.path, 'folder');
    final Directory evicted = Directory(
      p.join(folder, '20261120-000000-000-fushi-scheduled'),
    )..createSync(recursive: true);
    File(
      p.join(evicted.path, '.$kRestorePointMetaFileName.icloud'),
    ).writeAsStringSync('');
    Directory(p.join(folder, 'Photos')).createSync();
    final MirrorFolderListing listing = await IoBackupFolderMirror(
      folder,
    ).list();
    expect(listing.points, isEmpty);
    expect(listing.notDownloaded, 1);
    await expectLater(
      IoBackupFolderMirror(p.join(tmp.path, 'gone')).list(),
      throwsA(isA<BackupFolderUnavailableException>()),
    );
  });

  test('保留：只修剪本机写的副本，别的设备 / 没设备标记的不动，刚复制的那份永不删', () {
    final DateTime now = DateTime.utc(2026, 11, 25, 12);
    final List<MirroredRestorePoint> copies = <MirroredRestorePoint>[
      // 本机：同一天（48 小时以外）的三份，日桶只留最新一份。
      _copy('own-a', DateTime.utc(2026, 11, 20, 1), 'me'),
      _copy('own-b', DateTime.utc(2026, 11, 20, 5), 'me'),
      _copy('own-c', DateTime.utc(2026, 11, 20, 9), 'me'),
      _copy('own-new', DateTime.utc(2026, 11, 25, 11), 'me'),
      // 别的设备同一天的两份、没有设备标记的老副本：一份都不碰。
      _copy('other-a', DateTime.utc(2026, 11, 20, 2), 'phone-2'),
      _copy('other-b', DateTime.utc(2026, 11, 20, 3), 'phone-2'),
      _copy('legacy', DateTime.utc(2025, 1, 1), null),
    ];
    final List<String> doomed = <String>[
      for (final MirroredRestorePoint c in planMirrorRetention(
        copies,
        deviceId: 'me',
        now: now,
        protectId: 'own-a',
      ))
        c.id,
    ];
    expect(doomed, unorderedEquals(<String>['own-b']));
  });

  test('copyMirroredPointToStore：文件不全时不留半截点', () async {
    final String folder = p.join(tmp.path, 'folder');
    final RestorePoint local = _localPoint(
      folder,
      '20261125-010000-000-fushi-scheduled',
      DateTime.utc(2026, 11, 25, 1),
    );
    // 元数据说 zip 有 4 字节，文件夹里实际只剩 1 字节。
    File(
      p.join(folder, local.id, kRestorePointArchiveFileName),
    ).writeAsStringSync('z');
    final MirroredRestorePoint copy = (await IoBackupFolderMirror(
      folder,
    ).list()).points.single;
    final String db = p.join(tmp.path, 'db');
    Directory(db).createSync();
    final RestorePointStore store = RestorePointStore(db);
    await expectLater(
      copyMirroredPointToStore(IoBackupFolderMirror(folder), copy, store),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.list(), isEmpty);
    expect(
      Directory(p.join(db, '.restore_point_download')).existsSync(),
      isFalse,
    );
  });

  group('Android SAF 半边的 Dart 契约', () {
    const MethodChannel channel = MethodChannel('test/backup_folder');
    final List<MethodCall> calls = <MethodCall>[];
    Object? Function(MethodCall call) reply = (MethodCall _) => null;

    setUp(() {
      calls.clear();
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return reply(call);
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('pick → 句柄 + 显示名；取消 → null', () async {
      const AndroidSafBackupFolderPlatform platform =
          AndroidSafBackupFolderPlatform(channel);
      reply = (MethodCall _) => <String, Object?>{
        'tree': 'content://tree/primary%3ABackups',
        'label': 'Backups',
      };
      final AutoBackupMirrorFolder folder = (await platform.pick())!;
      expect(folder.handle, 'content://tree/primary%3ABackups');
      expect(folder.label, 'Backups');
      reply = (MethodCall _) => null;
      expect(await platform.pick(), isNull);
    });

    test('check 失败 / UNAVAILABLE → 文件夹不可用', () async {
      const AndroidSafBackupFolderPlatform platform =
          AndroidSafBackupFolderPlatform(channel);
      const AutoBackupMirrorFolder folder = AutoBackupMirrorFolder(
        handle: 'content://tree/x',
        label: 'X',
      );
      reply = (MethodCall _) => false;
      await expectLater(
        platform.open(folder),
        throwsA(isA<BackupFolderUnavailableException>()),
      );
      reply = (MethodCall call) => call.method == 'check'
          ? true
          : throw PlatformException(code: 'UNAVAILABLE', message: 'revoked');
      final BackupFolderSession session = await platform.open(folder);
      await expectLater(
        session.mirror.list(),
        throwsA(isA<BackupFolderUnavailableException>()),
      );
    });

    test('list / upload / download / delete 的参数形态', () async {
      final SafBackupFolderMirror mirror = SafBackupFolderMirror(
        'content://tree/x',
        channel: channel,
      );
      final RestorePoint local = _localPoint(
        tmp.path,
        '20261125-010000-000-fushi-scheduled',
        DateTime.utc(2026, 11, 25, 1),
      );
      final String meta = mirrorMetaText(local, deviceId: 'd', deviceName: 'n');
      reply = (MethodCall call) => call.method == 'list'
          ? <Object?>[
              <String, Object?>{'name': local.id, 'meta': meta},
              <String, Object?>{'name': 'junk', 'meta': 'not json'},
            ]
          : null;
      final MirrorFolderListing listing = await mirror.list();
      expect(listing.points.single.id, local.id);
      expect(listing.points.single.point.deviceId, 'd');

      await mirror.upload(local, metaText: meta);
      final MethodCall upload = calls.firstWhere(
        (MethodCall c) => c.method == 'upload',
      );
      final Map<Object?, Object?> args =
          upload.arguments as Map<Object?, Object?>;
      expect(args['tree'], 'content://tree/x');
      expect(args['dir'], local.id);
      expect(args['metaName'], kRestorePointMetaFileName);
      expect(args['metaText'], meta);
      expect(args['files'], <Object?>[
        <String, Object?>{
          'name': kRestorePointArchiveFileName,
          'path': p.join(local.directory, kRestorePointArchiveFileName),
        },
      ]);

      await mirror.download(listing.points.single, '/dest');
      final Map<Object?, Object?> down =
          calls.last.arguments as Map<Object?, Object?>;
      expect(calls.last.method, 'download');
      expect(down['files'], <Object?>[kRestorePointArchiveFileName]);
      expect(down['destDir'], '/dest');

      await mirror.delete(local.id);
      expect(calls.last.method, 'delete');
      expect((calls.last.arguments as Map<Object?, Object?>)['dir'], local.id);
    });
  });

  test('iOS：书签激活后经 dart:io 读写，用完停掉；书签过期交回新书签；拒绝访问 → 不可用', () async {
    final String folder = p.join(tmp.path, 'icloud');
    Directory(folder).createSync();
    final _FakeBookmarks bookmarks = _FakeBookmarks(folder);
    final IosBookmarkBackupFolderPlatform platform =
        IosBookmarkBackupFolderPlatform(bookmarks);
    final AutoBackupMirrorFolder picked = (await platform.pick())!;
    expect(picked.label, 'icloud');
    expect(picked.handle, 'bm-1');

    bookmarks.stale = true;
    final BackupFolderSession session = await platform.open(picked);
    expect(session.mirror, isA<IoBackupFolderMirror>());
    expect(session.refreshedFolder?.handle, 'bm-2');
    expect((await session.mirror.list()).points, isEmpty);
    await session.close();
    await session.close();
    expect(bookmarks.stopped, <String>[folder]);

    bookmarks.deny = true;
    await expectLater(
      platform.open(picked),
      throwsA(isA<BackupFolderUnavailableException>()),
    );
  });

  test('IoBackupFolderMirror.list：一份读不了只跳过它；不像还原点 id 的目录不列', () async {
    final String folder = p.join(tmp.path, 'folder');
    final RestorePoint good = _localPoint(
      folder,
      '20261125-010000-000-fushi-scheduled',
      DateTime.utc(2026, 11, 25, 1),
    );
    // 元数据不是 UTF-8：readAsString 抛 FileSystemException。
    final Directory bad = Directory(
      p.join(folder, '20261125-020000-000-fushi-scheduled'),
    )..createSync();
    File(
      p.join(bad.path, kRestorePointMetaFileName),
    ).writeAsBytesSync(<int>[0xff, 0xfe, 0xfd]);
    // 名字不对的目录（例如用户自己的文件夹、`..` 形状）即使有合法元数据也不列。
    final Directory odd = Directory(p.join(folder, 'my-backup'))..createSync();
    File(p.join(odd.path, kRestorePointMetaFileName)).writeAsStringSync(
      File(
        p.join(good.directory, kRestorePointMetaFileName),
      ).readAsStringSync(),
    );
    final MirrorFolderListing listing = await IoBackupFolderMirror(
      folder,
    ).list();
    expect(listing.points.map((MirroredRestorePoint c) => c.id), <String>[
      good.id,
    ]);
  });

  test('外来 id：取回 / 删除拒收 `..` 之类，不会逃出存储根', () async {
    final RestorePointStore store = RestorePointStore(p.join(tmp.path, 'db'));
    final IoBackupFolderMirror mirror = IoBackupFolderMirror(
      p.join(tmp.path, 'folder'),
    );
    Directory(mirror.root).createSync(recursive: true);
    final Directory victim = Directory(p.join(tmp.path, 'db', 'victim'))
      ..createSync(recursive: true);
    for (final String id in <String>['..', '.', '../victim', 'victim']) {
      final MirroredRestorePoint copy = _copy(id, DateTime.utc(2026), 'x');
      await expectLater(
        copyMirroredPointToStore(mirror, copy, store),
        throwsA(isA<ArgumentError>()),
        reason: id,
      );
      await expectLater(
        mirror.delete(id),
        throwsA(isA<ArgumentError>()),
        reason: id,
      );
    }
    expect(victim.existsSync(), isTrue);
  });

  test('取回本机的元数据带 copiedBackAtMs，其余字段原样', () {
    final String text = copiedBackMetaText(
      '{"kind":"scheduled","deviceId":"d","extra":1}',
      42,
    );
    final Map<String, Object?> json = jsonDecode(text) as Map<String, Object?>;
    expect(json['copiedBackAtMs'], 42);
    expect(json['deviceId'], 'd');
    expect(json['extra'], 1);
  });

  group('云端副本：SyncAssetStoreBackupMirror', () {
    late FakeAssetStore store;
    late SyncAssetStoreBackupMirror mine;

    SyncAssetStoreBackupMirror mirrorFor(String device) =>
        SyncAssetStoreBackupMirror(
          store: store,
          namespace: () => store.ensureNamespace(kCloudBackupNamespace),
          deviceFolder: device,
        );

    setUp(() {
      store = FakeAssetStore(reportNullSizes: true);
      mine = mirrorFor('dev-a');
    });

    test('上传 → 列出（跨设备目录）→ 取回 → 删除；元数据最后写', () async {
      final RestorePoint local = _localPoint(
        p.join(tmp.path, 'store'),
        '20261125-010000-000-fushi-scheduled',
        DateTime.utc(2026, 11, 25, 1),
      );
      await mine.upload(
        local,
        metaText: mirrorMetaText(local, deviceId: 'dev-a', deviceName: 'A'),
      );
      final RestorePoint other = _localPoint(
        p.join(tmp.path, 'store_b'),
        '20261125-020000-000-fushi-scheduled',
        DateTime.utc(2026, 11, 25, 2),
      );
      await mirrorFor('dev-b').upload(
        other,
        metaText: mirrorMetaText(other, deviceId: 'dev-b', deviceName: 'B'),
      );
      final MirrorFolderListing listing = await mine.list();
      expect(listing.points.map((MirroredRestorePoint c) => c.id), <String>[
        other.id,
        local.id,
      ]);
      final String dest = p.join(tmp.path, 'dest');
      Directory(dest).createSync();
      await mine.download(listing.points.last, dest);
      expect(
        File(p.join(dest, kRestorePointArchiveFileName)).readAsStringSync(),
        'zzzz',
      );
      // 删别的设备的副本（还原点页）：本机目录里没有就去别的设备目录找。
      await mine.delete(other.id);
      // 删不存在的不算错，也不调后端删除（FTP 删不存在的会抛）。
      await mine.delete('20200101-000000-000-fushi-scheduled');
      expect(
        (await mine.list()).points.map((MirroredRestorePoint c) => c.id),
        <String>[local.id],
      );
    });

    test('没写完元数据的目录不列；坏的一份只跳过它', () async {
      final String ns = await store.ensureNamespace(kCloudBackupNamespace);
      final String dev = await store.ensureFolder(ns, 'dev-a');
      final String half = await store.ensureFolder(
        dev,
        '20261125-030000-000-fushi-scheduled',
      );
      final File zip = File(p.join(tmp.path, 'z.zip'))..writeAsStringSync('z');
      await store.putAsset(half, kRestorePointArchiveFileName, zip);
      final String broken = await store.ensureFolder(
        dev,
        '20261125-040000-000-fushi-scheduled',
      );
      await store.putBytesAsset(
        broken,
        kRestorePointMetaFileName,
        Uint8List.fromList(<int>[0xff, 0xfe]),
      );
      expect((await mine.list()).points, isEmpty);
    });

    test('后端异常按宿主规则归成错误码，原文不外传；本机文件不见了是 copy_local_io', () async {
      final SyncAssetStoreBackupMirror failing = SyncAssetStoreBackupMirror(
        store: store,
        namespace: () async =>
            throw const SocketException('https://user:secret@example/dav'),
        deviceFolder: 'dev-a',
        classify: (Object e) => e is SocketException
            ? kBackupMirrorErrorCloudUnreachable
            : kBackupMirrorErrorCloudFailed,
      );
      await expectLater(
        failing.list(),
        throwsA(
          isA<BackupMirrorException>()
              .having(
                (BackupMirrorException e) => e.code,
                'code',
                kBackupMirrorErrorCloudUnreachable,
              )
              .having(
                (BackupMirrorException e) => '$e',
                'text',
                isNot(contains('secret')),
              ),
        ),
      );
      final RestorePoint local = _localPoint(
        p.join(tmp.path, 'gone'),
        '20261125-050000-000-fushi-scheduled',
        DateTime.utc(2026, 11, 25, 5),
      );
      File(p.join(local.directory, kRestorePointArchiveFileName)).deleteSync();
      await expectLater(
        mine.upload(local, metaText: '{}'),
        throwsA(
          isA<BackupMirrorException>().having(
            (BackupMirrorException e) => e.code,
            'code',
            kBackupMirrorErrorLocalIo,
          ),
        ),
      );
    });

    test('被打断后重传：先删旧元数据，中途看起来不完整', () async {
      final RestorePoint local = _localPoint(
        p.join(tmp.path, 'store'),
        '20261125-060000-000-fushi-scheduled',
        DateTime.utc(2026, 11, 25, 6),
      );
      final String meta = mirrorMetaText(
        local,
        deviceId: 'dev-a',
        deviceName: 'A',
      );
      await mine.upload(local, metaText: meta);
      store.failPutAsset = true;
      await expectLater(
        mine.upload(local, metaText: meta),
        throwsA(isA<BackupMirrorException>()),
      );
      expect((await mine.list()).points, isEmpty);
      store.failPutAsset = false;
      await mine.upload(local, metaText: meta);
      expect((await mine.list()).points.single.id, local.id);
    });
  });

  test(
    'IoBackupFolderMirror.list：目录在、元数据读不出来的记进 unreadable，没有元数据的不记',
    () async {
      final String folder = p.join(tmp.path, 'folder');
      _localPoint(
        folder,
        '20261125-010000-000-fushi-scheduled',
        DateTime.utc(2026, 11, 25, 1),
      );
      Directory bare(String id) =>
          Directory(p.join(folder, id))..createSync(recursive: true);
      // 元数据坏了（解析不出还原点）。
      final Directory broken = bare('20261125-020000-000-fushi-scheduled');
      File(
        p.join(broken.path, kRestorePointMetaFileName),
      ).writeAsStringSync('{');
      // 元数据还在 iCloud 上（占位）。
      final Directory cloudOnly = bare('20261125-030000-000-fushi-scheduled');
      File(
        p.join(cloudOnly.path, '.$kRestorePointMetaFileName.icloud'),
      ).writeAsStringSync('');
      // 元数据不是 UTF-8。
      final Directory garbled = bare('20261125-040000-000-fushi-scheduled');
      File(
        p.join(garbled.path, kRestorePointMetaFileName),
      ).writeAsBytesSync(<int>[0xff, 0xfe, 0xfd]);
      // 真的半截（只有 zip，没有元数据）。
      final Directory half = bare('20261125-050000-000-fushi-scheduled');
      File(
        p.join(half.path, kRestorePointArchiveFileName),
      ).writeAsStringSync('z');
      final MirrorFolderListing listing = await IoBackupFolderMirror(
        folder,
      ).list();
      expect(listing.points, hasLength(1));
      expect(listing.notDownloaded, 1);
      expect(listing.unreadable, <String>{
        p.basename(broken.path),
        p.basename(cloudOnly.path),
        p.basename(garbled.path),
      });
    },
  );

  group('云端副本：读不了的副本与目录', () {
    late _FlakyStore store;

    SyncAssetStoreBackupMirror mirrorFor(String device) =>
        SyncAssetStoreBackupMirror(
          store: store,
          namespace: () => store.ensureNamespace(kCloudBackupNamespace),
          deviceFolder: device,
        );

    setUp(() => store = _FlakyStore());

    Future<String> upload(String device, String id, int hour) async {
      final RestorePoint local = _localPoint(
        p.join(tmp.path, 'store_$device'),
        id,
        DateTime.utc(2026, 11, 25, hour),
      );
      await mirrorFor(device).upload(
        local,
        metaText: mirrorMetaText(local, deviceId: device, deviceName: device),
      );
      return '$kCloudBackupNamespace/$device/$id';
    }

    test('元数据这一步出错 / 坏了：记进 unreadable；没有元数据的半截不记', () async {
      const String readFails = '20261125-010000-000-fushi-scheduled';
      const String good = '20261125-020000-000-fushi-scheduled';
      final String failingDir = await upload('dev-a', readFails, 1);
      await upload('dev-a', good, 2);
      store.failGet.add('$failingDir/$kRestorePointMetaFileName');
      final String ns = await store.ensureNamespace(kCloudBackupNamespace);
      final String dev = await store.ensureFolder(ns, 'dev-a');
      final String broken = await store.ensureFolder(
        dev,
        '20261125-030000-000-fushi-scheduled',
      );
      await store.putBytesAsset(
        broken,
        kRestorePointMetaFileName,
        Uint8List.fromList(<int>[0xff, 0xfe]),
      );
      await store.ensureFolder(dev, '20261125-040000-000-fushi-scheduled');
      final MirrorFolderListing listing = await mirrorFor('dev-a').list();
      expect(listing.points.map((MirroredRestorePoint c) => c.id), <String>[
        good,
      ]);
      expect(listing.unreadable, <String>{
        readFails,
        '20261125-030000-000-fushi-scheduled',
      });
    });

    test('别的设备的目录列不出来只跳过它；本机的目录列不出来整份列表失败', () async {
      await upload('dev-a', '20261125-010000-000-fushi-scheduled', 1);
      await upload('dev-b', '20261125-020000-000-fushi-scheduled', 2);
      store.failList.add('$kCloudBackupNamespace/dev-b');
      expect(
        (await mirrorFor(
          'dev-a',
        ).list()).points.map((MirroredRestorePoint c) => c.id),
        <String>['20261125-010000-000-fushi-scheduled'],
      );
      await expectLater(
        mirrorFor('dev-b').list(),
        throwsA(isA<BackupMirrorException>()),
      );
    });
  });

  test('SAF：原生报读不了的副本记进 unreadable，元数据坏了的也算', () async {
    const MethodChannel channel = MethodChannel(
      'test/backup_folder_unreadable',
    );
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          return <Object?>[
            <String, Object?>{
              'name': '20261125-010000-000-fushi-scheduled',
              'unreadable': true,
            },
            <String, Object?>{
              'name': '20261125-020000-000-fushi-scheduled',
              'meta': '{',
            },
            <String, Object?>{'name': '../x', 'unreadable': true},
          ];
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final MirrorFolderListing listing = await SafBackupFolderMirror(
      'content://tree/x',
      channel: channel,
    ).list();
    expect(listing.points, isEmpty);
    expect(listing.unreadable, <String>{
      '20261125-010000-000-fushi-scheduled',
      '20261125-020000-000-fushi-scheduled',
    });
  });

  test('云端目标键：换账号 / 服务器就换键，原始身份不出现在键里；查不出身份只用类型', () {
    final String a = cloudBackupTargetKey('webDav', 'https://dav.a|alice');
    final String b = cloudBackupTargetKey('webDav', 'https://dav.a|bob');
    expect(a, isNot(b));
    expect(a, cloudBackupTargetKey('webDav', 'https://dav.a|alice'));
    expect(a, startsWith('cloud-webDav-'));
    expect(a, isNot(contains('alice')));
    expect(a, isNot(contains('dav.a')));
    expect(
      cloudBackupTargetKey('dropbox', 'a@example.com'),
      isNot(cloudBackupTargetKey('googleDrive', 'a@example.com')),
    );
    expect(cloudBackupTargetKey('dropbox', null), 'cloud-dropbox');
    expect(cloudBackupTargetKey('dropbox', '  '), 'cloud-dropbox');
  });

  test('云端错误文字归类：限流是连不上（稍后再试），只有空间满了才是配额', () {
    for (final String rateLimited in <String>[
      'DetailedApiRequestError(status: 403, message: Quota exceeded for quota '
          "metric 'Queries' and limit 'Queries per minute')",
      'DetailedApiRequestError(status: 403, message: User Rate Limit Exceeded)',
      '403 {"reason": "rateLimitExceeded"}',
      'HTTP 429 Too Many Requests',
      'Dropbox upload session finish failed: 409 too_many_write_operations',
    ]) {
      expect(
        classifyCloudBackupErrorText(rateLimited),
        kBackupMirrorErrorCloudUnreachable,
        reason: rateLimited,
      );
    }
    for (final String full in <String>[
      "DetailedApiRequestError(status: 403, message: The user's Drive storage "
          'quota has been exceeded.)',
      '403 {"reason": "storageQuotaExceeded"}',
      'Dropbox upload failed: 409 {"error": {".tag": "path", "path": '
          '{".tag": "insufficient_space"}}}',
      'WebDAV PUT failed: HTTP 507 Insufficient Storage',
      '552 Exceeded storage allocation',
    ]) {
      expect(
        classifyCloudBackupErrorText(full),
        kBackupMirrorErrorCloudQuota,
        reason: full,
      );
    }
    expect(
      classifyCloudBackupErrorText('500 Internal Server Error'),
      kBackupMirrorErrorCloudFailed,
    );
  });

  test('SAF：原生错误码 → 已知原因，不带原文；提供者给的怪名字不列', () async {
    const MethodChannel channel = MethodChannel('test/backup_folder_codes');
    TestWidgetsFlutterBinding.ensureInitialized();
    String code = 'NOT_FOUND';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'list') {
            return <Object?>[
              <String, Object?>{'name': '..', 'meta': '{}'},
              <String, Object?>{'name': '../x', 'meta': '{}'},
            ];
          }
          if (call.method == 'networkUnmetered') return true;
          throw PlatformException(code: code, message: 'content://secret');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final SafBackupFolderMirror mirror = SafBackupFolderMirror(
      'content://tree/x',
      channel: channel,
    );
    expect((await mirror.list()).points, isEmpty);
    final MirroredRestorePoint copy = _copy(
      '20261125-010000-000-fushi-scheduled',
      DateTime.utc(2026),
      'x',
    );
    for (final (String native, String expected) in <(String, String)>[
      ('NOT_FOUND', kBackupMirrorErrorNotFound),
      ('LOCAL_IO', kBackupMirrorErrorLocalIo),
      ('UNSUPPORTED', kBackupMirrorErrorUnsupported),
      ('RENAMED', kBackupMirrorErrorRenamed),
      ('LOADING', kBackupMirrorErrorLoading),
      ('INTERNAL', kBackupMirrorErrorFailed),
    ]) {
      code = native;
      await expectLater(
        mirror.download(copy, tmp.path),
        throwsA(
          isA<BackupMirrorException>().having(
            (BackupMirrorException e) => e.code,
            native,
            expected,
          ),
        ),
      );
    }
    code = 'UNAVAILABLE';
    await expectLater(
      mirror.delete(copy.id),
      throwsA(isA<BackupFolderUnavailableException>()),
    );
    expect(() => mirror.delete('..'), throwsArgumentError);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(await currentNetworkUnmetered(channel: channel), isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(await currentNetworkUnmetered(channel: channel), isTrue);
  });
}

class _FakeBookmarks implements SourceFolderBookmarks {
  _FakeBookmarks(this.path);

  final String path;
  bool stale = false;
  bool deny = false;
  final List<String> stopped = <String>[];

  @override
  Future<SourceFolderBookmarkPick?> pickDirectoryBookmark() async =>
      SourceFolderBookmarkPick(path: path, bookmark: 'bm-1');

  @override
  Future<SourceFolderGrant> startAccessingBookmark(String bookmark) async {
    if (deny) {
      throw const SourceFolderAccessException('ACCESS_DENIED', 'denied');
    }
    return SourceFolderGrant(
      path: path,
      stale: stale,
      refreshedBookmark: stale ? 'bm-2' : null,
    );
  }

  @override
  Future<void> stopAccessingBookmark(String path) async => stopped.add(path);
}
