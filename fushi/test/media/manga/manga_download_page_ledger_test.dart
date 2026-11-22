import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/download/manga_download_page_ledger.dart';
import 'package:path/path.dart' as p;

/// 拍板台 audit-035：在线漫画章下载续跑按源端页身份认盘上的页。
void main() {
  MangaDownloadLedgerEntry entry(String file, int index, String key) =>
      MangaDownloadLedgerEntry(file: file, index: index, key: key);

  group('planMangaDownloadResume', () {
    test('身份与页序都对得上：原地留用', () {
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>['a', 'b', 'c'],
        ledger: <MangaDownloadLedgerEntry>[
          entry('page-000001.png', 0, 'a'),
          entry('page-000002.png', 1, 'b'),
        ],
        filesOnDisk: <String>{'page-000001.png', 'page-000002.png'},
      );
      expect(plan.keep.keys, <int>[0, 1]);
      expect(plan.moves, isEmpty);
      expect(plan.discard, isEmpty);
    });

    test('同页数换了一页：只丢那一页', () {
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>['a', 'b2', 'c'],
        ledger: <MangaDownloadLedgerEntry>[
          entry('page-000001.png', 0, 'a'),
          entry('page-000002.png', 1, 'b'),
        ],
        filesOnDisk: <String>{'page-000001.png', 'page-000002.png'},
      );
      expect(plan.keep.keys, <int>[0]);
      expect(plan.discard, <String>{'page-000002.png'});
    });

    test('重排：唯一身份跟着页走', () {
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>['b', 'a'],
        ledger: <MangaDownloadLedgerEntry>[
          entry('page-000001.png', 0, 'a'),
          entry('page-000002.jpg', 1, 'b'),
        ],
        filesOnDisk: <String>{'page-000001.png', 'page-000002.jpg'},
      );
      expect(plan.keep[0]!.file, 'page-000002.jpg');
      expect(plan.keep[1]!.file, 'page-000001.png');
      expect(plan.moves.keys.toSet(), <int>{0, 1});
      expect(plan.discard, isEmpty);
    });

    test('身份重复（源给每页同一个地址）：只认页序也对得上的', () {
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>['x', 'x', 'x'],
        ledger: <MangaDownloadLedgerEntry>[
          entry('page-000001.png', 0, 'x'),
          entry('page-000003.png', 2, 'x'),
        ],
        filesOnDisk: <String>{'page-000001.png', 'page-000003.png'},
      );
      expect(plan.keep.keys.toSet(), <int>{0, 2});
      expect(plan.moves, isEmpty);

      // 页数变了、同一个身份不再唯一定位：页序越界的那条丢掉，不挪。
      final MangaDownloadResumePlan shrunk = planMangaDownloadResume(
        keys: <String?>['x', 'x'],
        ledger: <MangaDownloadLedgerEntry>[
          entry('page-000001.png', 0, 'x'),
          entry('page-000003.png', 2, 'x'),
        ],
        filesOnDisk: <String>{'page-000001.png', 'page-000003.png'},
      );
      expect(shrunk.keep.keys, <int>[0]);
      expect(shrunk.discard, <String>{'page-000003.png'});
    });

    test('新页表认不出身份的页不复用；账本外的文件、账本里但盘上没有的项都不算', () {
      final MangaDownloadResumePlan plan = planMangaDownloadResume(
        keys: <String?>[null, 'b', 'c'],
        ledger: <MangaDownloadLedgerEntry>[
          entry('page-000001.png', 0, 'a'),
          entry('page-000002.png', 1, 'b'),
          entry('page-000003.png', 2, 'c'),
        ],
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
      await writeMangaDownloadPageLedger(chapterDir, <MangaDownloadLedgerEntry>[
        entry('page-000001.png', 0, 'a'),
        entry('page-000002.png', 1, 'b'),
      ]);

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
      expect(
        await readMangaDownloadPageLedger(chapterDir),
        <MangaDownloadLedgerEntry>[
          entry('page-000001.png', 0, 'b'),
          entry('page-000002.png', 1, 'a'),
        ],
      );

      // 接着记账、下完删账本。
      put('page-000003.png', 'C');
      await result.ledger.record(index: 2, file: 'page-000003.png', key: 'c');
      expect(
        (await readMangaDownloadPageLedger(chapterDir)).last,
        entry('page-000003.png', 2, 'c'),
      );
      await result.ledger.discard();
      expect(mangaDownloadPageLedgerFile(chapterDir).existsSync(), isFalse);
    });

    test('坏账本 / 越出 images 的文件名：当空账本，盘上的页全删', () async {
      put('page-000001.png', 'A');
      mangaDownloadPageLedgerFile(chapterDir).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': 1,
          'pages': <Object?>[
            <String, Object?>{'file': '../manga.json', 'index': 0, 'key': 'a'},
          ],
        }),
      );
      expect(await readMangaDownloadPageLedger(chapterDir), isEmpty);
      final ({Map<int, String> kept, MangaDownloadPageLedgerWriter ledger})
      result = await reconcileMangaDownloadPages(
        chapterDir: chapterDir,
        images: images,
        keys: <String?>['a'],
      );
      expect(result.kept, isEmpty);
      expect(images.listSync(), isEmpty);

      mangaDownloadPageLedgerFile(chapterDir).writeAsStringSync('{not json');
      expect(await readMangaDownloadPageLedger(chapterDir), isEmpty);
    });
  });
}
