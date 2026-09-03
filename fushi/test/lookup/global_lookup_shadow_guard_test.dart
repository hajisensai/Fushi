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
// 3. shellRects 是 resize 事务预告，不得按旧 HWND 尺寸抢跑一次 SyncShadow；
//    direct 同 bbox 事务可能收不到 WM_WINDOWPOSCHANGED，成功提交后必须显式做
//    一次有 dirty 指纹去重的 SyncShadow；
// 4. Reveal/RevealStack 在 revealed_ 置位后必须显式补 SyncShadow——
//    SetWindowPos 触发漏斗时 revealed_ 还是 false，不补首帧无影；
// 5. 投影位图必须对卡矩形内部 punch-out（面板整窗 LWA_ALPHA 半透明时，
//    不打洞黑影会从卡片底下透出来压暗内容），同时不得再对大卡内部逐像素
//    执行 sqrt/exp。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late final String shadowCpp;
  late final String windowCpp;
  late final String cmake;

  setUpAll(() {
    final File shadow = File('windows/runner/global_lookup_shadow.cpp');
    expect(
      shadow.existsSync(),
      isTrue,
      reason: 'global_lookup_shadow.cpp 应存在: ${shadow.path}',
    );
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
          'WS_EX_TOOLWINDOW',
        ),
        isTrue,
        reason:
            '缺 TRANSPARENT=影子环吃掉底下应用的点击（BUG-749 同型回归）；'
            '缺 NOACTIVATE=抢焦点；缺 TOOLWINDOW=任务栏幽灵项；'
            '缺 LAYERED=UpdateLayeredWindow 直接失效',
      );
    });

    test('WM_WINDOWPOSCHANGED 漏斗：SyncShadow + 交回 DefWindowProc', () {
      final int caseAt = windowCpp.indexOf('case WM_WINDOWPOSCHANGED:');
      expect(
        caseAt,
        greaterThanOrEqualTo(0),
        reason: '投影同步单漏斗必须挂在 WM_WINDOWPOSCHANGED',
      );
      final int nextCase = windowCpp.indexOf('case ', caseAt + 10);
      final String block = windowCpp.substring(caseAt, nextCase);
      expect(
        block,
        contains('SyncShadow();'),
        reason: '漏斗内必须同步投影（移动/缩放/显隐/Z 序变化全经此处）',
      );
      expect(
        block,
        contains('return DefWindowProc('),
        reason:
            'WM_SIZE/WM_MOVE 由 DefWindowProc 从本消息派生，'
            '吞掉后 WebView bounds/region 全不再跟随窗口',
      );
    });

    test('shellRects 以 pending 事务提交 region，matching resize 前投影只 defer', () {
      final int fnAt = windowCpp.indexOf(
        'void GlobalLookupWindow::SetShellRectsFromCsv(',
      );
      expect(fnAt, greaterThanOrEqualTo(0));
      final int fnEnd = windowCpp.indexOf(
        '\nvoid GlobalLookupWindow::',
        fnAt + 1,
      );
      final String body = windowCpp.substring(
        fnAt,
        fnEnd > 0 ? fnEnd : windowCpp.length,
      );
      expect(
        body,
        isNot(contains('ApplyRoundedRegion();')),
        reason: 'pending HRGN 不能在旧 HWND/layer 原点上抢跑裁父卡',
      );
      expect(
        body,
        isNot(contains('SyncShadow();')),
        reason: '此时 HWND 还是旧尺寸；抢跑会画错一次并同步阻塞后续 overlaySize',
      );
      expect(
        body,
        contains('shell_geometry_pending_ = true;'),
        reason:
            'SetWindowRgn 会同步发送 WM_WINDOWPOSCHANGED；必须先置 pending，'
            '让漏斗里的 SyncShadow defer 旧 HWND 栅格',
      );
      final int syncFn = windowCpp.indexOf(
        'void GlobalLookupWindow::SyncShadow()',
      );
      final int syncEnd = windowCpp.indexOf(
        '\nvoid GlobalLookupWindow::',
        syncFn + 1,
      );
      final String syncBody = windowCpp.substring(syncFn, syncEnd);
      expect(
        syncBody,
        contains('shadow_rects = shell_rects_css_'),
        reason: '所有提前漏斗只能跟随当前可见 DOM 的 committed rects',
      );
      expect(
        syncBody,
        isNot(contains('pending_shell_rects_css_')),
        reason: 'pending rects 不得让旧影子在 layer shift 前隐藏或跳位',
      );
      expect(
        syncBody,
        contains('if (shell_geometry_pending_)'),
        reason: 'pending 期间必须保留当前正确影子，不能 Hide 后等两帧再闪回',
      );
      expect(
        syncBody,
        contains('return;'),
        reason: 'matching paint-ready finalize 前不得移动或重栅格旧影子',
      );
      expect(
        syncBody,
        isNot(contains('resizing_ || shell_geometry_pending_')),
        reason: '把 pending 当 defer_repaint 会让 dirty shadow 直接 Hide，造成闪烁',
      );
    });

    test('direct 同 bbox 几何提交也显式刷新投影指纹', () {
      final int fnAt = windowCpp.indexOf(
        'void GlobalLookupWindow::ResizeStackForGal(',
      );
      expect(fnAt, greaterThanOrEqualTo(0));
      final int fnEnd = windowCpp.indexOf('\nnamespace {', fnAt + 1);
      final String body = windowCpp.substring(
        fnAt,
        fnEnd > 0 ? fnEnd : windowCpp.length,
      );
      final int setPosAt = body.indexOf('if (SetWindowPos(');
      final int syncAt = body.indexOf('SyncShadow();', setPosAt);
      final int committedAt = body.indexOf(
        'resized_in_place = true;',
        setPosAt,
      );
      expect(setPosAt, greaterThanOrEqualTo(0));
      expect(
        syncAt,
        greaterThan(setPosAt),
        reason: '相同位置/尺寸的 SetWindowPos 可能不发 WM_WINDOWPOSCHANGED',
      );
      expect(committedAt, greaterThan(setPosAt));
      expect(
        syncAt,
        greaterThan(committedAt),
        reason: 'same-bbox 无 pending 时仍显式同步；pending 时该调用只 defer',
      );
      final int executeAt = body.indexOf('webview_->ExecuteScript(', syncAt);
      expect(executeAt, greaterThan(syncAt));
      expect(
        body.substring(executeAt),
        isNot(contains('FinalizePendingShellGeometry(geometry_epoch);')),
        reason: 'gal 影子/HRGN 等 host double-rAF captureReady 一起最终提交',
      );
    });

    test('direct 回缩保持 WebView viewport 高水位，避免 root Chromium 重排', () {
      final int sizeAt = windowCpp.indexOf('case WM_SIZE:');
      final int sizeEnd = windowCpp.indexOf('case WM_DPICHANGED:', sizeAt);
      expect(sizeAt, greaterThanOrEqualTo(0));
      expect(sizeEnd, greaterThan(sizeAt));
      final String body = windowCpp.substring(sizeAt, sizeEnd);
      expect(
        body,
        contains('direct_process_client_active_ && visible_ && revealed_'),
        reason: '只允许已显示的 gal direct surface 保留 viewport，桌面窗不受影响',
      );
      expect(body, contains('controller_->get_Bounds(&current)'));
      expect(body, contains('rc.right = std::max(rc.right, current.right)'));
      expect(body, contains('rc.bottom = std::max(rc.bottom, current.bottom)'));
      expect(body, contains('controller_->put_Bounds(rc)'));
      expect(body, contains('!EqualRect(&rc, &current)'));
    });

    test('SetWindowRgn 失败仍释放 HRGN（成功才由系统接管）', () {
      expect(
        windowCpp,
        contains('if (SetWindowRgn(hwnd_, union_region, redraw_region) != 0)'),
      );
      expect(
        windowCpp,
        contains('if (SetWindowRgn(hwnd_, region, redraw_region) == 0)'),
      );
      expect(windowCpp, contains('DeleteObject(region);'));
    });

    test('Reveal 与 RevealStack 在标志置位后显式补 SyncShadow（首帧有影）', () {
      for (final String fn in <String>[
        'GlobalLookupWindow::Reveal(',
        'GlobalLookupWindow::RevealStack(',
      ]) {
        final int fnAt = windowCpp.indexOf('void $fn');
        expect(fnAt, greaterThanOrEqualTo(0), reason: '$fn 应存在');
        final int fnEnd = windowCpp.indexOf(
          '\nvoid GlobalLookupWindow::',
          fnAt + 1,
        );
        final String body = windowCpp.substring(
          fnAt,
          fnEnd > 0 ? fnEnd : windowCpp.length,
        );
        final int revealedAt = body.indexOf('revealed_ = true;');
        final int syncAt = body.lastIndexOf('SyncShadow();');
        expect(
          revealedAt,
          greaterThanOrEqualTo(0),
          reason: '$fn 应置位 revealed_',
        );
        expect(
          syncAt,
          greaterThan(revealedAt),
          reason:
              '$fn 必须在 revealed_ 置位之后补 SyncShadow——SetWindowPos '
              '触发漏斗那一刻 revealed_ 还是 false，不补则首帧无影',
        );
      }
    });

    test('投影只栅格外围带，并按扫描线 punch-out 卡内', () {
      expect(
        shadowCpp,
        contains('punch-out'),
        reason: '卡内 alpha 必须清零：面板整窗半透明时黑影会从卡片底下透出',
      );
      expect(
        shadowCpp,
        contains('RoundedRectInteriorSpan('),
        reason: '每条扫描线应一次求出圆角卡内部连续区间',
      );
      expect(
        shadowCpp,
        contains('paint_range(x0, std::min(x1, inside_x0));'),
        reason: '阴影热循环只能扫描卡片左侧/圆角外围带',
      );
      expect(
        shadowCpp,
        contains('paint_range(std::max(x0, inside_x1), x1);'),
        reason: '阴影热循环只能扫描卡片右侧/圆角外围带',
      );
      expect(
        shadowCpp,
        contains('std::fill(row + clear_x0, row + clear_x1, 0u);'),
        reason: 'punch-out 应连续清零卡内扫描线，不能逐像素重复算距离',
      );
      expect(
        shadowCpp,
        isNot(contains('row[px] = 0;')),
        reason: '逐像素 punch-out 会把大卡重新退化成数百万次 sqrt/branch',
      );
    });

    test('CMakeLists 把 global_lookup_shadow.cpp 编入 runner', () {
      expect(
        cmake,
        contains('"global_lookup_shadow.cpp"'),
        reason: '源文件不进 add_executable 就是悄悄不生效',
      );
    });
  });
}
