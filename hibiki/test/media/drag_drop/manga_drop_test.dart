import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/drop_decision.dart';

/// 漫画库的拖入曾是个功能空洞：`MangaLibraryPage` 只是
/// `ReaderHibikiHistoryPage(mangaOnly: true)` 的壳，白拿了书架的 drop target，但
/// 分类与决策两层从没加过漫画语义——拖 `.mokuro` / `.cbz` / 页图**目录**进去全部
/// 静默无反应（分类落 unknown → decideDropIntent 返回 ignore），而这些东西按钮
/// 导入路径全都支持。拖 `.cbr` 同样静默。
///
/// 这里守卫修复后的口径：漫画载体被认出来 → importNewManga；认得出但导不了的
/// RAR 系 → 明确提示而非静默；漫画库拖入非漫画 → 明确提示而非悄悄导去别的书架。
void main() {
  group('classifyDroppedFiles — 漫画载体', () {
    test('.mokuro 归 mangas', () {
      final DroppedFiles files =
          classifyDroppedFiles(<String>['/a/vol1.mokuro']);
      expect(files.mangas, <String>['/a/vol1.mokuro']);
      expect(files.unknown, isEmpty, reason: '曾经落 unknown → 静默无反应');
    });

    test('.cbz 归 mangas', () {
      final DroppedFiles files = classifyDroppedFiles(<String>['/a/vol1.cbz']);
      expect(files.mangas, <String>['/a/vol1.cbz']);
      expect(files.unknown, isEmpty);
    });

    test('.cbr/.rar 归 unsupportedMangas（认得出但 archive 包不解 RAR）', () {
      final DroppedFiles files =
          classifyDroppedFiles(<String>['/a/v.cbr', '/a/v.rar']);
      expect(files.unsupportedMangas, <String>['/a/v.cbr', '/a/v.rar']);
      expect(files.mangas, isEmpty);
      expect(files.hasAny, isTrue, reason: '必须能触发提示，不能落进静默的 ignore');
    });

    test('目录经 isDirectory 谓词归 mangas（页图文件夹）', () {
      final DroppedFiles files = classifyDroppedFiles(
        <String>['/a/第01巻'],
        isDirectory: (String pth) => pth == '/a/第01巻',
      );
      expect(files.mangas, <String>['/a/第01巻']);
    });

    test('目录名带点也归 mangas（不被 p.extension 误当扩展名）', () {
      final DroppedFiles files = classifyDroppedFiles(
        <String>['/a/第01巻.v2'],
        isDirectory: (String pth) => pth == '/a/第01巻.v2',
      );
      expect(files.mangas, <String>['/a/第01巻.v2']);
      expect(files.unknown, isEmpty);
    });

    test('不传 isDirectory 时行为与历史一致（目录落 unknown）', () {
      final DroppedFiles files = classifyDroppedFiles(<String>['/a/第01巻']);
      expect(files.mangas, isEmpty);
      expect(files.unknown, <String>['/a/第01巻']);
    });

    test('.zip 不归漫画（无内容判据，避免把词典包当漫画导）', () {
      final DroppedFiles files = classifyDroppedFiles(<String>['/a/dict.zip']);
      expect(files.mangas, isEmpty);
      expect(files.dictionaries, <String>['/a/dict.zip']);
    });

    test('.epub 不归漫画（图片型 epub 由导入对话框真读包判定）', () {
      final DroppedFiles files = classifyDroppedFiles(<String>['/a/b.epub']);
      expect(files.mangas, isEmpty);
      expect(files.books, <String>['/a/b.epub']);
    });
  });

  group('decideDropIntent — manga 表面', () {
    DroppedFiles files({
      List<String> mangas = const <String>[],
      List<String> unsupportedMangas = const <String>[],
      List<String> books = const <String>[],
      List<String> videos = const <String>[],
    }) =>
        DroppedFiles(
          books: books,
          videos: videos,
          subtitles: const <String>[],
          audios: const <String>[],
          playlists: const <String>[],
          dictionaries: const <String>[],
          urls: const <String>[],
          mangas: mangas,
          unsupportedMangas: unsupportedMangas,
          unknown: const <String>[],
        );

    test('漫画载体 -> importNewManga', () {
      expect(
        decideDropIntent(
          surface: DropSurface.manga,
          files: files(mangas: <String>['/a/v.cbz']),
          cardHit: false,
        ),
        DropIntent.importNewManga,
      );
    });

    test('RAR 系 -> unsupportedMangaArchive（明确提示，不静默）', () {
      expect(
        decideDropIntent(
          surface: DropSurface.manga,
          files: files(unsupportedMangas: <String>['/a/v.cbr']),
          cardHit: false,
        ),
        DropIntent.unsupportedMangaArchive,
      );
    });

    test('漫画库拖普通书 -> unsupportedSurface（不悄悄导进另一个书架）', () {
      expect(
        decideDropIntent(
          surface: DropSurface.manga,
          files: files(books: <String>['/a/b.epub']),
          cardHit: false,
        ),
        DropIntent.unsupportedSurface,
      );
    });

    test('漫画库拖视频 -> unsupportedSurface（不沿用 books 表面的自动切视频）', () {
      expect(
        decideDropIntent(
          surface: DropSurface.manga,
          files: files(videos: <String>['/a/v.mp4']),
          cardHit: false,
        ),
        DropIntent.unsupportedSurface,
      );
    });

    test('什么都没有 -> ignore', () {
      expect(
        decideDropIntent(
          surface: DropSurface.manga,
          files: files(),
          cardHit: false,
        ),
        DropIntent.ignore,
      );
    });
  });

  group('decideDropIntent — books 表面也接漫画（漫画是书的一种）', () {
    DroppedFiles files({
      List<String> mangas = const <String>[],
      List<String> unsupportedMangas = const <String>[],
      List<String> books = const <String>[],
    }) =>
        DroppedFiles(
          books: books,
          videos: const <String>[],
          subtitles: const <String>[],
          audios: const <String>[],
          playlists: const <String>[],
          dictionaries: const <String>[],
          urls: const <String>[],
          mangas: mangas,
          unsupportedMangas: unsupportedMangas,
          unknown: const <String>[],
        );

    test('普通书架拖漫画包也导入漫画，不静默', () {
      expect(
        decideDropIntent(
          surface: DropSurface.books,
          files: files(mangas: <String>['/a/v.cbz']),
          cardHit: false,
        ),
        DropIntent.importNewManga,
      );
    });

    test('漫画优先于普通书文件（.mokuro 是 JSON，被 books 分支吃掉会转成乱码 EPUB）', () {
      expect(
        decideDropIntent(
          surface: DropSurface.books,
          files: files(
            mangas: <String>['/a/v.mokuro'],
            books: <String>['/a/note.txt'],
          ),
          cardHit: false,
        ),
        DropIntent.importNewManga,
      );
    });

    test('books 表面的 RAR 系也给提示', () {
      expect(
        decideDropIntent(
          surface: DropSurface.books,
          files: files(unsupportedMangas: <String>['/a/v.cbr']),
          cardHit: false,
        ),
        DropIntent.unsupportedMangaArchive,
      );
    });
  });
}
