// v130 游戏台词（galgame_text_lines）进备份：所有者 2026-10-24 拍板——语料库里的游戏
// 台词曾是唯一持久副本，换设备 / 恢复备份不能丢。台词进 DB 表后随 games 类别出境，
// 覆盖导入整库落地、「我库里的例句」从表重建；合并导入按游戏身份重映射 + (游戏, 台词)
// 去重。语料目录（<数据根>/corpus，派生索引）本身不进备份：坏了 / 缺了都不影响备份。
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart'
    show OrderClauseGenerator, OrderingTerm, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/corpus/library_corpus_service.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_corpus/fushi_corpus.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// 假词元：按空白切词、小写 = 词典形（这里测的是备份往返，不是词形还原）。
Uint8List _fakeTerms(List<String> sentences) {
  final BytesBuilder b = BytesBuilder();
  void u32(int v) =>
      b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  for (final String s in sentences) {
    final List<RegExpMatch> words = RegExp(r'[^\s]+').allMatches(s).toList();
    u32(words.length);
    for (final RegExpMatch m in words) {
      final List<int> lemma = utf8.encode(m.group(0)!.toLowerCase());
      u32(m.start);
      u32(m.end - m.start);
      u32(lemma.length);
      b.add(lemma);
    }
  }
  return b.takeBytes();
}

class _FakeNormalizer implements CorpusNormalizer {
  @override
  String? get signature => 'dict-v1';

  @override
  Future<T?> runInBackground<T>(T Function(CorpusTermsFn terms) job) =>
      Isolate.run(() => job(_fakeTerms));
}

void main() {
  late Directory src;
  late Directory dst;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('bk_gtl_src_');
    dst = await Directory.systemTemp.createTemp('bk_gtl_dst_');
  });
  tearDown(() async {
    for (final Directory d in <Directory>[src, dst]) {
      if (d.existsSync()) await cleanupTempDir(d);
    }
  });

  Future<void> addGame(
    FushiDatabase db,
    String id, {
    String exePath = r'D:\games\g1\g1.exe',
    String? bgm,
  }) async {
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: id,
        name: 'Game $id',
        exePath: exePath,
        workdir: p.dirname(exePath),
        addedAt: 1,
      ),
    );
    if (bgm != null) {
      await db.upsertGalgameSource(
        GalgameSourcesCompanion.insert(
          gameId: id,
          source: 'bgm',
          externalId: Value<String?>(bgm),
          dataJson: '{}',
          fetchedAt: 1,
        ),
      );
    }
  }

  Future<List<String>> lines(FushiDatabase db, String gameId) async => <String>[
    for (final GalgameTextLineRow r
        in await (db.select(db.galgameTextLines)
              ..where(($GalgameTextLinesTable t) => t.gameId.equals(gameId))
              ..orderBy(<OrderClauseGenerator<$GalgameTextLinesTable>>[
                ($GalgameTextLinesTable t) => OrderingTerm.asc(t.id),
              ]))
            .get())
      r.lineText,
  ];

  /// 源设备：一部游戏（bgm:100）三句台词；语料目录里故意放一个坏文件。
  Future<({FushiDatabase db, String dbDir})> seed() async {
    final String dbDir = p.join(src.path, 'support');
    Directory(dbDir).createSync(recursive: true);
    final Directory corpus = Directory(
      LibraryCorpusService.directoryUnder(dbDir),
    )..createSync(recursive: true);
    File(p.join(corpus.path, 'broken.fcd')).writeAsBytesSync(<int>[0, 1, 2]);
    final FushiDatabase db = FushiDatabase(dbDir);
    await addGame(db, 'G1', bgm: '100');
    await db
        .insertGalgameTextLines('G1', const <({String text, int receivedAt})>[
          (text: 'The night is long', receivedAt: 10),
          (text: 'Run to the sea', receivedAt: 20),
          (text: 'We ran together', receivedAt: 30),
        ]);
    return (db: db, dbDir: dbDir);
  }

  BackupService serviceFor(({FushiDatabase db, String dbDir}) s) =>
      BackupService(db: s.db, dbDirectory: s.dbDir, appVersion: '1.0.0');

  test('整份备份 → 空数据根覆盖恢复：台词落地、例句索引从表重建可查；语料目录不进包', () async {
    final s = await seed();
    final String zip = p.join(src.path, 'full.zip');
    await serviceFor(s).createBackup(zip);
    await s.db.close();

    final Archive archive = ZipDecoder().decodeBytes(
      await File(zip).readAsBytes(),
    );
    expect(
      archive.files.any((ArchiveFile f) => f.name.startsWith('corpus/')),
      isFalse,
      reason: '语料索引是派生数据（坏文件也一样），不进备份；备份照常完成',
    );

    final String curDbDir = p.join(dst.path, 'support');
    Directory(curDbDir).createSync(recursive: true);
    await BackupRestoreService.restoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
    );
    final FushiDatabase cur = FushiDatabase(curDbDir);
    final LibraryCorpusService corpus = LibraryCorpusService(
      normalizer: _FakeNormalizer(),
      startDelay: Duration.zero,
      debounce: const Duration(milliseconds: 1),
    );
    try {
      expect(await lines(cur, 'G1'), <String>[
        'The night is long',
        'Run to the sea',
        'We ran together',
      ]);
      corpus.start(
        database: cur,
        directory: LibraryCorpusService.directoryUnder(curDbDir),
        isEnabled: () => true,
      );
      for (int i = 0; i < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await corpus.idle;
      }
      final CorpusQueryResult result = await corpus.query(<String>['ran']);
      expect(result.groups.single.kind, CorpusSourceKind.game);
      expect(result.groups.single.items.single.text, 'We ran together');
      expect(result.groups.single.items.single.pos, 30);
    } finally {
      await corpus.stop();
      await cur.close();
    }
  });

  test('games 未勾：台词随游戏一起裁掉', () async {
    final s = await seed();
    final String zip = p.join(src.path, 'no_games.zip');
    await serviceFor(s).createBackup(
      zip,
      categories: BackupCategory.values.toSet()..remove(BackupCategory.games),
    );
    await s.db.close();
    final String curDbDir = p.join(dst.path, 'support');
    Directory(curDbDir).createSync(recursive: true);
    await BackupRestoreService.restoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
    );
    final FushiDatabase cur = FushiDatabase(curDbDir);
    try {
      expect(await cur.countGalgameTextLines('G1'), 0);
    } finally {
      await cur.close();
    }
  });

  test('合并导入两次：按游戏身份重映射（bgm 同 id）+ (游戏, 台词) 去重，不重复', () async {
    final s = await seed();
    final String zip = p.join(src.path, 'merge.zip');
    await serviceFor(s).createBackup(zip);
    await s.db.close();

    // 目标设备：同一部游戏 T1（bgm:100）装在别处，已有一句相同、一句独有的台词。
    final String curDbDir = p.join(dst.path, 'support');
    Directory(curDbDir).createSync(recursive: true);
    final FushiDatabase seedDb = FushiDatabase(curDbDir);
    await addGame(seedDb, 'T1', exePath: r'E:\gal\one.exe', bgm: '100');
    await seedDb
        .insertGalgameTextLines('T1', const <({String text, int receivedAt})>[
          (text: 'Run to the sea', receivedAt: 5),
          (text: 'Only on this device', receivedAt: 6),
        ]);
    await seedDb.close();

    for (int round = 0; round < 2; round++) {
      await BackupRestoreService.mergeRestoreBackup(
        dbDirectory: curDbDir,
        zipPath: zip,
      );
    }
    final FushiDatabase cur = FushiDatabase(curDbDir);
    try {
      expect(await lines(cur, 'T1'), <String>[
        'Run to the sea',
        'Only on this device',
        'The night is long',
        'We ran together',
      ]);
      expect(await cur.countGalgameTextLines('G1'), 0, reason: 'G1 已并入 T1');
      final GalgameTextLineRow shared =
          (await cur.select(cur.galgameTextLines).get()).firstWhere(
            (GalgameTextLineRow r) => r.lineText == 'Run to the sea',
          );
      expect(shared.receivedAt, 5, reason: '本机已有的行原样保留');
    } finally {
      await cur.close();
    }
  });
}
