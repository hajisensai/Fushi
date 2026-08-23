// 2026-08-23 弹窗观感（Niratan 对齐）— 伴随投影窗源码扫描守卫。
//
// 背景：查词浮窗/剪贴板面板是 windowed WebView2 + SetWindowRgn 裁形的窗口，
// 拿不到 DWM 系统投影；投影由伴随的 layered 影子窗（global_lookup_shadow.cpp）
// 自绘。这里钉住四条会静默退化的结构不变式（无法用 flutter test 驱动真窗口，
// 故源码扫描是能落地的最强层；窗口真观感由 Windows 构建 + 真机复测兜底）：
// 1. 影子窗必须点击穿透 + 不可激活 + 无任务栏项（WS_EX_TRANSPARENT |
//    WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_LAYERED）——少任何一个都会
//    出现「影子吃点击/抢焦点/任务栏幽灵项」级别的回归；
// 2. WM_WINDOWPOSCHANGED 漏斗必须调 SyncShadow 且把消息交回 DefWindowProc
//    （WM_SIZE/WM_MOVE 由它派生，吞掉=窗口一动内容就不跟）；
// 3. Reveal/RevealStack 在 revealed_ 置位后必须显式补 SyncShadow——
//    SetWindowPos 触发漏斗时 revealed_ 还是 false，不补首帧无影；
// 4. 投影位图必须对卡矩形内部 punch-out（面板整窗 LWA_ALPHA 半透明时，
//    不打洞黑影会从卡片底下透出来压暗内容）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late final String shadowCpp;
  late final String windowCpp;
  late final String cmake;

  setUpAll(() {
    final File shadow = File('windows/runner/global_lookup_shadow.cpp');
    expect(shadow.existsSync(), isTrue,
        reason: 'global_lookup_shadow.cpp 应存在: ${shadow.path}');
    shadowCpp = shadow.readAsStringSync();
    final File window = File('windows/runner/global_lookup_window.cpp');
    expect(window.existsSync(), isTrue);
    windowCpp = window.readAsStringSync();
    cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
  });

  group('伴随投影窗（global_lookup_shadow）结构不变式', () {
    test('影子窗 ex-style：layered + 点击穿透 + 不可激活 + 无任务栏项', () {
      expect(
        shadowCpp.contains(
            'WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | '
            'WS_EX_TOOLWINDOW'),
        isTrue,
        reason: '缺 TRANSPARENT=影子环吃掉底下应用的点击（BUG-749 同型回归）；'
            '缺 NOACTIVATE=抢焦点；缺 TOOLWINDOW=任务栏幽灵项；'
            '缺 LAYERED=UpdateLayeredWindow 直接失效',
      );
    });

    test('WM_WINDOWPOSCHANGED 漏斗：SyncShadow + 交回 DefWindowProc', () {
      final int caseAt = windowCpp.indexOf('case WM_WINDOWPOSCHANGED:');
      expect(caseAt, greaterThanOrEqualTo(0),
          reason: '投影同步单漏斗必须挂在 WM_WINDOWPOSCHANGED');
      final int nextCase = windowCpp.indexOf('case ', caseAt + 10);
      final String block = windowCpp.substring(caseAt, nextCase);
      expect(block, contains('SyncShadow();'),
          reason: '漏斗内必须同步投影（移动/缩放/显隐/Z 序变化全经此处）');
      expect(block, contains('return DefWindowProc('),
          reason: 'WM_SIZE/WM_MOVE 由 DefWindowProc 从本消息派生，'
              '吞掉后 WebView bounds/region 全不再跟随窗口');
    });

    test('Reveal 与 RevealStack 在标志置位后显式补 SyncShadow（首帧有影）', () {
      for (final String fn in <String>[
        'GlobalLookupWindow::Reveal(',
        'GlobalLookupWindow::RevealStack(',
      ]) {
        final int fnAt = windowCpp.indexOf('void $fn');
        expect(fnAt, greaterThanOrEqualTo(0), reason: '$fn 应存在');
        final int fnEnd = windowCpp.indexOf('\nvoid GlobalLookupWindow::',
            fnAt + 1);
        final String body = windowCpp.substring(
            fnAt, fnEnd > 0 ? fnEnd : windowCpp.length);
        final int revealedAt = body.indexOf('revealed_ = true;');
        final int syncAt = body.lastIndexOf('SyncShadow();');
        expect(revealedAt, greaterThanOrEqualTo(0),
            reason: '$fn 应置位 revealed_');
        expect(syncAt, greaterThan(revealedAt),
            reason: '$fn 必须在 revealed_ 置位之后补 SyncShadow——SetWindowPos '
                '触发漏斗那一刻 revealed_ 还是 false，不补则首帧无影');
      }
    });

    test('投影位图对卡矩形内部 punch-out', () {
      expect(shadowCpp, contains('punch-out'),
          reason: '卡内 alpha 必须清零：面板整窗半透明时黑影会从卡片底下透出');
      // punch 循环的实际形状：卡内 (d <= 0) 像素置 0。
      expect(shadowCpp.contains('row[px] = 0;'), isTrue,
          reason: 'punch-out 循环必须真的清像素，不是只留注释');
    });

    test('CMakeLists 把 global_lookup_shadow.cpp 编入 runner', () {
      expect(cmake, contains('"global_lookup_shadow.cpp"'),
          reason: '源文件不进 add_executable 就是悄悄不生效');
    });
  });
}
