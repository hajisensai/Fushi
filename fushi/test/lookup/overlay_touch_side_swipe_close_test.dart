import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/popup_swipe_close_script.dart';
import 'package:fushi/src/utils/misc/swipe_dismiss_wrapper.dart';

/// BUG-2770：Windows 触屏在查词覆盖窗（桌面全局查词 / galgame 游戏内卡片）上
/// 横滑关闭。三段链路各钉一层：
///   ① runner 把触摸 / 触控笔的 WM_POINTER* 经 SendPointerInput 原样送进 WebView2
///      （否则页面里 pointerType 恒为 'mouse'，任何触摸手势都认不出来）；
///   ② 覆盖窗注入 [kPopupTouchSideSwipeReleaseJs]，应用内弹窗不注入（它有 Flutter
///      正文横滑检测器，重复识别会一划关两层）——JS 行为经 node 真跑；
///   ③ Dart 侧 [popupSideSwipeDismissAllowed] 按触摸偏好 + 灵敏度阈值判定。
void main() {
  group('popupSideSwipeDismissAllowed', () {
    final double threshold = swipeDismissThreshold(1.0);

    bool allowed({
      Object? kind = 'touch',
      Object? dx,
      bool mouse = false,
      bool touch = true,
    }) => popupSideSwipeDismissAllowed(
      pointerKind: kind,
      dx: dx ?? threshold + 1,
      threshold: threshold,
      mouseSwipeEnabled: mouse,
      touchSwipeEnabled: touch,
    );

    test('touch past the threshold closes in either direction', () {
      expect(allowed(dx: threshold + 1), isTrue);
      expect(allowed(dx: -(threshold + 1)), isTrue);
      expect(allowed(kind: 'pen'), isTrue);
    });

    test('short swipe, mouse or unknown kind never closes', () {
      expect(allowed(dx: threshold), isFalse);
      expect(allowed(kind: 'mouse', mouse: true), isFalse);
      expect(allowed(kind: null), isFalse);
      expect(allowed(dx: 'far'), isFalse);
      expect(allowed(dx: double.nan), isFalse);
    });

    test('an explicit off preference disables it', () {
      expect(allowed(touch: false), isFalse);
      expect(allowed(touch: false, mouse: true), isTrue);
    });
  });

  group('wiring', () {
    String read(String path) => File(path).readAsStringSync();

    test('only the overlay injects the side-swipe script', () {
      expect(
        read('lib/src/lookup/global_lookup_render.dart'),
        contains(r'$kPopupTouchSideSwipeReleaseJs'),
      );
      expect(
        read('lib/src/pages/implementations/dictionary_popup_webview.dart'),
        isNot(contains('kPopupTouchSideSwipeReleaseJs')),
      );
    });

    test('the overlay controller gates sideSwipeReleased on the shared '
        'threshold and touch preference', () {
      final String src = read('lib/src/lookup/global_lookup_controller.dart');
      final int start = src.indexOf("handler == 'sideSwipeReleased'");
      expect(start, isNonNegative);
      final String body = src.substring(start, start + 700);
      expect(body, contains('popupSideSwipeDismissAllowed('));
      expect(body, contains('swipeDismissThreshold('));
      expect(body, contains('enableTouchSwipeToClose'));
      expect(body, contains('GlobalLookupChannel.hide()'));
    });

    test('the composition overlay forwards touch and pen as pointers', () {
      final String src = read('windows/runner/global_lookup_window.cpp');
      final int fn = src.indexOf(
        'bool GlobalLookupWindow::ForwardCompositionPointer(',
      );
      expect(fn, isNonNegative);
      final String body = src.substring(fn, src.indexOf('\n}\n', fn));
      expect(body, contains('type != PT_TOUCH && type != PT_PEN'));
      expect(body, contains('SendPointerInput('));
      expect(body, contains('ScreenToClient(hwnd_, &location)'));
      for (final String message in <String>[
        'WM_POINTERDOWN',
        'WM_POINTERUPDATE',
        'WM_POINTERUP',
      ]) {
        expect(
          RegExp(
            'case $message:[\\s\\S]{0,200}ForwardCompositionPointer\\(',
          ).hasMatch(src),
          isTrue,
          reason: '$message must reach ForwardCompositionPointer',
        );
      }
    });
  });

  test(
    'side-swipe script recognises one-finger horizontal swipes via node',
    () async {
      final String? node = _resolveNode();
      if (node == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final Directory dir = await Directory.systemTemp.createTemp(
        'fushi_side_swipe_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final File harness = File('${dir.path}/harness.js')
        ..writeAsStringSync(_harness(kPopupTouchSideSwipeReleaseJs));
      final ProcessResult result = await Process.run(node, <String>[
        harness.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final Map<String, Object?> calls =
          (jsonDecode((result.stdout as String).trim()) as Map)
              .cast<String, Object?>();
      expect(calls['right'], <Object?>[
        <Object?>['sideSwipeReleased', 'touch', 120],
      ]);
      expect(calls['left'], <Object?>[
        <Object?>['sideSwipeReleased', 'touch', -90],
      ]);
      expect(calls['vertical'], isEmpty);
      expect(calls['verticalThenHorizontal'], isEmpty);
      expect(calls['tiny'], isEmpty);
      expect(calls['twoFingers'], isEmpty);
      expect(calls['selection'], isEmpty);
      expect(calls['cancelled'], isEmpty);
      // A selection left over from before the swipe must not block closing.
      expect(calls['staleSelection'], <Object?>[
        <Object?>['sideSwipeReleased', 'touch', 160],
      ]);
      expect(calls['installOnce'], <Object?>[
        <Object?>['sideSwipeReleased', 'touch', 60],
      ]);
    },
  );
}

String _harness(String script) =>
    '''
const listeners = {};
let selection = '';
const calls = [];
global.window = {
  addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
  getSelection() { return { isCollapsed: selection === '', toString() { return selection; } }; },
  flutter_inappwebview: { callHandler(...args) { calls.push(args); } },
};
const install = () => { (new Function(${jsonEncode(script)}))(); };
install();
const t = (x, y) => ({ clientX: x, clientY: y });
function fire(type, touches, changed) {
  for (const fn of listeners[type] || []) fn({ touches, changedTouches: changed || touches });
}
function swipe(points) {
  fire('touchstart', [t(...points[0])]);
  for (const p of points.slice(1)) fire('touchmove', [t(...p)]);
  const last = points[points.length - 1];
  fire('touchend', [], [t(...last)]);
}
const out = {};
function run(name, fn) { calls.length = 0; selection = ''; fn(); out[name] = calls.slice(); }
run('right', () => swipe([[100, 100], [120, 102], [220, 110]]));
run('left', () => swipe([[300, 100], [280, 98], [210, 95]]));
run('vertical', () => swipe([[100, 100], [102, 130], [104, 300]]));
run('verticalThenHorizontal', () => swipe([[100, 100], [100, 120], [400, 120]]));
run('tiny', () => swipe([[100, 100], [104, 101]]));
run('twoFingers', () => {
  fire('touchstart', [t(100, 100)]);
  fire('touchstart', [t(100, 100), t(200, 200)]);
  fire('touchmove', [t(300, 100), t(200, 200)]);
  fire('touchend', [t(200, 200)], [t(300, 100)]);
  fire('touchend', [], [t(200, 200)]);
});
run('selection', () => {
  fire('touchstart', [t(100, 100)]);
  selection = 'x';
  fire('touchmove', [t(140, 100)]);
  fire('touchend', [], [t(260, 100)]);
});
run('staleSelection', () => { selection = 'old'; swipe([[100, 100], [140, 100], [260, 100]]); });
run('cancelled', () => {
  fire('touchstart', [t(100, 100)]);
  fire('touchmove', [t(200, 100)]);
  fire('touchcancel', []);
  fire('touchend', [], [t(260, 100)]);
});
run('installOnce', () => { install(); swipe([[100, 100], [120, 100], [160, 100]]); });
process.stdout.write(JSON.stringify(out));
''';

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  for (final String dir in (Platform.environment['PATH'] ?? '').split(
    Platform.isWindows ? ';' : ':',
  )) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
