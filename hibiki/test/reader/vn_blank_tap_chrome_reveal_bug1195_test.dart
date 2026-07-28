import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_chrome_floating.dart';

/// BUG-1195：视觉小说（VN）模式点屏幕只会翻页，控制栏（菜单）永远唤不出来。
///
/// 根因：VN 是唯一把「点空白」绑成翻页的 view-mode，旧实现在 JS 的 `_gestureEnd`
/// 里直接 `window.hoshiReader.paginate('forward')` 并 return，抢在查词 /
/// `onTapEmpty` 之前。而 `onTapEmpty` 是触屏**唯一**能唤出控制栏的通道；
/// `tap_empty_hide_chrome` 默认 true ⇒ 底栏悬浮、几秒后自动收起 ⇒ VN 下底栏一收起
/// 就再也叫不回来（点文字=查词、点空白=翻页，没有第三条路）。
///
/// 修复：JS 只回传「这是一次 VN 空白点」，翻页还是唤栏由 Dart（chrome 可见性的
/// 状态拥有者）判定，语义是**唤出优先**——控制栏不可见时先叫出来，可见时才推进。
///
/// 两层锁：① 纯谓词 [readerVnBlankTapAction] 的三态真值表（headless 可真跑）；
/// ② 源码守卫，钉死 JS→Dart 的分派结构不回退成「JS 自己 paginate」。
void main() {
  group('BUG-1195 VN blank-tap action truth table', () {
    test('挤压态底栏被收起 → 先展开底栏，不翻页', () {
      expect(
        readerVnBlankTapAction(
          chromeExpanded: false,
          bottomBarFloating: false,
          transientVisible: false,
        ),
        ReaderVnBlankTapAction.expandChrome,
      );
      // 悬浮标志此时不影响结论：_showChrome==false 底栏根本不画。
      expect(
        readerVnBlankTapAction(
          chromeExpanded: false,
          bottomBarFloating: true,
          transientVisible: true,
        ),
        ReaderVnBlankTapAction.expandChrome,
      );
    });

    test('悬浮态底栏已自动收起 → 先唤出，不翻页（本 bug 的原始失败路径）', () {
      expect(
        readerVnBlankTapAction(
          chromeExpanded: true,
          bottomBarFloating: true,
          transientVisible: false,
        ),
        ReaderVnBlankTapAction.revealFloatingChrome,
      );
    });

    test('底栏此刻可见 → 才翻页（悬浮唤出中 / 挤压常驻两种可见都算）', () {
      expect(
        readerVnBlankTapAction(
          chromeExpanded: true,
          bottomBarFloating: true,
          transientVisible: true,
        ),
        ReaderVnBlankTapAction.advance,
      );
      expect(
        readerVnBlankTapAction(
          chromeExpanded: true,
          bottomBarFloating: false,
          transientVisible: false,
        ),
        ReaderVnBlankTapAction.advance,
      );
    });

    test('三态与 bottomBarVisible 逐格对齐：不可见必唤栏、可见必翻页', () {
      for (final bool expanded in <bool>[false, true]) {
        for (final bool floating in <bool>[false, true]) {
          for (final bool transient in <bool>[false, true]) {
            final bool visible = bottomBarVisible(
              // 能点到 VN 屏就说明内容已就绪，故恒真。
              hasEverLoaded: true,
              chromeExpanded: expanded,
              floating: floating,
              transientVisible: transient,
            );
            final ReaderVnBlankTapAction action = readerVnBlankTapAction(
              chromeExpanded: expanded,
              bottomBarFloating: floating,
              transientVisible: transient,
            );
            expect(
              action == ReaderVnBlankTapAction.advance,
              visible,
              reason: 'expanded=$expanded floating=$floating '
                  'transient=$transient：底栏可见性与「是否翻页」必须同真同假，'
                  '否则又会出现「底栏叫不出来」或「底栏已在却不翻页」',
            );
          }
        }
      }
    });
  });

  group('BUG-1195 dispatch structure guard', () {
    late String webview;
    late String chrome;
    late String page;

    setUpAll(() {
      webview = File(
        'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
      ).readAsStringSync();
      chrome = File(
        'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
      ).readAsStringSync();
      page = File(
        'lib/src/pages/implementations/reader_hibiki_page.dart',
      ).readAsStringSync();
    });

    test('JS 空白点只回传事实，绝不自己 paginate', () {
      expect(
        webview.contains("callHandler('onVnBlankTap')"),
        isTrue,
        reason: 'VN blank-tap 必须回传 Dart 决策',
      );
      // 注释里会引用旧写法（说明为什么不能那么写），只看真代码。
      expect(
        _stripLineComments(webview)
            .contains("window.hoshiReader.paginate('forward')"),
        isFalse,
        reason: 'BUG-1195：JS 直接 paginate 会吞掉唯一能唤出控制栏的手势；'
            '翻页必须走 Dart 的 _paginate（同时才有跨章 / 节流 / caret 重锚）',
      );
    });

    test('Dart 侧注册了 onVnBlankTap handler 并接到唯一决策点', () {
      expect(
        webview.contains("handlerName: 'onVnBlankTap'"),
        isTrue,
        reason: 'handler 未注册则 VN 空白点变成完全无响应（比原 bug 更糟）',
      );
      expect(
        webview.contains('_handleVnBlankTap()'),
        isTrue,
        reason: 'handler 必须调用唯一决策点 _handleVnBlankTap',
      );
    });

    test('_handleVnBlankTap 三条分支齐全，且翻页走 _paginate 唯一入口', () {
      final int start = chrome.indexOf('void _handleVnBlankTap()');
      expect(start, greaterThanOrEqualTo(0),
          reason: '_handleVnBlankTap must exist in chrome.part.dart');
      final int end =
          chrome.indexOf('Future<void> _reanchorContinuousForUiScale', start);
      expect(end, greaterThan(start));
      final String body = chrome.substring(start, end);

      expect(
        body.contains('readerVnBlankTapAction('),
        isTrue,
        reason: '分派必须走纯谓词，不得在页里重写一套内联条件',
      );
      expect(
        body.contains('ReaderVnBlankTapAction.expandChrome') &&
            body.contains('ReaderVnBlankTapAction.revealFloatingChrome') &&
            body.contains('ReaderVnBlankTapAction.advance'),
        isTrue,
        reason: '三态分支必须都落地，漏任一态就会重现「菜单叫不出来」',
      );
      expect(
        body.contains('_paginate(ReaderNavigationDirection.forward)'),
        isTrue,
        reason: '翻页必须复用 _paginate（跨章 / 节流 / caret 重锚的唯一入口）',
      );
      expect(
        body.contains('_toggleChrome()') &&
            body.contains('_handleFloatingChromeReveal()'),
        isTrue,
        reason: '挤压态展开与悬浮态唤出各自复用既有状态机，不新造第三套',
      );
    });

    test('底栏可见性收敛到 bottomBarVisible 单一真相源', () {
      expect(
        page.contains('bool get _bottomBarShouldPaint => bottomBarVisible('),
        isTrue,
        reason: 'BUG-1195：_bottomBarShouldPaint 与 readerVnBlankTapAction 必须'
            '读同一套可见性规则，否则两边漂开又会出现「判为可见却没画出来」',
      );
    });
  });
}

/// 去掉行注释（Dart 与注入 JS 同用 `//`），使守卫只看真代码——注释里正当地引用了
/// 被修掉的旧写法。
String _stripLineComments(String source) {
  return source.split('\n').map((String line) {
    final int idx = line.indexOf('//');
    return idx >= 0 ? line.substring(0, idx) : line;
  }).join('\n');
}
