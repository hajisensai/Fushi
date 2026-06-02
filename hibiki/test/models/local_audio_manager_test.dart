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

  test('new local audio DB entries default to disabled', () {
    const LocalAudioDbEntry entry = LocalAudioDbEntry(
      path: '/tmp/off.db',
      displayName: 'off',
    );

    expect(entry.enabled, isFalse);
  });

  test('legacy local audio DB JSON without enabled stays enabled', () {
    expect(
      LocalAudioDbEntry.fromJson(const <String, dynamic>{
        'path': '/tmp/old.db',
        'displayName': 'old',
      }).enabled,
      isTrue,
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

  test('importFile copies into store and does NOT persist prefs', () async {
    final Directory src = await Directory.systemTemp.createTemp('src');
    final File source = File('${src.path}/nhk.db');
    await source.writeAsString('sqlite-bytes');

    final LocalAudioDbEntry entry =
        await manager.importFile(source.path, displayName: 'nhk');

    expect(entry.displayName, 'nhk');
    expect(File(entry.path).existsSync(), isTrue);
    expect(entry.path.startsWith(directory.path), isTrue);
    expect(manager.entries, isEmpty); // not persisted
    await src.delete(recursive: true);
  });

  test('deleteFiles removes db + wal + shm', () async {
    final File dbf = File('${directory.path}/x.db')..writeAsStringSync('a');
    final File wal = File('${directory.path}/x.db-wal')..writeAsStringSync('b');
    final File shm = File('${directory.path}/x.db-shm')..writeAsStringSync('c');

    await LocalAudioManager.deleteFiles(dbf.path);

    expect(dbf.existsSync(), isFalse);
    expect(wal.existsSync(), isFalse);
    expect(shm.existsSync(), isFalse);
  });

  test('pruneOrphans deletes unreferenced local_audio_*.db files only',
      () async {
    // a referenced db we keep
    final File keep = File('${directory.path}/local_audio_1.db')
      ..writeAsStringSync('k');
    // an orphan copied db + sidecars
    final File orphan = File('${directory.path}/local_audio_2.db')
      ..writeAsStringSync('o');
    final File orphanWal = File('${directory.path}/local_audio_2.db-wal')
      ..writeAsStringSync('w');
    // an unrelated file that must NOT be touched
    final File other = File('${directory.path}/hibiki.db')
      ..writeAsStringSync('h');

    await manager.pruneOrphans(<String>[keep.path]);

    expect(keep.existsSync(), isTrue); // referenced -> kept
    expect(orphan.existsSync(), isFalse); // unreferenced -> deleted
    expect(orphanWal.existsSync(), isFalse);
    expect(other.existsSync(), isTrue); // not a local_audio_* file -> untouched
  });
}
