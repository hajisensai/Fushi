import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/server/music_server_download_index.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// 服务器曲目的离线副本（v173）是设备本地的事实：覆盖恢复一份没有这些曲目的备份、或合并
/// 进来的较新一行清了入库时刻，都不许让本机下好的文件丢掉——副本行回灌，曲目放回音乐库，
/// 启动接上库时也只放回、不删文件。
const String _server = 'jellyfin:http://nas:8096|user-1';

MusicRemoteTracksCompanion _remote(
  String uid, {
  required int at,
  required bool inLibrary,
  String title = 'Server title',
}) => MusicRemoteTracksCompanion.insert(
  trackUid: uid,
  kind: 'server',
  sourceKey: _server,
  itemId: 'item-$uid',
  title: title,
  artist: const Value<String?>('Server artist'),
  coverRef: Value<String?>('cover-$uid'),
  libraryAddedAt: Value<int?>(inLibrary ? at : null),
  createdAt: at,
  updatedAt: at,
);

/// 本机：两首服务器曲目在库、都有离线副本（文件真在磁盘上）。返回 uid → 文件。
Future<Map<String, File>> _seedDevice(String dbDir, Directory files) async {
  final FushiDatabase db = FushiDatabase(dbDir);
  final Map<String, File> out = <String, File>{};
  for (final String uid in <String>['srva', 'srvb']) {
    final Directory album = Directory(
      p.join(files.path, 'media-servers', 'Dev [abc123]', 'Album $uid [0a0b]'),
    )..createSync(recursive: true);
    final File f = File(p.join(album.path, '01 Song $uid [1234abcd].flac'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    out[uid] = f;
    await db.recordMusicServerDownload(
      MusicServerDownloadsCompanion.insert(
        trackUid: uid,
        sourceKey: _server,
        itemId: 'item-$uid',
        filePath: f.path,
        downloadedAt: 0,
      ),
      track: _remote(uid, at: 100, inLibrary: true, title: 'Local $uid'),
      at: 100,
    );
  }
  await db.close();
  return out;
}

/// 备份：[remote] 里的远程曲目行（没有离线副本，副本表本就设备本地、不出境）。
Future<String> _backup(
  Directory root,
  List<MusicRemoteTracksCompanion> remote,
) async {
  final String dbDir = p.join(root.path, 'support');
  Directory(dbDir).createSync(recursive: true);
  final FushiDatabase src = FushiDatabase(dbDir);
  for (final MusicRemoteTracksCompanion r in remote) {
    await src.into(src.musicRemoteTracks).insert(r);
  }
  final String zip = p.join(root.path, 'music.zip');
  await BackupService(
    db: src,
    dbDirectory: dbDir,
    appVersion: '3.0.0',
  ).createBackup(zip);
  await src.close();
  return zip;
}

void main() {
  late Directory tmp;
  late String curDir;
  late Directory files;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('musdl_bak_');
    curDir = p.join(tmp.path, 'cur', 'support');
    Directory(curDir).createSync(recursive: true);
    files = Directory(p.join(tmp.path, 'downloads'))..createSync();
  });
  tearDown(() => cleanupTempDir(tmp));

  Future<void> expectBackInLibrary(
    Map<String, File> seeded, {
    required Map<String, String> titles,
  }) async {
    final FushiDatabase db = FushiDatabase(curDir);
    addTearDown(db.close);
    final Map<String, MusicServerDownloadRow> rows = await db
        .listMusicServerDownloadsOf(seeded.keys);
    expect(rows.keys.toSet(), seeded.keys.toSet(), reason: '副本行回灌');
    for (final MapEntry<String, File> e in seeded.entries) {
      expect(e.value.existsSync(), isTrue, reason: '${e.key} 文件还在');
      final MusicRemoteTrackRow? r = await db.getMusicRemoteTrack(e.key);
      expect(r, isNotNull, reason: '${e.key} 远程曲目行在');
      expect(r!.libraryAddedAt, isNotNull, reason: '${e.key} 放回音乐库');
      expect(r.title, titles[e.key]);
      expect(r.sourceKey, _server);
      expect(r.itemId, 'item-${e.key}');
    }
    // 启动接上库：只放回、不删文件。
    final MusicServerDownloadIndex index = MusicServerDownloadIndex();
    addTearDown(index.dispose);
    index.attach(db);
    expect(await index.reconcileIntoLibrary(), 0);
    for (final File f in seeded.values) {
      expect(f.existsSync(), isTrue);
    }
  }

  test('覆盖恢复一份没有这些曲目的备份：副本行回灌，曲目从恢复前的本机库搬回并放回曲库', () async {
    final Map<String, File> seeded = await _seedDevice(curDir, files);
    final String zip = await _backup(
      Directory(p.join(tmp.path, 'src'))..createSync(),
      <MusicRemoteTracksCompanion>[
        // srvb 在备份里，但备份那边早就移出了曲库。
        _remote('srvb', at: 500, inLibrary: false, title: 'Backup srvb'),
      ],
    );

    await BackupRestoreService.restoreBackup(dbDirectory: curDir, zipPath: zip);

    await expectBackInLibrary(
      seeded,
      titles: <String, String>{
        // 备份里没有：恢复前的本机行原样搬回（元数据完整）。
        'srva': 'Local srva',
        // 备份里有：保留备份的行，只把入库时刻填回来。
        'srvb': 'Backup srvb',
      },
    );
  });

  test('合并导入较新的「已移出曲库」行：本机有副本的放回曲库，文件不删', () async {
    final Map<String, File> seeded = await _seedDevice(curDir, files);
    final String zip = await _backup(
      Directory(p.join(tmp.path, 'src'))..createSync(),
      <MusicRemoteTracksCompanion>[
        _remote('srva', at: 900, inLibrary: false, title: 'Merged srva'),
        _remote('srvb', at: 900, inLibrary: false, title: 'Merged srvb'),
      ],
    );

    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: curDir,
      zipPath: zip,
    );

    await expectBackInLibrary(
      seeded,
      titles: <String, String>{'srva': 'Merged srva', 'srvb': 'Merged srvb'},
    );
    // 放回曲库是本机的设备本地修正：不抬 updated_at（不当成新编辑传给别的设备）。
    final FushiDatabase db = FushiDatabase(curDir);
    addTearDown(db.close);
    expect((await db.getMusicRemoteTrack('srva'))!.updatedAt, 900);
  });

  test('远程曲目行整个没了（兜底）：按副本的服务器身份 + 落点文件名重建并入库', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final String path = p.join(
      files.path,
      'media-servers',
      'Dev [abc123]',
      '初恋テスト [0a0b0c0d]',
      '02 Song B [1234abcd].flac',
    );
    await db
        .into(db.musicServerDownloads)
        .insert(
          MusicServerDownloadsCompanion.insert(
            trackUid: 'srvx',
            sourceKey: _server,
            itemId: 'item-x',
            filePath: path,
            downloadedAt: 42,
          ),
        );

    expect(await db.reconcileMusicServerDownloadsIntoLibrary(at: 50), 1);
    final MusicRemoteTrackRow r = (await db.getMusicRemoteTrack('srvx'))!;
    expect(r.kind, 'server');
    expect(r.sourceKey, _server);
    expect(r.itemId, 'item-x');
    expect(r.title, '02 Song B');
    expect(r.album, '初恋テスト');
    expect(r.libraryAddedAt, 42);
    // 幂等。
    expect(await db.reconcileMusicServerDownloadsIntoLibrary(at: 60), 0);
  });
}
