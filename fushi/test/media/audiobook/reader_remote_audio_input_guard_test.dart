// 源码守卫：阅读器里把音频交给 ffmpeg 的地方（句子音频制卡、片段导出）必须经
// `AudiobookPlayerController.trackInputFor`，并把它给的鉴权头一起传下去。
//
// 为什么要守：流式（Audiobookshelf）书的 `controller.audioFiles` 是**不存在于磁盘的
// 占位文件**。哪天有人图省事写回 `inputPath: audioFiles[i].path`，本机书照样能用、
// 测试全绿，流式书的制卡却静默失败（ffmpeg 报输入不存在，用户只看到「没有句子音频」）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final Directory readerDir = Directory(
    'lib/src/pages/implementations/reader_fushi',
  );

  List<File> readerParts() => <File>[
    for (final FileSystemEntity e in readerDir.listSync(recursive: true))
      if (e is File && e.path.endsWith('.dart')) e,
  ];

  test('阅读器的 part 文件非空（守卫没有扫空目录）', () {
    expect(readerParts(), isNotEmpty);
  });

  test('inputPath: 一律来自 trackInputFor 的结果，且紧跟着传 httpHeaders', () {
    final List<String> violations = <String>[];
    int checked = 0;
    for (final File file in readerParts()) {
      final List<String> lines = file.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (!lines[i].contains('inputPath:')) continue;
        checked++;
        final String where = '${p.basename(file.path)}:${i + 1}';
        if (!lines[i].contains('audioInput.input')) {
          violations.add(
            '$where inputPath 不是 audioInput.input: ${lines[i].trim()}',
          );
        }
        final String next = lines.skip(i + 1).take(2).join('\n');
        if (!next.contains('httpHeaders: audioInput.headers')) {
          violations.add('$where inputPath 后面没有传 httpHeaders');
        }
      }
    }
    expect(checked, greaterThanOrEqualTo(2), reason: '制卡与片段导出两处');
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('阅读器里没有 audioFiles[…].path 这类直接取本机路径的写法', () {
    final RegExp direct = RegExp(r'audioFiles\s*(\?|!)?\s*\[[^\]]*\]\s*\.path');
    // 注释里讲「不要这样写」不算违规：只看代码行。
    String codeOf(File file) => file
        .readAsLinesSync()
        .where((String line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    final List<String> violations = <String>[
      for (final File file in readerParts())
        if (direct.hasMatch(codeOf(file))) p.basename(file.path),
    ];
    expect(violations, isEmpty, reason: '改走 trackInputFor：$violations');
  });
}
