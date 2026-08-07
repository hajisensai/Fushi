import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// TODO-1260：启动步进面包屑（`init_step_breadcrumb.txt`）契约。
///
/// app「偶发无限加载」的根因是某启动早期 IO（对掉线的自定义数据根盘 stat / 建目录）
/// 永不返回——这类 hang 不是崩溃（无异常、进程还在），用户只能强杀。为让下次启动能从
/// error_log.txt 定位「上次卡在哪一步」，[ErrorLogService] 在每个高风险启动步骤前
/// **同步**写步进面包屑，正常跑完清空；残留 = 上次卡这步没返回，折成 `AppInit.hangRecovered`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('errlog_initstep_test');
    await ErrorLogService.instance.init(directoryOverride: tmp);
    await ErrorLogService.instance.clear();
  });

  tearDown(() {
    // 尽力清理临时目录：Windows 下日志文件的异步 append 句柄 / AV 扫描偶发占用会让
    // deleteSync 抛 errno 32（文件占用），那是清理噪声、非测试失败，吞掉即可。
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('markInitStep 同步落盘；clearInitStep 清除', () {
    final File f = File('${tmp.path}/init_step_breadcrumb.txt');
    ErrorLogService.instance.markInitStep('resolve-data-roots');
    expect(f.existsSync(), isTrue, reason: '步进面包屑必须同步落盘（存活强杀）');
    expect(f.readAsStringSync(), contains('resolve-data-roots'));

    ErrorLogService.instance.clearInitStep();
    expect(f.existsSync(), isFalse, reason: '正常跑完必须清掉，否则下次误报 hang');
  });

  test('残留步进面包屑 → 下次 init() 折成 AppInit.hangRecovered', () async {
    // 模拟上次启动卡在某步没返回：写入残留面包屑但不清除。
    File('${tmp.path}/init_step_breadcrumb.txt').writeAsStringSync(
      '[2026-07-06 12:00:00.000] create-runtime-dirs',
      flush: true,
    );

    // 下次启动重新 init（同一目录）→ 恢复分支应读到残留并折进错误日志。
    await ErrorLogService.instance.init(directoryOverride: tmp);

    final bool recovered = ErrorLogService.instance.entries
        .any((e) => e.source == 'AppInit.hangRecovered');
    expect(recovered, isTrue, reason: '残留步进面包屑必须折成 AppInit.hangRecovered');
    final entry = ErrorLogService.instance.entries
        .firstWhere((e) => e.source == 'AppInit.hangRecovered');
    expect(entry.error, contains('create-runtime-dirs'),
        reason: '错误日志须记下卡在哪一步');

    // 折入后残留文件应被清掉（readAndClearBreadcrumb 语义），不重复上报。
    expect(File('${tmp.path}/init_step_breadcrumb.txt').existsSync(), isFalse);
  });

  test('无残留 → 不产生 hangRecovered 误报', () async {
    await ErrorLogService.instance.init(directoryOverride: tmp);
    final bool any = ErrorLogService.instance.entries
        .any((e) => e.source == 'AppInit.hangRecovered');
    expect(any, isFalse, reason: '正常启动（无残留）不得误报 hang');
  });
}
