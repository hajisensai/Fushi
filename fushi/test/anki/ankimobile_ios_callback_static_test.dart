import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS declares Hibiki and Anki URL schemes for AnkiMobile callbacks', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(plist, contains('<string>fushi</string>'));
    expect(plist, contains('<key>LSApplicationQueriesSchemes</key>'));
    expect(plist, contains('<string>anki</string>'));
  });

  test('AppDelegate exposes AnkiMobile pasteboard and URL callbacks', () {
    final src = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(src, contains('app.fushi.reader/ankimobile'));
    expect(src, contains('consumeInfoForAddingPasteboard'));
    expect(src, contains('net.ankimobile.json'));
    expect(src, contains('app.fushi.reader/url_events'));
    expect(src, contains('override func application('));
    expect(src, contains('open url: URL'));
  });

  // BUG-2150：读剪贴板的前置条件不是「URL 回调到了」，而是「app 真的 active 了」。
  // iOS 只允许前台活跃的 app 读别的 app 写进通用剪贴板的内容（iOS 16+ 还要弹一次
  // 系统「允许粘贴」确认，而弹窗只有 active 的 app 能呈现），而 x-callback 回跳时
  // 系统的顺序是 willEnterForeground → application(_:open:) → didBecomeActive，
  // 也就是说 URL 回调整个跑在 .inactive 阶段。Swift 进不了 flutter test，源码守卫
  // 是这层唯一可落地的自动化。
  test('AppDelegate 等 app active 之后才读 AnkiMobile 剪贴板', () {
    final String src = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    // 方法通道的 case 只许分发给带时序门的 helper——不许在这里直接读剪贴板。
    const String caseAnchor = 'case "consumeInfoForAddingPasteboard":';
    final int caseStart = src.indexOf(caseAnchor);
    expect(caseStart, greaterThan(-1), reason: '锚点漂移，守卫失效');
    final int caseEnd =
        src.indexOf('case "beginMediaImportBackgroundTask":', caseStart);
    expect(caseEnd, greaterThan(caseStart), reason: '找不到下一个 case，截取失败');
    final String caseBody =
        src.substring(caseStart + caseAnchor.length, caseEnd);
    // 自检：截出来的必须真是那个 case 的 body，否则下面两条断言都变成空转。
    expect(caseBody.trim(), isNotEmpty, reason: '截出的 case body 是空的');
    expect(
      caseBody,
      contains('consumeAnkiMobilePasteboard'),
      reason: 'case 必须分发给带 active 门的 helper',
    );
    expect(
      caseBody,
      isNot(contains('UIPasteboard')),
      reason: '又在 URL 回调那一刻直接读剪贴板了——那时 app 还是 .inactive',
    );

    // 时序门本身。
    expect(src, contains('UIApplication.shared.applicationState == .active'));
    expect(src, contains('UIApplication.didBecomeActiveNotification'));
    expect(src, contains('removeObserver'));
  });

  // BUG-2150：「读不到」必须能区分「AnkiMobile 没写」与「系统不让读」——两者的下一步
  // 动作完全不同。contains(pasteboardTypes:) 只查元数据、不触发粘贴确认弹窗。
  test('AppDelegate 用非提示性探测区分 denied 与 empty', () {
    final String src = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(src, contains('pasteboardTypes:'));
    expect(src, contains('"denied"'));
    expect(src, contains('"empty"'));
    expect(src, contains('"status"'));
  });

  test('Dart startup consumes the AnkiMobile info callback', () {
    final main = File('lib/main.dart').readAsStringSync();
    final vm = File('lib/src/anki/anki_view_model.dart').readAsStringSync();

    expect(main, contains('IosUrlEventChannel'));
    expect(main, contains('fushiAnkiFetchCallback'));
    expect(main, contains('consumeInfoForAddingPasteboard'));
    expect(main, contains('ankiViewModelProvider.notifier'));
    expect(vm, contains('Future<void> applyFetchedConfiguration()'));
    // BUG-2150：失败文案必须过本地化入口（此前是硬编码英文，中文 UI 里原样显示）。
    expect(main, contains('AnkiViewModel.localizeAnkiFetchError'));
  });
}
