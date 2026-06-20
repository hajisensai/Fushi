import 'dart:io';

/// TODO-590: `video_hibiki_page.dart` 正被分批拆成主壳 + `video_hibiki/*.part.dart`
/// 一组 part 文件（零行为重构，照搬 TODO-589 reader_hibiki 范式）。原来逐文件硬编码
/// 读单文件的静态守卫，凡断言落在已搬出主壳的方法体里，必须改读这份「合并语料」：
/// 主壳 + 全部 part 文件按固定顺序拼接（主壳在前，保 build 域内 widget 相对顺序断言）。
///
/// part 文件里的方法仍是 2 空格缩进的 `extension on _VideoHibikiPageState` 成员，主壳
/// 顶层 class / 常量 / 其它方法照搬不动，所以基于方法签名 / 字符串切片的守卫逻辑零改写，
/// 只把数据源从「单文件」换成「合并语料」。新增 part 文件时补进 [_videoHibikiPageFiles]。
///
/// 批1（danmaku）只列主壳 + danmaku.part；后续批往里追加 part 路径即可。
const List<String> _videoHibikiPageFiles = <String>[
  'lib/src/pages/implementations/video_hibiki_page.dart',
  'lib/src/pages/implementations/video_hibiki/danmaku.part.dart',
];

/// 读「视频页合并语料」：主壳 + 全部 part 文件拼成单个字符串，供静态守卫切片/断言。
/// 统一把 CRLF 归一成 LF，与逐文件守卫此前的隐式假设一致。
String readVideoHibikiSource() {
  final StringBuffer buffer = StringBuffer();
  for (final String path in _videoHibikiPageFiles) {
    buffer.writeln(File(path).readAsStringSync().replaceAll('\r\n', '\n'));
  }
  return buffer.toString();
}
