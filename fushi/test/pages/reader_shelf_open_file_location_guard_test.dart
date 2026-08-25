import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 书架书卡「打开文件位置」的接线守卫。
///
/// 这条动作只在有文件管理器契约的桌面端成立。门控一旦被删，移动端会多出一个点了
/// 必然失败的菜单项——它不会让任何测试变红，只会让用户点了以为坏了，所以判据放在
/// 源码层：门控表达式必须**紧挨着**这条动作本身，而不是文件里某处出现过。
void main() {
  final String source =
      File('lib/src/pages/implementations/reader_fushi_history_page.dart')
          .readAsStringSync();

  test('「打开文件位置」被 currentRevealHost 门控', () {
    // \s 覆盖 \r\n，故本判据在 CRLF 与 LF 两种 checkout 下同样成立。
    expect(
      RegExp(r'currentRevealHost\(\)\s*!=\s*null\s*\)\s*DialogListAction\('
              r'\s*label:\s*t\.book_file_location_open')
          .hasMatch(source),
      isTrue,
      reason: '门控必须直接包住这条动作，移动端不得出现点了必失败的菜单项',
    );
  });

  test('定位走共享的书路径原语，不在页面里另拼一份路径', () {
    expect(source, contains('revealBookLocation('));
    // 页面里自己 join extractDir/epubPath = 又一份会和 [bookMainFilePath] 漂移的
    // 路径逻辑；三种书身份取路径只允许有一处实现。
    expect(source.contains('.extractDir, '), isFalse,
        reason: '书主文件路径只能由 bookMainFilePath 决定');
  });
}
