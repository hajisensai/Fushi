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
    // Only reuse-warm-slot or empty results reveal immediately.
    expect(base.contains('reuse || dictionaryResult.entries.isEmpty'), isTrue,
        reason: '只有复用热槽或无词条才立即 show');
  });

  test('video/home (dictionary_page_mixin) gates a cold nested popup on render',
      () {
    final String mixin = File(
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ).readAsStringSync();
    expect(mixin.contains('controller.markPendingReveal(entry)'), isTrue,
        reason: '冷嵌套层就绪后挂起，不立即 show');
    expect(mixin.contains('controller.revealRendered(entry)'), isTrue,
        reason: 'onRendered 翻可见挂起层');
    expect(mixin.contains('reuseWarmSlot || result.entries.isEmpty'), isTrue,
        reason: '只有复用热槽或无词条才立即 show');
  });
}
