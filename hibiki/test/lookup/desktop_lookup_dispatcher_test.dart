// spec 2026-07-10 §4 — Dispatcher 分区消费的源码守卫 + 可离屏断言。
//
// Dispatcher 的运行时行为依赖 AppModel（prefs）与 GlobalLookupController
// （native channel），headless 无法整链驱动；分区正确性已由
// desktop_lookup_router_test 全矩阵锁死。这里锁两件事：
// ① 源码接线不变式（dispatcher 过路由、mainTab 不清 pending、transient 走
//    lookupText 且带 sentence）；
// ② main.dart 启动顺序（dispatcher 先挂监听，applyDesktopClipboardLifecycle
//    后启服务——防首个剪贴板事件竞态）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String dispatcherSrc =
      File('lib/src/lookup/desktop_lookup_dispatcher.dart').readAsStringSync();
  final String mainSrc = File('lib/main.dart').readAsStringSync();

  test('dispatcher 消费必须过 resolveDesktopLookupConsumer 路由', () {
    expect(dispatcherSrc.contains('resolveDesktopLookupConsumer'), isTrue);
  });

  test('mainTab 分区不清 pending（留给 HomeDictionaryPage）', () {
    final int mainTabCase =
        dispatcherSrc.indexOf('case DesktopLookupConsumer.mainTab:');
    final int panelCase =
        dispatcherSrc.indexOf('case DesktopLookupConsumer.panel:');
    expect(mainTabCase, isNonNegative);
    expect(panelCase, isNonNegative);
    final String mainTabBody = dispatcherSrc.substring(mainTabCase, panelCase);
    expect(mainTabBody.contains('clearPending'), isFalse,
        reason: 'mainTab 请求归 HomeDictionaryPage 消费，dispatcher 不得清走');
  });

  test('transient 分区清 pending 并带整句进覆盖窗', () {
    final int panelCase =
        dispatcherSrc.indexOf('case DesktopLookupConsumer.panel:');
    final String tail = dispatcherSrc.substring(panelCase);
    expect(tail.contains('clearPending'), isTrue);
    expect(tail.contains('lookupText(request.text, sentence: request.text)'),
        isTrue,
        reason: '整句作 root 卡句子横幅 + 制卡 sentence 字段');
  });

  test('main.dart 启动顺序：dispatcher 先挂监听，再启剪贴板服务', () {
    final int dispatcherStart =
        mainSrc.indexOf('DesktopLookupDispatcher.instance.start');
    final int lifecycleStart =
        mainSrc.indexOf('applyDesktopClipboardLifecycle');
    expect(dispatcherStart, isNonNegative);
    expect(lifecycleStart, isNonNegative);
    expect(dispatcherStart < lifecycleStart, isTrue,
        reason: '先挂监听再启服务，防首个剪贴板事件在监听挂上前丢失');
  });
}
