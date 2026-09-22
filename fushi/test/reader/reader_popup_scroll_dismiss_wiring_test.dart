import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-09-23 用户诉求：滚动（连续）模式下查词后继续滚动正文（横排/竖排）即关闭
/// 查词弹窗，并做成开关（偏好 `dismiss_popup_on_scroll`）。
///
/// barrier 的手势契约由 `test/pages/lookup_dismiss_barrier_test.dart` 覆盖；本文件
/// 咬住页面接线——这几处任何一处断开都是静默失效（弹窗照样开着、正文照样不动），
/// 单测与 analyze 全绿：
///   - base 页把 [dismissBarrierScrollAxis] / [onDismissBarrierScrollDrag] 接进
///     barrier；
///   - 阅读器页两个入口（滚轮 + 拖动）都受「连续模式 && 偏好」同一道门控；
///   - 竖排取横轴、横排取纵轴；
///   - 拖动认领后跟随剩余指针移动，页面销毁时摘掉路由。
void main() {
  late String base;
  late String reader;

  setUpAll(() {
    base = File('lib/src/pages/base_source_page.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    reader = File('lib/src/pages/implementations/reader_fushi_page.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
  });

  String bodyOf(String source, String signature) {
    final int start = source.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature 缺失');
    int depth = 0;
    for (int i = source.indexOf('{', start); i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}' && --depth == 0) {
        return source.substring(start, i + 1);
      }
    }
    fail('$signature 括号不配对');
  }

  test('base page wires the scroll channel into the barrier', () {
    expect(base, contains('scrollDismissAxis: dismissBarrierScrollAxis,'));
    expect(base, contains('onScrollDismiss: onDismissBarrierScrollDrag,'));
  });

  test('gate = continuous mode && user preference', () {
    final String gate = reader.substring(
      reader.indexOf('bool get _dismissPopupOnScrollActive =>'),
      reader.indexOf(
          ';', reader.indexOf('bool get _dismissPopupOnScrollActive')),
    );
    expect(gate, contains('isContinuousMode == true'));
    expect(gate, contains('ReaderFushiSource.instance.dismissPopupOnScroll'));
  });

  test('scroll axis follows writing mode and the gate', () {
    final String axis = bodyOf(reader, 'Axis? get dismissBarrierScrollAxis');
    expect(axis, contains('if (!_dismissPopupOnScrollActive) return null;'));
    expect(axis, contains("startsWith('vertical')"));
    expect(
      axis.indexOf('Axis.horizontal'),
      lessThan(axis.indexOf('Axis.vertical')),
      reason: '竖排（vertical）→ 横向滚动轴；横排 → 纵向',
    );
  });

  test('wheel over the barrier is gated, closes the stack and forwards', () {
    final String wheel = bodyOf(
      reader,
      'void onDismissBarrierPointerSignal(PointerSignalEvent event)',
    );
    expect(wheel, contains('!_dismissPopupOnScrollActive'));
    expect(wheel, contains('clearDictionaryResult();'));
    expect(wheel, contains('window.scrollBy'));
  });

  test('drag claim follows the rest of the pointer and cleans up', () {
    final String drag = bodyOf(
      reader,
      'void onDismissBarrierScrollDrag(int pointer, Offset delta)',
    );
    expect(drag, contains('clearDictionaryResult();'));
    expect(drag, contains('pointerRouter.addRoute('));
    final String dispose = bodyOf(reader, '  void dispose() {');
    expect(dispose, contains('_stopFollowingScrollDismissPointer();'));
  });
}
