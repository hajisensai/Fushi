import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop_drop is only imported inside the platform-gated wrapper', () {
    final Directory libDir = Directory('lib');
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in libDir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      // 唯一允许引用 desktop_drop 的文件。
      if (e.path
          .replaceAll(r'\', '/')
          .endsWith('src/media/drag_drop/hibiki_file_drop_target.dart')) {
        continue;
      }
      final String src = e.readAsStringSync();
      if (src.contains('package:desktop_drop/')) {
        offenders.add(e.path);
      }
    }
    expect(offenders, isEmpty,
        reason:
            'desktop_drop 只能在 hibiki_file_drop_target.dart 里引用（平台门控）；其余文件请用 HibikiFileDropTarget');
  });
}
