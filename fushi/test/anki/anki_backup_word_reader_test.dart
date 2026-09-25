import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_backup_word_reader.dart';
import 'package:sqlite3/sqlite3.dart';

// iOS（AnkiMobile）查重的「导入 Anki 备份」：从 .colpkg / .apkg 读出全部笔记的
// 第一字段。对齐 Hoshi Reader iOS 的 importAnkiBackup，并补上它缺的两处：
// 旧格式 collection 也认、第一字段先去 HTML。
//
// 真 zstd（collection.anki21b）解压走 fushidicts 原生库，单测宿主上没有，由
// `integration_test/ios_anki_backup_import_itest.dart` 在 iOS 模拟器上覆盖；
// 这里注入一个「原样拷贝」的解压器，只验「选对 collection、交给解压、读解压产物」。

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('anki_backup_test_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 造一个只有 `notes(flds)` 的最小 collection，返回其字节。
  List<int> collectionBytes(List<String> flds) {
    final String path =
        '${tmp.path}/c_${DateTime.now().microsecondsSinceEpoch}.db';
    final Database db = sqlite3.open(path);
    db.execute(
      'CREATE TABLE notes (id INTEGER PRIMARY KEY, flds TEXT NOT NULL)',
    );
    final PreparedStatement insert = db.prepare(
      'INSERT INTO notes (flds) VALUES (?)',
    );
    for (final String f in flds) {
      insert.execute(<Object>[f]);
    }
    insert.dispose();
    db.dispose();
    final List<int> bytes = File(path).readAsBytesSync();
    File(path).deleteSync();
    return bytes;
  }

  String zipBackup(String name, Map<String, List<int>> entries) {
    final Archive archive = Archive();
    entries.forEach((String entryName, List<int> bytes) {
      archive.addFile(ArchiveFile(entryName, bytes.length, bytes));
    });
    final String path = '${tmp.path}/$name';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
    return path;
  }

  void copyDecompress(String inPath, String outPath) =>
      File(inPath).copySync(outPath);

  Set<String> read(String backup, {String work = 'work'}) =>
      readAnkiBackupFirstFieldsSync(
        backupPath: backup,
        workDir: '${tmp.path}/$work',
        decompressZstd: copyDecompress,
      );

  test('旧格式 collection.anki21：取每条笔记的第一字段', () {
    final String backup = zipBackup('old.colpkg', <String, List<int>>{
      'collection.anki21': collectionBytes(<String>[
        '見物\u001fけんぶつ\u001fsightseeing',
        '勉強\u001fべんきょう',
        '見物\u001f重复的笔记',
      ]),
      'media': '{}'.codeUnits,
    });
    expect(read(backup), <String>{'見物', '勉強'});
  });

  test('最旧的 collection.anki2 也认（Hoshi 只认 anki21b，旧备份直接失败）', () {
    final String backup = zipBackup('oldest.apkg', <String, List<int>>{
      'collection.anki2': collectionBytes(<String>['猫\u001fねこ']),
    });
    expect(read(backup), <String>{'猫'});
  });

  test('新版导出同时带 anki21b 与占位 anki2：必须读 anki21b，并经过解压', () {
    final List<String> calls = <String>[];
    final String backup = zipBackup('new.colpkg', <String, List<int>>{
      // 2.1.50+ 导出的占位 collection：只有一条「请升级 Anki」。
      'collection.anki2': collectionBytes(<String>[
        'Please update to the latest Anki version\u001f',
      ]),
      'collection.anki21b': collectionBytes(<String>['見物\u001fけんぶつ']),
    });
    final Set<String> words = readAnkiBackupFirstFieldsSync(
      backupPath: backup,
      workDir: '${tmp.path}/work',
      decompressZstd: (String inPath, String outPath) {
        calls.add(inPath.split(RegExp(r'[\\/]')).last);
        copyDecompress(inPath, outPath);
      },
    );
    expect(words, <String>{'見物'});
    expect(calls, <String>['collection.anki21b']);
  });

  test('未压缩的 collection 不经解压器', () {
    final String backup = zipBackup('old.colpkg', <String, List<int>>{
      'collection.anki21': collectionBytes(<String>['見物']),
    });
    final Set<String> words = readAnkiBackupFirstFieldsSync(
      backupPath: backup,
      workDir: '${tmp.path}/work',
      decompressZstd: (String _, String __) => fail('不该解压'),
    );
    expect(words, <String>{'見物'});
  });

  test('第一字段去 HTML、解实体、trim，空字段不入集合', () {
    final String backup = zipBackup('html.colpkg', <String, List<int>>{
      'collection.anki21': collectionBytes(<String>[
        '<b>見物</b>\u001fx',
        ' <div>勉強&nbsp;</div> \u001fx',
        'A&amp;B\u001fx',
        '&#x732B;\u001fx',
        '<br>\u001fx',
      ]),
    });
    expect(read(backup), <String>{'見物', '勉強', 'A&B', '猫'});
  });

  test('备份里没有 collection：报格式错', () {
    final String backup = zipBackup('empty.colpkg', <String, List<int>>{
      'media': '{}'.codeUnits,
    });
    expect(() => read(backup), throwsA(isA<AnkiBackupFormatException>()));
  });

  test('collection 不是 SQLite：报格式错', () {
    final String backup = zipBackup('bad.colpkg', <String, List<int>>{
      'collection.anki21': 'not a database at all'.codeUnits,
    });
    expect(() => read(backup), throwsA(isA<AnkiBackupFormatException>()));
  });

  test('选中的根本不是 zip：报格式错', () {
    final String path = '${tmp.path}/notes.txt';
    File(path).writeAsStringSync('hello');
    expect(() => read(path), throwsA(isA<AnkiBackupFormatException>()));
  });

  test('中间文件用完即删（成功与失败都删）', () {
    final String ok = zipBackup('ok.colpkg', <String, List<int>>{
      'collection.anki21': collectionBytes(<String>['見物']),
    });
    read(ok, work: 'w1');
    expect(Directory('${tmp.path}/w1').existsSync(), isFalse);

    final String bad = zipBackup('bad.colpkg', <String, List<int>>{
      'media': '{}'.codeUnits,
    });
    expect(() => read(bad, work: 'w2'), throwsA(anything));
    expect(Directory('${tmp.path}/w2').existsSync(), isFalse);
  });

  group('ankiFirstFieldKey', () {
    test('没有分隔符时整串就是第一字段', () {
      expect(ankiFirstFieldKey(' 見物 '), '見物');
    });

    test('&amp; 最后解，不会把 &amp;lt; 二次解成 <', () {
      expect(ankiFirstFieldKey('&amp;lt;'), '&lt;');
    });
  });
}
