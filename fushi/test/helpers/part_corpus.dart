import 'dart:io';

/// 「主壳 + `<dir>/*.part.dart`」型**合并语料**的共享枚举。
///
/// 本仓有 4 份这种语料（阅读器页 / 书架页 / 视频页 / 同步设置 schema），各自被几十到
/// 90+ 个静态守卫当数据源读。其中大量断言是**负向**的（`isNot(contains(...))`），而负向
/// 断言有个天然弱点：**语料少读一个文件，它照样绿**——不是被禁的符号真的没了，是根本
/// 没扫到那个文件。
///
/// 手写 part 清单正好在持续制造这种真空：新增 / 改名一个 part 要靠人记得回来补清单，
/// 漏了没有任何反馈。**这不是假想威胁**——本文件落地时，磁盘上已经有 3 个 part 不在
/// 任何清单里：`sync_settings_schema/data_root.part.dart`、
/// `video_fushi/flicker_notice.part.dart`、`video_fushi/quality.part.dart`。
///
/// 所以清单一律**从磁盘枚举**（排序保证跨机器/跨次运行顺序确定），新 part 自动进语料，
/// 负向断言不可能因为漏登记而假绿。
///
/// 目录不存在 / 一个 part 都没有一律 `throw`，绝不退化成「只剩主壳」——那正是最典型的
/// 静默假绿形态（语料变短，所有 `isNot(contains(...))` 一起真空通过）。
List<String> partCorpusFiles({
  required String shell,
  required String partDir,
}) {
  final Directory dir = Directory(partDir);
  if (!dir.existsSync()) {
    throw StateError('$partDir 不存在——part 目录被搬走了，'
        '本语料及其全部消费方守卫需同步更新（否则它们会静默只扫主壳）');
  }
  final List<String> parts = dir
      .listSync()
      .whereType<File>()
      .map((File f) => f.path.replaceAll(r'\', '/'))
      .where((String p) => p.endsWith('.part.dart'))
      .toList()
    ..sort();
  if (parts.isEmpty) {
    throw StateError('$partDir 下一个 *.part.dart 都没有——要么目录结构变了，'
        '要么工作目录不是 hibiki/；此时语料只剩主壳，'
        '所有落在 part 里的守卫（含负向断言）都会真空通过');
  }
  return <String>[shell, ...parts];
}

/// 把 [files] 逐个读出来拼成单个字符串（CRLF 归一成 LF），供静态守卫切片/断言。
///
/// 主壳恒在首位（各语料都有「build 域内 widget 相对顺序」这类断言依赖它）。
String readPartCorpus(List<String> files) {
  final StringBuffer buffer = StringBuffer();
  for (final String path in files) {
    buffer.writeln(File(path).readAsStringSync().replaceAll('\r\n', '\n'));
  }
  return buffer.toString();
}
