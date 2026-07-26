import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// TODO-1171: after importing a backup on another machine, single-word local
/// audio silently stopped playing because the stored source paths kept the
/// SOURCE machine's absolute prefix. Prefs are PrefCodec-tagged in production
/// (local_audio_dbs -> s:<json>, audio_source_configs -> j:<json>), but the old
/// rebase json-decoded the whole tagged string and silently no-op'd. The fix
/// (a) strips/re-applies the tag and (b) re-homes BOTH prefs by FILENAME.
void main() {
  group('pure path-normalization helpers', () {
    test('normalizeLocalAudioDbsJson re-homes internal copies by filename', () {
      final String body = jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'path': r'C:\Users\A\support\local_audio_111.db',
          'displayName': 'Forvo',
          'enabled': true,
        },
        <String, Object?>{
          'path': r'D:\my_dicts\external.db',
          'displayName': 'External',
          'enabled': true,
        },
      ]);
      final List<dynamic> out =
          jsonDecode(normalizeLocalAudioDbsJson(body, '/home/b/support'))
              as List<dynamic>;
      expect((out[0] as Map)['path'],
          p.join('/home/b/support', 'local_audio_111.db'));
      expect((out[1] as Map)['path'], r'D:\my_dicts\external.db');
    });

    test('normalizeAudioSourceConfigsJson only re-homes localAudio entries',
        () {
      final String body = jsonEncode(<Map<String, Object?>>[
        <String, Object?>{'kind': 'hibikiRemote', 'enabled': true},
        <String, Object?>{
          'kind': 'remoteAudio',
          'enabled': true,
          'url': 'http://localhost:8765/get?term={term}',
        },
        <String, Object?>{
          'kind': 'localAudio',
          'enabled': true,
          'label': 'Forvo',
          'path': r'C:\Users\A\support\local_audio_222.db',
        },
      ]);
      final List<dynamic> out =
          jsonDecode(normalizeAudioSourceConfigsJson(body, '/home/b/support'))
              as List<dynamic>;
      expect((out[0] as Map)['kind'], 'hibikiRemote');
      expect((out[1] as Map)['url'], 'http://localhost:8765/get?term={term}');
      expect((out[2] as Map)['path'],
          p.join('/home/b/support', 'local_audio_222.db'));
    });

    test('malformed bodies are returned verbatim', () {
      expect(normalizeLocalAudioDbsJson('not json', '/x'), 'not json');
      expect(normalizeAudioSourceConfigsJson('{oops', '/x'), '{oops');
    });
  });

  group('cross-machine import (production tagged prefs)', () {
    late Directory src;
    late Directory dst;

    setUp(() async {
      src = await Directory.systemTemp.createTemp('la_port_src_');
      dst = await Directory.systemTemp.createTemp('la_port_dst_');
    });
    tearDown(() async {
      for (final Directory d in <Directory>[src, dst]) {
        try {
          if (d.existsSync()) await cleanupTempDir(d);
        } on PathNotFoundException {
          // Windows temp cleanup race.
        }
      }
    });

    Future<void> writeFile(String path, String content) async {
      final File f = File(path);
      f.parent.createSync(recursive: true);
      await f.writeAsString(content);
    }

    test(
        'both local_audio_dbs AND audio_source_configs re-homed by filename '
        'and stay PrefCodec-tagged', () async {
      final String srcDbDir = p.join(src.path, 'db');
      Directory(srcDbDir).createSync(recursive: true);
      final String laPath = p.join(srcDbDir, 'local_audio_111.db');
      await writeFile(laPath, 'FORVO');
      await writeFile('$laPath-wal', 'WAL');

      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      await db.setPref(
        'local_audio_dbs',
        PrefCodec.encode(jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'path': laPath,
            'displayName': 'Forvo',
            'enabled': true,
          },
        ])),
      );
      await db.setPref(
        'audio_source_configs',
        PrefCodec.encode(<Map<String, Object?>>[
          <String, Object?>{'kind': 'hibikiRemote', 'enabled': false},
          <String, Object?>{
            'kind': 'localAudio',
            'enabled': true,
            'label': 'Forvo',
            'path': laPath,
          },
        ]),
      );

      final BackupService service =
          BackupService(db: db, dbDirectory: srcDbDir, appVersion: '1.0.0');
      final String zip = p.join(src.path, 'la.zip');
      await service.createBackup(zip, categories: {BackupCategory.localAudio});
      await db.close();

      final String dstDbDir = p.join(dst.path, 'db');
      Directory(dstDbDir).createSync(recursive: true);
      await BackupService.restoreBackup(dbDirectory: dstDbDir, zipPath: zip);

      expect(File(p.join(dstDbDir, 'local_audio_111.db')).existsSync(), isTrue);

      final HibikiDatabase restored = HibikiDatabase(dstDbDir);
      try {
        final Map<String, String> prefs = await restored.getAllPrefs();
        expect(prefs['local_audio_dbs']!, startsWith('s:'));
        expect(prefs['audio_source_configs']!, startsWith('j:'));

        final List<dynamic> dbs = jsonDecode(
                PrefCodec.decode<String>(prefs['local_audio_dbs']!, '[]'))
            as List<dynamic>;
        final String dbsPath = (dbs.single as Map)['path'] as String;
        expect(dbsPath, startsWith(dstDbDir));
        expect(File(dbsPath).existsSync(), isTrue);

        final List<dynamic> cfgs =
            jsonDecode(prefs['audio_source_configs']!.substring(2))
                as List<dynamic>;
        final Map<String, dynamic> local = cfgs
            .cast<Map<String, dynamic>>()
            .firstWhere((Map<String, dynamic> e) => e['kind'] == 'localAudio');
        expect(local['path'], dbsPath,
            reason:
                'typed config path must match local_audio_dbs after import');
      } finally {
        await restored.close();
      }
    });

    test(
        'BUG-816: unticking localAudio strips the local_audio_dbs registry from '
        'the export (paths are personal) — a fresh import has none', () async {
      final String srcDbDir = p.join(src.path, 'db');
      Directory(srcDbDir).createSync(recursive: true);
      final String laPath = p.join(srcDbDir, 'local_audio_333.db');
      await writeFile(laPath, 'NHK');

      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      await db.setPref(
        'local_audio_dbs',
        PrefCodec.encode(jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'path': laPath,
            'displayName': 'NHK',
            'enabled': true,
          },
        ])),
      );

      final BackupService service =
          BackupService(db: db, dbDirectory: srcDbDir, appVersion: '1.0.0');
      final String zip = p.join(src.path, 'books_only.zip');
      // Empty set = every category unticked, including localAudio → the
      // local-audio registry (which holds this device's absolute `.db` paths)
      // must be stripped from the exported DB copy (BUG-816).
      await service.createBackup(zip, categories: <BackupCategory>{});
      await db.close();

      final String dstDbDir = p.join(dst.path, 'db');
      Directory(dstDbDir).createSync(recursive: true);
      // Fresh device (no current DB), so there is nothing to preserve from bak;
      // the imported registry is simply absent.
      await BackupService.restoreBackup(dbDirectory: dstDbDir, zipPath: zip);

      final HibikiDatabase restored = HibikiDatabase(dstDbDir);
      try {
        final Map<String, String> prefs = await restored.getAllPrefs();
        expect(prefs.containsKey('local_audio_dbs'), isFalse,
            reason:
                'localAudio unticked → registry paths never leave the device');
      } finally {
        await restored.close();
      }
    });
  });
}
