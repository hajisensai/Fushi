import 'dart:io';

/// TODO-589: `reader_hibiki_page.dart` 正被分批拆成主壳 + `reader_hibiki/*.part.dart`
/// 一组 part 文件（零行为重构）。原来逐文件硬编码读单文件的静态守卫，凡断言落在已搬出
/// 主壳的方法体里，必须改读这份「合并语料」：主壳 + 全部 part 文件按固定顺序拼接。
///
/// part 文件里的方法仍是 2 空格缩进的 `extension on _ReaderHibikiPageState` 成员，主壳
/// 顶层 class / 常量 / 其它方法照搬不动，所以基于方法签名 / 字符串切片的守卫逻辑零改写，
/// 只把数据源从「单文件」换成「合并语料」。新增 part 文件时补进 [_readerHibikiPageFiles]。
///
/// 批1（lyrics）只列主壳 + lyrics.part；后续批往里追加 part 路径即可。
const List<String> _readerHibikiPageFiles = <String>[
  'lib/src/pages/implementations/reader_hibiki_page.dart',
  'lib/src/pages/implementations/reader_hibiki/lyrics.part.dart',
  'lib/src/pages/implementations/reader_hibiki/mining.part.dart',
  'lib/src/pages/implementations/reader_hibiki/lookup.part.dart',
  'lib/src/pages/implementations/reader_hibiki/navigation.part.dart',
  'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
  'lib/src/pages/implementations/reader_hibiki/caret.part.dart',
  'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
];

/// 读「阅读器页合并语料」：主壳 + 全部 part 文件拼成单个字符串，供静态守卫切片/断言。
/// 统一把 CRLF 归一成 LF，与逐文件守卫此前的隐式假设一致。
String readReaderPageSource() {
  final StringBuffer buffer = StringBuffer();
  for (final String path in _readerHibikiPageFiles) {
    buffer.writeln(File(path).readAsStringSync().replaceAll('\r\n', '\n'));
  }
  return buffer.toString();
}
