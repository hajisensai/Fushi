import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';

/// Hoshi/ッツ 互通逐字节守卫。
///
/// 与 Hoshi-Reader-Android 共享同一个可见 Google Drive `ttu-reader-data` 文件夹时，
/// 一本书的云端文件夹名 = `sanitizeTtuFilename(书名)`，进度文件名 =
/// `progress_1_6_<ts>_<progress>.json`。只要两端对这两个函数的输出有一个字节不同，
/// 同一本书就会落进不同文件夹 / 选不到对方最新进度文件，互通静默失效。
///
/// 下列断言值直接抄自 Hoshi 源码的 `TtuSyncRulesTest.kt`
/// （`sanitizeTtuFilenameMatchesIosAndTtuRules` 与 progress 文件名断言），是 Hoshi /
/// ッツ web / iOS 三端共用的参考实现。改 [sanitizeTtuFilename] / [progressFileName]
/// 若动到这些输出即视为破坏互通契约，本测试会红。
void main() {
  group('Hoshi/ッツ sanitize byte-parity', () {
    test('trailing space marker matches Hoshi', () {
      expect(sanitizeTtuFilename('Book '), 'Book~ttu-spc~');
    });

    test('trailing dot marker matches Hoshi', () {
      expect(sanitizeTtuFilename('Book.'), 'Book~ttu-dend~');
    });

    test('full mixed vector matches Hoshi TtuSyncRulesTest verbatim', () {
      // Hoshi: sanitizeTtuFilename("a*b/c?d<e>f\\g:h|i%j\"k")
      expect(
        sanitizeTtuFilename('a*b/c?d<e>f\\g:h|i%j"k'),
        'a~ttu-star~b%2Fc%3Fd%3Ce%3Ef%5Cg%3Ah%7Ci%25j%22k',
      );
    });

    test('every reserved char maps to uppercase percent-encoding', () {
      // The complete reserved set Hoshi percent-encodes (`*` handled earlier as
      // ~ttu-star~): / ? < > \ : | % "
      expect(sanitizeTtuFilename('/'), '%2F');
      expect(sanitizeTtuFilename('?'), '%3F');
      expect(sanitizeTtuFilename('<'), '%3C');
      expect(sanitizeTtuFilename('>'), '%3E');
      expect(sanitizeTtuFilename('\\'), '%5C');
      expect(sanitizeTtuFilename(':'), '%3A');
      expect(sanitizeTtuFilename('|'), '%7C');
      expect(sanitizeTtuFilename('%'), '%25');
      expect(sanitizeTtuFilename('"'), '%22');
    });
  });

  group('Hoshi/ッツ progress file name parity', () {
    test('progress_1_6 template matches Hoshi verbatim', () {
      // Hoshi: progressFileName(TtuProgress(lastBookmarkModified=1700000123456,
      // progress=0.375, ...)) == "progress_1_6_1700000123456_0.375.json"
      expect(
        progressFileName(1700000123456, 0.375),
        'progress_1_6_1700000123456_0.375.json',
      );
    });

    test('audioBook_1_6 template shares the same schema marker', () {
      expect(
        audioBookFileName(1700000123456, 12.5),
        'audioBook_1_6_1700000123456_12.5.json',
      );
    });
  });
}
