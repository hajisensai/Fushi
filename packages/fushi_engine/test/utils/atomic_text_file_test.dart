import 'dart:io';

import 'package:fushi_engine/utils/misc/atomic_text_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('atomic_text_file_');
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('目标不存在时建好父目录并写入，不留 .tmp', () async {
    final File target = File(p.join(temporary.path, 'a', 'b', 'out.json'));
    await writeTextFileAtomically(target, '{"v":1}');
    expect(target.readAsStringSync(), '{"v":1}');
    expect(File('${target.path}.tmp').existsSync(), isFalse);
  });

  test('目标已存在时 rename 直接覆盖', () async {
    final File target = File(p.join(temporary.path, 'out.json'))
      ..writeAsStringSync('old');
    await writeTextFileAtomically(target, 'new');
    expect(target.readAsStringSync(), 'new');
    expect(File('${target.path}.tmp').existsSync(), isFalse);
  });

  // 行为断言测不到「崩溃时刻目标是否存在」，只能钉源码：先 delete 再 rename 会
  // 开出一个目标完全不存在的窗口。漫画 OCR 的逐页缓存与整卷中间产物都走这个
  // helper，不得各自再手写一份。
  test('源码守卫：helper 与它的调用方都不先 delete 再 rename', () {
    final String helper = File(
      'lib/utils/misc/atomic_text_file.dart',
    ).readAsStringSync();
    expect(helper, isNot(contains('.delete(')));

    final String folderJob = File(
      'lib/ocr/manga_ocr_folder_job.dart',
    ).readAsStringSync();
    expect(folderJob, contains('writeTextFileAtomically('));
    expect(folderJob, isNot(contains('.rename(')));
    expect(folderJob, isNot(contains("'.tmp'")));
    expect(folderJob, isNot(contains(r".path}.tmp'")));
  });
}
