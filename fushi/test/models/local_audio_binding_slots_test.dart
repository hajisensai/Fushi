import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/local_audio_manager.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/misc/local_audio_db.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late Directory root;
  late String present;
  late LocalAudioManager manager;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    root = Directory.systemTemp.createTempSync('local_audio_binding_');
    present = path.join(root.path, 'present.db');
    final sqlite.Database audio = sqlite.sqlite3.open(present);
    audio.execute('CREATE TABLE entries '
        '(expression TEXT, reading TEXT, file TEXT, source TEXT)');
    audio.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
    audio.execute("INSERT INTO entries VALUES ('cat', '', 'cat.mp3', 'valid')");
    audio.execute("INSERT INTO android VALUES ('cat.mp3', 'valid', X'010203')");
    audio.dispose();
    manager = LocalAudioManager(prefsRepo: prefs, databaseDirectory: root);
  });

  tearDown(() async {
    await LocalAudioDb.waitForPendingIndexing(present);
    await TtsChannel.instance.setLocalAudioDbs(<LocalAudioDbConfig>[]);
    prefs.dispose();
    await db.close();
    root.deleteSync(recursive: true);
  });

  Future<void> bind(List<LocalAudioDbEntry> entries) async {
    await prefs.setPref('local_audio_dbs',
        jsonEncode(entries.map((LocalAudioDbEntry e) => e.toJson()).toList()));
    await manager.bindForNativeHandler();
  }

  test('missing first enabled DB retains its index before a working DB',
      () async {
    await bind(<LocalAudioDbEntry>[
      LocalAudioDbEntry(
        path: path.join(root.path, 'missing.db'),
        displayName: 'missing',
        enabled: true,
      ),
      LocalAudioDbEntry(path: present, displayName: 'valid', enabled: true),
    ]);
    expect(await TtsChannel.instance.queryLocalAudio('cat', '', dbIndex: 0),
        isNull);
    final Map<String, dynamic>? found =
        await TtsChannel.instance.queryLocalAudio('cat', '', dbIndex: 1);
    expect(found?['source'], 'valid');
    expect(found?['dbIndex'], 1);
  });

  test('disabled sources do not consume enabled-source indices', () async {
    await bind(<LocalAudioDbEntry>[
      LocalAudioDbEntry(
          path: path.join(root.path, 'disabled.db'), displayName: 'off'),
      LocalAudioDbEntry(path: present, displayName: 'valid', enabled: true),
    ]);
    expect(
        (await TtsChannel.instance
            .queryLocalAudio('cat', '', dbIndex: 0))?['source'],
        'valid');
  });

  for (final bool removed in <bool>[true, false]) {
    test('warm rebind clears previous DB when removed=$removed', () async {
      await bind(<LocalAudioDbEntry>[
        LocalAudioDbEntry(path: present, displayName: 'valid', enabled: true),
      ]);
      expect(await TtsChannel.instance.queryLocalAudio('cat', ''), isNotNull);
      await bind(<LocalAudioDbEntry>[
        if (!removed) LocalAudioDbEntry(path: present, displayName: 'off'),
      ]);
      expect(await TtsChannel.instance.queryLocalAudio('cat', ''), isNull);
    });
  }

  test('native binding allocates slots before failure and consumes null safely',
      () {
    final String java = File(
      'android/app/src/main/java/app/fushi/reader/TtsChannelHandler.java',
    ).readAsStringSync();
    final int start = java.indexOf('for (String dbPath : paths)');
    expect(start, isNonNegative);
    final String loop =
        java.substring(start, java.indexOf('indexFuture =', start));
    expect(loop.indexOf('localAudioDbs.add(null)'),
        lessThan(loop.indexOf('if (dbPath == null')));
    expect(loop, contains('localAudioDbs.set(slot, db)'));
    expect(loop, isNot(contains('localAudioDbs.add(db)')));
    expect(loop, contains('indexTargets.add(dbPath)'));
    final String query = java.substring(
      java.indexOf('private void handleQueryLocalAudio('),
      java.indexOf('private static String[] pickByOrder('),
    );
    expect(query, contains('if (db == null || !db.isOpen()) continue'));
    final String extract = java.substring(
      java.indexOf('private void handleExtractLocalAudio('),
      java.indexOf('private static String localAudioCacheKey('),
    );
    expect(extract, contains('if (db == null || !db.isOpen())'));
    final String close =
        java.substring(java.indexOf('private void closeAllAudioDbsLocked()'));
    expect(close, contains('if (db != null && db.isOpen())'));
  });
}
