import 'package:flutter_test/flutter_test.dart';

import 'reader_history_source_corpus.dart';

/// 书架书卡「打开文件位置」的接线守卫。
///
/// 这条动作只在有文件管理器契约的桌面端成立。门控一旦被删，移动端会多出一个点了
/// 必然失败的菜单项——它不会让任何测试变红，只会让用户点了以为坏了，所以判据放在
/// 源码层：门控表达式必须**紧挨着**这条动作本身，而不是文件里某处出现过。
///
/// 数据源是「书架页合并语料」（主壳 + 磁盘枚举的全部 `reader_history/*.part.dart`，
/// TODO-2707）：书卡菜单的兄弟动作本来就住在 `books.part.dart` 里，只读主壳单文件时
/// 下面那条**负向**断言会真空通过——第二份路径拼法写进 part 文件照样绿。
void main() {
  final String source = readReaderHistorySource();

  test('「打开文件位置」被 currentRevealHost 门控', () {
    // \s 覆盖 \r\n，故本判据在 CRLF 与 LF 两种 checkout 下同样成立。
    expect(
      RegExp(
        r'currentRevealHost\(\)\s*!=\s*null\s*\)\s*DialogListAction\('
        r'\s*label:\s*t\.book_file_location_open',
      ).hasMatch(source),
      isTrue,
      reason: '门控必须直接包住这条动作，移动端不得出现点了必失败的菜单项',
    );
  });

  test('定位走共享的书路径原语，不在页面里另拼一份路径', () {
    expect(source, contains('revealBookLocation('));
    // 页面（含全部 part）里自己 join extractDir/epubPath = 又一份会和
    // [bookMainFilePath] 漂移的路径逻辑；三种书身份取路径只允许有一处实现。
    expect(
      source.contains('.extractDir, '),
      isFalse,
      reason: '书主文件路径只能由 bookMainFilePath 决定',
    );
  });
}
