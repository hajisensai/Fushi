import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1299 / BUG-595 源码守卫：手机（默认 lapis 卡组）制卡无书籍封面。
///
/// 根因 = 制卡取封面的唯一入口 `mining.part.dart` 里
///   `if (_book?.coverHref != null && _extractDir != null) { coverPath = ... }`
/// 只在 `_book.coverHref` 非空时才拿到 coverPath。主解析路径 `parseBookOnly`
/// （epub_parser.dart）会设 coverHref；但当主解析抛 `FormatException` 回退到
/// `_buildBookFromDb` / `_buildLegacyBook` 构造 `EpubBook` 时**漏设 coverHref**，
/// 导致回退路径下 `_book.coverHref==null` → coverPath 恒 null → 制卡无书籍封面
/// （AnkiDroid / AnkiConnect 两端对称，都是 `<img src>` 嵌入，上游 coverPath 为 null
/// 时无从嵌入）。DB 行 `EpubBooks.coverPath` 存的正是导入时落库的相对封面 href
/// （epub_importer.dart：`coverPath: book.coverHref`），与 `_extractDir` 拼接即封面文件。
///
/// 修复 = 两个回退构造点都补 coverHref：
///   (1) `_buildBookFromDb` 的 `EpubBook(...)` 传 `coverHref: row.coverPath`；
///   (2) `_buildLegacyBook` 增 `{String? coverHref}` 形参并在 `EpubBook(...)` 透传，
///       调用点传 `bookRow?.coverPath`。
///
/// 守卫断言修复结构在位；删掉任一 coverHref 透传即红。ReaderHibikiPage 过重
/// （WebView + 音频 + 全 ProviderContainer），无法在 widget test 可靠拉起跑
/// `_buildBookFromDb` / `_buildLegacyBook`（皆为 State 私有方法），故落在最强可靠
/// 可落地的源码语料层（与 reader_* 一系列 *_static_test 同纪律）。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('回退路径 _buildBookFromDb / _buildLegacyBook 构造 EpubBook 时携带 coverHref',
      () {
    final String src =
        read('lib/src/pages/implementations/reader_hibiki_page.dart');

    // 界定三段函数体的切片边界（按定义顺序：_buildBookFromDb -> _buildLegacyBook ->
    // _persistRecomputedCharCounts）。
    final int fromDbStart = src.indexOf('Future<EpubBook?> _buildBookFromDb(');
    expect(fromDbStart, greaterThan(-1), reason: '找不到 _buildBookFromDb 定义');
    final int legacyStart = src.indexOf('EpubBook _buildLegacyBook(');
    expect(legacyStart, greaterThan(fromDbStart),
        reason: '找不到 _buildLegacyBook 定义');
    final int legacyEnd =
        src.indexOf('_persistRecomputedCharCounts', legacyStart);
    expect(legacyEnd, greaterThan(legacyStart),
        reason: '找不到 _buildLegacyBook 之后的边界方法');

    final String fromDbBody = src.substring(fromDbStart, legacyStart);
    final String legacyBody = src.substring(legacyStart, legacyEnd);

    // (1) _buildBookFromDb 从 DB 行取封面：EpubBook 携带 coverHref: row.coverPath。
    expect(fromDbBody.contains('coverHref: row.coverPath'), isTrue,
        reason:
            '_buildBookFromDb 必须给 EpubBook 传 coverHref: row.coverPath，否则回退路径制卡无封面');

    // (2) _buildLegacyBook 声明可选 coverHref 形参并透传给 EpubBook。
    expect(
        RegExp(r'_buildLegacyBook\(\s*String extractDir\s*,\s*\{\s*String\?\s+coverHref\s*\}')
            .hasMatch(legacyBody),
        isTrue,
        reason: '_buildLegacyBook 必须接受 {String? coverHref} 形参');
    expect(legacyBody.contains('coverHref: coverHref'), isTrue,
        reason: '_buildLegacyBook 必须把 coverHref 透传给 EpubBook');

    // (3) 调用点把 DB 行的 coverPath 喂给 _buildLegacyBook。
    expect(
        src.contains(
            '_buildLegacyBook(extractDir, coverHref: bookRow?.coverPath)'),
        isTrue,
        reason: '_buildLegacyBook 调用点必须传 coverHref: bookRow?.coverPath');
  });
}
