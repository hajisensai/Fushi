import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // BUG-121: 退出视频/退全屏闪红屏。根因 = 查词浮层 entry 插在根 Overlay（跨路由生存），
  // 退出当帧本 State 先 deactivate，但同帧 layout 阶段根 Overlay 的 LayoutBuilder 仍重建
  // entry，内层经 appModel(ref.read) / mixinTheme(Theme.of) 做祖先查找，而 deactivated
  // element 上的查找不安全 → 抛异常红屏。根因修=deactivate 置 popupOverlayInert（早于同帧
  // layout），LayoutBuilder builder 起始据此空渲染。deactivate↔layout 同帧时序 headless
  // 难稳定复现，用源码守卫锁住生命周期拦截。
  //
  // 2026-07-24 去重：标志本体（popupOverlayInert）与浮层 builder
  // （buildPopupOverlayContent）已上提到 DictionaryPopupOverlayHostMixin
  // （dictionary_page_mixin.dart）；video 页保留生命周期钩子里的置位/复位。守卫随之分两处。
  final String pageSource = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  ).readAsStringSync();
  final String mixinSource = File(
    'lib/src/pages/implementations/dictionary_page_mixin.dart',
  ).readAsStringSync();

  test('popupOverlayInert flag is set on deactivate and cleared on activate',
      () {
    expect(mixinSource, contains('bool popupOverlayInert'),
        reason: '需销毁期标志拦截浮层 builder（BUG-121）');
    final String deactivate = _functionSource(
      pageSource,
      '  void deactivate() {',
      '  void activate() {',
    );
    expect(deactivate, contains('popupOverlayInert = true'),
        reason: 'deactivate 必须置位（早于同帧 layout 阶段）');
    final String activate = _functionSource(
      pageSource,
      '  void activate() {',
      '  void _refocusVideo() {',
    );
    expect(activate, contains('popupOverlayInert = false'),
        reason: 'activate 必须复位 popupOverlayInert，重挂后恢复浮层');
    // 防呆：deactivate/activate 都调 super。
    expect(deactivate, contains('super.deactivate()'));
    expect(activate, contains('super.activate()'));
  });

  test('popup overlay LayoutBuilder bails out during teardown before lookups',
      () {
    final String fn = _functionSource(
      mixinSource,
      '  Widget buildPopupOverlayContent(BuildContext overlayContext) {',
      '\n}',
    );
    // 外层与内层 LayoutBuilder 都要有 popupOverlayInert 早返回守卫。
    expect(
        'popupOverlayInert) return const SizedBox.shrink();'
            .allMatches(fn)
            .length,
        greaterThanOrEqualTo(2),
        reason: '外层 + 内层 LayoutBuilder builder 都要在访问 appModel 前空渲染兜底');

    // 内层守卫必须出现在 LayoutBuilder 的 screen 计算（首个 appModel 失效查找前）之前。
    final int layoutIdx = fn.indexOf(
        'builder: (BuildContext context, BoxConstraints constraints) {');
    expect(layoutIdx, isNonNegative);
    final int guardIdx = fn.indexOf(
        'popupOverlayInert) return const SizedBox.shrink();', layoutIdx);
    final int screenIdx = fn.indexOf('final Size screen', layoutIdx);
    expect(guardIdx, isNonNegative);
    expect(screenIdx, isNonNegative);
    expect(guardIdx, lessThan(screenIdx),
        reason: '守卫必须在 LayoutBuilder 体内 screen/子层构建之前');
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
