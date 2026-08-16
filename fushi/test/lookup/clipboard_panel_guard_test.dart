// spec 2026-07-10 — 剪贴板面板（host 面板模式 + 半透明变量 + 句子条可点）的
// 源码接线守卫。行为级断言在 node harness（global_lookup_host_test.mjs P1-P3）；
// 这里锁跨文件契约：变量名 / payload 键 / CSS 默认值——任何一端单方面改名都会
// 让面板静默失效，故三端（Dart render / host JS / popup.css）互相钉死。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

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
      // 窗口不再是 `+ 200` 定长切片：注册函数体由花括号配对给出，两个创建点各自
      // 由**圆括号配对**给出。owner 实参是最后一个，前面的 IntFromValue(...) 多写
      // 一行、或参数换行重排，旧窗口就会把 `nullptr` 挤出去（要求型断言凭空变红）
      // 或把下一条语句读进来当本调用的实参（`GetHandle()` 禁止型断言误报）。
      // methodBody/enclosingCall 在 C++ 上同样适用：两者是花括号 / 圆括号配对 +
      // 词法掩码，不依赖 Dart 语法（本文件两个 .cpp 均无 R"(...)" 原始串）。
      final String body =
          methodBody(fw, 'void FlutterWindow::RegisterClipboardPanelChannel()');
      final String masked = maskComments(body);
      const String prewarmAnchor = 'clipboard_panel_window_->PrewarmWebView(';
      const String showAnchor = 'clipboard_panel_window_->ShowAt(';
      final int prewarm = masked.indexOf(prewarmAnchor);
      final int showAt = masked.indexOf(showAnchor);
      expect(prewarm, isNonNegative);
      expect(showAt, isNonNegative);
      // 下标落在左括号之后 = 落在实参里，enclosingCall 取到的就是这一次调用。
      final String prewarmCall =
          enclosingCall(body, prewarm + prewarmAnchor.length).text;
      final String showAtCall =
          enclosingCall(body, showAt + showAnchor.length).text;
      expect(prewarmCall.contains('nullptr'), isTrue,
          reason: '面板 prewarm 不得把主窗 HWND 作 owner');
      expect(showAtCall.contains('nullptr'), isTrue,
          reason: '面板 showAt 不得把主窗 HWND 作 owner');
      expect(prewarmCall.contains('GetHandle()'), isFalse);
      expect(showAtCall.contains('GetHandle()'), isFalse);
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
      // 旧的 `fn + 700` 定长窗口已经滑进下一个方法（SetTopmost 全体才 425 字），
      // 改用花括号配对取整个方法体，边界由源码结构给出。
      // 断言走 containsCodeLine：SetTopmost 的**注释**里也写着 SWP_NOOWNERZORDER，
      // 裸 contains 会被注释喂绿——把标志从 SetWindowPos 参数里删掉照样通过。
      final String body =
          methodBody(cpp, 'void GlobalLookupWindow::SetTopmost(');
      expect(containsCodeLine(body, 'SWP_NOOWNERZORDER'), isTrue);
    });
  });

  group('半透明卡背景（--fushi-card-bg-* 三端契约）', () {
    test('注入端产出 rgb 三元组变量', () {
      expect(injectionDart.contains('--fushi-card-bg-rgb'), isTrue);
      // 三元组值经共享真源 popup_theme_css.dart（cssRgbTriplet →
      // buildPopupThemeCssVars）派生，注入端不再本地手抄格式化。
      expect(injectionDart.contains('buildPopupThemeCssVars('), isTrue);
    });

    test('render 端恒注入 alpha 变量（1.0 也写——防调回 100% 后旧值残留）', () {
      expect(renderDart.contains('--fushi-card-bg-alpha'), isTrue);
      expect(renderDart.contains('cardBgAlpha.toStringAsFixed(2)'), isTrue);
      expect(renderDart.contains('cardBgAlpha < 1.0'), isFalse,
          reason: '条件注入会让常驻面板从 0.85 调回 1.0 后停在半透明（审查 #4）');
    });

    test('popup.css 卡背景消费两变量且默认 alpha=1（零回归）', () {
      expect(popupCss.contains('var(--fushi-card-bg-rgb'), isTrue);
      expect(popupCss.contains('var(--fushi-card-bg-alpha, 1)'), isTrue);
    });
  });

  group('句子横幅逐字可点', () {
    final int fn = popupJs.indexOf('function buildGlobalLookupSentenceBanner');
    final String bannerBody = fn < 0
        ? ''
        : popupJs.substring(
            fn, popupJs.indexOf('function prependSentenceBanner'));

    test('popup.js 逐字 span + 后缀查词', () {
      expect(fn, isNonNegative);
      expect(bannerBody.contains('global-lookup-sentence-char'), isTrue);
      expect(bannerBody.contains('chars.slice(i).join('), isTrue,
          reason: '点字=该字到句尾后缀查词（同 in-app 剪贴板面板语义）');
    });

    test(
        '真机第 4 轮：面板 root 点字=panelSentenceLookup 原地更新，'
        '瞬态窗保持 onLinkClick 嵌套', () {
      expect(bannerBody.contains('__globalLookupPanelRoot'), isTrue,
          reason: '面板/瞬态分流判据由 settingsJs 注入（render 侧 panelRoot）');
      expect(bannerBody.contains("'panelSentenceLookup', suffix, i"), isTrue,
          reason: '面板：后缀 + 码点下标 → Dart 换根结果=底部原地变动');
      expect(
          bannerBody.contains("'onLinkClick'") &&
              bannerBody.contains('getBoundingClientRect'),
          isTrue,
          reason: '瞬态窗路径保留：点字=onLinkClick 嵌套子卡（零回归）');
      expect(bannerBody.contains('global-lookup-sentence-hit'), isTrue,
          reason: '引擎 bestLength 整词高亮=「按正常的断词」');
    });

    test('popup.css：hover 格子只留瞬态窗，面板有整词高亮 + 正文字号', () {
      expect(
        popupCss.contains(
            '.global-lookup-sentence:not(.global-lookup-sentence-panel)'),
        isTrue,
        reason: '逐字 hover 框在面板里=「按照字来划分」，必须作用域隔离',
      );
      expect(popupCss.contains('.global-lookup-sentence-hit'), isTrue);
      // 窗口=这条 CSS 规则块本身（花括号配对），不再是 `+ 200` 定长窗口。规则体
      // 只有 92 字，旧窗口已经滑过后面两条规则：从本规则里删掉 font-size 后，
      // 只要邻居规则里出现同一声明就会被喂成假绿。
      final String panelRule =
          methodBody(popupCss, '.global-lookup-sentence-panel {');
      expect(
        panelRule.contains('font-size: 1em;'),
        isTrue,
        reason: '真机第 4 轮：选词区文字与底下词条正文一样大，不得回 0.85em',
      );
    });

    test('句子条=普通搜索框外观（真机反馈：左侧强调竖条已删，不得复活）', () {
      expect(
        popupCss.contains('border-left: 3px solid var(--primary-color'),
        isFalse,
        reason: '左侧 3px 竖条在面板里像「搜索栏左边一块莫名深色」',
      );
    });
  });

  group('真机第 4 轮：选词区/释义分流 + 面板可激活', () {
    final String controllerDart =
        File('lib/src/lookup/clipboard_panel_controller.dart')
            .readAsStringSync();
    final String cpp =
        File('windows/runner/global_lookup_window.cpp').readAsStringSync();
    final String fw =
        File('windows/runner/flutter_window.cpp').readAsStringSync();

    test('BUG-1689：可激活面板 Reveal 时接管本线程活动窗口', () {
      // 用户 2026-08-16：在游戏/浏览器里点一下剪贴板查词面板，Fushi 主界面就浮到
      // 正在用的窗口上面（主窗非最小化时可见）。根因不在本仓代码：点击「所属进程
      // 不在前台」的可激活窗口时，Windows 先把该线程的**活动窗口**（= runner 主窗）
      // 前台化并抬升 Z 序，再把激活交给被点的窗口。把活动窗口换成面板自己，被抬升
      // 的就是面板（它本来就该在最上），主窗不再被牵动。
      //
      // 断言走 containsCodeLine：上面这段根因注释里同样出现 SetActiveWindow。
      expect(containsCodeLine(cpp, 'SetActiveWindow(hwnd_);'), isTrue,
          reason: '面板不接管本线程活动窗口 -> 点面板会把主窗抬到用户窗口之上');
      // 必须在 Reveal 的可激活分支里：无条件调用会让带 WS_EX_NOACTIVATE 的瞬态卡 /
      // gal 卡窗也去抢本线程活动窗口，那是它们**刻意**不参与的（见 OverlayCreateExStyle）。
      final int revealAt = cpp.indexOf('void GlobalLookupWindow::Reveal(');
      expect(revealAt, greaterThan(0));
      final String revealBody = cpp.substring(
          revealAt, cpp.indexOf('void GlobalLookupWindow::RevealStack('));
      expect(containsCodeLine(revealBody, 'if (activatable_) {'), isTrue,
          reason: 'SetActiveWindow 必须被 activatable_ 门住');
      expect(containsCodeLine(revealBody, 'SetActiveWindow(hwnd_);'), isTrue,
          reason: '接管活动窗口必须发生在 Reveal（面板真正上屏那一刻）');
    });

    test('render 仅面板 root 注入 panelRoot 标记（cascade settingsJs 恒不带）', () {
      expect(
          renderDart
              .contains("layoutMode == 'panel' && p.frame.parentIndex < 0"),
          isTrue);
      expect(renderDart.contains('__globalLookupPanelRoot = true'), isTrue);
      expect(renderDart.contains('__globalLookupSentenceHit'), isTrue);
    });

    test('controller：panelSentenceLookup 换根，onLinkClick 走外部瞬态窗', () {
      expect(controllerDart.contains("case 'panelSentenceLookup':"), isTrue);
      expect(controllerDart.contains('_lookupFromBanner'), isTrue);
      expect(controllerDart.contains('GlobalLookupController.instance'), isTrue,
          reason: '释义点击=独立瞬态覆盖窗（可越出面板 HWND，点外即关）');
      expect(
          controllerDart.contains('anchorScreenRect: anchorScreenRect'), isTrue,
          reason: '真机第 5 轮：外部弹窗锚定被点文字（面板矩形折算屏幕逻辑 px）');
      expect(
          controllerDart.contains('anchorRect?.shift(Offset(_panelRect.left'),
          isTrue,
          reason: 'host 面板窗内 CSS px + 面板原点 = 屏幕逻辑 px，单位链守卫');
      expect(controllerDart.contains('await _lookupNested(query, anchorRect)'),
          isTrue,
          reason: '瞬态窗不可用时回退面板内嵌套卡，点击绝不静默丢失');
    });

    test('真机第 5 轮：释义点击高亮 + 文字锚点 + 视口感知列数收敛', () {
      final String glcDart =
          File('lib/src/lookup/global_lookup_controller.dart')
              .readAsStringSync();
      // ① 被点释义文字高亮：helper 定义 + 4 个 onLinkClick 发射点全部标记。
      expect(
        'markGlobalLookupExtHit('.allMatches(popupJs).length,
        greaterThanOrEqualTo(5),
        reason: '定义 + 释义链接/汉字标签/见出语/汉字卡 4 个发射点',
      );
      expect(popupCss.contains('.global-lookup-ext-hit'), isTrue);
      // ② 外部瞬态窗按文字锚点定位（native atCursor:false 用传入点算工作区）。
      expect(glcDart.contains('anchorScreenRect == null'), isTrue);
      expect(glcDart.contains('atCursor: false'), isTrue,
          reason: '有锚点=文字左下定位；无锚点保持 atCursor（热键/悬浮字幕零变化）');
      // ③ 窄视口词典方块重叠：有效列数 = min(设置, 视口装得下)，grid 消费
      //    effective 变量并保留旧值回退链。
      expect(popupJs.contains('updateEffectiveDictColumns'), isTrue);
      expect(popupJs.contains('--dict-columns-effective'), isTrue);
      expect(
        popupCss
            .contains('var(--dict-columns-effective, var(--dict-columns, 1))'),
        isTrue,
        reason: 'TODO-1357「窄屏不硬塞多列」的视口宽度动态版；变量缺席回退原行为',
      );
      expect(popupJs.contains("addEventListener('resize'"), isTrue,
          reason: '面板 resize grip 拖窄后 grid 即时收敛，无需等下次查词');
      // ④ 超窄面板 clamp(160, viewport) 下界>上界 ArgumentError 假死守卫。
      expect(controllerDart.contains('viewportW < 160'), isTrue);
    });

    test('面板窗可激活（点击落焦点，滚轮不穿游戏）；瞬态窗保持 NOACTIVATE', () {
      // 背景逐像素透明重构：activatable_ 分流收进 OverlayCreateExStyle 单一真相源，
      // ShowAt/PrewarmWebView 两个创建点共用它（不再各写一份），比旧的「两处各写、
      // 靠计数守一致」更强。
      expect(
        'activatable_ ? 0 : WS_EX_NOACTIVATE'.allMatches(cpp).length,
        greaterThanOrEqualTo(1),
        reason: 'activatable_ 分流在 OverlayCreateExStyle 里，两创建点共用',
      );
      expect(
        'OverlayCreateExStyle()'.allMatches(cpp).length,
        greaterThanOrEqualTo(3),
        reason: '两个 CreateWindowExW 都调 OverlayCreateExStyle()（+ 定义 = ≥3）',
      );
      final int panelChannel = fw.indexOf('RegisterClipboardPanelChannel() {');
      expect(panelChannel, isNonNegative);
      expect(
        fw.substring(panelChannel).contains('SetActivatable(true)'),
        isTrue,
        reason: '面板实例开激活旋钮（真机第 4 轮：滚轮把底下的游戏滚动）',
      );
      expect(
        '->SetActivatable(true)'.allMatches(fw).length,
        1,
        reason: '只有面板实例可激活；瞬态覆盖窗抢焦点=违反 design §5 保证 3',
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

  // BUG-768 — 面板栏（图钉/关闭）在 document.body、fixed，不继承 shell 的
  // data-theme；旧代码只给 light 主题的深灰字色，暗窗上完全看不见。修复=把 root
  // 主题转写到面板栏 + 常驻 chip 背景 + 暗主题浅色字。三处互钉，任一改回都回归。
  group('面板栏图钉/关闭可见（BUG-768 暗背景不可见）', () {
    test('renderStack 把 root descriptor 主题转写到面板栏 data-theme', () {
      expect(hostJs.contains('panelBar.setAttribute('), isTrue,
          reason: '面板栏必须拿到 data-theme，否则暗主题变种永不命中');
      expect(hostJs.contains('popups[0] && popups[0].theme'), isTrue,
          reason: '主题真值源=root 弹窗 descriptor（render 侧 map[theme]）');
    });

    test('.panel-btn 恒有 chip 背景（用户诉求：给它个背景）', () {
      final int rule = hostJs.indexOf("'#global-lookup-panel-bar .panel-btn{'");
      expect(rule, isNonNegative);
      // 该规则块到 :hover 之间必须含 background（非仅 hover 才出现）。
      final int hover = hostJs.indexOf('.panel-btn:hover', rule);
      expect(hover, isNonNegative);
      expect(
        hostJs.substring(rule, hover).contains('background:'),
        isTrue,
        reason: '常驻 chip 背景=按钮在任意窗底都可见；不能退回只 hover 才有背景',
      );
    });

    test('暗主题面板栏按钮有浅色变种（暗窗不再深灰吃掉）', () {
      expect(
        hostJs.contains(
            '#global-lookup-panel-bar[data-theme="dark"] .panel-btn{'),
        isTrue,
        reason: '暗主题必须覆盖为浅色字 + 浅色 chip，镜像 .global-lookup-close 暗变种',
      );
      expect(hostJs.contains('rgba(235,235,245'), isTrue);
    });
  });
}
