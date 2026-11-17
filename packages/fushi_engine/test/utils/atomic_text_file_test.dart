import 'dart:io';
import 'dart:isolate';

import 'package:fushi_engine/utils/misc/atomic_text_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 目录里残留的临时文件（任何以 `.tmp` 结尾的）。
List<String> _leftoverTemporaries(Directory dir) => <String>[
  for (final FileSystemEntity entry in dir.listSync(recursive: true))
    if (entry is File && entry.path.endsWith('.tmp')) p.basename(entry.path),
];

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
    expect(_leftoverTemporaries(temporary), isEmpty);
  });

  test('目标已存在时 rename 直接覆盖', () async {
    final File target = File(p.join(temporary.path, 'out.json'))
      ..writeAsStringSync('old');
    await writeTextFileAtomically(target, 'new');
    expect(target.readAsStringSync(), 'new');
    expect(_leftoverTemporaries(temporary), isEmpty);
  });

  group('BUG-4801：临时文件每次写入一个唯一名', () {
    test('同一目标连着取两次、别的 isolate 再取一次：名字互不相同，都在目标旁边', () async {
      final File target = File(p.join(temporary.path, 'page.json'));
      final String first = temporaryFileForAtomicWrite(target).path;
      final String second = temporaryFileForAtomicWrite(target).path;
      // 序号是顶层变量，每个 isolate 各从 0 数起：跨 isolate 不重名靠的是标签。
      final String targetPath = target.path;
      final List<String> other = await Isolate.run<List<String>>(
        () => <String>[
          temporaryFileForAtomicWrite(File(targetPath)).path,
          temporaryFileForAtomicWrite(File(targetPath)).path,
        ],
      );
      final List<String> all = <String>[first, second, ...other];
      expect(all.toSet(), hasLength(all.length), reason: '$all');
      for (final String path in all) {
        expect(p.dirname(path), temporary.path, reason: '同目录才能原子 rename');
        expect(path, endsWith('.tmp'));
        expect(path, isNot('${target.path}.tmp'), reason: '不是 per-target 固定名');
      }
    });

    // 确定性地摆出「旧写者写到一半、新写者整个写完」的交错：固定名下新写者会
    // 截断旧写者的临时文件再把它 rename 走，旧写者接着往一个不存在的文件名写、
    // 或把半截内容 rename 成目标。
    test('一个写者写到一半时另一个写者整个写完：互不相扰，各自落下完整内容', () async {
      final File target = File(p.join(temporary.path, 'page.json'));
      final File slowTemporary = temporaryFileForAtomicWrite(target);
      final RandomAccessFile slow = slowTemporary.openSync(mode: FileMode.write)
        ..writeStringSync('{"writer":"old","half":');

      await writeTextFileAtomically(target, '{"writer":"new"}');
      expect(target.readAsStringSync(), '{"writer":"new"}');
      expect(slowTemporary.existsSync(), isTrue, reason: '新写者不能把旧写者的临时文件带走');

      slow
        ..writeStringSync('true}')
        ..closeSync();
      expect(
        slowTemporary.readAsStringSync(),
        '{"writer":"old","half":true}',
        reason: '新写者不能截断 / 覆盖旧写者的临时文件',
      );
      slowTemporary.renameSync(target.path);
      expect(target.readAsStringSync(), '{"writer":"old","half":true}');
      expect(_leftoverTemporaries(temporary), isEmpty);
    });

    test('写入失败：原错误照抛，本次的临时文件不留在盘上', () async {
      // 目标位置是个目录：写临时文件成功，rename 覆盖失败。
      final Directory blocked = Directory(p.join(temporary.path, 'page.json'))
        ..createSync();
      await expectLater(
        writeTextFileAtomically(File(blocked.path), 'x'),
        throwsA(isA<FileSystemException>()),
      );
      expect(_leftoverTemporaries(temporary), isEmpty);
    });
  });

  // 行为断言测不到「崩溃时刻目标是否存在」，只能钉源码：先 delete 再 rename 会
  // 开出一个目标完全不存在的窗口。漫画 OCR 的逐页缓存与整卷中间产物都走这个
  // helper，不得各自再手写一份。
  test('源码守卫：helper 与它的调用方都不先 delete 再 rename', () {
    final String helper = File(
      'lib/utils/misc/atomic_text_file.dart',
    ).readAsStringSync();
    expect(helper, isNot(contains('.delete(')));
    expect(helper, isNot(contains('target.deleteSync(')));
    // 临时文件名只能来自 temporaryFileForAtomicWrite（BUG-4801）。
    expect(helper, isNot(contains(r"${target.path}.tmp'")));

    final String folderJob = File(
      'lib/ocr/manga_ocr_folder_job.dart',
    ).readAsStringSync();
    expect(folderJob, contains('writeTextFileAtomically('));
    expect(folderJob, isNot(contains('.rename(')));
    expect(folderJob, isNot(contains("'.tmp'")));
    expect(folderJob, isNot(contains(r".path}.tmp'")));
  });
}
