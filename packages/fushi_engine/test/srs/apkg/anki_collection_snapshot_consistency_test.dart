// 本机 Anki 集合快照的一致性判据（拷贝期间被写 → changedDuringCopy），以及媒体目录
// 枚举不在调用方 isolate 上同步执行。
//
// 只依赖 anki_collection_snapshot.dart（不经导入器），集合用最小的四张表手工建。
import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/srs/apkg/anki_collection_snapshot.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// 最小的「像 Anki 集合」的 SQLite：快照的结构检查只认 col / notes / cards / revlog。
File _writeMinimalCollection(Directory dir) {
  dir.createSync(recursive: true);
  final File col = File(p.join(dir.path, ankiCollectionFileName));
  final Database db = sqlite3.open(col.path);
  try {
    db.execute('CREATE TABLE col (id INTEGER PRIMARY KEY, crt INTEGER)');
    db.execute('CREATE TABLE notes (id INTEGER PRIMARY KEY, flds TEXT)');
    db.execute('CREATE TABLE cards (id INTEGER PRIMARY KEY, nid INTEGER)');
    db.execute('CREATE TABLE revlog (id INTEGER PRIMARY KEY, cid INTEGER)');
    db.execute('INSERT INTO col VALUES (1, 0)');
    for (int i = 1; i <= 50; i++) {
      db.execute('INSERT INTO notes VALUES (?, ?)', <Object?>[i, 'n$i' * 40]);
      db.execute('INSERT INTO cards VALUES (?, ?)', <Object?>[i, i]);
    }
  } finally {
    db.close();
  }
  return col;
}

/// 原位覆盖 [f] 中间的一段字节（长度不变），再把修改时刻拨回覆盖前的值——
/// 也就是「大小 + 修改时刻」指纹看来什么都没发生。返回覆盖前后的 (大小, 修改时刻) 供断言。
((int, DateTime), (int, DateTime)) _overwriteInPlaceKeepingStat(File f) {
  final FileStat before = f.statSync();
  final RandomAccessFile raf = f.openSync(mode: FileMode.append);
  try {
    final int at = before.size ~/ 2;
    raf.setPositionSync(at);
    final List<int> old = raf.readSync(16);
    raf.setPositionSync(at);
    raf.writeFromSync(<int>[for (final int b in old) b ^ 0xFF]);
  } finally {
    raf.closeSync();
  }
  f.setLastModifiedSync(before.modified);
  final FileStat after = f.statSync();
  return ((before.size, before.modified), (after.size, after.modified));
}

Matcher _failsWith(AnkiSnapshotFailure reason) => throwsA(
  isA<AnkiSnapshotException>().having(
    (AnkiSnapshotException e) => e.reason,
    'reason',
    reason,
  ),
);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('anki_snap_consist_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放。
    }
  });

  group('snapshot consistency', () {
    test('拷贝期间主文件被原位覆盖、大小与修改时刻都不变 → changedDuringCopy，临时目录不残留', () async {
      final File col = _writeMinimalCollection(
        Directory(p.join(tmp.path, 'User 1')),
      );
      final Directory work = Directory(p.join(tmp.path, 'work'));
      ((int, DateTime), (int, DateTime))? stat;
      await expectLater(
        debugSnapshotAnkiCollection(
          collection: col,
          tempParent: work,
          afterFirstCopy: () async => stat = _overwriteInPlaceKeepingStat(col),
        ),
        _failsWith(AnkiSnapshotFailure.changedDuringCopy),
      );
      // 前提：旧的「大小 + 修改时刻」指纹在这里看不出任何变化。
      expect(stat, isNotNull);
      expect(stat!.$2, stat!.$1);
      expect(work.listSync(), isEmpty);
    });

    test('Anki 开着、WAL 重置后原位覆盖 -wal（大小与修改时刻不变）→ changedDuringCopy', () async {
      final File col = _writeMinimalCollection(
        Directory(p.join(tmp.path, 'User 1')),
      );
      final Database live = sqlite3.open(col.path);
      try {
        live.execute('PRAGMA journal_mode = WAL');
        live.execute('PRAGMA wal_autocheckpoint = 0');
        for (int i = 100; i < 140; i++) {
          live.execute('INSERT INTO notes VALUES (?, ?)', <Object?>[
            i,
            'wal$i' * 40,
          ]);
        }
        final File wal = File('${col.path}-wal');
        expect(wal.lengthSync(), greaterThan(0));
        ((int, DateTime), (int, DateTime))? stat;
        await expectLater(
          debugSnapshotAnkiCollection(
            collection: col,
            tempParent: Directory(p.join(tmp.path, 'work')),
            afterFirstCopy: () async =>
                stat = _overwriteInPlaceKeepingStat(wal),
          ),
          _failsWith(AnkiSnapshotFailure.changedDuringCopy),
        );
        expect(stat!.$2, stat!.$1);
      } finally {
        live.close();
      }
    });

    test('拷贝期间新出现 -journal → changedDuringCopy', () async {
      final File col = _writeMinimalCollection(
        Directory(p.join(tmp.path, 'User 1')),
      );
      await expectLater(
        debugSnapshotAnkiCollection(
          collection: col,
          tempParent: Directory(p.join(tmp.path, 'work')),
          afterFirstCopy: () async =>
              File('${col.path}-journal').writeAsBytesSync(<int>[0]),
        ),
        _failsWith(AnkiSnapshotFailure.changedDuringCopy),
      );
    });

    test('拷贝期间没人写 → 快照可用，只留一份集合（对照副本已删），原始文件不变', () async {
      final File col = _writeMinimalCollection(
        Directory(p.join(tmp.path, 'User 1')),
      );
      final List<int> original = col.readAsBytesSync();
      final AnkiCollectionSnapshot snap = await debugSnapshotAnkiCollection(
        collection: col,
        tempParent: Directory(p.join(tmp.path, 'work')),
        afterFirstCopy: () async {},
      );
      try {
        expect(snap.stats.notes, 50);
        expect(snap.stats.cards, 50);
        expect(
          snap.collection.parent.listSync().map((FileSystemEntity e) {
            return p.basename(e.path);
          }),
          <String>[ankiCollectionFileName],
        );
        expect(col.readAsBytesSync(), original);
      } finally {
        await snap.discard();
      }
    });
  });

  group('AnkiMediaFolder.index', () {
    test('枚举不在调用方 isolate 上同步跑：调用前排的 Timer 先于结果触发', () async {
      final Directory media = Directory(
        p.join(tmp.path, 'p', ankiMediaFolderName),
      )..createSync(recursive: true);
      for (int i = 0; i < 200; i++) {
        File(p.join(media.path, 'm$i.png')).writeAsBytesSync(<int>[i & 0xFF]);
      }
      Directory(p.join(media.path, 'sub')).createSync();
      final List<String> order = <String>[];
      Timer.run(() => order.add('timer'));
      final Map<String, String> index = await AnkiMediaFolder(media)
          .index()
          .then((Map<String, String> v) {
            order.add('index');
            return v;
          });
      // 同步枚举（listSync 在调用方 isolate 上跑完、结果走微任务）会让结果抢在 Timer 前面。
      expect(order, <String>['timer', 'index']);
      expect(index.length, 200);
      expect(index['m7.png'], 'm7.png');
      expect(index.containsKey('sub'), isFalse);
    });

    test('单文件读也是异步的：调用前排的 Timer 先于结果触发；越界名字不读', () async {
      final Directory media = Directory(
        p.join(tmp.path, 'q', ankiMediaFolderName),
      )..createSync(recursive: true);
      File(p.join(media.path, 'a.png')).writeAsBytesSync(<int>[1, 2, 3]);
      final AnkiMediaFolder folder = AnkiMediaFolder(media);
      final List<String> order = <String>[];
      Timer.run(() => order.add('timer'));
      final List<int>? bytes = await folder.read('a.png').then((List<int>? v) {
        order.add('read');
        return v;
      });
      expect(order, <String>['timer', 'read']);
      expect(bytes, <int>[1, 2, 3]);
      expect(await folder.read('../a.png'), isNull);
      expect(await folder.read('missing.png'), isNull);
    });
  });
}
