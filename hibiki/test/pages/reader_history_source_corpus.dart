import 'dart:io';

/// TODO-587: `reader_hibiki_history_page.dart` 被拆成主壳 + `reader_history/*.part.dart`
/// 五个 part 文件（card_widgets / remote / video / books / dialogs）。原来逐文件硬编码
/// 读单文件的静态守卫，现在读这份「合并语料」：主壳 + 全部 part 文件按固定顺序拼接。
///
/// part 文件里的方法仍是 2 空格缩进的 `extension on _ReaderHibikiHistoryPageState` 成员，
/// 顶层类/常量也照搬不动，所以基于方法签名 / 类名 / 字符串切片的守卫逻辑零改写，只把
/// 数据源从「单文件」换成「合并语料」。新增 part 文件时补进 [_readerHistoryFiles] 即可。
const List<String> _readerHistoryFiles = <String>[
  'lib/src/pages/implementations/reader_hibiki_history_page.dart',
  'lib/src/pages/implementations/reader_history/card_widgets.part.dart',
  'lib/src/pages/implementations/reader_history/remote.part.dart',
  'lib/src/pages/implementations/reader_history/video.part.dart',
  'lib/src/pages/implementations/reader_history/books.part.dart',
  'lib/src/pages/implementations/reader_history/dialogs.part.dart',
];

/// 读「书架页合并语料」：主壳 + 五个 part 文件拼成单个字符串，供静态守卫切片/断言。
String readReaderHistorySource() {
  final StringBuffer buffer = StringBuffer();
  for (final String path in _readerHistoryFiles) {
    buffer.writeln(File(path).readAsStringSync());
  }
  return buffer.toString();
}
