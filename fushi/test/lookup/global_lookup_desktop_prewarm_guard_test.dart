import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';

/// PR #2763 审查：台词浮窗一显示就调 `prewarmDesktopStatic`。桌面查词在
/// `hide(notify:false)` 与重新显示之间 `isShowing` 为 false，旧实现只看它就铸一个更新
/// 的 desktop 路由，原生 SetRouteContext 把在途查词的 showAt / render / revealStack
/// 当成旧 epoch 丢掉——查词窗不出现。与游戏内 `_prewarmCardIfIdle` 同一纪律：在途就不做，
/// 且判断必须在 `isShowing` 的 await 之后、铸路由之前（await 期间开始的查词也拦住）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final String controller = File(
    'lib/src/lookup/global_lookup_controller.dart',
  ).readAsStringSync();

  test('桌面预热在查词在途时不铸新路由', () {
    final int start = controller.indexOf(
      'Future<void> prewarmDesktopStatic() async {',
    );
    expect(start, isNonNegative);
    final int end = controller.indexOf('\n  }\n', start);
    final String body = controller.substring(start, end);
    final int showing = body.indexOf(
      'if (await GlobalLookupChannel.isShowing()) return;',
    );
    final int inFlight = body.indexOf('if (desktopLookupInFlight) return;');
    final int mint = body.indexOf('++_desktopLookupEpoch');
    expect(showing, isNonNegative);
    expect(inFlight, greaterThan(showing), reason: '在途判断必须在 await 之后');
    expect(mint, greaterThan(inFlight), reason: '铸路由之前先判在途');
  });

  test('「在途」= 当前路由是 desktop 且仍有效（查词入口在首个 await 前就激活路由）', () {
    final int start = controller.indexOf('bool get desktopLookupInFlight {');
    expect(start, isNonNegative);
    final String body = controller.substring(
      start,
      controller.indexOf('\n  }\n', start),
    );
    expect(body, contains("active.source == 'desktop'"));
    expect(body, contains('GlobalLookupChannel.isRouteValid(active)'));
  });

  // 「路由仍有效」≠「查词在途」：查词半路中止（这里走的是 appModel 未就绪的那条中止；
  // 空选区 / 无辅助功能权限 / showAt 被拒 / 异常同一个 finally 收口）时窗没显示、
  // 不会有 overlayHidden 来作废路由。旧实现路由一直有效 → desktopLookupInFlight 恒真，
  // prewarmDesktopStatic 被静默跳过，直到下一次查词真正显示又被关掉。
  test('桌面查词半路中止后不再算「在途」，预热不被永久挡住', () async {
    final GlobalLookupController lookup = GlobalLookupController.instance;
    expect(lookup.desktopLookupInFlight, isFalse);
    await lookup.triggerSelectionLookup(source: 'test');
    expect(lookup.desktopLookupInFlight, isFalse, reason: '中止的查词必须结束自己的路由生命周期');
  });
}
