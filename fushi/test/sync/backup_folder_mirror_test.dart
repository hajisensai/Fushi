import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_folder_access.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_platform.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

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
