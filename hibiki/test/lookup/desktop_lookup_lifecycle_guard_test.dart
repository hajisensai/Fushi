// spec 2026-07-10 §7 — 生命周期上移的源码守卫：
// ① HomeDictionaryPage 不得再启动/停止 DesktopLookupService（服务归 AppModel）；
// ② AppModel 必须持有 applyDesktopClipboardLifecycle（app 级 start/stop）；
// ③ HomeDictionaryPage 的消费必须过 resolveDesktopLookupConsumer 路由
//    （防后人绕过分区直接消费，造成 panel/transient 双消费）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String pageSrc = File(
    'lib/src/pages/implementations/home_dictionary_page.dart',
  ).readAsStringSync();
  final String appModelSrc =
      File('lib/src/models/app_model.dart').readAsStringSync();

  test('HomeDictionaryPage 不启动/停止 DesktopLookupService（spec §7）', () {
    expect(pageSrc.contains('DesktopLookupService.instance.start('), isFalse,
        reason: '服务生命周期归 AppModel.applyDesktopClipboardLifecycle，'
            '页面只消费不启动');
    expect(pageSrc.contains('DesktopLookupService.instance.stop('), isFalse,
        reason: '面板/瞬态去向要求监听在词典 tab 卸载后继续运行');
  });

  test('AppModel 持有 app 级生命周期入口', () {
    expect(appModelSrc.contains('Future<void> applyDesktopClipboardLifecycle'),
        isTrue);
  });

  test('HomeDictionaryPage 消费经 resolveDesktopLookupConsumer 分区', () {
    expect(pageSrc.contains('resolveDesktopLookupConsumer'), isTrue,
        reason: '绕过路由直接消费会与 DesktopLookupDispatcher 双消费');
  });
}
