import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// 词典批量导入崩溃面包屑：native 词典解析在进程级硬崩（访问违例 / 栈溢出）时
/// 会绕过 Dart try/catch 直接带崩整个 app，异步错误日志来不及落盘。
/// [ErrorLogService.markImportStart] 在每本调 FFI 前**同步**写一条面包屑，返回后
/// [markImportEnd] 清掉；若进程崩在中间，面包屑存活，下次启动经
/// [readAndClearBreadcrumb] 读出残留 = 把进程带崩的那本词典。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hibiki_breadcrumb_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('文件不存在时返回 null（正常无崩溃路径）', () {
    final f = File('${tmp.path}/import_crash_breadcrumb.txt');
    expect(f.existsSync(), isFalse);
    expect(ErrorLogService.readAndClearBreadcrumb(f), isNull);
  });

  test('空 / 纯空白面包屑返回 null 且不误报', () {
    final f = File('${tmp.path}/import_crash_breadcrumb.txt')
      ..writeAsStringSync('   \n  ');
    expect(ErrorLogService.readAndClearBreadcrumb(f), isNull);
  });

  test('崩溃残留：读出 trim 后的内容并删除文件（恢复后不重复报警）', () {
    final f = File('${tmp.path}/import_crash_breadcrumb.txt')
      ..writeAsStringSync('  native 词典导入未返回：C:\\dicts\\broken.zip  ');

    final recovered = ErrorLogService.readAndClearBreadcrumb(f);
    expect(recovered, 'native 词典导入未返回：C:\\dicts\\broken.zip');
    // 读完即删，避免下次启动重复把同一条当成新崩溃。
    expect(f.existsSync(), isFalse);

    // 第二次（模拟再次启动）已无残留 → 不再报警。
    expect(ErrorLogService.readAndClearBreadcrumb(f), isNull);
  });

  test('正常导入：start 写入、end 清除后无残留可恢复', () {
    // 直接以静态原语模拟一本词典 start→end 的生命周期（不依赖单例文件路径）。
    final f = File('${tmp.path}/import_crash_breadcrumb.txt')
      ..writeAsStringSync('native 词典导入未返回：good.zip'); // markImportStart
    expect(f.existsSync(), isTrue);

    // markImportEnd 等价：导入返回后删除面包屑。
    if (f.existsSync()) f.deleteSync();

    // 下次启动恢复检查：无残留。
    expect(ErrorLogService.readAndClearBreadcrumb(f), isNull);
  });

  group('TODO-892：native 步进面包屑折进 crashRecovered', () {
    test('importStepBreadcrumbDir 在 init 后指向注入目录', () async {
      await ErrorLogService.instance.init(directoryOverride: tmp);
      expect(ErrorLogService.instance.importStepBreadcrumbDir, tmp.path);
    });

    test('导入面包屑 + native 步进文件都残留：crashRecovered 同时含文件名与最后步骤', () async {
      File('${tmp.path}/import_crash_breadcrumb.txt')
          .writeAsStringSync('native 词典导入未返回：C:/dicts/big.zip');
      // 文件名必须与 native import_breadcrumb::kStepFileName 一致。
      File('${tmp.path}/import_step_breadcrumb.txt')
          .writeAsStringSync('yomitan: term_bank #3 / term_bank_3.json');

      await ErrorLogService.instance.init(directoryOverride: tmp);

      final log = ErrorLogService.instance.getFullLog();
      expect(log, contains('DictImport.crashRecovered'));
      expect(log, contains('big.zip'));
      expect(log,
          contains('native 最后步骤=yomitan: term_bank #3 / term_bank_3.json'));

      // 读完即删：两个面包屑都清掉，下次启动不重复报警。
      expect(File('${tmp.path}/import_crash_breadcrumb.txt').existsSync(),
          isFalse);
      expect(
          File('${tmp.path}/import_step_breadcrumb.txt').existsSync(), isFalse);
    });

    test('只有 native 步进文件残留（导入面包屑已清）：仍报告最后步骤', () async {
      File('${tmp.path}/import_step_breadcrumb.txt')
          .writeAsStringSync('yomitan: media #1 / cover.png');

      await ErrorLogService.instance.init(directoryOverride: tmp);

      final log = ErrorLogService.instance.getFullLog();
      expect(log, contains('DictImport.crashRecovered'));
      expect(log, contains('native 最后步骤=yomitan: media #1 / cover.png'));
      expect(
          File('${tmp.path}/import_step_breadcrumb.txt').existsSync(), isFalse);
    });

    test('两个面包屑都不存在（正常路径）：不产生 crashRecovered', () async {
      await ErrorLogService.instance.init(directoryOverride: tmp);
      final log = ErrorLogService.instance.getFullLog();
      expect(log, isNot(contains('DictImport.crashRecovered')));
    });

    tearDown(() async {
      await ErrorLogService.instance.clear();
    });
  });
}
