import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';

/// BUG-4102 guard（原 TODO-550）：WGC 帧上报委托必须是 AGILE 委托。
///
/// 取帧线程（MTA）把上报任务 `TryEnqueue` 到平台线程的 DispatcherQueue；跨线程
/// 投递的 `IDispatcherQueueHandler` 必须 agile（聚合 FtmBase），否则投递被拒、
/// WebView 纹理恒空。TODO-550 当年是同一类错误：非 agile 的 Tick 委托被
/// `add_Tick` 以 RO_E_MUST_BE_AGILE 拒绝，全部 Windows WebView 白屏。
String _read(List<String> candidates, String name) {
  final File? file = candidates
      .map(File.new)
      .cast<File?>()
      .firstWhere((File? f) => f != null && f.existsSync(), orElse: () => null);
  expect(file, isNotNull, reason: '$name not found');
  return file!.readAsStringSync();
}

/// 删掉所有 `//` 行注释,只保留真实代码,避免守卫被解释根因的注释误判。
String _stripLineComments(String src) => maskComments(src);

void main() {
  test('BUG-4102: WGC frame delivery delegate is an AGILE delegate', () {
    final String rawSrc = _read(<String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
    ], 'texture_bridge.cc');
    // 只看真实代码(剥离 // 注释),注释里复述根因写法不应触发守卫。
    final String src = _stripLineComments(rawSrc);

    // 1) 上报处理器赋值必须存在,且使用 agile 委托工厂。
    final int assignIdx = src.indexOf('shared->deliver_handler =');
    expect(
      assignIdx,
      greaterThanOrEqualTo(0),
      reason: 'deliver_handler assignment must exist',
    );

    final int factoryEnd = src.indexOf('[pump_state, mailbox]', assignIdx);
    expect(
      factoryEnd,
      greaterThan(assignIdx),
      reason:
          'delivery handler must capture only the invalidation gate and the '
          'mailbox, never the bridge itself',
    );
    final String factoryHead = src.substring(assignIdx, factoryEnd);

    final bool usesFtmBase =
        factoryHead.contains('FtmBase') &&
        factoryHead.contains('Implements') &&
        factoryHead.contains('WgcDeliverHandler');
    final bool usesWilAgile = factoryHead.contains(
      'MakeAgileCallback<WgcDeliverHandler>',
    );
    expect(
      usesFtmBase || usesWilAgile,
      isTrue,
      reason:
          'the handler is enqueued from the frame worker thread onto the '
          'platform DispatcherQueue; it must be agile (Implements<..., '
          'WgcDeliverHandler, FtmBase> or wil::MakeAgileCallback)',
    );

    // 2) 禁止裸 Callback<WgcDeliverHandler>(...)(非 agile)。
    expect(
      factoryHead.contains('Callback<WgcDeliverHandler>'),
      isFalse,
      reason: 'bare Callback<WgcDeliverHandler>(...) is non-agile',
    );

    // 3) 取帧线程投递的就是这个处理器。
    expect(
      src.contains('shared->deliver_handler.Get(), &enqueued'),
      isTrue,
      reason: 'the frame worker must enqueue the agile delivery handler',
    );
  });
}
