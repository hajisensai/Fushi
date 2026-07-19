import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// AppModel 审计加固源码守卫（BUG-911 / BUG-913 / BUG-914）。
///
/// AppModel 太大、依赖整页初始化 + Drift + FFI，无法在单测里实例化并驱动
/// dispose()/searchDictionary() 的真实路径，故这里用源码扫描守卫锁住三簇加固不回归。
/// 测试从 `hibiki/` 工作目录运行，读 `lib/src/models/app_model.dart`。
void main() {
  final File file = File('lib/src/models/app_model.dart');
  late final String source;

  setUpAll(() {
    expect(file.existsSync(), isTrue,
        reason: 'expected source at ${file.absolute.path}');
    source = file.readAsStringSync();
  });

  /// 截取 `void dispose() { ... super.dispose(); }` 的方法体，避免把 closeForPopup
  /// 等其它清理逻辑误当成 dispose 内容。
  String disposeBody(String src) {
    const String marker = 'void dispose() {';
    final int start = src.indexOf(marker);
    expect(start, greaterThanOrEqualTo(0), reason: 'AppModel.dispose() 声明必须存在');
    final int superIdx = src.indexOf('super.dispose();', start);
    expect(superIdx, greaterThan(start),
        reason: 'dispose() 必须以 super.dispose() 收尾');
    return src.substring(start, superIdx);
  }

  group('BUG-913 dispose 对称释放 4 个常驻子系统', () {
    test('LAN sync server 在 dispose 内被 stop', () {
      expect(disposeBody(source), contains('syncServerController.stop()'),
          reason: 'initialise 起的 LAN sync server 必须在 dispose 关停');
    });

    test('sync server ChangeNotifier 在 dispose 内被 dispose', () {
      expect(disposeBody(source), contains('syncServerController.dispose()'),
          reason: 'syncServerController 是 ChangeNotifier，stop 后还需 dispose');
    });

    test('texthooker 在 dispose 内被 stop', () {
      expect(disposeBody(source),
          contains('TexthookerWsClientHost.instance.stop()'),
          reason: 'initialise 起的 texthooker host 必须在 dispose 关停');
    });

    test('yomitan api server 在 dispose 内被 stop', () {
      expect(disposeBody(source), contains('stopYomitanApiServer()'),
          reason: 'initialise 起的 yomitan-api server 必须在 dispose 关停');
    });

    test('anime 下载服务在 dispose 内被 stop', () {
      expect(disposeBody(source), contains('_animeDownloadService?.stop()'),
          reason: 'initialise 起的番剧下载服务必须在 dispose 关停');
    });
  });

  group('BUG-913 弹窗内联 family provider autoDispose 化', () {
    // 剥离所有空白后匹配：dart format 会把 `.autoDispose` 与 `.family<...>`
    // 折成两行，精确单行子串会误判，故对无空白视图断言。`source` 是 late（setUpAll
    // 赋值），故 noWs 必须在 test 体内计算，不能放组级（收集期 source 未初始化）。
    test('quickActionColorProvider 声明含 autoDispose', () {
      expect(
          source.replaceAll(RegExp(r'\s+'), ''),
          contains(
              'FutureProvider.autoDispose.family<Map<String,Color?>,DictionaryEntry>'),
          reason: '弹窗内联颜色 family 随查词单调增长，须 autoDispose（弹窗关即释放）');
    });

    test('visibleOnceProvider 声明含 autoDispose', () {
      expect(source.replaceAll(RegExp(r'\s+'), ''),
          contains('StateProvider.autoDispose.family<bool,DictionaryEntry>'),
          reason: '一次性可见标记 family 随查词单调增长，须 autoDispose（弹窗关即释放）');
    });
  });

  group('BUG-914 移除查词热路径 [dict-perf] 性能探针', () {
    test('app_model.dart 不再出现 [dict-perf]', () {
      expect(source, isNot(contains('[dict-perf]')),
          reason: 'searchDictionary 每次查词必跑，发布版不得留 [dict-perf] 打点');
    });
  });

  group('BUG-911 yomitan 自启动 fail-open 补日志', () {
    test('自启动 catchError 不再是空吞', () {
      expect(source,
          isNot(contains('startYomitanApiServer().catchError((Object _) {})')),
          reason: 'BUG-911：空 catchError 静默吞异常必须移除');
    });

    test('自启动失败经 ErrorLogService 留痕', () {
      expect(source, contains('AppModel.startYomitanApiServer.autostart'),
          reason: 'fail-open 保持不变，但失败须记日志（与邻居 startSyncServer 一致）');
    });
  });
}
