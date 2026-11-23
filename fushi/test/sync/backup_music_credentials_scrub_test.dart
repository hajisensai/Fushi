import 'dart:io';

import 'package:drift/drift.dart' show QueryRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-5290：备份里的播放流快照可能带旧版本落的服务器凭据。迁移（< v172）会清洗，但同版本
/// / 外来拼出的备份不走迁移——覆盖恢复与合并导入之后都得再清洗，旧备份不能把凭据带回来。
const String _token = 'JF-SECRET-TOKEN-1234';
const String _streamUrl =
    'http://nas:8096/Audio/Tr-1/stream?static=true&DeviceId=d&api_key=$_token';
const String _coverUrl =
    'http://nas:8096/Items/Al-1/Images/Primary?maxWidth=400&api_key=$_token';
const String _ssUrl =
    'https://music.example.com/rest/stream?u=listener&s=salt&t=deadbeefcafe&id=42';

Future<String> _backupWithCredentialedRows(Directory root) async {
  final String dbDir = p.join(root.path, 'support');
  Directory(dbDir).createSync(recursive: true);
  final FushiDatabase src = FushiDatabase(dbDir);
  // 绕过写入守门：模拟旧版本落库 / 手工拼出的同版本备份。
  await src.customStatement(
    'INSERT INTO music_play_events (track_uid, started_at, listened_ms, '
    'completed, path, cover_path, title, source_kind, source_id, source_cover) '
    "VALUES ('srvjf', 10, 0, 0, '$_streamUrl', '$_coverUrl', 'jf', "
    "'server_album', 'jellyfin:x/Al-1', '$_coverUrl')",
  );
  await src.customStatement(
    'INSERT INTO music_play_events (track_uid, started_at, listened_ms, '
    "completed, path, title) VALUES ('srvss', 20, 0, 0, '$_ssUrl', 'ss')",
  );
  final String zip = p.join(root.path, 'music.zip');
  await BackupService(
    db: src,
    dbDirectory: dbDir,
    appVersion: '3.0.0',
  ).createBackup(zip);
  await src.close();
  return zip;
}

Future<void> _expectScrubbed(String dbDir) async {
  final FushiDatabase db = FushiDatabase(dbDir);
  addTearDown(db.close);
  final List<QueryRow> rows = await db
      .customSelect(
        'SELECT track_uid, path, cover_path, source_cover '
        'FROM music_play_events ORDER BY started_at',
      )
      .get();
  expect(rows, hasLength(2));
  for (final QueryRow r in rows) {
    for (final String c in <String>['path', 'cover_path', 'source_cover']) {
      final String? v = r.read<String?>(c);
      if (v == null) continue;
      expect(v, isNot(contains(_token)), reason: '$c: $v');
      expect(v, isNot(contains('deadbeefcafe')), reason: '$c: $v');
      expect(musicUrlCarriesCredentials(v), isFalse, reason: '$c: $v');
    }
  }
  expect(parseMusicServerRef(rows[0].read<String?>('path'))?.id, 'Tr-1');
  expect(
    parseMusicServerRef(rows[0].read<String?>('source_cover'))?.serverId,
    'jellyfin:x',
  );
  expect(parseMusicServerRef(rows[1].read<String?>('path'))?.id, '42');
}

void main() {
  test('合并导入：备份里带凭据的播放流快照合进来就被清洗', () async {
    final Directory srcRoot = await Directory.systemTemp.createTemp('mcs_src_');
    addTearDown(() => cleanupTempDir(srcRoot));
    final String zip = await _backupWithCredentialedRows(srcRoot);

    final Directory curRoot = await Directory.systemTemp.createTemp('mcs_cur_');
    addTearDown(() => cleanupTempDir(curRoot));
    final String curDir = p.join(curRoot.path, 'support');
    Directory(curDir).createSync(recursive: true);
    await FushiDatabase(curDir).close();

    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: curDir,
      zipPath: zip,
    );
    await _expectScrubbed(curDir);
  });

  test('覆盖恢复（全新安装）：恢复进来的库同样被清洗', () async {
    final Directory srcRoot = await Directory.systemTemp.createTemp('mcs_src_');
    addTearDown(() => cleanupTempDir(srcRoot));
    final String zip = await _backupWithCredentialedRows(srcRoot);

    final Directory curRoot = await Directory.systemTemp.createTemp('mcs_rst_');
    addTearDown(() => cleanupTempDir(curRoot));
    final String curDir = p.join(curRoot.path, 'support');
    Directory(curDir).createSync(recursive: true);

    await BackupRestoreService.restoreBackup(dbDirectory: curDir, zipPath: zip);
    await _expectScrubbed(curDir);
  });
}
