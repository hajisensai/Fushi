import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';

/// BUG-2274：`sanitizeTtuFilename` / `unsanitizeTtuFilename` 必须成对无损。
/// 云盘远端书的文件夹名 = sanitize(title)，列举时必须反解成 raw title，否则去重再
/// sanitize 一次就成了 `%253A`。
void main() {
  const List<String> titles = <String>[
    'Love, Death and Robots: The Official Anthology',
    'a/b?c<d>e\\f:g|h%i"j',
    '100% 自由',
    'trailing space ',
    'trailing dot.',
    'star*wars',
    'A%3AB', // 原文里本来就有字面 %3A：sanitize 把 % 编成 %25，反解只解一趟
    '日本語のタイトル：副題',
  ];

  test('sanitize → unsanitize 往返恒等', () {
    for (final String title in titles) {
      expect(unsanitizeTtuFilename(sanitizeTtuFilename(title)), title,
          reason: title);
    }
  });

  test('反解后的 raw title 再 sanitize 一次就是本地 bookKey（去重键一致）', () {
    for (final String title in titles) {
      final String folderName = sanitizeTtuFilename(title);
      expect(sanitizeTtuFilename(unsanitizeTtuFilename(folderName)), folderName,
          reason: title);
    }
  });

  test('直接拿文件夹名当 title 会二次编码（这就是 BUG-2274 的形状）', () {
    const String title = 'Love, Death and Robots: The Official Anthology';
    final String folderName = sanitizeTtuFilename(title);
    expect(folderName, contains('%3A'));
    expect(sanitizeTtuFilename(folderName), contains('%253A'));
    expect(sanitizeTtuFilename(folderName), isNot(folderName));
  });
}
