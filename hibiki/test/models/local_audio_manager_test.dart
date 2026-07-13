import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/models/local_audio_source_pref.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:sqlite3/sqlite3.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

/// 写一个「可用」的本地音频源库（entries + android schema + 一行音频），让
/// [LocalAudioManager.importFile] 的 BUG-777 内容校验通过（旧测试写的假字符串
/// 现在会被正确拒绝，故 importFile 相关用例统一改用真实库）。
void _writeValidAudioDb(String path) {
  final Database db = sqlite3.open(path);
  db.execute('CREATE TABLE entries '
      '(expression TEXT, reading TEXT, file TEXT, source TEXT)');
  db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
  db.execute("INSERT INTO entries VALUES ('猫','ねこ','neko.mp3','forvo')");
  final PreparedStatement stmt =
      db.prepare('INSERT INTO android (file, source, data) VALUES (?,?,?)');
  stmt.execute(<Object?>[
    'neko.mp3',
    'forvo',
    Uint8List.fromList(<int>[1, 2, 3])
  ]);
  stmt.dispose();
  db.dispose();
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

  test('LocalAudioDbEntry round trips its source prefs through json', () {
    const LocalAudioDbEntry entry = LocalAudioDbEntry(
      path: '/tmp/a.db',
      displayName: 'a',
      enabled: true,
      sources: <LocalAudioSourcePref>[
        LocalAudioSourcePref(name: 'nhk16'),
        LocalAudioSourcePref(name: 'forvo', enabled: false),
      ],
    );
    final LocalAudioDbEntry restored =
        LocalAudioDbEntry.fromJson(entry.toJson());
    expect(restored.sources, entry.sources);
  });

  test('entry without sources omits the key and decodes to empty', () {
    const LocalAudioDbEntry entry =
        LocalAudioDbEntry(path: '/tmp/b.db', displayName: 'b');
    expect(entry.toJson().containsKey('sources'), isFalse);
    expect(
      LocalAudioDbEntry.fromJson(const <String, dynamic>{
        'path': '/tmp/b.db',
        'displayName': 'b',
      }).sources,
      isEmpty,
    );
  });

  test('setSourcesFor updates only the matching db, leaving others intact',
      () async {
    await manager.setEntries(const <LocalAudioDbEntry>[
      LocalAudioDbEntry(path: '/tmp/one.db', displayName: 'one', enabled: true),
      LocalAudioDbEntry(path: '/tmp/two.db', displayName: 'two', enabled: true),
    ]);

    await manager.setSourcesFor('/tmp/two.db', const <LocalAudioSourcePref>[
      LocalAudioSourcePref(name: 'forvo'),
      LocalAudioSourcePref(name: 'nhk16', enabled: false),
    ]);

    final List<LocalAudioDbEntry> after = manager.entries;
    expect(after.firstWhere((e) => e.path == '/tmp/one.db').sources, isEmpty);
    expect(
      after.firstWhere((e) => e.path == '/tmp/two.db').sources,
      const <LocalAudioSourcePref>[
        LocalAudioSourcePref(name: 'forvo'),
        LocalAudioSourcePref(name: 'nhk16', enabled: false),
      ],
    );
  });

  test('setSourcesFor on an unknown path is a no-op', () async {
    await manager.setEntries(const <LocalAudioDbEntry>[
      LocalAudioDbEntry(path: '/tmp/one.db', displayName: 'one'),
    ]);
    await manager.setSourcesFor('/tmp/missing.db', const <LocalAudioSourcePref>[
      LocalAudioSourcePref(name: 'x'),
    ]);
    expect(manager.entries.single.sources, isEmpty);
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
    _writeValidAudioDb(source.path);

    final LocalAudioDbEntry entry =
        await manager.importFile(source.path, displayName: 'nhk');

    expect(entry.displayName, 'nhk');
    expect(File(entry.path).existsSync(), isTrue);
    expect(entry.path.startsWith(directory.path), isTrue);
    expect(manager.entries, isEmpty); // not persisted
    await src.delete(recursive: true);
  });

  // BUG-446：源文件不存在时旧实现静默跳过 copy，返回指向空 internalPath 的 entry
  // （「假成功」）。修复后必须显式抛 FileSystemException，让上层记录真因并反馈用户。
  test('importFile throws when the source file does not exist (BUG-446)',
      () async {
    expect(
      () => manager.importFile('/no/such/file/missing.db', displayName: 'x'),
      throwsA(isA<FileSystemException>()),
    );
    // 未在库目录留下任何空副本。
    final List<FileSystemEntity> leftover = directory.listSync();
    expect(leftover, isEmpty);
  });

  // BUG-777：无效文件（没用的 zip / 备份 zip / 非音频 sqlite / 空库）不再假成功。
  // importFile 在收进库前用 LocalAudioDb.isUsableAudioSource 校验，无效即抛
  // InvalidLocalAudioDbException，且绝不在库目录留下内部副本孤儿。
  test(
      'importFile rejects a non-audio file (zip / junk) and leaves no copy '
      '(BUG-777)', () async {
    final Directory src = await Directory.systemTemp.createTemp('src_junk');
    final File junk = File('${src.path}/backup.zip');
    // ZIP 魔数 + 垃圾字节：能被 FilePicker 选中，但不是音频源库。
    await junk.writeAsBytes(
        Uint8List.fromList(<int>[0x50, 0x4b, 0x03, 0x04, 7, 7, 7, 7]));

    await expectLater(
      () => manager.importFile(junk.path, displayName: 'junk'),
      throwsA(isA<InvalidLocalAudioDbException>()),
    );
    // 无效文件绝不被拷进库目录（无假成功 + 无孤儿副本）。
    expect(directory.listSync(), isEmpty);
    await src.delete(recursive: true);
  });

  // BUG-777：引用模式同样校验（引用一个没用的文件也是假成功）。
  test('importFile reference=true also rejects a non-audio file (BUG-777)',
      () async {
    final Directory src = await Directory.systemTemp.createTemp('src_junk_ref');
    final File junk = File('${src.path}/notes.txt')..writeAsStringSync('hello');

    await expectLater(
      () => manager.importFile(junk.path, displayName: 'x', reference: true),
      throwsA(isA<InvalidLocalAudioDbException>()),
    );
    expect(directory.listSync(), isEmpty);
    await src.delete(recursive: true);
  });

  // BUG-483：引用模式（仅桌面）不复制，entry.path 直接指向用户原文件，不在 AppData
  // 库目录留任何副本。
  test(
      'importFile reference=true does NOT copy and points at the original path '
      '(BUG-483)', () async {
    final Directory src = await Directory.systemTemp.createTemp('src_ref');
    final File source = File('${src.path}/nhk.db');
    _writeValidAudioDb(source.path);

    final LocalAudioDbEntry entry = await manager.importFile(
      source.path,
      displayName: 'nhk',
      reference: true,
    );

    expect(entry.path, source.path); // 直接引用原路径，不重命名
    expect(entry.path.startsWith(directory.path), isFalse); // 不在库目录
    expect(directory.listSync(), isEmpty); // 库目录里没有任何复制副本
    expect(source.existsSync(), isTrue); // 原文件原封不动
    expect(entry.enabled, isTrue);
    await src.delete(recursive: true);
  });

  // 引用模式仍要校验源文件存在（不能假成功，沿用 BUG-446 不变量）。
  test(
      'importFile reference=true still throws when the source is missing '
      '(BUG-483)', () async {
    expect(
      () => manager.importFile('/no/such/ref.db',
          displayName: 'x', reference: true),
      throwsA(isA<FileSystemException>()),
    );
    expect(directory.listSync(), isEmpty);
  });

  // BUG-483 安全：移除一个引用条目绝不删用户原文件（路径在库目录之外）。
  test('remove does NOT delete a referenced external file (BUG-483)', () async {
    final Directory ext = await Directory.systemTemp.createTemp('ext_ref');
    final File original = File('${ext.path}/ref.db')..writeAsStringSync('keep');

    await manager.setEntries(<LocalAudioDbEntry>[
      LocalAudioDbEntry(path: original.path, displayName: 'ref', enabled: true),
    ]);
    await manager.remove(0);

    expect(manager.entries, isEmpty); // 条目已移除
    expect(original.existsSync(), isTrue); // 但用户原文件绝不被删
    await ext.delete(recursive: true);
  });

  // BUG-483 安全：pruneOrphans 只回收库目录内的内部副本，外部引用路径天然不在
  // 遍历范围内、绝不被删（即便它没出现在 keepPaths 里）。
  test('pruneOrphans never touches external referenced files (BUG-483)',
      () async {
    final Directory ext = await Directory.systemTemp.createTemp('ext_prune');
    final File external = File('${ext.path}/ref.db')..writeAsStringSync('safe');

    // keepPaths 故意不含外部路径，证明安全靠「目录边界」而非「被引用名单」。
    await manager.pruneOrphans(const <String>[]);

    expect(external.existsSync(), isTrue);
    await ext.delete(recursive: true);
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
