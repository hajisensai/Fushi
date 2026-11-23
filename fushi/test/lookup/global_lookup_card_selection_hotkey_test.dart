import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

import '../helpers/source_guard.dart';

/// BUG-5310 — app 外查词卡片里选中一段字再按全局查词热键（手柄 / 鼠标侧键同一执行
/// 体），必须在卡片里嵌套查这段选区；旧实现先 hide 卡片再抓**前台程序**的选区（卡片
/// WS_EX_NOACTIVATE，永不是前台），于是卡片闪一下、在鼠标处重新弹出原来那个词。
///
/// 修复契约：
///   · 卡片在场（有在途 desktop 路由）时，[GlobalLookupController.triggerSelectionLookup]
///     在铸新路由之前、带着卡片自己的路由问 native `lookupOverlaySelection`；
///   · 回 true = 卡片接手：不铸新路由（否则 host 发回的 textSelected 被当成旧路由丢掉）、
///     不 hide、不抓前台选区；
///   · 回 false / 平台没有这条方法 = 照旧走前台抓取；
///   · 卡片不在场时一次往返都不多。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final List<MethodCall> calls = <MethodCall>[];
  late Object? Function(MethodCall call) reply;

  setUp(() {
    GlobalLookupController.platformOverride = true;
    calls.clear();
    reply = (MethodCall call) => null;
    messenger.setMockMethodCallHandler(FushiChannels.globalLookup, (
      MethodCall call,
    ) async {
      calls.add(call);
      return reply(call);
    });
  });

  tearDown(() {
    GlobalLookupController.platformOverride = null;
    messenger.setMockMethodCallHandler(FushiChannels.globalLookup, null);
  });

  final GlobalLookupController lookup = GlobalLookupController.instance;

  List<String> methods() => calls.map((MethodCall c) => c.method).toList();

  test('卡片不在场：不问卡片，直接走前台抓取', () async {
    expect(lookup.desktopLookupInFlight, isFalse);
    await lookup.triggerSelectionLookup(source: 'test');
    expect(methods(), isNot(contains('lookupOverlaySelection')));
  });

  test('卡片在场且有选区：卡片接手，不铸新路由、不收卡', () async {
    final GlobalLookupRoute card = lookup.debugActivateDesktopRoute();
    reply = (MethodCall call) =>
        call.method == 'lookupOverlaySelection' ? true : null;

    await lookup.triggerSelectionLookup(source: 'hotkey');

    expect(methods(), <String>['lookupOverlaySelection']);
    final Map<Object?, Object?> args =
        calls.single.arguments as Map<Object?, Object?>;
    expect(args['source'], 'desktop');
    expect(args['routeEpoch'], card.routeEpoch);
    expect(
      args['lookupEpoch'],
      card.lookupEpoch,
      reason: '必须带卡片自己的路由去问，native 才认这张卡',
    );
    expect(
      GlobalLookupChannel.isRouteValid(card),
      isTrue,
      reason: '卡片路由被作废 = host 发回的 textSelected 会被当旧消息丢掉',
    );
    expect(lookup.desktopLookupInFlight, isTrue);
  });

  test('卡片在场但没选区：照旧铸新路由走前台抓取', () async {
    final GlobalLookupRoute card = lookup.debugActivateDesktopRoute();
    reply = (MethodCall call) =>
        call.method == 'lookupOverlaySelection' ? false : null;

    await lookup.triggerSelectionLookup(source: 'hotkey');

    expect(methods().first, 'lookupOverlaySelection');
    expect(
      GlobalLookupChannel.isRouteValid(card),
      isFalse,
      reason: '回落路径要铸新路由（并作废卡片路由），与修复前行为一致',
    );
  });

  test('平台没有 lookupOverlaySelection（macOS / Linux）：当作不接手', () async {
    final GlobalLookupRoute card = lookup.debugActivateDesktopRoute();
    reply = (MethodCall call) {
      if (call.method == 'lookupOverlaySelection') {
        throw MissingPluginException();
      }
      return null;
    };

    await lookup.triggerSelectionLookup(source: 'hotkey');

    expect(methods().first, 'lookupOverlaySelection');
    expect(GlobalLookupChannel.isRouteValid(card), isFalse);
  });

  group('native / host 接线源码守卫（WebView2 headless 测不了）', () {
    String readRaw(String p) =>
        File(p).readAsStringSync().replaceAll('\r\n', '\n');

    test('native 判据与 Ctrl+C 接管同源，并调用 host.lookupSelection', () {
      final String cpp = maskComments(
        readRaw('windows/runner/global_lookup_window.cpp'),
      );
      final int at = cpp.indexOf(
        'bool GlobalLookupWindow::LookupOverlaySelection(',
      );
      expect(at, greaterThanOrEqualTo(0));
      final String body = cpp.substring(at, cpp.indexOf('\n}', at));
      expect(body, contains('!selection_present_ || !IsShowing()'));
      expect(body, contains('h.lookupSelection()'));
      expect(body, contains('return true;'));

      final String flutterWindow = maskComments(
        readRaw('windows/runner/flutter_window.cpp'),
      );
      expect(
        flutterWindow,
        contains('method == "lookupOverlaySelection"'),
        reason: 'Dart 调的方法名必须在 global_lookup 通道上有分支',
      );
      expect(flutterWindow, contains('win->LookupOverlaySelection()'));
    });

    test('host 导出 lookupSelection，经卡片 realm 的桥发 textSelected', () {
      final String hostJs = maskJsComments(
        readRaw('assets/popup/global_lookup_host.js'),
      );
      expect(hostJs, contains('lookupSelection: lookupSelection,'));
      expect(
        hostJs,
        contains("bridge.callHandler('textSelected', text, rect)"),
      );
    });
  });
}
