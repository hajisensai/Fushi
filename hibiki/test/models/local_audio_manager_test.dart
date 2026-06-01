import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  late HibikiDatabase db;
  late PreferencesRepository prefs;
  late Directory directory;
  late LocalAudioManager manager;

  setUp(() async {
    db = _testDb();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    directory = Directory.systemTemp.createTempSync('hibiki_local_audio_mgr');
    manager = LocalAudioManager(
      prefsRepo: prefs,
      databaseDirectory: directory,
    );
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  test('reorder persists source order', () async {
    await manager.setEntries(const <LocalAudioDbEntry>[
      LocalAudioDbEntry(path: '/tmp/one.db', displayName: 'one'),
      LocalAudioDbEntry(path: '/tmp/two.db', displayName: 'two'),
      LocalAudioDbEntry(path: '/tmp/three.db', displayName: 'three'),
    ]);

    await manager.reorder(0, 3);

    expect(
      manager.entries.map((LocalAudioDbEntry entry) => entry.displayName),
      <String>['two', 'three', 'one'],
    );
  });

  test('reorder ignores out-of-range indexes', () async {
    await manager.setEntries(const <LocalAudioDbEntry>[
      LocalAudioDbEntry(path: '/tmp/one.db', displayName: 'one'),
      LocalAudioDbEntry(path: '/tmp/two.db', displayName: 'two'),
    ]);
    final String before = prefs.getPref('local_audio_dbs', defaultValue: '');

    await manager.reorder(-1, 0);
    await manager.reorder(0, 9);

    expect(prefs.getPref('local_audio_dbs', defaultValue: ''), before);
    expect(
      jsonDecode(before) as List<dynamic>,
      hasLength(2),
    );
  });
}
