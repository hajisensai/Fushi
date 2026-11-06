import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/popup_body_static_layer.dart';

/// 查词弹窗打开期间给正文 WebView 开静态硬件层的闸门（Android Hybrid Composition）。
///
/// 正文静止、弹窗在上面滚动 / 开关动画时，没有层的正文每帧都要重画（120Hz 平板
/// 80 → 61 fps）；弹窗全关就必须关层，否则正文滚动时每帧重画整屏离屏层。这里钉的是
/// 「弹窗栈变化 → set(true/false) 调用序列」。
class _Recorder {
  final List<String> calls = <String>[];

  Future<bool> set(Object viewId, {required bool enabled}) async {
    calls.add('$viewId:${enabled ? 'on' : 'off'}');
    return true;
  }
}

void main() {
  group('PopupBodyStaticLayerGate', () {
    test('开 → 开层，重复开不重复调用，关 → 关层', () {
      final _Recorder r = _Recorder();
      final PopupBodyStaticLayerGate gate = PopupBodyStaticLayerGate(
        setter: r.set,
      )..resolveBody = () => 7;

      gate.popupOpenChanged(true);
      gate.popupOpenChanged(true);
      expect(r.calls, <String>['7:on']);
      expect(gate.layeredViewId, 7);

      gate.popupOpenChanged(false);
      gate.popupOpenChanged(false);
      expect(r.calls, <String>['7:on', '7:off']);
      expect(gate.layeredViewId, isNull);
    });

    test('弹窗开着时正文 WebView 才建好：bodyChanged 补开', () {
      final _Recorder r = _Recorder();
      Object? body;
      final PopupBodyStaticLayerGate gate = PopupBodyStaticLayerGate(
        setter: r.set,
      )..resolveBody = () => body;

      gate.popupOpenChanged(true);
      expect(r.calls, isEmpty, reason: '还没有正文 WebView');
      body = 3;
      gate.bodyChanged();
      expect(r.calls, <String>['3:on']);
    });

    test('正文 WebView 重建（新 viewId）：旧的关、新的开；关弹窗只关新的', () {
      final _Recorder r = _Recorder();
      Object? body = 1;
      final PopupBodyStaticLayerGate gate = PopupBodyStaticLayerGate(
        setter: r.set,
      )..resolveBody = () => body;

      gate.popupOpenChanged(true);
      body = 2;
      gate.bodyChanged();
      gate.bodyChanged();
      gate.popupOpenChanged(false);
      expect(r.calls, <String>['1:on', '1:off', '2:on', '2:off']);
    });

    test('弹窗关着时正文重建：不调用（新 WebView 默认就没有层）', () {
      final _Recorder r = _Recorder();
      Object? body = 1;
      final PopupBodyStaticLayerGate gate = PopupBodyStaticLayerGate(
        setter: r.set,
      )..resolveBody = () => body;

      body = 2;
      gate.bodyChanged();
      expect(r.calls, isEmpty);
      gate.popupOpenChanged(true);
      expect(r.calls, <String>['2:on']);
    });

    test('dispose 关掉开着的层，之后不再调用', () {
      final _Recorder r = _Recorder();
      final PopupBodyStaticLayerGate gate = PopupBodyStaticLayerGate(
        setter: r.set,
      )..resolveBody = () => 5;

      gate.popupOpenChanged(true);
      gate.dispose();
      gate.bodyChanged();
      expect(r.calls, <String>['5:on', '5:off']);
    });

    test('没有平台实现（非 Android）：整体 no-op，连正文都不取', () {
      int resolved = 0;
      final PopupBodyStaticLayerGate gate = PopupBodyStaticLayerGate()
        ..resolveBody = () {
          resolved++;
          return 1;
        };
      gate.popupOpenChanged(true);
      gate.bodyChanged();
      gate.popupOpenChanged(false);
      expect(resolved, 0);
      expect(gate.layeredViewId, isNull);
    });

    test('宿主没有 WebView 正文（不设 resolveBody）：不调用', () {
      final _Recorder r = _Recorder();
      final PopupBodyStaticLayerGate gate = PopupBodyStaticLayerGate(
        setter: r.set,
      );
      gate.popupOpenChanged(true);
      gate.popupOpenChanged(false);
      expect(r.calls, isEmpty);
    });

    test('platformWebViewStaticLayerSetter 只在 Android 给实现', () {
      // 测试跑在桌面宿主上。
      expect(platformWebViewStaticLayerSetter(), isNull);
    });
  });

  group('DictionaryPopupController 驱动闸门（唯一收口点）', () {
    DictionaryPopupController make(_Recorder r) {
      final DictionaryPopupController c = DictionaryPopupController(
        lowMemory: false,
        bodyStaticLayer: PopupBodyStaticLayerGate(setter: r.set),
      );
      c.bodyStaticLayer.resolveBody = () => 42;
      return c;
    }

    test('热槽隐身不算打开；顶层可见开层、嵌套不重复、整栈关回热槽关层', () {
      final _Recorder r = _Recorder();
      final DictionaryPopupController c = make(r)..seedWarmSlot();
      expect(r.calls, isEmpty, reason: '常驻热槽 visible=false，不是打开的弹窗');

      c.beginTop(
        term: 'あ',
        rect: Rect.zero,
        reuseWarmSlot: true,
        replaceStack: false,
        visible: true,
      );
      expect(r.calls, <String>['42:on']);

      c.pushChild(term: 'い', rect: Rect.zero, parentIndex: 0, visible: true);
      c.truncateTo(1);
      expect(r.calls, <String>['42:on'], reason: '栈一直非空，不翻层');

      c.dismissAt(0);
      expect(c.hasVisiblePopup, isFalse);
      expect(r.calls, <String>['42:on', '42:off']);
    });

    test('搜索期占位（弹窗开场动画）就算打开；无结果收起即关', () {
      final _Recorder r = _Recorder();
      final DictionaryPopupController c = make(r)..seedWarmSlot();
      final DictionaryPopupEntry target = c.beginTop(
        term: 'あ',
        rect: Rect.zero,
        reuseWarmSlot: true,
        replaceStack: false,
        visible: false,
      );
      c.beginSearchUi(const Rect.fromLTWH(0, 0, 10, 10), target);
      expect(c.isSearchingUi, isTrue);
      expect(r.calls, <String>['42:on']);

      c.endSearchUi();
      c.dismissAt(0);
      expect(r.calls, <String>['42:on', '42:off']);
    });

    test('clear 关层；宿主 dispose 时弹窗还开着也关层', () {
      final _Recorder r = _Recorder();
      final DictionaryPopupController c = make(r);
      c.beginTop(
        term: 'あ',
        rect: Rect.zero,
        reuseWarmSlot: false,
        replaceStack: true,
        visible: true,
      );
      c.clear();
      expect(r.calls, <String>['42:on', '42:off']);

      c.beginTop(
        term: 'う',
        rect: Rect.zero,
        reuseWarmSlot: false,
        replaceStack: true,
        visible: true,
      );
      c.dispose();
      expect(r.calls, <String>['42:on', '42:off', '42:on', '42:off']);
    });
  });
}
