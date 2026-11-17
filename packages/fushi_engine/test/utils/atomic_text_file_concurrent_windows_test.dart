// Windows 专属：两个写者在同一瞬间 rename 到同一个目标时，`MoveFileEx` 会让其中
// 一些以「拒绝访问」失败（POSIX 没有这个限制，那边所有写者都成功，见
// atomic_text_file_concurrent_test.dart）。这个平台限制没有消掉（BUG-4801
// 备注）；这里钉住的是它的边界：落败的写者只能干净地失败。
@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/utils/misc/atomic_text_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('atomic_text_file_win_');
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('并发写同一个目标：目标是其中一份完整内容、不留临时文件，落败的写者只以文件系统错误收场', () async {
    final File target = File(p.join(temporary.path, 'page.json'));
    final List<String> contents = <String>[
      for (int i = 0; i < 12; i++) jsonEncode(List<int>.filled(200000, i)),
    ];
    final List<Object?> outcomes = await Future.wait(<Future<Object?>>[
      for (final String content in contents)
        writeTextFileAtomically(
          target,
          content,
        ).then<Object?>((_) => null, onError: (Object error) => error),
    ]);
    final List<Object> failures = outcomes.nonNulls.toList();
    expect(failures, everyElement(isA<FileSystemException>()));
    expect(failures.length, lessThan(contents.length), reason: '至少有一个写者成功');
    expect(contents, contains(target.readAsStringSync()));
    expect(<String>[
      for (final FileSystemEntity entry in temporary.listSync())
        if (entry.path.endsWith('.tmp')) p.basename(entry.path),
    ], isEmpty);
  });
}
