import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-791 source-scan guard：书架的 `hibikiBooksProvider` / `srtBooksProvider` 是
/// `FutureProvider`，本身不监听 DB；历史上靠每个导入/变更点各自 `ref.invalidate`
/// 刷新——哪天冒出一个不 invalidate 的加书路径（如外部打开、跨设备下载），新导入
/// 的书就要重启/重进才出现（与视频库 BUG-791 同病）。
///
/// 根因修复：两个 provider 各 `ref.watch` 一个监听 DB 行集的 StreamProvider
/// （`_epubBookKeysProvider` / `_srtBookUidsProvider`，底层
/// `watchEpubBookKeys()` / `watchSrtBookUids()` + `.distinct` 按集合去重），任意
/// 导入路径落库后自动重算，无需每个导入点各自记得刷新。
///
/// DB 流本身的行为由 `test/database/epub_books_test.dart` 的 `watchEpubBookKeys` 组与
/// `test/database/srt_books_test.dart` 的 `watchSrtBookUids` 组守；这里守 *provider
/// 接线*：若 provider 不再订阅这些流，本测试转红，提醒回归者书架将退回「导入不
/// 自动出现」。
void main() {
  // Tests run with CWD = `hibiki/`.
  final File source = File('lib/src/media/sources/reader_hibiki_source.dart');

  test('reader_hibiki_source.dart exists', () {
    expect(source.existsSync(), isTrue);
  });

  test('book providers subscribe to DB row-set watch streams', () {
    final String src = source.readAsStringSync();
    expect(src.contains('watchEpubBookKeys()'), isTrue,
        reason: 'BUG-791：EPUB 书集合响应式来源必须订阅 watchEpubBookKeys');
    expect(src.contains('watchSrtBookUids()'), isTrue,
        reason: 'BUG-791：有声书集合响应式来源必须订阅 watchSrtBookUids');
    expect(src.contains('ref.watch(_epubBookKeysProvider)'), isTrue,
        reason: 'BUG-791：hibikiBooksProvider 必须订阅 EPUB 书集合以自动刷新');
    expect(src.contains('ref.watch(_srtBookUidsProvider)'), isTrue,
        reason: 'BUG-791：srtBooksProvider 必须订阅有声书集合以自动刷新');
  });
}
