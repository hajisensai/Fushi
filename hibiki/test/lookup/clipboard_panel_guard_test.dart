// spec 2026-07-10 — 剪贴板面板（host 面板模式 + 半透明变量 + 句子条可点）的
// 源码接线守卫。行为级断言在 node harness（global_lookup_host_test.mjs P1-P3）；
// 这里锁跨文件契约：变量名 / payload 键 / CSS 默认值——任何一端单方面改名都会
// 让面板静默失效，故三端（Dart render / host JS / popup.css）互相钉死。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String hostJs =
      File('assets/popup/global_lookup_host.js').readAsStringSync();
  final String popupJs = File('assets/popup/popup.js').readAsStringSync();
  final String popupCss = File('assets/popup/popup.css').readAsStringSync();
  final String renderDart =
      File('lib/src/lookup/global_lookup_render.dart').readAsStringSync();
  final String injectionDart =
      File('lib/src/pages/implementations/popup_settings_injection.dart')
          .readAsStringSync();

  group('host 面板模式（layoutMode 契约）', () {
    test('render 侧仅 panel 模式携带 layoutMode 键（cascade 载荷字节不变）', () {
      expect(renderDart.contains("if (layoutMode == 'panel')"), isTrue);
      expect(renderDart.contains("payloadObj['layoutMode'] = 'panel'"), isTrue);
    });

    test('host 读 payload.layoutMode 且面板短路 measureAndReport', () {
      expect(hostJs.contains('payload.layoutMode'), isTrue);
      expect(hostJs.contains("layoutMode === 'panel'"), isTrue);
      expect(hostJs.contains('ensurePanelBar'), isTrue);
    });

    test('面板点空白不关（onHostPointerDown 面板早退）', () {
      final int fn = hostJs.indexOf('function onHostPointerDown');
      expect(fn, isNonNegative);
      final String body =
          hostJs.substring(fn, hostJs.indexOf('function handleGlobalClick'));
      expect(body.contains("layoutMode === 'panel'"), isTrue,
          reason: '常驻语义：面板内点空白永不 dismissRootWithSlide');
    });
  });

  group('半透明窗底（native 透明链）', () {
    final String cpp =
        File('windows/runner/global_lookup_window.cpp').readAsStringSync();

    test('Win11 acrylic 优先，Win10 accent 回退（spec §6 透明度链）', () {
      expect(cpp.contains('DWMWA_SYSTEMBACKDROP_TYPE'), isTrue);
      expect(cpp.contains('SetWindowCompositionAttribute'), isTrue,
          reason: 'Win10 唯一可行半透明路（未文档化 accent policy）');
      expect(cpp.contains('ApplyWin10AccentBlurBehind(hwnd_)'), isTrue,
          reason: 'Win11 backdrop 失败必须回退 Win10 accent，而不是直接放弃');
    });

    test('Win10 用 BLURBEHIND(3) 而非 ACRYLICBLURBEHIND(4)（拖动 lag 回归）', () {
      expect(cpp.contains('accent.accent_state = 3;'), isTrue,
          reason: 'acrylic accent 自 Win10 1903 有未修复的拖动卡顿，'
              '面板靠 HTCAPTION 拖动摆位会正面命中');
      expect(cpp.contains('accent.accent_state = 4;'), isFalse);
    });
  });

  // 真机反馈修复（2026-07-10）：面板窗必须与主窗解耦、拖动必须真能进模态循环。
  group('面板窗解耦与拖动（真机修复回归钉）', () {
    final String cpp =
        File('windows/runner/global_lookup_window.cpp').readAsStringSync();
    final String fw =
        File('windows/runner/flutter_window.cpp').readAsStringSync();

    test('面板窗无 owner（owned 窗随主窗最小化隐藏 + Z 序连带拉主窗前台）', () {
      final int start = fw.indexOf('RegisterClipboardPanelChannel() {');
      expect(start, isNonNegative);
      final String body = fw.substring(start);
      final int prewarm =
          body.indexOf('clipboard_panel_window_->PrewarmWebView');
      final int showAt = body.indexOf('clipboard_panel_window_->ShowAt');
      expect(prewarm, isNonNegative);
      expect(showAt, isNonNegative);
      expect(body.substring(prewarm, prewarm + 200).contains('nullptr'), isTrue,
          reason: '面板 prewarm 不得把主窗 HWND 作 owner');
      expect(body.substring(showAt, showAt + 200).contains('nullptr'), isTrue,
          reason: '面板 showAt 不得把主窗 HWND 作 owner');
      expect(body.substring(prewarm, prewarm + 200).contains('GetHandle()'),
          isFalse);
      expect(body.substring(showAt, showAt + 200).contains('GetHandle()'),
          isFalse);
    });

    test('拖动经 PostMessage 进模态循环，结束由 WM_EXITSIZEMOVE 报 rect', () {
      expect(cpp.contains('PostMessage(hwnd_, WM_NCLBUTTONDOWN'), isTrue,
          reason: 'SendMessage 在 WebMessageReceived COM 回调栈里同步进模态'
              '循环会挂住 WebView2 派发（真机=拖不动）');
      expect(cpp.contains('SendMessage(hwnd_, WM_NCLBUTTONDOWN'), isFalse);
      expect(cpp.contains('case WM_EXITSIZEMOVE:'), isTrue,
          reason: '模态循环结束的 rect 回报唯一出口');
    });

    test('SetTopmost 带 SWP_NOOWNERZORDER（图钉不得连带主窗 Z 序）', () {
      final int fn = cpp.indexOf('void GlobalLookupWindow::SetTopmost');
      expect(fn, isNonNegative);
      final String body = cpp.substring(fn, fn + 700);
      expect(body.contains('SWP_NOOWNERZORDER'), isTrue);
    });
  });

  group('半透明卡背景（--hibiki-card-bg-* 三端契约）', () {
    test('注入端产出 rgb 三元组变量', () {
      expect(injectionDart.contains('--hibiki-card-bg-rgb'), isTrue);
      expect(injectionDart.contains('_cssRgbTriplet'), isTrue);
    });

    test('render 端恒注入 alpha 变量（1.0 也写——防调回 100% 后旧值残留）', () {
      expect(renderDart.contains('--hibiki-card-bg-alpha'), isTrue);
      expect(renderDart.contains('cardBgAlpha.toStringAsFixed(2)'), isTrue);
      expect(renderDart.contains('cardBgAlpha < 1.0'), isFalse,
          reason: '条件注入会让常驻面板从 0.85 调回 1.0 后停在半透明（审查 #4）');
    });

    test('popup.css 卡背景消费两变量且默认 alpha=1（零回归）', () {
      expect(popupCss.contains('var(--hibiki-card-bg-rgb'), isTrue);
      expect(popupCss.contains('var(--hibiki-card-bg-alpha, 1)'), isTrue);
    });
  });

  group('句子横幅逐字可点', () {
    test('popup.js 逐字 span + 后缀 onLinkClick', () {
      final int fn =
          popupJs.indexOf('function buildGlobalLookupSentenceBanner');
      expect(fn, isNonNegative);
      final String body = popupJs.substring(
          fn, popupJs.indexOf('function prependSentenceBanner'));
      expect(body.contains('global-lookup-sentence-char'), isTrue);
      expect(body.contains('chars.slice(i).join('), isTrue,
          reason: '点字=该字到句尾后缀查词（同 in-app 剪贴板面板语义）');
      expect(body.contains('callHandler(') && body.contains("'onLinkClick'"),
          isTrue,
          reason: '复用现有 onLinkClick 桥（host 重锚定 + 嵌套子卡）');
    });

    test('popup.css 有逐字 hover 样式', () {
      expect(popupCss.contains('.global-lookup-sentence-char'), isTrue);
    });

    test('句子条=普通搜索框外观（真机反馈：左侧强调竖条已删，不得复活）', () {
      expect(
        popupCss.contains('border-left: 3px solid var(--primary-color'),
        isFalse,
        reason: '左侧 3px 竖条在面板里像「搜索栏左边一块莫名深色」',
      );
    });
  });

  group('面板 root 卡无 per-shell ×（真机反馈：与面板栏 × 重复）', () {
    test('host 标记 panel-root 且 CSS 隐藏其关闭钮', () {
      expect(
          hostJs.contains("setAttribute('data-panel-root', 'true')"), isTrue);
      expect(
        hostJs.contains('[data-panel-root="true"] '),
        isTrue,
        reason: 'CSS 规则隐藏 root 卡 ×；嵌套子卡的 × 保留（关子层有用）',
      );
    });
  });
}
