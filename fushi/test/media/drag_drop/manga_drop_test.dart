import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/drop_decision.dart';

/// 漫画库的拖入曾是个功能空洞：`MangaLibraryPage` 只是
/// `ReaderFushiHistoryPage(mangaOnly: true)` 的壳，白拿了书架的 drop target，但
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

    // ↓ 用户实指：「你怎么知道是普通 epub 啊」——同理，`.zip` 也分不出是一包页图的
    //   漫画还是 Yomitan 词典包。没有判据时图片型 zip 归 dictionaries，books 分支
    //   走到 `files.hasAny` 兜底回「本页面不支持」，而导入对话框导得了它（其分派
    //   对 .zip 会真读包）——又一处「按钮能导、拖进去不认」。
    test('图片型 .zip 经 isImageArchive 判据归 mangas（此前回「本页面不支持」）', () {
      final DroppedFiles files = classifyDroppedFiles(
        <String>['/a/vol1.zip'],
        isImageArchive: (String pth) => pth == '/a/vol1.zip',
      );
      expect(files.mangas, <String>['/a/vol1.zip']);
      expect(files.dictionaries, isEmpty,
          reason: '命中图片包判据后不得再落 dictionaries（否则归属歧义）');
    });

    test('图片型 .zip 在两个表面都 -> importNewManga', () {
      final DroppedFiles files = classifyDroppedFiles(
        <String>['/a/vol1.zip'],
        isImageArchive: (String _) => true,
      );
      for (final DropSurface surface in <DropSurface>[
        DropSurface.books,
        DropSurface.manga,
      ]) {
        expect(
          decideDropIntent(surface: surface, files: files, cardHit: false),
          DropIntent.importNewManga,
          reason: '$surface 表面的图片型 zip 必须能导入而不是回「不支持」',
        );
      }
    });

    test('词典 .zip 有判据也仍归 dictionaries（不误把词典包当漫画导）', () {
      final DroppedFiles files = classifyDroppedFiles(
        <String>['/a/dict.zip'],
        isImageArchive: (String _) => false,
      );
      expect(files.mangas, isEmpty);
      expect(files.dictionaries, <String>['/a/dict.zip']);
    });

    test('判据只探 zip，不对 epub / 无关扩展名白开压缩包', () {
      final List<String> probed = <String>[];
      classifyDroppedFiles(
        <String>['/a/v.mp4', '/a/b.epub', '/a/s.srt', '/a/x.zip'],
        isImageArchive: (String pth) {
          probed.add(pth);
          return false;
        },
      );
      // epub 刻意不探：它在 books 分支就走 BookImportDialog，而对话框收下路径时会
      // 用 classifyImportCarrier 真读包，图片型 EPUB 在那里被认出并（经用户确认后）
      // 转交漫画导入——识别没丢。为每次拖 EPUB 在分类层白开一次包换不来可见改进。
      expect(probed, <String>['/a/x.zip']);
    });

    test('无判据时 .zip 维持词典包分类（向后兼容）', () {
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
      List<String> subtitles = const <String>[],
    }) =>
        DroppedFiles(
          books: books,
          videos: videos,
          subtitles: subtitles,
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

    // ↓↓↓ 「非漫画一律沿用 books 表面」是**改动前就有的行为**（漫画库是书架页的
    // mangaOnly 壳、共用同一个 drop target）。曾一度收窄成「本页面不支持」，那等于
    // 移除用户可能一直在用的能力，已按「用户没表态就保持现状」回退。要改成不支持
    // 是产品决定，不是实现细节——下面几条就是钉住不许再被顺手收窄。
    test('漫画库拖普通 epub -> importNewBook（仍自动导去书架，不得收窄成不支持）', () {
      expect(
        decideDropIntent(
          surface: DropSurface.manga,
          files: files(books: <String>['/a/b.epub']),
          cardHit: false,
        ),
        DropIntent.importNewBook,
      );
    });

    test('漫画库拖视频 -> importNewVideo（沿用 books 表面的自动切视频）', () {
      expect(
        decideDropIntent(
          surface: DropSurface.manga,
          files: files(videos: <String>['/a/v.mp4']),
          cardHit: false,
        ),
        DropIntent.importNewVideo,
      );
    });

    test('漫画库拖字幕到书卡 -> attachToBookCard（books 表面能做的这里都能做）', () {
      expect(
        decideDropIntent(
          surface: DropSurface.manga,
          files: files(subtitles: <String>['/a/s.srt']),
          cardHit: true,
        ),
        DropIntent.attachToBookCard,
      );
    });

    test('漫画载体仍优先于 books 规则：同时拖 .cbz + .epub -> importNewManga', () {
      expect(
        decideDropIntent(
          surface: DropSurface.manga,
          files: files(
            mangas: <String>['/a/m.cbz'],
            books: <String>['/a/b.epub'],
          ),
          cardHit: false,
        ),
        DropIntent.importNewManga,
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
