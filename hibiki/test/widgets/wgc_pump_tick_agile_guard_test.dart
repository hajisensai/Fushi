import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-550 guard: the WGC timer-pump Tick delegate must be AGILE.
///
/// 根因回归点: `DispatcherQueueTimer` 是 MarshalingBehavior=Agile,它的
/// `add_Tick` 强制要求 agile 委托;裸 `Microsoft::WRL::Callback<PumpTickHandler>`
/// 产生【非-agile】委托 → `add_Tick` 返回 RO_E_MUST_BE_AGILE (0x8000001C) →
/// pump-start-fail → RetireFramePoolLocked → WebView 纹理恒空(阅读器白屏 +
/// 查词弹窗空)。修复是把 tick 处理器聚合 FtmBase 变成 free-threaded(agile)委托。
///
/// 这个守卫断言 `texture_bridge.cc` 注册到 `add_Tick` 的处理器是 agile 委托
/// (经 `Microsoft::WRL::Implements<..., FtmBase>` 包裹的 `PumpTickHandler`,
/// 或 `wil::MakeAgileCallback`),并禁止把裸 `Callback<PumpTickHandler>(...)`
/// 直接喂给 `add_Tick`。
String _read(List<String> candidates, String name) {
  final File? file = candidates.map(File.new).cast<File?>().firstWhere(
        (File? f) => f != null && f.existsSync(),
        orElse: () => null,
      );
  expect(file, isNotNull, reason: '$name not found');
  return file!.readAsStringSync();
}

/// 删掉所有 `//` 行注释,只保留真实代码,避免守卫被解释根因的注释误判。
String _stripLineComments(String src) {
  return src.split('\n').map((String line) {
    final int idx = line.indexOf('//');
    return idx >= 0 ? line.substring(0, idx) : line;
  }).join('\n');
}

void main() {
  test('TODO-550: WGC timer-pump Tick handler is an AGILE delegate', () {
    final String rawSrc = _read(<String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
    ], 'texture_bridge.cc');
    // 只看真实代码(剥离 // 注释),注释里复述根因写法不应触发守卫。
    final String src = _stripLineComments(rawSrc);

    // 1) tick 处理器赋值必须存在,且使用 agile 委托工厂。
    final int assignIdx = src.indexOf('lifetime->pump_tick_handler =');
    expect(assignIdx, greaterThanOrEqualTo(0),
        reason: 'pump_tick_handler assignment must exist');

    // 取赋值语句到结尾分号前的 lambda 开头一段(委托工厂头部)。
    final int factoryEnd = src.indexOf('[pump_state]', assignIdx);
    expect(factoryEnd, greaterThan(assignIdx),
        reason: 'tick handler must capture pump_state in its lambda');
    final String factoryHead = src.substring(assignIdx, factoryEnd);

    final bool usesFtmBase = factoryHead.contains('FtmBase') &&
        factoryHead.contains('Implements') &&
        factoryHead.contains('PumpTickHandler');
    final bool usesWilAgile =
        factoryHead.contains('MakeAgileCallback<PumpTickHandler>');
    expect(usesFtmBase || usesWilAgile, isTrue,
        reason: 'Tick delegate must be agile: either Microsoft::WRL::Callback<'
            'Implements<..., PumpTickHandler, FtmBase>>(...) or '
            'wil::MakeAgileCallback<PumpTickHandler>(...). '
            'DispatcherQueueTimer::add_Tick rejects non-agile delegates with '
            'RO_E_MUST_BE_AGILE -> pump-start-fail -> blank WebView.');

    // 2) 禁止把裸 Callback<PumpTickHandler>(...) 直接作为委托工厂喂给 add_Tick。
    expect(factoryHead.contains('Callback<PumpTickHandler>'), isFalse,
        reason:
            'bare Microsoft::WRL::Callback<PumpTickHandler>(...) is non-agile '
            'and is the exact regression that blanked all Windows WebViews');

    // 3) 注册路径仍存在: add_Tick 用的就是这个被聚合 FtmBase 的处理器成员。
    expect(
        src.contains('add_Tick(\n        lifetime->pump_tick_handler.Get()') ||
            src.contains('add_Tick(lifetime->pump_tick_handler.Get()') ||
            src.contains('pump_tick_handler.Get(), &lifetime->on_tick_token'),
        isTrue,
        reason:
            'the agile tick handler must be the delegate registered via add_Tick');
  });
}
