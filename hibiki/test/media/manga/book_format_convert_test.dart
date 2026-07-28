import 'package:hibiki_core/hibiki_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/manga/book_format_convert.dart';

/// 「书 ↔ 漫画」转化的可行性判定。
///
/// 用户要求：手动导入哪个就是哪个，导错了用右键菜单转化，**转化就是重建**，
/// 「那个不匹配的说明一下，说不支持」。这里守卫的就是「什么算不匹配」，以及每种
/// 不匹配都得给出**具体**原因（能翻成一句人话），而不是笼统拒绝。
void main() {
  const BookSourceProbe present = BookSourceProbe(
    sourceExists: true,
    sourceIsImageArchive: false,
  );
  const BookSourceProbe imageArchive = BookSourceProbe(
    sourceExists: true,
    sourceIsImageArchive: true,
  );
  const BookSourceProbe missing = BookSourceProbe(
    sourceExists: false,
    sourceIsImageArchive: false,
  );

  group('转成漫画', () {
    test('PDF 恒可转（扫描版 PDF 无文本层、阅读器不做 OCR 兜底，转漫画才有查词）', () {
      final BookConvertVerdict v = verdictToManga(
        format: BookFormat.pdf,
        sourceAbsolutePath: '/books/k/hibiki.pdf',
        probe: present,
      );
      expect(v.supported, isTrue);
      expect(v.sourcePath, '/books/k/hibiki.pdf');
    });

    test('图片型 EPUB 可转（扫描版漫画的常见分发形态）', () {
      final BookConvertVerdict v = verdictToManga(
        format: BookFormat.epub,
        sourceAbsolutePath: '/books/k/scan.epub',
        probe: imageArchive,
      );
      expect(v.supported, isTrue);
      expect(v.sourcePath, '/books/k/scan.epub');
    });

    test('文字书不可转，且原因必须是 textOnlyBook（要能说清「为什么」）', () {
      final BookConvertVerdict v = verdictToManga(
        format: BookFormat.epub,
        sourceAbsolutePath: '/books/k/novel.epub',
        probe: present,
      );
      expect(v.supported, isFalse);
      expect(v.blocker, BookConvertBlocker.textOnlyBook,
          reason: '文字书没有页图，转过去只会得到一本空漫画');
      expect(v.sourcePath, isNull);
    });

    test('已经是漫画 -> alreadyTarget', () {
      final BookConvertVerdict v = verdictToManga(
        format: BookFormat.manga,
        sourceAbsolutePath: '/books/k/manga.json',
        probe: present,
      );
      expect(v.blocker, BookConvertBlocker.alreadyTarget);
    });

    test('源文件被删 -> sourceMissing（不是笼统的「不支持」）', () {
      final BookConvertVerdict v = verdictToManga(
        format: BookFormat.pdf,
        sourceAbsolutePath: '/books/k/hibiki.pdf',
        probe: missing,
      );
      expect(v.blocker, BookConvertBlocker.sourceMissing);
    });

    test('源文件不存在时即使标着图片型也不放行（先查存在性）', () {
      final BookConvertVerdict v = verdictToManga(
        format: BookFormat.epub,
        sourceAbsolutePath: '/books/k/gone.epub',
        probe: const BookSourceProbe(
          sourceExists: false,
          sourceIsImageArchive: true,
        ),
      );
      expect(v.blocker, BookConvertBlocker.sourceMissing);
    });
  });

  group('转回书', () {
    test('原始文件仍在书目录 -> 可转，且指回那个文件', () {
      final BookConvertVerdict v = verdictToBook(
        format: BookFormat.manga,
        probe: const BookSourceProbe(
          sourceExists: true,
          sourceIsImageArchive: true,
          recoverableOriginalPath: '/books/k/scan.epub',
        ),
      );
      expect(v.supported, isTrue);
      expect(v.sourcePath, '/books/k/scan.epub');
    });

    test('mokuro / 裸图片目录导入的漫画没有原始文件 -> noOriginalFile（不造假书）', () {
      final BookConvertVerdict v = verdictToBook(
        format: BookFormat.manga,
        probe: present,
      );
      expect(v.supported, isFalse);
      expect(v.blocker, BookConvertBlocker.noOriginalFile);
    });

    test('原始路径是空串也算没有', () {
      final BookConvertVerdict v = verdictToBook(
        format: BookFormat.manga,
        probe: const BookSourceProbe(
          sourceExists: true,
          sourceIsImageArchive: false,
          recoverableOriginalPath: '',
        ),
      );
      expect(v.blocker, BookConvertBlocker.noOriginalFile);
    });

    test('本来就不是漫画 -> alreadyTarget', () {
      for (final BookFormat format in <BookFormat>[
        BookFormat.epub,
        BookFormat.pdf,
      ]) {
        expect(
          verdictToBook(format: format, probe: present).blocker,
          BookConvertBlocker.alreadyTarget,
          reason: '$format 本来就是书',
        );
      }
    });
  });

  test('每个 blocker 都必须被判定函数真的产出过（没有说不出理由的拒绝）', () {
    final Set<BookConvertBlocker> produced = <BookConvertBlocker>{
      verdictToManga(
        format: BookFormat.manga,
        sourceAbsolutePath: '/a',
        probe: present,
      ).blocker!,
      verdictToManga(
        format: BookFormat.epub,
        sourceAbsolutePath: '/a',
        probe: present,
      ).blocker!,
      verdictToManga(
        format: BookFormat.pdf,
        sourceAbsolutePath: '/a',
        probe: missing,
      ).blocker!,
      verdictToBook(format: BookFormat.manga, probe: present).blocker!,
    };
    expect(produced, BookConvertBlocker.values.toSet(),
        reason: '新增 blocker 必须同时有产出它的判定路径与说明文案');
  });
}
