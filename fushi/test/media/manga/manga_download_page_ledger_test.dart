import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/download/manga_download_page_ledger.dart';
import 'package:path/path.dart' as p;

/// 拍板台 audit-035：在线漫画章下载续跑按源端页身份认盘上的页。
void main() {
  MangaDownloadLedgerEntry entry(String file, int index, String key) =>
      MangaDownloadLedgerEntry(file: file, index: index, key: key);

  MangaDownloadLedger ledgerOf(
    List<String?> table,
    List<MangaDownloadLedgerEntry> pages,
  ) => MangaDownloadLedger(table: table, pages: pages);

  group('planMangaDownloadResume', () {
    test('身份与页序都对得上：原地留用', () {
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>['a', 'b', 'c'],
        ledger: ledgerOf(
          <String?>['a', 'b', 'c'],
          <MangaDownloadLedgerEntry>[
            entry('page-000001.png', 0, 'a'),
            entry('page-000002.png', 1, 'b'),
          ],
        ),
        filesOnDisk: <String>{'page-000001.png', 'page-000002.png'},
      );
      expect(plan.keep.keys, <int>[0, 1]);
      expect(plan.moves, isEmpty);
      expect(plan.discard, isEmpty);
    });

    test('同页数换了一页：只丢那一页', () {
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>['a', 'b2', 'c'],
        ledger: ledgerOf(
          <String?>['a', 'b', 'c'],
          <MangaDownloadLedgerEntry>[
            entry('page-000001.png', 0, 'a'),
            entry('page-000002.png', 1, 'b'),
          ],
        ),
        filesOnDisk: <String>{'page-000001.png', 'page-000002.png'},
      );
      expect(plan.keep.keys, <int>[0]);
      expect(plan.discard, <String>{'page-000002.png'});
    });

    test('重排：唯一身份跟着页走', () {
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>['b', 'a'],
        ledger: ledgerOf(
          <String?>['a', 'b'],
          <MangaDownloadLedgerEntry>[
            entry('page-000001.png', 0, 'a'),
            entry('page-000002.jpg', 1, 'b'),
          ],
        ),
        filesOnDisk: <String>{'page-000001.png', 'page-000002.jpg'},
      );
      expect(plan.keep[0]!.file, 'page-000002.jpg');
      expect(plan.keep[1]!.file, 'page-000001.png');
      expect(plan.moves.keys.toSet(), <int>{0, 1});
      expect(plan.discard, isEmpty);
    });

    test('身份重复（源给每页同一个地址）：页表整份没变才原地留用', () {
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>['x', 'x', 'x'],
        ledger: ledgerOf(
          <String?>['x', 'x', 'x'],
          <MangaDownloadLedgerEntry>[
            entry('page-000001.png', 0, 'x'),
            entry('page-000003.png', 2, 'x'),
          ],
        ),
        filesOnDisk: <String>{'page-000001.png', 'page-000003.png'},
      );
      expect(plan.keep.keys.toSet(), <int>{0, 2});
      expect(plan.moves, isEmpty);

      // 页数变了：重复的身份认不出是哪一页，页序相同也不留，全部重下。
      final MangaDownloadResumePlan shrunk = planMangaDownloadResume(
        keys: <String?>['x', 'x'],
        ledger: ledgerOf(
          <String?>['x', 'x', 'x'],
          <MangaDownloadLedgerEntry>[
            entry('page-000001.png', 0, 'x'),
            entry('page-000003.png', 2, 'x'),
          ],
        ),
        filesOnDisk: <String>{'page-000001.png', 'page-000003.png'},
      );
      expect(shrunk.keep, isEmpty);
      expect(shrunk.discard, <String>{'page-000001.png', 'page-000003.png'});
    });

    test('HBK-AUDIT-206：旧表 A、B 同身份只落了 A，新表只剩 B：不把 A 当 B', () {
      // 修复前账本只记已落地的页，A 的身份在账本里看着唯一、新表里也唯一，A 的
      // 旧图被留作新表第 0 页（B）。
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>['shared'],
        ledger: ledgerOf(
          <String?>['shared', 'shared'],
          <MangaDownloadLedgerEntry>[entry('page-000001.png', 0, 'shared')],
        ),
        filesOnDisk: <String>{'page-000001.png'},
      );
      expect(plan.keep, isEmpty);
      expect(plan.discard, <String>{'page-000001.png'});
    });

    test('身份在旧表唯一、新表重复：同样不认', () {
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>['x', 'x'],
        ledger: ledgerOf(
          <String?>['x', 'y'],
          <MangaDownloadLedgerEntry>[entry('page-000001.png', 0, 'x')],
        ),
        filesOnDisk: <String>{'page-000001.png'},
      );
      expect(plan.keep, isEmpty);
    });

    test('账本项与账本页表对不上：当坏项不认', () {
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>['a', 'b'],
        ledger: ledgerOf(
          <String?>['a', 'b'],
          <MangaDownloadLedgerEntry>[
            entry('page-000001.png', 0, 'b'),
            entry('page-000002.png', 5, 'a'),
          ],
        ),
        filesOnDisk: <String>{'page-000001.png', 'page-000002.png'},
      );
      expect(plan.keep, isEmpty);
    });

    test('新页表认不出身份的页不复用；账本外的文件、账本里但盘上没有的项都不算', () {
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>[null, 'b', 'c'],
        ledger: ledgerOf(
          <String?>['a', 'b', 'c'],
          <MangaDownloadLedgerEntry>[
            entry('page-000001.png', 0, 'a'),
            entry('page-000002.png', 1, 'b'),
            entry('page-000003.png', 2, 'c'),
          ],
        ),
        filesOnDisk: <String>{
          'page-000001.png',
          'page-000002.png',
          'page-000004.png',
        },
      );
      expect(plan.keep.keys, <int>[1]);
      expect(plan.discard, <String>{'page-000001.png', 'page-000004.png'});
    });
  });

  group('reconcileMangaDownloadPages（盘上执行）', () {
    late Directory chapterDir;
    late Directory images;

    setUp(() async {
      chapterDir = await Directory.systemTemp.createTemp('fushi-ledger-');
      images = Directory(p.join(chapterDir.path, 'images'))..createSync();
    });

    tearDown(() async {
      if (chapterDir.existsSync()) await chapterDir.delete(recursive: true);
    });

    void put(String name, String content) =>
        File(p.join(images.path, name)).writeAsStringSync(content);

    String read(String name) =>
        File(p.join(images.path, name)).readAsStringSync();

    test('两页互换位置：两段改名不互相覆盖，账本记新页序', () async {
      put('page-000001.png', 'A');
      put('page-000002.png', 'B');
      put('page-000003.png.part', 'half');
      await writeMangaDownloadPageLedger(
        chapterDir,
        table: <String?>['a', 'b', 'c'],
        entries: <MangaDownloadLedgerEntry>[
          entry('page-000001.png', 0, 'a'),
          entry('page-000002.png', 1, 'b'),
        ],
      );

      final ({Map<int, String> kept, MangaDownloadPageLedgerWriter ledger})
      result = await reconcileMangaDownloadPages(
        chapterDir: chapterDir,
        images: images,
        keys: <String?>['b', 'a', 'c'],
      );

      expect(result.kept, <int, String>{
        0: 'page-000001.png',
        1: 'page-000002.png',
      });
      expect(read('page-000001.png'), 'B');
      expect(read('page-000002.png'), 'A');
      expect(
        images.listSync().map((FileSystemEntity e) => p.basename(e.path)),
        unorderedEquals(<String>['page-000001.png', 'page-000002.png']),
        reason: '暂存 / 来历不明的文件删掉',
      );
      final MangaDownloadLedger written = await readMangaDownloadPageLedger(
        chapterDir,
      );
      expect(written.table, <String?>['b', 'a', 'c']);
      expect(written.pages, <MangaDownloadLedgerEntry>[
        entry('page-000001.png', 0, 'b'),
        entry('page-000002.png', 1, 'a'),
      ]);

      // 接着记账、下完删账本。
      put('page-000003.png', 'C');
      await result.ledger.record(index: 2, file: 'page-000003.png', key: 'c');
      expect(
        (await readMangaDownloadPageLedger(chapterDir)).pages.last,
        entry('page-000003.png', 2, 'c'),
      );
      await result.ledger.discard();
      expect(mangaDownloadPageLedgerFile(chapterDir).existsSync(), isFalse);
    });

    test('坏账本 / 越出 images 的文件名：当空账本，盘上的页全删', () async {
      put('page-000001.png', 'A');
      mangaDownloadPageLedgerFile(chapterDir).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': 2,
          'table': <Object?>['a'],
          'pages': <Object?>[
            <String, Object?>{'file': '../manga.json', 'index': 0, 'key': 'a'},
          ],
        }),
      );
      expect((await readMangaDownloadPageLedger(chapterDir)).pages, isEmpty);
      final ({Map<int, String> kept, MangaDownloadPageLedgerWriter ledger})
      result = await reconcileMangaDownloadPages(
        chapterDir: chapterDir,
        images: images,
        keys: <String?>['a'],
      );
      expect(result.kept, isEmpty);
      expect(images.listSync(), isEmpty);

      mangaDownloadPageLedgerFile(chapterDir).writeAsStringSync('{not json');
      expect((await readMangaDownloadPageLedger(chapterDir)).pages, isEmpty);

      // v1 账本（没有整份页表，判不出身份当时是否唯一）：当空账本。
      mangaDownloadPageLedgerFile(chapterDir).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': 1,
          'pages': <Object?>[
            <String, Object?>{
              'file': 'page-000001.png',
              'index': 0,
              'key': 'a',
            },
          ],
        }),
      );
      expect((await readMangaDownloadPageLedger(chapterDir)).pages, isEmpty);
    });
  });
}
