import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// TODO-607 P0-2/②：查词崩溃面包屑——**独立**文件 lookup_crash_breadcrumb.txt，
/// 独立恢复分支，下次启动折成 `Lookup.crashRecovered`。
///
/// 嵌套查词触发的 native 进程级闪退绕过所有 Dart 错误捕获，异步日志来不及落盘；
/// [ErrorLogService.markLookupStackDepth] 在查词栈层进出时**同步**写面包屑，进程
/// 崩在查词活跃期时面包屑存活，下次 [ErrorLogService.init] 读出残留并折成
/// `Lookup.crashRecovered`（日志 label，非 i18n key），记下崩时第几层。
void main() {
  final ErrorLogService svc = ErrorLogService.instance;
  late Directory tmp;

  File lookupBreadcrumb() => File('${tmp.path}/lookup_crash_breadcrumb.txt');
  File importBreadcrumb() => File('${tmp.path}/import_crash_breadcrumb.txt');

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hibiki_lookup_bc_test');
    await svc.init(directoryOverride: tmp);
    await svc.clear();
  });

  tearDown(() {
    // 单例 ErrorLogService 仍持有指向本 tmp 的 _logFile（异步 _appendToFile 可能在
    // 飞），Windows 文件锁下 deleteSync 偶发 errno=32。删失败不影响断言，OS 退出回收。
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // ignore: Windows 文件句柄释放时机不可控，留给 OS 回收。
    }
  });

  test('查词面包屑文件名与导入面包屑独立（不复用同一文件）', () {
    svc.markLookupStackDepth(2, topTerm: '言葉');
    expect(lookupBreadcrumb().existsSync(), isTrue,
        reason: '查词面包屑必须写进 lookup_crash_breadcrumb.txt');
    expect(importBreadcrumb().existsSync(), isFalse,
        reason: '绝不能复用导入的 import_crash_breadcrumb.txt');
  });

  test('栈深度<=0 清掉查词面包屑（栈空后崩溃与查词无关）', () {
    svc.markLookupStackDepth(2, topTerm: 'x');
    expect(lookupBreadcrumb().existsSync(), isTrue);
    svc.markLookupStackDepth(0);
    expect(lookupBreadcrumb().existsSync(), isFalse,
        reason: '深度归 0 = 所有弹窗关闭，应清面包屑');
  });

  test('面包屑内容含栈深度（嵌套层数）与栈顶词', () {
    svc.markLookupStackDepth(3, topTerm: '辞書');
    final String body = lookupBreadcrumb().readAsStringSync();
    expect(body, contains('栈深度=3'));
    expect(body, contains('辞書'));
  });

  test('写面包屑→模拟启动→错误日志出现 Lookup.crashRecovered', () async {
    // 模拟「嵌套查词第 2 层活跃时进程被 native 闪退带崩」：面包屑残留。
    svc.markLookupStackDepth(2, topTerm: '嵌套');
    expect(lookupBreadcrumb().existsSync(), isTrue);

    // 模拟下次启动：重新 init（同一注入目录），应读出残留并折成日志条目。
    await svc.init(directoryOverride: tmp);

    final bool recovered = svc.entries
        .any((ErrorLogEntry e) => e.source == 'Lookup.crashRecovered');
    expect(recovered, isTrue, reason: '上次查词残留面包屑应折成 Lookup.crashRecovered');
    // 恢复后面包屑被清，下次启动不重复报。
    expect(lookupBreadcrumb().existsSync(), isFalse);
  });

  test('无残留面包屑时启动不报 Lookup.crashRecovered（正常路径）', () async {
    expect(lookupBreadcrumb().existsSync(), isFalse);
    await svc.init(directoryOverride: tmp);
    final bool recovered = svc.entries
        .any((ErrorLogEntry e) => e.source == 'Lookup.crashRecovered');
    expect(recovered, isFalse);
  });

  test('查词与导入面包屑互不干扰：恢复各自折成独立 label', () async {
    importBreadcrumb().writeAsStringSync('[t] broken.zip');
    svc.markLookupStackDepth(1, topTerm: '词');
    await svc.init(directoryOverride: tmp);
    expect(
      svc.entries
          .any((ErrorLogEntry e) => e.source == 'DictImport.crashRecovered'),
      isTrue,
    );
    expect(
      svc.entries.any((ErrorLogEntry e) => e.source == 'Lookup.crashRecovered'),
      isTrue,
    );
  });
}
