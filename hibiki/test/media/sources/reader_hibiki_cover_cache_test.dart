import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// BUG-513: EPUB 封面 imageUrl 非持久列，_resolveCoverUrl 每次书架重建都用异步
/// File.exists() 即时探测。hibikiBooksProvider 被大量 invalidate 重跑，deleteBook
/// 的 VACUUM/checkpoint 后紧随的重探在 IO 竞争下 File.exists() 偶发 false 时当次
/// imageUrl 塌成 null 被书架 AsyncValue 缓存，封面运行期消失，须冷启动才恢复。
///
/// 根因修复：探测成功的封面 URL 进程内缓存(按稳定 bookKey)，一次瞬时探测落空时
/// 回落上次成功值而非无条件返回 null。下面两层测试锁死这一不变量：
/// - 纯函数 resolveCoverUrlFor(mock 文件系统)：瞬时全落空回落 last-good 而非 null。
/// - DB 集成(走 mediaItemForBookKey -> _bookToMediaItem -> _resolveCoverUrl 真实
///   路径，与书架 getBooksFromDb 复用同一解析链)：封面文件先在盘上 imageUrl 解析
///   成功；再模拟瞬时探测落空后重建 imageUrl 不塌空。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderHibikiSource.resolveCoverUrlFor 纯函数 last-good 回落 (BUG-513)', () {
    setUp(ReaderHibikiSource.debugResetCoverCache);
    tearDown(ReaderHibikiSource.debugResetCoverCache);

    test('探测命中：返回首个存在候选的 file 协议 URL 并写入缓存', () async {
      final Map<String, String> cache = <String, String>{};
      const String hit = '/books/Kokoro/cover.jpg';
      final String? url = await ReaderHibikiSource.resolveCoverUrlFor(
        bookKey: 'Kokoro',
        candidates: <String>[
          '/books/Kokoro/cover.jpg',
          '/books/Kokoro/cover.png',
        ],
        probe: (String path) async => path == hit,
        cache: cache,
      );

      expect(url, Uri.file(hit).toString());
      expect(cache['Kokoro'], Uri.file(hit).toString());
    });

    test('声明封面路径优先于 cover 兜底(两者都存在时取首个)', () async {
      final String? url = await ReaderHibikiSource.resolveCoverUrlFor(
        bookKey: 'Botchan',
        candidates: <String>[
          '/books/Botchan/OEBPS/images/decl.png',
          '/books/Botchan/cover.jpg',
        ],
        probe: (String _) async => true,
        cache: <String, String>{},
      );
      expect(url, Uri.file('/books/Botchan/OEBPS/images/decl.png').toString());
    });

    test('瞬时全落空但缓存有 last-good：回落上次成功值而非 null', () async {
      final Map<String, String> cache = <String, String>{};
      const String hit = '/books/Kokoro/cover.jpg';

      final String? first = await ReaderHibikiSource.resolveCoverUrlFor(
        bookKey: 'Kokoro',
        candidates: <String>[hit],
        probe: (String path) async => path == hit,
        cache: cache,
      );
      expect(first, Uri.file(hit).toString());

      final String? second = await ReaderHibikiSource.resolveCoverUrlFor(
        bookKey: 'Kokoro',
        candidates: <String>[hit],
        probe: (String _) async => false,
        cache: cache,
      );

      expect(second, Uri.file(hit).toString(),
          reason: '瞬时探测落空必须回落 last-good，否则封面运行期消失(BUG-513)');
    });

    test('从未成功过(缓存为空)且探测落空：返回 null(不凭空捏造路径)', () async {
      final String? url = await ReaderHibikiSource.resolveCoverUrlFor(
        bookKey: 'NoCover',
        candidates: <String>['/books/NoCover/cover.jpg'],
        probe: (String _) async => false,
        cache: <String, String>{},
      );
      expect(url, isNull);
    });

    test('空 bookKey：不进缓存、不回落(避免不同书串味)', () async {
      final Map<String, String> cache = <String, String>{'': 'file:///stale'};
      final String? url = await ReaderHibikiSource.resolveCoverUrlFor(
        bookKey: '',
        candidates: <String>['/x/cover.jpg'],
        probe: (String _) async => false,
        cache: cache,
      );
      expect(url, isNull, reason: '空 key 不共享缓存槽，避免跨书污染');
    });
  });

  group('ReaderHibikiSource.coverCandidatePaths 候选顺序 (BUG-513)', () {
    test('有声明封面：声明路径在前，cover.jpg/jpeg/png 兜底在后', () {
      final String extractDir = p.join('books', 'Kokoro');
      final List<String> c = ReaderHibikiSource.coverCandidatePaths(
        extractDir: extractDir,
        coverPath: 'OEBPS/cover-img.png',
      );
      // 声明封面来自 EPUB，通常带正斜杠；p.join 保留其内部分隔符，只在与
      // extractDir 拼接处补平台分隔符。关键不变量是它排在候选首位。
      expect(c.first, p.join(extractDir, 'OEBPS/cover-img.png'));
      expect(c, contains(p.join('books', 'Kokoro', 'cover.jpg')));
      expect(c, contains(p.join('books', 'Kokoro', 'cover.jpeg')));
      expect(c, contains(p.join('books', 'Kokoro', 'cover.png')));
    });

    test('无声明封面：仅 cover 兜底', () {
      final List<String> c = ReaderHibikiSource.coverCandidatePaths(
        extractDir: p.join('books', 'Botchan'),
      );
      expect(c, <String>[
        p.join('books', 'Botchan', 'cover.jpg'),
        p.join('books', 'Botchan', 'cover.jpeg'),
        p.join('books', 'Botchan', 'cover.png'),
      ]);
    });
  });

  group('书架数据源封面不因重建塌空 (BUG-513 真实解析链)', () {
    late Directory tempDir;

    setUp(() {
      ReaderHibikiSource.debugResetCoverCache();
      tempDir = Directory.systemTemp.createTempSync('hibiki_cover_cache_');
    });
    tearDown(() {
      ReaderHibikiSource.debugResetCoverCache();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    EpubBooksCompanion bookWithCover(String key, String extractDir) {
      return EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: p.join(tempDir.path, '$key.epub'),
        extractDir: extractDir,
        coverPath: const Value('cover.jpg'),
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }

    test(
        '封面文件在盘上 imageUrl 解析成功；随后模拟瞬时探测落空(删文件)后重建，'
        'imageUrl 仍回落 last-good 不塌成 null', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final Directory extractDir = Directory(p.join(tempDir.path, 'Kokoro'))
        ..createSync(recursive: true);
      final File cover = File(p.join(extractDir.path, 'cover.jpg'))
        ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);
      await db.insertEpubBook(bookWithCover('Kokoro', extractDir.path));

      final ReaderHibikiSource source = ReaderHibikiSource.instance;

      final MediaItem? first = await source.mediaItemForBookKey('Kokoro');
      final String expectedUrl = Uri.file(cover.path).toString();
      expect(first, isNotNull);
      expect(first!.imageUrl, expectedUrl);

      cover.deleteSync();
      final MediaItem? second = await source.mediaItemForBookKey('Kokoro');

      expect(second, isNotNull);
      expect(second!.imageUrl, expectedUrl,
          reason: '重建期探测落空必须回落 last-good，封面不得消失(BUG-513)');
    });
  });
}
