import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-058 source-scan guard: locks the "a cold nested popup's visibility is
/// driven by the WebView render signal, not by FFI-result-ready" wiring across
/// the reader (base_source_page) and video/home (dictionary_page_mixin) paths.
/// Rendering can't be exercised in the unit harness (the fake WebView never
/// fires real lifecycle callbacks), so this pins the contract that kills the
/// second-popup white flash. If someone reverts to an unconditional `show()` on
/// a cold layer, this fails.
void main() {
  test('controller exposes the pending-reveal state machine', () {
    final String ctrl = File(
      'lib/src/pages/implementations/dictionary_popup_controller.dart',
    ).readAsStringSync();
    expect(ctrl.contains('bool revealOnRender'), isTrue,
        reason: '条目需带「等渲染才显示」挂起标记');
    expect(ctrl.contains('void markPendingReveal('), isTrue,
        reason: '冷层挂起 API');
    expect(ctrl.contains('bool revealRendered('), isTrue,
        reason: '渲染完成翻可见 API');
  });

  test('reader (base_source_page) gates a cold nested popup on render', () {
    final String base =
        File('lib/src/pages/base_source_page.dart').readAsStringSync();
    // Cold (non-warm-slot, non-empty) nested layer is parked pending render.
    expect(base.contains('markPendingReveal(item)'), isTrue,
        reason: '冷嵌套层就绪后挂起，不立即 show');
    // The render signal (onRendered) reveals the pending layer.
    expect(base.contains('_onPopupLayerRendered('), isTrue,
        reason: 'onRendered 经统一入口翻可见挂起层');
    expect(base.contains('_popup.revealRendered('), isTrue,
        reason: '渲染完成时调 revealRendered');
    // Renderable results, including reused warm slots, must wait for the current
    // WebView render signal; completed empty results can use Flutter's
    // no-results placeholder immediately.
    expect(
        base.contains(
            'final bool needsWebViewRender = _itemNeedsWebViewRender(item);'),
        isTrue,
        reason: 'reader 必须先判断结果是否需要 WebView 渲染');
    expect(base.contains('revealImmediately && needsWebViewRender'), isTrue,
        reason: '复用 warm slot 但有可渲染内容时也要等 popupRendered');
    expect(base.contains('result.kanjiResults.isNotEmpty'), isTrue,
        reason: 'kanji-only 结果也需要 WebView 渲染');
  });

  test('video/home (dictionary_page_mixin) gates a cold nested popup on render',
      () {
    final String mixin = File(
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ).readAsStringSync();
    expect(mixin.contains('controller.markPendingReveal('), isTrue,
        reason: '冷嵌套层就绪后挂起，不立即 show');
    expect(mixin.contains('controller.revealRendered(entry)'), isTrue,
        reason: 'onRendered 翻可见挂起层');
    expect(mixin.contains('final bool needsWebViewRender ='), isTrue,
        reason: 'mixin 必须先判断结果是否需要 WebView 渲染');
    expect(mixin.contains('result.kanjiResults.isNotEmpty'), isTrue,
        reason: 'kanji-only 结果也需要 WebView 渲染');
    expect(mixin.contains('if (!needsWebViewRender) {'), isTrue,
        reason: '只有真实空结果才立即 show Flutter 占位');
  });

  // ── TODO-058 fail-safe 守卫：popupRendered 永不发也不卡死 ───────────────────
  test('controller has a timeout fail-safe Timer for pending reveals', () {
    final String ctrl = File(
      'lib/src/pages/implementations/dictionary_popup_controller.dart',
    ).readAsStringSync();
    expect(ctrl.contains('kRevealFailsafeTimeout'), isTrue, reason: '挂起层超时常量');
    expect(ctrl.contains('_revealFailsafeTimers'), isTrue,
        reason: '每挂起层一个兜底 Timer');
    expect(ctrl.contains('Timer(timeout'), isTrue, reason: '一次性超时 Timer');
    expect(ctrl.contains('void dispose()'), isTrue,
        reason: 'dispose 取消 Timer 防泄漏');
  });

  test('popup webview surfaces a load-error reveal signal (onRenderError)', () {
    final String wv = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
    expect(wv.contains('onRenderError'), isTrue, reason: '错误回调字段');
    expect(wv.contains('onReceivedError:'), isTrue, reason: '主框架加载失败回调');
    expect(wv.contains('widget.onRenderError?.call()'), isTrue,
        reason: '加载失败通知宿主翻可见');
  });

  test('reader/mixin wire onRenderError to the same reveal path', () {
    final String base =
        File('lib/src/pages/base_source_page.dart').readAsStringSync();
    expect(base.contains('onRenderError:'), isTrue,
        reason: 'reader 把加载失败接到翻可见入口');
    expect(base.contains('_popup.dispose()'), isTrue,
        reason: 'reader 作为 controller 所有者 dispose 取消 Timer');
    final String mixin = File(
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ).readAsStringSync();
    expect(mixin.contains('onRenderError:'), isTrue,
        reason: 'mixin 把加载失败接到翻可见入口');
    expect(mixin.contains('onForcedReveal:'), isTrue,
        reason: 'mixin 超时强制翻可见后 setState 重建');
  });
}
