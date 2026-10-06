import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 桌面应用外悬浮球（BUG-2793 合并后审查）：Windows runner 没有能驱动窗口过程的
/// 单测装置，这里按源码钉住三条修法——任何一条退回，对应的症状就会回来。
const String _runner = 'windows/runner';

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

/// 取 `LRESULT FloatingBallWindow::<name>(` 的函数体（到下一个顶层 `}`）。
String _body(String src, String name) {
  final int start = src.indexOf('LRESULT FloatingBallWindow::$name(');
  expect(start, isNot(-1), reason: '$name 不见了');
  final int end = src.indexOf('\n}\n', start);
  expect(end, isNot(-1));
  return src.substring(start, end);
}

void main() {
  final String window = _read('$_runner/floating_ball_window.cpp');

  test('球窗与按钮窗：触摸 / 触控笔按下也不激活（WM_POINTERACTIVATE 走共用策略）', () {
    expect(window, contains('#include "window_activation_policy.h"'));
    for (final String proc in <String>[
      'HandleBallMessage',
      'HandleMenuMessage',
    ]) {
      final String body = _body(window, proc);
      // WS_EX_NOACTIVATE 只挡鼠标；WM_POINTERACTIVATE 落到 DefWindowProc 会回
      // PA_ACTIVATE，触摸点球就把前台抢走（BUG-2788 同一个坑）。
      expect(
        body,
        contains(
          'case WM_POINTERACTIVATE:\n'
          '    case WM_MOUSEACTIVATE:\n'
          '      return OverlayNoActivateReply(message);',
        ),
        reason: '$proc 必须把两条激活请求都交给 OverlayNoActivateReply',
      );
      expect(body, isNot(contains('return MA_NOACTIVATE;')), reason: proc);
    }
  });

  test('拖动阈值按窗口 DPI 换成物理像素（200% 屏上一抖不被判成拖动）', () {
    final String body = _body(window, 'HandleBallMessage');
    expect(body, contains('GetDpiForWindow(hwnd)'));
    // SM_CXDRAG 是裸像素，GetSystemMetricsForDpi 对它不缩放（实测 96~288 DPI
    // 恒回 4）——用它等于没修，必须自己按 dpi/96 换算。
    expect(body, isNot(contains('GetSystemMetricsForDpi(SM_CXDRAG')));
    expect(body, isNot(contains('GetSystemMetricsForDpi(SM_CYDRAG')));
    expect(
      body,
      contains(
        'MulDiv(GetSystemMetrics(SM_CXDRAG), dpi, USER_DEFAULT_SCREEN_DPI)',
      ),
    );
    expect(
      body,
      contains(
        'MulDiv(GetSystemMetrics(SM_CYDRAG), dpi, USER_DEFAULT_SCREEN_DPI)',
      ),
    );
    expect(body, contains('dx <= drag_x && dy <= drag_y'));
  });

  test('startSystemBall 回原生的真实结果（起不来时 Dart 不记签名、下次再试）', () {
    final String flutterWindow = _read('$_runner/flutter_window.cpp');
    final int start = flutterWindow.indexOf('if (method == "startSystemBall")');
    expect(start, isNot(-1));
    final String branch = flutterWindow.substring(
      start,
      flutterWindow.indexOf('} else if (method == "stopSystemBall")', start),
    );
    expect(
      branch,
      matches(
        RegExp(
          r'const bool started =\s*floating_ball_window_->Start\(',
          multiLine: true,
        ),
      ),
    );
    expect(
      branch,
      contains('result->Success(flutter::EncodableValue(started));'),
    );
    expect(branch, isNot(contains('EncodableValue(true)')));

    final String mac = _read('macos/Runner/FushiDesktopFloatingBall.swift');
    expect(
      mac,
      contains('result(start(call.arguments as? [String: Any] ?? [:]))'),
    );
    expect(mac, contains('private func start(_ args: [String: Any]) -> Bool'));
  });

  test('desktop label preference keeps legacy defaults and native names', () {
    final String flutterWindow = _read('$_runner/flutter_window.cpp');
    expect(
      flutterWindow,
      contains('config.show_labels = BoolFromValue(args, "showLabels", true);'),
    );
    final String mac = _read('macos/Runner/FushiDesktopFloatingBall.swift');
    expect(
      mac,
      contains('showsActionLabels = (args["showLabels"] as? Bool) ?? true'),
    );
    expect(mac, contains('let showLabels = showsActionLabels && columns == 1'));
    // AppKit cannot run on the Windows test host. This checks wiring only;
    // native rendering/hit-area behavior is exercised by the Windows DIB test.
    expect(mac, contains('toolTip = label'));
    expect(mac, contains('setAccessibilityLabel(label)'));
  });
}
