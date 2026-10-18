// 「从 Anki 迁移」来源侧：数据根、profile 发现、只读快照（含未并回的 WAL）、媒体目录，
// 以及「本机集合快照」与「导出的包」走同一条导入路径、结果一致。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/apkg/anki_collection_snapshot.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'apkg_test_support.dart';
import 'srs_apkg_import_test.dart' as fx;

String _sha(File f) => sha1.convert(f.readAsBytesSync()).toString();

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('anki_snap_test_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放。
    }
  });

  /// 在 [dir] 下写一份旧 schema 集合（fixture 与 srs_apkg_import_test 同一份）+ 媒体目录。
  File writeCollection(Directory dir, int nowMs) {
    dir.createSync(recursive: true);
    final File col = File(p.join(dir.path, ankiCollectionFileName))
      ..writeAsBytesSync(
        buildLegacyCollection(
          crtSecs: fx.crtSecs,
          conf: <String, Object?>{
            'rollover': 4,
            'localOffset': 0,
            'fsrs': true,
          },
          models: fx.legacyModels(),
          decks: fx.legacyDecks(),
          dconf: fx.legacyDconf(),
          notes: fx.fixtureNotes(nowMs),
        ),
      );
    final Directory media = Directory(p.join(dir.path, ankiMediaFolderName))
      ..createSync();
    File(p.join(media.path, 'a.png')).writeAsBytesSync(<int>[1, 2, 3]);
    File(p.join(media.path, '_font.woff')).writeAsBytesSync(<int>[4, 5]);
    File(p.join(media.path, 'unused.png')).writeAsBytesSync(<int>[6]);
    return col;
  }

  group('ankiDataRoots', () {
    test('Windows：ANKI_BASE 优先，再 %APPDATA%\\Anki2', () {
      expect(
        ankiDataRoots(
          os: 'windows',
          env: <String, String>{
            'APPDATA': r'C:\Users\u\AppData\Roaming',
            'ANKI_BASE': r'D:\AnkiData',
          },
        ),
        <AnkiDataRoot>[
          const AnkiDataRoot(r'D:\AnkiData', AnkiDataRootKind.desktop),
          const AnkiDataRoot(
            r'C:\Users\u\AppData\Roaming\Anki2',
            AnkiDataRootKind.desktop,
          ),
        ],
      );
    });

    test('macOS：~/Library/Application Support/Anki2', () {
      expect(
        ankiDataRoots(os: 'macos', env: <String, String>{'HOME': '/Users/u'}),
        <AnkiDataRoot>[
          const AnkiDataRoot(
            '/Users/u/Library/Application Support/Anki2',
            AnkiDataRootKind.desktop,
          ),
        ],
      );
    });

    test('Linux：XDG_DATA_HOME、~/.local/share、Flatpak；重复的只留一个', () {
      expect(
        ankiDataRoots(
          os: 'linux',
          env: <String, String>{
            'HOME': '/home/u',
            'XDG_DATA_HOME': '/home/u/.local/share',
          },
        ),
        <AnkiDataRoot>[
          const AnkiDataRoot(
            '/home/u/.local/share/Anki2',
            AnkiDataRootKind.desktop,
          ),
          const AnkiDataRoot(
            '/home/u/.var/app/net.ankiweb.Anki/data/Anki2',
            AnkiDataRootKind.desktop,
          ),
        ],
      );
    });

    test('Android：AnkiDroid 旧默认目录；iOS 没有；缺环境变量不产出空路径', () {
      expect(
        ankiDataRoots(os: 'android', env: const <String, String>{}),
        <AnkiDataRoot>[
          const AnkiDataRoot(
            '/storage/emulated/0/AnkiDroid',
            AnkiDataRootKind.ankiDroid,
          ),
        ],
      );
      expect(ankiDataRoots(os: 'ios', env: const <String, String>{}), isEmpty);
      expect(
        ankiDataRoots(
          os: 'windows',
          env: const <String, String>{'APPDATA': '  '},
        ),
        isEmpty,
      );
    });
  });

  group('discoverAnkiProfiles', () {
    test('桌面根下每个含集合的子目录一个 profile；AnkiDroid 根本身即集合；不存在的根跳过', () async {
      final int now = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
      final Directory desktop = Directory(p.join(tmp.path, 'Anki2'));
      writeCollection(Directory(p.join(desktop.path, 'User 1')), now);
      writeCollection(Directory(p.join(desktop.path, 'Alt')), now);
      Directory(
        p.join(desktop.path, 'addons21', 'x'),
      ).createSync(recursive: true);
      File(
        p.join(desktop.path, 'User 1', '$ankiCollectionFileName-wal'),
      ).writeAsBytesSync(List<int>.filled(32, 0));
      final Directory droid = Directory(p.join(tmp.path, 'AnkiDroid'));
      writeCollection(droid, now);

      final AnkiDiscovery d = await discoverAnkiProfiles(<AnkiDataRoot>[
        AnkiDataRoot(desktop.path, AnkiDataRootKind.desktop),
        AnkiDataRoot(droid.path, AnkiDataRootKind.ankiDroid),
        AnkiDataRoot(p.join(tmp.path, 'missing'), AnkiDataRootKind.desktop),
        // 同一目录以另一种身份再出现一次：不重复。
        AnkiDataRoot(droid.path, AnkiDataRootKind.custom),
      ]);
      expect(d.unreadableRoots, isEmpty);
      expect(
        d.profiles.map((AnkiProfileCandidate c) => '${c.kind.name}:${c.name}'),
        <String>['desktop:Alt', 'desktop:User 1', 'ankiDroid:AnkiDroid'],
      );
      final AnkiProfileCandidate user1 = d.profiles[1];
      expect(user1.walBytes, 32);
      expect(user1.probablyOpen, isTrue);
      expect(d.profiles.first.probablyOpen, isFalse);
      expect(user1.collectionBytes, greaterThan(0));
      expect(
        user1.mediaDir.path,
        p.join(user1.directory.path, 'collection.media'),
      );
    });
  });

  group('snapshotAnkiCollection', () {
    test('Anki 开着、修改还在 -wal 里：快照带上 WAL 的内容，原始文件一个字节都不变', () async {
      final int now = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
      final File col = writeCollection(
        Directory(p.join(tmp.path, 'User 1')),
        now,
      );
      // 模拟运行中的 Anki：WAL 模式、关掉自动 checkpoint，新写的笔记只在 -wal 里。
      final Database live = sqlite3.open(col.path);
      try {
        live.execute('PRAGMA journal_mode = WAL');
        live.execute('PRAGMA wal_autocheckpoint = 0');
        insertNotes(live, <FxNote>[
          FxNote(
            id: 99,
            guid: 'wal-only',
            mid: fx.kBasic,
            fields: <String>['wal', 'only'],
            cards: <FxCard>[FxCard(id: 991, ord: 0, did: 1)],
          ),
        ]);
        final File wal = File('${col.path}-wal');
        expect(wal.lengthSync(), greaterThan(0));
        final String colSha = _sha(col);
        final String walSha = _sha(wal);

        final AnkiCollectionSnapshot snap = await snapshotAnkiCollection(
          collection: col,
          tempParent: Directory(p.join(tmp.path, 'work')),
        );
        try {
          expect(snap.stats.notes, 4);
          expect(snap.stats.cards, 6);
          expect(snap.stats.reviews, 7);
          expect(
            snap.mediaDir.path,
            p.join(col.parent.path, 'collection.media'),
          );
          // 快照已是单文件（WAL 回放进主文件、改成 DELETE 日志模式）。
          expect(File('${snap.collection.path}-wal').existsSync(), isFalse);
          expect(_sha(col), colSha);
          expect(_sha(wal), walSha);
        } finally {
          await snap.discard();
        }
      } finally {
        live.close();
      }
    });

    test('集合不存在 → missing；不是 SQLite → corrupt，临时目录不残留', () async {
      final Directory work = Directory(p.join(tmp.path, 'work'));
      await expectLater(
        snapshotAnkiCollection(
          collection: File(p.join(tmp.path, 'nope', ankiCollectionFileName)),
          tempParent: work,
        ),
        throwsA(
          isA<AnkiSnapshotException>().having(
            (AnkiSnapshotException e) => e.reason,
            'reason',
            AnkiSnapshotFailure.missing,
          ),
        ),
      );
      final File junk = File(p.join(tmp.path, 'junk', ankiCollectionFileName))
        ..createSync(recursive: true)
        ..writeAsStringSync('definitely not sqlite, just some bytes' * 100);
      await expectLater(
        snapshotAnkiCollection(collection: junk, tempParent: work),
        throwsA(
          isA<AnkiSnapshotException>().having(
            (AnkiSnapshotException e) => e.reason,
            'reason',
            AnkiSnapshotFailure.corrupt,
          ),
        ),
      );
      expect(work.listSync(), isEmpty);
    });

    test('是 SQLite 但不是 Anki 集合 → corrupt', () async {
      final File other = File(p.join(tmp.path, 'x', ankiCollectionFileName))
        ..parent.createSync(recursive: true);
      final Database db = sqlite3.open(other.path);
      db.execute('CREATE TABLE t (a)');
      db.close();
      await expectLater(
        snapshotAnkiCollection(
          collection: other,
          tempParent: Directory(p.join(tmp.path, 'work')),
        ),
        throwsA(
          isA<AnkiSnapshotException>().having(
            (AnkiSnapshotException e) => e.reason,
            'reason',
            AnkiSnapshotFailure.corrupt,
          ),
        ),
      );
    });
  });

  group('AnkiMediaFolder', () {
    test('只读单层文件名：路径穿越 / 绝对路径 / 子目录一律不读', () {
      final Directory media = Directory(
        p.join(tmp.path, 'p', 'collection.media'),
      )..createSync(recursive: true);
      File(p.join(media.path, 'ok.png')).writeAsBytesSync(<int>[7]);
      File(p.join(tmp.path, 'p', 'secret.txt')).writeAsStringSync('s');
      Directory(p.join(media.path, 'sub')).createSync();
      final AnkiMediaFolder f = AnkiMediaFolder(media);
      expect(f.index(), <String, String>{'ok.png': 'ok.png'});
      expect(f.read('ok.png'), <int>[7]);
      expect(f.read('../secret.txt'), isNull);
      expect(f.read(r'..\secret.txt'), isNull);
      expect(f.read('..'), isNull);
      expect(f.read(p.join(tmp.path, 'p', 'secret.txt')), isNull);
      expect(f.read('missing.png'), isNull);
      expect(
        AnkiMediaFolder(Directory(p.join(tmp.path, 'none'))).index(),
        isEmpty,
      );
      expect(isSafeAnkiMediaName('C:secret'), isFalse);
      expect(isSafeAnkiMediaName('猫 1.mp3'), isTrue);
    });
  });

  test('本机集合快照与同一集合导出的包：导入结果一致（排程 / 复习记录 / 媒体）', () async {
    final int now = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
    int clock = now;
    final File col = writeCollection(
      Directory(p.join(tmp.path, 'User 1')),
      now,
    );

    Future<(SrsImportReport, SrsDbStore, Set<String>)> run(
      Future<SrsImportReport> Function(SrsDbStore s, SrsImportMediaSink sink)
      body,
    ) async {
      final SrsDbStore s = await openTestStore(
        profileUid: fx.kProfile,
        deviceId: 'a',
        now: () => clock,
      );
      final Set<String> stored = <String>{};
      final SrsImportReport r = await body(s, (String name, Uint8List b) async {
        stored.add(name);
        return 'h_$name';
      });
      return (r, s, stored);
    }

    final AnkiCollectionSnapshot snap = await snapshotAnkiCollection(
      collection: col,
      tempParent: Directory(p.join(tmp.path, 'work')),
    );
    final (SrsImportReport a, SrsDbStore sa, Set<String> mediaA) = await run(
      (SrsDbStore s, SrsImportMediaSink sink) => importAnkiCollectionSnapshot(
        store: s,
        snapshot: snap,
        storeMedia: sink,
        options: fx.kFullOptions,
      ),
    );
    await snap.discard();

    final Uint8List pkg = zipOf(<String, List<int>>{
      'collection.anki2': col.readAsBytesSync(),
      'media': utf8.encode(
        jsonEncode(<String, String>{
          '0': 'a.png',
          '1': '_font.woff',
          '2': 'unused.png',
        }),
      ),
      '0': <int>[1, 2, 3],
      '1': <int>[4, 5],
      '2': <int>[6],
    });
    final (SrsImportReport b, SrsDbStore sb, Set<String> mediaB) = await run(
      (SrsDbStore s, SrsImportMediaSink sink) => importAnkiPackage(
        store: s,
        bytes: pkg,
        storeMedia: sink,
        options: fx.kFullOptions,
        zstdDecompress: (Uint8List x) => null,
      ),
    );

    expect(a.notesAdded, 3);
    expect(a.cardsAdded, 5);
    expect(a.reviewLogsImported, 6);
    expect(a.anchorsWritten, 2);
    expect(mediaA, <String>{'a.png', '_font.woff'});
    expect(a.mediaMissing, isEmpty);
    final Map<String, Object?> ja = a.toJson()..remove('latestFormat');
    final Map<String, Object?> jb = b.toJson()..remove('latestFormat');
    expect(jsonEncode(ja), jsonEncode(jb));
    expect(mediaA, mediaB);

    // 同一张卡在两边的排程与日志完全相同（ID 只由来源决定）。
    final String n1 = SrsIds.note(fx.kProfile, 'g1');
    final String nt = SrsIds.noteType(fx.kProfile, fx.kBasic);
    final String c11 = SrsIds.card(n1, SrsIds.template(nt, 333), 0);
    final SrsCardCacheRow ra = (await sa.cardRow(c11))!;
    final SrsCardCacheRow rb = (await sb.cardRow(c11))!;
    expect(ra.queue, rb.queue);
    expect(ra.dueDay, rb.dueDay);
    expect(ra.dueDay, fx.crtDay + 70);
    expect(
      (await sa.history(c11)).all.map((SrsReviewLog l) => l.id).toSet(),
      (await sb.history(c11)).all.map((SrsReviewLog l) => l.id).toSet(),
    );
    clock += 1;
  });
}
