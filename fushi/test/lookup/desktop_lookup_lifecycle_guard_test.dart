// TODO-1394 方案B（保留 1385/BUG-700 refcount + 取 PR#13 独立面板 UI）后的源码守卫：
// ① HomeDictionaryPage 恢复页级引用计数 start/stop（1385 生命周期，跨 600px 断点重建
//    时 watcher 存活，见 home_dictionary_clipboard_watcher_breakpoint_test.dart）；
// ② AppModel 仍持有 applyDesktopClipboardLifecycle（app 级 hold，让剪贴板独立面板/瞬态
//    去向在词典 tab 未挂载时也收到 watcher 事件；refcount 令页级 + app 级两持有者并存）；
// ③ HomeDictionaryPage 的消费必须过 resolveDesktopLookupConsumer 路由分区
//    （防与 DesktopLookupDispatcher 双消费 panel/transient）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String pageSrc = File(
    'lib/src/pages/implementations/home_dictionary_page.dart',
  ).readAsStringSync();
  final String appModelSrc =
      File('lib/src/models/app_model.dart').readAsStringSync();

  test('HomeDictionaryPage 页级引用计数 start/stop DesktopLookupService（1385）', () {
    expect(pageSrc.contains('DesktopLookupService.instance.start('), isTrue,
        reason: '进入查词页按引用计数 start（BUG-700 断点重建守卫依赖页级 start）');
    expect(pageSrc.contains('DesktopLookupService.instance.stop('), isTrue,
        reason: '离开查词页 stop（refcount -1；app 级 hold 仍保 watcher 存活）');
  });

  test('AppModel 持有 app 级生命周期入口（独立面板/瞬态去向要求 tab 未挂载也监听）', () {
    expect(appModelSrc.contains('Future<void> applyDesktopClipboardLifecycle'),
        isTrue);
  });

  test('HomeDictionaryPage 消费经 resolveDesktopLookupConsumer 分区', () {
    expect(pageSrc.contains('resolveDesktopLookupConsumer'), isTrue,
        reason: '绕过路由直接消费会与 DesktopLookupDispatcher 双消费');
  });
}
