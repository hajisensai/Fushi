import 'dart:io';

import 'package:test/test.dart';

/// 路线图 #3722 c41 遗留的两处接线，源码守卫（Windows 文件锁与「关了立刻再开」的
/// 控制器生命周期都没有可在 CI 上跑的行为测试）：
///
/// - 整卷 OCR 产物 `manga_ocr_out/manga.json` 由 `writeTextFileAtomically` 写；可能与
///   写者同时发生的两处读（app 任务注册表收结果、互联 host 回传结果）走配套的
///   `readAtomicallyWrittenTextFile`，否则 Windows 上开着读会让同一刻的替换以
///   「拒绝访问」失败（BUG-4801）。
/// - app 每次开互联新建的 OCR 任务管理器，队列接在上一个管理器执行体停下之后。
void main() {
  String read(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: '须在 fushi/ 下运行：$path');
    return file.readAsStringSync();
  }

  test('任务注册表读整卷产物走 readAtomicallyWrittenTextFile', () {
    final String source = read(
      'lib/src/media/manga/ocr/manga_ocr_job_registry.dart',
    );
    expect(source, contains('readAtomicallyWrittenTextFile(File(resultPath))'));
    expect(source, isNot(contains('File(resultPath).readAsString()')));
  });

  test('互联 host 回传整卷产物走 readAtomicallyWrittenTextFile', () {
    final String source = read(
      '../packages/fushi_engine/lib/sync/fushi_manga_ocr_host.dart',
    );
    final int start = source.indexOf('Future<String?> resultJson(');
    expect(start, isNonNegative);
    final String body = source.substring(start, source.indexOf('\n  }', start));
    expect(body, contains('readAtomicallyWrittenTextFile(file)'));
    expect(body, isNot(contains('readAsString')));
  });

  test('控制器新建的 OCR 管理器接在上一个管理器执行体停下之后', () {
    final String source = read('lib/src/sync/fushi_server_controller.dart');
    expect(
      source,
      contains('runAfter: _lastMangaOcrJobs?.whenExecutorsStopped'),
    );
    expect(source, contains('_lastMangaOcrJobs = manager;'));
  });
}
