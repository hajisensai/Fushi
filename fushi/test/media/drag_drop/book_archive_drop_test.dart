// 拍板 83Fe7zQbhv：书架 / 漫画库拖放按**包里装的是什么**认「一包书」——
// 装着 EPUB / TXT 的 zip / rar 归 bookArchives（不再落词典包 / 漫画包），.7z 与分卷
// 第一卷按扩展名收下、解开后再定性；页图包仍归漫画、不注入判据的落点（词典页）不变。
import 'package:fushi/src/media/drag_drop/book_archive_probe.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/drop_decision.dart';
import 'package:test/test.dart';

void main() {
  group('classifyDroppedFiles · bookArchives', () {
    test('zip 判据说是一批书 → 只归 bookArchives，不再落词典包', () {
      final DroppedFiles r = classifyDroppedFiles(
        <String>['/x/novels.zip'],
        isImageArchive: (_) => false,
        isBookArchive: (_) => true,
      );
      expect(r.bookArchives, <String>['/x/novels.zip']);
      expect(r.dictionaries, isEmpty);
      expect(r.mangas, isEmpty);
      expect(r.hasAny, isTrue);
    });

    test('页图判据先问：一包页图仍归漫画，书包判据不被问到', () {
      final List<String> asked = <String>[];
      final DroppedFiles r = classifyDroppedFiles(
        <String>['/x/vol1.zip'],
        isImageArchive: (_) => true,
        isBookArchive: (String path) {
          asked.add(path);
          return true;
        },
      );
      expect(r.mangas, <String>['/x/vol1.zip']);
      expect(r.bookArchives, isEmpty);
      expect(asked, isEmpty);
    });

    test('zip 两个判据都否 → 维持词典包', () {
      final DroppedFiles r = classifyDroppedFiles(
        <String>['/x/jmdict.zip'],
        isImageArchive: (_) => false,
        isBookArchive: (_) => false,
      );
      expect(r.dictionaries, <String>['/x/jmdict.zip']);
      expect(r.bookArchives, isEmpty);
    });

    test('rar 装着书 → bookArchives；不是书 → 照旧漫画包', () {
      final DroppedFiles books = classifyDroppedFiles(<String>[
        '/x/txt.rar',
      ], isBookArchive: (_) => true);
      expect(books.bookArchives, <String>['/x/txt.rar']);
      expect(books.mangas, isEmpty);
      final DroppedFiles manga = classifyDroppedFiles(<String>[
        '/x/vol.rar',
      ], isBookArchive: (_) => false);
      expect(manga.mangas, <String>['/x/vol.rar']);
      expect(manga.bookArchives, isEmpty);
    });

    test('.7z 与分卷第一卷按扩展名归 bookArchives；后续卷与 cb7 不算', () {
      final DroppedFiles r = classifyDroppedFiles(<String>[
        '/x/a.7z',
        '/x/b.7z.001',
        '/x/b.7z.002',
        '/x/c.zip.001',
        '/x/d.cb7',
      ]);
      expect(r.bookArchives, <String>[
        '/x/a.7z',
        '/x/b.7z.001',
        '/x/c.zip.001',
      ]);
      expect(r.mangas, <String>['/x/d.cb7']);
      expect(r.unknown, <String>['/x/b.7z.002']);
    });

    test('不注入判据时 zip / rar 的分类与改动前一致', () {
      final DroppedFiles r = classifyDroppedFiles(<String>[
        '/x/a.zip',
        '/x/b.rar',
      ]);
      expect(r.dictionaries, <String>['/x/a.zip']);
      expect(r.mangas, <String>['/x/b.rar']);
      expect(r.bookArchives, isEmpty);
    });

    test('词典页拖放：.7z / .rar 按词典包收（落点意图是词典，拍板 design-dict-drop-7z-rar）', () {
      expect(
        classifyDroppedFilesForDictionary(<String>[
          '/x/a.zip',
          '/x/b.7z',
          '/x/c.rar',
        ]),
        <String>['/x/a.zip', '/x/b.7z', '/x/c.rar'],
      );
    });
  });

  group('decideDropIntent · importBookArchive', () {
    DroppedFiles files({
      List<String> bookArchives = const <String>[],
      List<String> books = const <String>[],
      List<String> mangas = const <String>[],
    }) => DroppedFiles(
      books: books,
      videos: const <String>[],
      subtitles: const <String>[],
      audios: const <String>[],
      playlists: const <String>[],
      dictionaries: const <String>[],
      urls: const <String>[],
      unknown: const <String>[],
      mangas: mangas,
      bookArchives: bookArchives,
    );

    test('书架与漫画库都产出 importBookArchive，且先于单本书', () {
      for (final DropSurface surface in <DropSurface>[
        DropSurface.books,
        DropSurface.manga,
      ]) {
        expect(
          decideDropIntent(
            surface: surface,
            files: files(
              bookArchives: <String>['/x/a.7z'],
              books: <String>['/x/b.epub'],
            ),
            cardHit: false,
          ),
          DropIntent.importBookArchive,
          reason: surface.name,
        );
      }
    });

    test('漫画载体仍优先', () {
      expect(
        decideDropIntent(
          surface: DropSurface.books,
          files: files(
            bookArchives: <String>['/x/a.7z'],
            mangas: <String>['/x/v.cbz'],
          ),
          cardHit: false,
        ),
        DropIntent.importNewManga,
      );
    });

    test('视频页拖一包书 → 明确提示不支持，不静默', () {
      expect(
        decideDropIntent(
          surface: DropSurface.video,
          files: files(bookArchives: <String>['/x/a.7z']),
          cardHit: false,
        ),
        DropIntent.unsupportedSurface,
      );
    });
  });

  group('probeDroppedBookArchives', () {
    test('只开 zip / rar，跳过已判成页图包的路径，判据抛出按 false', () async {
      final List<String> probed = <String>[];
      final Map<String, bool> r = await probeDroppedBookArchives(
        <String>['/x/a.zip', '/x/b.rar', '/x/c.7z', '/x/d.epub', '/x/e.zip'],
        imageArchives: <String, bool>{'/x/e.zip': true},
        probe: (String path) async {
          probed.add(path);
          if (path.endsWith('.rar')) throw StateError('7z broke');
          return true;
        },
      );
      expect(probed, <String>['/x/a.zip', '/x/b.rar']);
      expect(r, <String, bool>{'/x/a.zip': true, '/x/b.rar': false});
    });
  });
}
