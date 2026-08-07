import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guard for BUG-870: the Windows WebView2 fork must accumulate a
/// per-axis sub-unit remainder in [InAppWebView::sendScroll] instead of
/// truncating each scroll delta to a `short` independently.
///
/// Root cause: `static_cast<short>(delta * kScrollMultiplier)` rounds toward
/// zero with no cross-call carry. A precision touchpad delivers small per-frame
/// deltas; any frame whose scaled magnitude is < 1 became 0 and sent no wheel to
/// WebView2 at all — the dictionary popup "could not scroll" with a touchpad
/// while a mouse (delta≈20 → 120) worked. This is upstream of popup.js's
/// TODO-1387 sub-pixel carry: the wheel never even reached the DOM.
///
/// The native window cannot run on the test host, so this pins the load-bearing
/// bits of the fix so a `pub get` re-vendor or refactor cannot silently regress
/// it. Behaviour proof of the JS-side factor lives in
/// popup_wheel_scroll_behavior_test.js.
void main() {
  late String sendScrollBody;
  late String forwardCompositionMouseBody;

  setUpAll(() {
    final String cpp = File(
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp',
    ).readAsStringSync();
    final int start = cpp.indexOf('void InAppWebView::sendScroll');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'sendScroll must exist in the vendored in_app_webview.cpp');
    final int end = cpp.indexOf('void InAppWebView::setScrollDelta', start);
    expect(end, greaterThan(start),
        reason: 'setScrollDelta must follow sendScroll');
    sendScrollBody = cpp.substring(start, end);

    // BUG-1065 对照端：app 外查词弹窗的裸 WebView2 overlay 转发路径。
    final String overlayCpp =
        File('windows/runner/global_lookup_window.cpp').readAsStringSync();
    final int overlayStart =
        overlayCpp.indexOf('void GlobalLookupWindow::ForwardCompositionMouse');
    expect(overlayStart, greaterThanOrEqualTo(0),
        reason:
            'ForwardCompositionMouse must exist in global_lookup_window.cpp');
    final int overlayEnd = overlayCpp.indexOf(
        'void GlobalLookupWindow::EnsureWebView', overlayStart);
    expect(overlayEnd, greaterThan(overlayStart),
        reason: 'EnsureWebView must follow ForwardCompositionMouse');
    forwardCompositionMouseBody =
        overlayCpp.substring(overlayStart, overlayEnd);
  });

  group('BUG-870 native sendScroll carries a sub-unit remainder', () {
    test('reads a per-axis residual and carries the truncated fraction', () {
      // A precision touchpad's small deltas must accumulate across calls rather
      // than each truncating to 0.
      expect(sendScrollBody.contains('scrollResidualX_'), isTrue,
          reason: 'horizontal axis must carry its own sub-unit remainder');
      expect(sendScrollBody.contains('scrollResidualY_'), isTrue,
          reason: 'vertical axis must carry its own sub-unit remainder');
      expect(sendScrollBody.contains('residual = scaled - offset'), isTrue,
          reason: 'the truncated fraction must be kept for the next call');
    });

    test('skips sending a wheel only when the accumulated offset is still zero',
        () {
      // A sub-unit frame must return WITHOUT sending (offset 0), so the fraction
      // keeps accumulating instead of firing a spurious zero-delta wheel.
      expect(sendScrollBody.contains('if (offset == 0)'), isTrue,
          reason:
              'a sub-unit frame must carry its fraction and not send a 0 wheel');
    });

    test('does not truncate the raw delta directly to short (the old bug)', () {
      // The regression was `static_cast<short>(delta * kScrollMultiplier)` with
      // no residual — truncating each frame independently. The cast must now act
      // on the residual-accumulated `scaled` value, never on the raw product.
      expect(
        sendScrollBody
            .contains('static_cast<short>(delta * kScrollMultiplier)'),
        isFalse,
        reason: 'truncating the raw delta*multiplier drops small touchpad '
            'frames to 0 (BUG-870); it must accumulate a residual first',
      );
      expect(sendScrollBody.contains('static_cast<short>(scaled)'), isTrue,
          reason: 'the short cast must act on the residual-accumulated value');
    });
  });

  // BUG-1065 —— app 内 / app 外两种查词弹窗喂给 WebView2 的 wheel 单位必须同尺度。
  //
  // app 内走 Flutter PointerScrollEvent，framework converter.dart 已把 scrollDelta
  // 除过 devicePixelRatio（逻辑像素）；kScrollMultiplier=6 的「一档 delta≈20」前提
  // 只在 dpr=1 成立。app 外的裸 WebView2 overlay 则原样转发系统 WHEEL_DELTA。
  // 150% 缩放下 app 内一档只有 0.67 个 WHEEL_DELTA → 同一份 popup.js 收到的 deltaY
  // 小 1/dpr，用户直观感受就是「app 内滚得慢」。dpr≥2 时更会跌破 popup.js 的
  // POPUP_WHEEL_MOUSE_NOTCH_PX=60 粗/细设备阈值而被误判成触控板。
  group('BUG-1065 wheel delta 与 app 外 overlay 同尺度', () {
    test('in-app sendScroll 按 scaleFactor_ 还原物理像素后再乘倍数', () {
      expect(sendScrollBody.contains('scaleFactor_'), isTrue,
          reason: '滚轮 delta 是逻辑像素，必须用 scaleFactor_（devicePixelRatio）'
              '还原成物理像素，与同文件鼠标坐标 (x * scaleFactor_) 的处理一致');
      expect(
        RegExp(r'delta \* kScrollMultiplier \* \w+ \+ residual')
            .hasMatch(sendScrollBody),
        isTrue,
        reason: '缩放系数必须乘进 scaled，且仍走 BUG-870 的 residual 累积',
      );
    });

    test('不再出现无 DPR 还原的旧形式', () {
      expect(
        sendScrollBody.contains('delta * kScrollMultiplier + residual'),
        isFalse,
        reason: '直接用逻辑像素乘 6 会让高 DPI 机器的 app 内弹窗慢 1/dpr（BUG-1065）',
      );
    });

    test('scaleFactor_ 为 0/未初始化时回退 1.0，绝不把 wheel 归零', () {
      expect(sendScrollBody.contains('1.0'), isTrue,
          reason: 'scaleFactor_ 非法（<=0）时必须回退 1.0，否则一乘 0 滚轮全死');
      expect(RegExp(r'scaleFactor_ > 0').hasMatch(sendScrollBody), isTrue,
          reason: '必须显式判非法缩放系数再回退');
    });

    test('对照端：app 外 overlay 仍原样转发系统 WHEEL_DELTA', () {
      // 这是 parity 的另一半锚点：修 app 内是为了对齐这里，若哪天有人反过来给
      // overlay 加打折，两端又会漂开。
      expect(
        forwardCompositionMouseBody.contains('GET_WHEEL_DELTA_WPARAM(wparam)'),
        isTrue,
        reason: 'app 外弹窗必须把系统原始 wheel delta 原样交给 WebView2',
      );
      expect(
        RegExp(r'GET_WHEEL_DELTA_WPARAM\(wparam\)\s*[*/]')
            .hasMatch(forwardCompositionMouseBody),
        isFalse,
        reason: 'overlay 侧不得对 wheel delta 再做缩放/打折（parity 对照端）',
      );
    });
  });
}
