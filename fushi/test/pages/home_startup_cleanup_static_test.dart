// 首页首帧的启动清理挂点（#3722 c08 / c15 遗留）。
//
//  - gap-scanner-10：以前的进程在扫描中途被杀留下的临时来源行 / 临时目录，以前要等
//    下一次任意来源扫描才清；现在首帧清一次，且排在启动自动扫描之前。
//  - BUG-4813：旧版本留下的制卡队列 done 行，以前挂在两个读入口里当副作用；现在挪回
//    首页启动处，读方法不再删行（行为由 web_mine_queue_store_test 钉着）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final String src = File(
    p.join('lib', 'src', 'pages', 'implementations', 'home_page.dart'),
  ).readAsStringSync();

  String body(String signature) {
    final int start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '找不到 $signature');
    final int end = src.indexOf('\n  }\n', start);
    return src.substring(start, end);
  }

  test('initState 的首帧回调走启动清理再自动扫描', () {
    final String init = body('void initState() {');
    expect(init, contains('unawaited(_startupCleanupThenAutoScan())'));
    expect(
      init,
      isNot(contains('_sourceAutoScan.trigger(SourceAutoScanTrigger.startup)')),
      reason: '启动自动扫描只能在清扫之后由 _startupCleanupThenAutoScan 发起',
    );
  });

  test('清扫在自动扫描之前 await，旧 done 行也在这里清', () {
    final String cleanup = body(
      'Future<void> _startupCleanupThenAutoScan() async {',
    );
    final int sweep = cleanup.indexOf('await sweepSourceScanLeftoversOnce(');
    final int scan = cleanup.indexOf(
      'await _sourceAutoScan.trigger(SourceAutoScanTrigger.startup)',
    );
    expect(sweep, isNonNegative);
    expect(scan, greaterThan(sweep));
    expect(cleanup, contains('.sweepLegacyDone()'));
  });

  test('读入口不再带 done 行清扫副作用', () {
    final String store = File(
      p.join('lib', 'src', 'mining', 'web_mine_queue_store.dart'),
    ).readAsStringSync();
    final String queue = File(
      p.join('lib', 'src', 'mining', 'video_mine_queue.dart'),
    ).readAsStringSync();
    final int uids = store.indexOf('Future<List<String>> pendingBookUids()');
    expect(uids, isNonNegative);
    expect(
      store.substring(uids, store.indexOf('\n  }\n', uids)),
      isNot(contains('sweepLegacyDone')),
    );
    expect(queue, isNot(contains('sweepLegacyDone();')));
  });
}
