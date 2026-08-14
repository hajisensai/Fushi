import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';

/// TODO-1233 — 867 app 外查词覆盖窗的 `overlayHidden` 回调契约。
///
/// 背景：872 把桌面悬浮歌词点词切到覆盖窗，但视频字幕路径（路径 A）没切——因为
/// native 覆盖窗 `Hide()` 不回调 Dart，视频查词的 BUG-072「查词暂停→关窗续播」无处
/// 挂。本卷补上并钉死回调契约：
///
///  1. [GlobalLookupChannel.hide] 默认 `notify:true`（真实关闭，会触发 overlayHidden）；
///     `notify:false`（两次查词之间的 reset）不得被当成用户关闭——否则会在换词/重查
///     的一瞬间把暂停的视频误恢复。
///  2. native 反向 `overlayHidden` 方法调用必须派发到 [GlobalLookupChannel.setHandlers]
///     注册的 `onOverlayHidden`。
///  3. 三端接线（源码扫描）：native `Hide(bool)` 只在真实关闭时 fire `hidden_cb_`；
///     `flutter_window` 把 `SetHiddenCallback` 接到 `overlayHidden` InvokeMethod；
///     controller 把 `_onOverlayHidden` 接进 setHandlers、两处 between-lookups reset
///     用 `notify: false`、并暴露公开 `onHidden` 消费点。
///
/// 覆盖窗真实弹出/关闭依赖 native WebView2（Windows-only），headless 测不了整链——
/// C++ 改动真机验收见 TODO-1233 看板项。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('app.fushi.reader/global_lookup');
  const StandardMethodCodec codec = StandardMethodCodec();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  group('hide(notify) 出站契约', () {
    late List<MethodCall> outgoing;

    setUp(() {
      outgoing = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        outgoing.add(call);
        return null;
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('hide() 默认发 notify:true（真实关闭）', () async {
      await GlobalLookupChannel.hide();
      expect(outgoing.single.method, 'hide');
      expect((outgoing.single.arguments as Map)['notify'], isTrue);
    });

    test('hide(notify:false) 发 notify:false（两次查词间的 reset，不算用户关闭）', () async {
      await GlobalLookupChannel.hide(notify: false);
      expect(outgoing.single.method, 'hide');
      expect((outgoing.single.arguments as Map)['notify'], isFalse);
    });
  });

  group('overlayHidden 入站派发', () {
    test('native overlayHidden 调用派发到 onOverlayHidden 回调', () async {
      int hiddenCalls = 0;
      GlobalLookupChannel.setHandlers(
        onGetMedia: (_) async => Uint8List(0),
        onJsMessage: (_) {},
        onOverlayHidden: () => hiddenCalls++,
      );
      // 模拟 native 反向调用 overlayHidden（无参）。
      await messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('overlayHidden')),
        (_) {},
      );
      expect(hiddenCalls, 1);

      // getMedia / jsMessage 不误触发 onOverlayHidden。
      await messenger.handlePlatformMessage(
        channel.name,
        codec
            .encodeMethodCall(const MethodCall('jsMessage', '{"handler":"x"}')),
        (_) {},
      );
      expect(hiddenCalls, 1, reason: 'overlayHidden 只由 overlayHidden 方法触发');
    });

    test('未注册 onOverlayHidden 时 overlayHidden 调用不抛（可选消费点）', () async {
      GlobalLookupChannel.setHandlers(
        onGetMedia: (_) async => Uint8List(0),
        onJsMessage: (_) {},
      );
      await messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('overlayHidden')),
        (_) {},
      );
    });
  });

  group('三端接线（源码扫描）', () {
    test('native Hide(bool) 只在真实关闭时 fire hidden_cb_', () {
      final String cpp = read('windows/runner/global_lookup_window.cpp');
      expect(cpp.contains('void GlobalLookupWindow::Hide(bool notify)'), isTrue,
          reason: 'Hide 必须带 notify 参数区分 reset 与真实关闭');
      // 离屏卡片窗（游戏内查词）**从来不 visible_**，它活着的标志是 offscreen_active_。
      // 只看 visible_ 的话，那条路由的 hidden 回调一次都不会触发，Dart 侧的卡片状态
      // 就永远停在"还开着"。
      expect(
          cpp.contains(
              'const bool was_showing = visible_ || offscreen_active_;'),
          isTrue,
          reason: '必须在清 visible_ 前捕获（含离屏路由），避免双钩子双通知');
      expect(cpp.contains('if (notify && was_showing && hidden_cb_)'), isTrue,
          reason: '回调仅在 notify 且确曾在屏时触发');
      final String h = read('windows/runner/global_lookup_window.h');
      // 回调必须带 RouteContext：桌面浮窗与游戏内离屏卡片共用同一个 channel，
      // 不带路由的 overlayHidden 会让 Dart 把另一条路由的关闭当成自己的。
      expect(
          h.contains(
              'using HiddenCallback = std::function<void(const RouteContext& route)>;'),
          isTrue);
      expect(h.contains('void SetHiddenCallback(HiddenCallback cb)'), isTrue);
    });

    test('flutter_window 把 SetHiddenCallback 接到 overlayHidden InvokeMethod',
        () {
      final String src = read('windows/runner/flutter_window.cpp');
      final int at = src.indexOf('global_lookup_window_->SetHiddenCallback(');
      expect(at, greaterThan(-1), reason: '必须注册 hidden 回调');
      final int invoke = src.indexOf('"overlayHidden"', at);
      expect(invoke, greaterThan(at),
          reason: 'hidden 回调必须 InvokeMethod("overlayHidden") 回 Dart');
      // 回调签名与回传都必须带 route：同一个 channel 上跑着桌面浮窗和游戏内离屏
      // 卡片两条路由，裸的 overlayHidden 会被 Dart 当成自己那条关了。
      final String cb = src.substring(at, invoke + 120);
      expect(
          cb.contains('const GlobalLookupWindow::RouteContext& route'), isTrue,
          reason: 'hidden 回调必须接收 RouteContext');
      expect(cb.contains('RoutedHiddenEnvelope(route)'), isTrue,
          reason: 'overlayHidden 必须带上路由信息回 Dart');
      // "hide" 方法读 notify 参数转发给 Hide（通道按 target 路由后统一用 win）。
      expect(src.contains('win->Hide(BoolFromValue(args, "notify", true))'),
          isTrue,
          reason: 'hide 方法必须把 notify 参数透给 native Hide');
    });

    test(
        'controller：接 _onOverlayHidden + 三处 reset 用 notify:false + 暴露 onHidden',
        () {
      final String c = read('lib/src/lookup/global_lookup_controller.dart');
      expect(c.contains('onOverlayHidden: _onOverlayHidden'), isTrue,
          reason: 'setHandlers 必须接上 _onOverlayHidden');
      expect(c.contains('void Function()? onHidden;'), isTrue,
          reason: '必须暴露公开 onHidden 消费点（872 前置条件）');
      // 入站的 overlayHidden 带路由；处理器必须接得住并在该路由上下文里跑，
      // 否则游戏内卡片关闭会被当成桌面浮窗关闭（反之亦然）。
      expect(c.contains('void _onOverlayHidden([GlobalLookupRoute? routed])'),
          isTrue,
          reason: '_onOverlayHidden 必须接收路由');
      expect(
          c.contains(
              'GlobalLookupChannel.runWithRoute(route, () => _onOverlayHidden(route))'),
          isTrue,
          reason: '必须在来源路由的上下文里派发 hidden');
      // between-lookups 的三处 reset 必须 notify:false：_onHotKey（热键前导）、
      // _lookupExternal（渲染前 TODO-1079 D）、lookupText（TODO-1268/BUG-578 程序化
      // 悬浮字幕点词前导复位，与热键对齐）；真实关闭路径（_onJsMessage 的
      // dismiss/tapOutside）保持默认 notify:true。
      expect('GlobalLookupChannel.hide(notify: false)'.allMatches(c).length, 3,
          reason: '恰三处 between-lookups reset 用 notify:false');
    });
  });
}
