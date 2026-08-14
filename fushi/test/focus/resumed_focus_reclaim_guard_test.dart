// BUG-1619 守卫：`AppLifecycleState.resumed` 是**进程级**信号，桌面多顶层窗口
// （剪贴板查词面板 / app 外查词覆盖窗 / 悬浮窗）夺焦时同样会触发它。此时若把
// 键盘焦点收回主窗，Flutter 引擎会对 FlutterView 调 SetFocus，Win32 语义下
// 连带激活主窗 —— 用户正在玩的游戏 / 正在看的浏览器被主界面盖住。
//
// 三层守：
// ① 判据本身（窗口级，不是进程级）；
// ② 共享回收入口 PageFocusOwnership 在 appResumed 上真的过了判据；
// ③ 源码扫描：resumed 分支不得绕过判据裸调 requestFocus（首页走的是自己那条
//    手写路径，不经 PageFocusOwnership，最容易漏）。
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    DesktopForegroundGuard.debugMainWindowForeground = null;
  });

  group('主窗前台判据', () {
    test('Dart 侧类名常量与 runner 注册的窗口类名逐字符一致', () {
      final File source = File('windows/runner/win32_window.cpp');
      expect(source.existsSync(), isTrue,
          reason: '守卫要读 ${source.path}，路径变了就更新这里');
      final String text = source.readAsStringSync();
      expect(
        text.contains('L"$kFushiMainWindowClassName"'),
        isTrue,
        reason: 'win32_window.cpp 改了主窗类名，'
            'kFushiMainWindowClassName 必须同步——否则判据永远为假，'
            '主窗回到前台后再也收不回键盘焦点',
      );
    });

    test('测试注入生效（判据可被守卫测试驱动）', () {
      DesktopForegroundGuard.debugMainWindowForeground = false;
      expect(DesktopForegroundGuard.isMainWindowForeground(), isFalse);
      DesktopForegroundGuard.debugMainWindowForeground = true;
      expect(DesktopForegroundGuard.isMainWindowForeground(), isTrue);
    });
  });

  group('PageFocusOwnership.reclaim(appResumed)', () {
    late FocusNode node;

    setUp(() => node = FocusNode());
    tearDown(() => node.dispose());

    test('主窗不在前台时不回收（辅助窗夺焦触发的 resumed）', () {
      DesktopForegroundGuard.debugMainWindowForeground = false;
      final PageFocusOwnership ownership = PageFocusOwnership(
        node: node,
        canOwn: (FocusReclaimCause cause) => true,
      );
      expect(ownership.reclaim(FocusReclaimCause.appResumed), isFalse);
    });

    test('主窗在前台时照常回收（Alt+Tab 真的切回主窗）', () {
      DesktopForegroundGuard.debugMainWindowForeground = true;
      final PageFocusOwnership ownership = PageFocusOwnership(
        node: node,
        canOwn: (FocusReclaimCause cause) => true,
      );
      expect(ownership.reclaim(FocusReclaimCause.appResumed), isTrue);
    });

    test('判据只管 appResumed，其它 cause 一律不受影响', () {
      DesktopForegroundGuard.debugMainWindowForeground = false;
      final PageFocusOwnership ownership = PageFocusOwnership(
        node: node,
        canOwn: (FocusReclaimCause cause) => true,
      );
      for (final FocusReclaimCause cause in FocusReclaimCause.values) {
        if (cause == FocusReclaimCause.appResumed) continue;
        expect(ownership.reclaim(cause), isTrue,
            reason: '$cause 是页面内部时序，与窗口前台归属无关，不该被这条判据拦下');
      }
    });
  });

  group('源码扫描：resumed 分支不得绕过判据', () {
    test('首页 resumed 回收路径带主窗前台判据', () {
      final File source = File('lib/src/pages/implementations/home_page.dart');
      expect(source.existsSync(), isTrue);
      final String text = source.readAsStringSync();
      final int reclaimAt = text.indexOf('void _reclaimHomeFocusIfOwned()');
      expect(reclaimAt, greaterThan(0), reason: '首页回收方法改名了，同步更新本守卫');
      final int end = text.indexOf('\n  }', reclaimAt);
      final String body = text.substring(reclaimAt, end);
      expect(
        body.contains('isMainWindowForeground'),
        isTrue,
        reason: '首页 resumed 回收必须先确认主窗自己在前台；'
            '否则剪贴板面板夺焦就会把主界面拽到用户面前（BUG-1619）',
      );
    });
  });
}
