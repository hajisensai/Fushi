import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1857 — 源码接线守卫：查词浮窗拖右下角 grip 期间 root 卡跟随 viewport。
///
/// 行为级断言在 node harness（`global_lookup_host_test.mjs` 的 BUG-1857 段）；
/// 这里只钉 JS 与 C++ 之间的**接线**——它们在 `flutter test` 里没法一起跑：
///   ① grip mousedown 必须在 postToHost('beginWindowResize') 之前武装 live-fit；
///   ② host 必须把 handleWindowResize 挂在 window resize 上（WM_SIZE → put_Bounds
///      → Chromium viewport 变化是唯一驱动源）；
///   ③ native 的 WM_EXITSIZEMOVE 必须在回报 windowMoved 之前调 endLiveResize，
///      让 Dart 的权威重排到达时 host 已不在 live 态；
///   ④ renderStack 自己也解除武装（Dart 重排接管 + 清悬空武装）。
void main() {
  late String host;
  late String window;

  setUpAll(() {
    host = File('assets/popup/global_lookup_host.js').readAsStringSync();
    window = File('windows/runner/global_lookup_window.cpp').readAsStringSync();
  });

  test('① grip mousedown 先武装 live-fit 再进模态循环', () {
    // 先抹掉注释：被注释掉的 `// beginLiveResize();` 不算调用（变异实测抓过这条）。
    final String code = maskComments(host);
    final int grip = code.indexOf('function createResizeGrip() {');
    expect(grip, isNot(-1));
    final int arm = code.indexOf('beginLiveResize();', grip);
    final int post = code.indexOf("postToHost('beginWindowResize', []);", grip);
    expect(arm, isNot(-1), reason: 'grip mousedown 必须调用 beginLiveResize()');
    expect(post, isNot(-1));
    expect(arm < post, isTrue, reason: '武装必须在进模态循环之前');
    // 两者之间不得再有别的 postToHost（武装必须紧贴模态循环入口）。
    final String between = code.substring(arm, post);
    expect(
      between.contains('postToHost('),
      isFalse,
      reason: '武装与进模态循环之间不得插其它 host 消息',
    );
  });

  test('② handleWindowResize 挂在 window resize 上', () {
    expect(
      host.contains("window.addEventListener('resize', handleWindowResize);"),
      isTrue,
      reason: '模态 size 循环里唯一的驱动源是 viewport resize',
    );
    expect(
      host.contains('handleWindowResize: handleWindowResize,'),
      isTrue,
      reason: 'node harness 直接驱动它验证行为',
    );
    expect(
      host.contains('endLiveResize: endLiveResize,'),
      isTrue,
      reason: 'native WM_EXITSIZEMOVE 经 __globalLookupHost.endLiveResize 解除',
    );
  });

  test('③ WM_EXITSIZEMOVE 先 endLiveResize 再回报 windowMoved', () {
    final int exit = window.indexOf('case WM_EXITSIZEMOVE: {');
    expect(exit, isNot(-1));
    final int end = window.indexOf('__globalLookupHost.endLiveResize();', exit);
    final int moved = window.indexOf('"handler\\":\\"windowMoved\\"', exit);
    expect(end, isNot(-1), reason: '松手必须解除 host 的 live-fit');
    expect(moved, isNot(-1));
    expect(end < moved, isTrue, reason: '先解除后回报：Dart 重排到达时 host 必须已不在 live 态');
  });

  test('④ renderStack 自己解除武装', () {
    final String code = maskComments(host);
    final int render = code.indexOf('function renderStack(payload) {');
    expect(render, isNot(-1));
    final int end = code.indexOf('endLiveResize();', render);
    expect(end, isNot(-1));
    expect(
      end - render < 400,
      isTrue,
      reason: 'endLiveResize 必须在 renderStack 开头（Dart 权威 frame 接管前）',
    );
  });
}
