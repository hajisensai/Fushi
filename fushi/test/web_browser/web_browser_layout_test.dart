import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/pages/implementations/web_browser/web_browser_layout.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_menus.dart';
import 'package:fushi/src/web_browser/web_browser_prefs.dart';

void main() {
  group('版式只看窗口尺寸与标签页样式', () {
    test('窄窗口恒为底栏，不受标签页样式影响', () {
      for (final WebBrowserTabStyle style in WebBrowserTabStyle.values) {
        expect(
          webBrowserShellLayout(size: const Size(390, 844), style: style),
          WebBrowserShellLayout.bottomBar,
        );
        expect(
          webBrowserShellLayout(size: const Size(599, 900), style: style),
          WebBrowserShellLayout.bottomBar,
        );
      }
    });

    test('宽窗口按标签页样式：侧边栏 / 顶部标签栏', () {
      expect(
        webBrowserShellLayout(
          size: const Size(1280, 720),
          style: WebBrowserTabStyle.sidebar,
        ),
        WebBrowserShellLayout.sidebar,
      );
      expect(
        webBrowserShellLayout(
          size: const Size(844, 390),
          style: WebBrowserTabStyle.topStrip,
        ),
        WebBrowserShellLayout.topStrip,
      );
    });

    test('标签页样式默认侧边栏（用户拍板）', () {
      expect(WebBrowserTabStyle.fromName(null), WebBrowserTabStyle.sidebar);
      expect(WebBrowserTabStyle.fromName('bogus'), WebBrowserTabStyle.sidebar);
      expect(kWebBrowserTabStyleDefault, WebBrowserTabStyle.sidebar);
    });

    test('侧边栏：桌面挤开网页，手机横屏 / 窄平板盖在网页上', () {
      expect(webBrowserSidebarOverlays(size: const Size(1280, 720)), isFalse);
      expect(webBrowserSidebarOverlays(size: const Size(844, 390)), isTrue);
      expect(webBrowserSidebarOverlays(size: const Size(800, 1280)), isTrue);
    });

    test('滚动收起：竖屏底栏与矮窗口可收，桌面不收', () {
      expect(
        webBrowserToolbarCollapsible(
          layout: WebBrowserShellLayout.bottomBar,
          size: const Size(390, 844),
        ),
        isTrue,
      );
      expect(
        webBrowserToolbarCollapsible(
          layout: WebBrowserShellLayout.topStrip,
          size: const Size(844, 390),
        ),
        isTrue,
      );
      expect(
        webBrowserToolbarCollapsible(
          layout: WebBrowserShellLayout.sidebar,
          size: const Size(1280, 720),
        ),
        isFalse,
      );
    });
  });

  group('滚动收起状态机', () {
    test('往下累计过阈值收起，往上累计过阈值展开，回到顶部恒展开', () {
      WebBrowserCollapseState s = const WebBrowserCollapseState();
      s = s.onScroll(y: 10, dy: 10);
      expect(s.collapsed, isFalse, reason: '单次抖动不翻转');
      s = s.onScroll(y: 40, dy: 30);
      expect(s.collapsed, isTrue);
      s = s.onScroll(y: 30, dy: -10);
      expect(s.collapsed, isTrue);
      s = s.onScroll(y: 0 + 5, dy: -20);
      expect(s.collapsed, isFalse);
      s = s.onScroll(y: 100, dy: 50);
      expect(s.collapsed, isTrue);
      s = s.onScroll(y: 0, dy: -1);
      expect(s.collapsed, isFalse, reason: '滚到顶部恒展开');
    });

    test('换方向时累计量清零', () {
      WebBrowserCollapseState s = const WebBrowserCollapseState();
      s = s.onScroll(y: 50, dy: 20);
      s = s.onScroll(y: 45, dy: -5);
      s = s.onScroll(y: 60, dy: 15);
      expect(s.collapsed, isFalse, reason: '20 被反向清零，15 不过阈值');
    });
  });

  test('返回的优先级：查词 → 临时层 → 网页历史 → 关子标签页 → 离开', () {
    expect(
      webBrowserBackStep(
        lookupOpen: true,
        canGoBack: true,
        overlayOpen: true,
        openedByOtherTab: true,
      ),
      WebBrowserBackStep.closeLookup,
    );
    expect(
      webBrowserBackStep(lookupOpen: false, canGoBack: true, overlayOpen: true),
      WebBrowserBackStep.dismissOverlay,
    );
    expect(
      webBrowserBackStep(
        lookupOpen: false,
        canGoBack: true,
        openedByOtherTab: true,
      ),
      WebBrowserBackStep.webHistoryBack,
    );
    expect(
      webBrowserBackStep(
        lookupOpen: false,
        canGoBack: false,
        openedByOtherTab: true,
      ),
      WebBrowserBackStep.closeTab,
    );
    expect(
      webBrowserBackStep(lookupOpen: false, canGoBack: false),
      WebBrowserBackStep.leavePage,
    );
  });

  test('地址拆成前缀 / 域名 / 其余', () {
    final ({String prefix, String host, String rest}) p =
        webBrowserAddressParts(
          Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        );
    expect(p.prefix, 'https://');
    expect(p.host, 'www.youtube.com');
    expect(p.rest, '/watch?v=dQw4w9WgXcQ');
  });

  test('文字大小步进夹在 50..300', () {
    expect(webBrowserStepTextZoom(100, 1), 110);
    expect(webBrowserStepTextZoom(50, -1), 50);
    expect(webBrowserStepTextZoom(300, 1), 300);
  });
}
