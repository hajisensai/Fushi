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
/// 状态拥有者）判定。语义是**悬浮态下同一下既翻页又唤栏**——不是「唤出优先、可见才
/// 翻页」：那一版慢读的人每屏要点两下（底栏的自动收起计时是在读这一屏时走完的），
/// 比原 bug 被撞到得更频繁。
///
/// 三层锁：① 纯谓词 [readerVnBlankTapAction] 的真值表（headless 可真跑）；
/// ② 源码守卫，钉死 JS→Dart 的分派结构不回退成「JS 自己 paginate」、也不回退成
/// 「唤栏吃掉翻页」；③ 反向守卫，非 VN 模式点空白的行为一个字节都不许动。
void main() {
  group('BUG-1195 VN blank-tap action truth table', () {
    test('挤压态底栏被收起 → 只展开底栏，不翻页', () {
      expect(
        readerVnBlankTapAction(
          chromeExpanded: false,
          bottomBarFloating: false,
        ),
        ReaderVnBlankTapAction.expandChrome,
      );
      // 悬浮标志此时不影响结论：_showChrome==false 底栏根本不画。
      expect(
        readerVnBlankTapAction(
          chromeExpanded: false,
          bottomBarFloating: true,
        ),
        ReaderVnBlankTapAction.expandChrome,
      );
    });

    test('悬浮态 → 翻页 + 唤栏（不论底栏此刻画没画出来）', () {
      // 本 bug 的原始失败路径：悬浮底栏已自动收起。旧修法在这里只唤栏、不翻页，
      // 于是慢读每屏点两下；现在这一下必须**同时**推进。
      expect(
        readerVnBlankTapAction(
          chromeExpanded: true,
          bottomBarFloating: true,
        ),
        ReaderVnBlankTapAction.advanceAndRevealChrome,
      );
    });

    test('挤压态且已展开（底栏常驻）→ 只翻页', () {
      expect(
        readerVnBlankTapAction(
          chromeExpanded: true,
          bottomBarFloating: false,
        ),
        ReaderVnBlankTapAction.advance,
      );
    });

    test('🔴 只要 chrome 已展开，任何悬浮/收起组合都必须推进——不存在「白点一下」', () {
      // 这是防回归的核心不变式。第一版修法正是在这里破了：悬浮态且底栏已收起时
      // 返回「只唤栏」，那一下用户的翻页意图被吞掉。逐格穷举，任何一格退回
      // 「不推进」都会红。
      for (final bool floating in <bool>[false, true]) {
        final ReaderVnBlankTapAction action = readerVnBlankTapAction(
          chromeExpanded: true,
          bottomBarFloating: floating,
        );
        expect(
          action == ReaderVnBlankTapAction.advance ||
              action == ReaderVnBlankTapAction.advanceAndRevealChrome,
          isTrue,
          reason: 'floating=$floating：chrome 已展开时这一下必须推进；'
              '「先唤栏、下一下才翻页」= 慢读每屏点两下（比原 bug 更频繁）',
        );
      }
    });

    test('悬浮态的推进必须捎带唤栏——否则菜单又叫不出来了', () {
      // 与上一条互为夹逼：上一条钉「不许不翻页」，这一条钉「不许不唤栏」。
      // 两条都在，才不可能滑向任一侧的旧 bug。
      expect(
        readerVnBlankTapAction(
          chromeExpanded: true,
          bottomBarFloating: true,
        ),
        ReaderVnBlankTapAction.advanceAndRevealChrome,
        reason: '悬浮底栏会自动收起，若推进时不唤栏就回到原 bug：菜单永远不可达',
      );
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
      final String body = _vnBlankTapBody(chrome);

      expect(
        body.contains('readerVnBlankTapAction('),
        isTrue,
        reason: '分派必须走纯谓词，不得在页里重写一套内联条件',
      );
      expect(
        body.contains('ReaderVnBlankTapAction.expandChrome') &&
            body.contains('ReaderVnBlankTapAction.advanceAndRevealChrome') &&
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
            body.contains('_revealFloatingChromeForVnAdvance()'),
        isTrue,
        reason: '挤压态展开与悬浮态唤栏各自复用既有状态机，不新造第三套',
      );
    });

    test('🔴 悬浮态分支必须同时唤栏和翻页（两句都在同一 case 下）', () {
      final String body = _vnBlankTapBody(chrome);
      final int caseAt =
          body.indexOf('case ReaderVnBlankTapAction.advanceAndRevealChrome:');
      expect(caseAt, greaterThanOrEqualTo(0),
          reason: '悬浮态 case 必须存在');
      final int nextCase = body.indexOf('case ', caseAt + 10);
      final String branch = nextCase > caseAt
          ? body.substring(caseAt, nextCase)
          : body.substring(caseAt);
      expect(
        branch.contains('_revealFloatingChromeForVnAdvance()'),
        isTrue,
        reason: '不唤栏 → 底栏自动收起后菜单又不可达（原 bug 复发）',
      );
      expect(
        branch.contains('_paginate(ReaderNavigationDirection.forward)'),
        isTrue,
        reason: '不翻页 → 慢读每屏点两下（第一版修法的回归）；'
            '这一下必须两件事都做',
      );
    });

    test('🔴 唤栏助手每次都重新武装自动收起，且绝不 toggle 关掉底栏', () {
      final int start =
          chrome.indexOf('void _revealFloatingChromeForVnAdvance()');
      expect(start, greaterThanOrEqualTo(0),
          reason: 'VN 推进专用的唤栏助手必须存在');
      final int end = chrome.indexOf('bool _handleFloatingChromeReveal()', start);
      expect(end, greaterThan(start));
      final String body = chrome.substring(start, end);

      expect(
        body.contains('_armChromeAutoHide()'),
        isTrue,
        reason: '每次推进都要重新计时，否则连续翻页时底栏会在中途消失',
      );
      // _armChromeAutoHide 必须无条件调用（在任何 if 之外），否则「已可见就不重新
      // 计时」会让底栏在连续翻页中途按上一次的计时收起。
      expect(
        body.trimRight().endsWith('_armChromeAutoHide();\n  }') ||
            RegExp(r'\}\s*\n\s*_armChromeAutoHide\(\);').hasMatch(body),
        isTrue,
        reason: '_armChromeAutoHide 必须在条件分支之外无条件执行',
      );
      expect(
        body.contains('_chromeTransientVisible = false'),
        isFalse,
        reason: 'VN 推进的唤栏绝不能 toggle 关掉底栏——'
            '连点两下就把刚叫出来的菜单关掉是最难查的那类交互 bug；'
            '开关语义留给 _handleFloatingChromeReveal（点空白/点进度条）',
      );
    });

    test('底栏可见性收敛到 bottomBarVisible 单一真相源', () {
      expect(
        page.contains('bool get _bottomBarShouldPaint => bottomBarVisible('),
        isTrue,
        reason: 'BUG-1195：_bottomBarShouldPaint 必须读唯一那套可见性规则，'
            '否则两边漂开又会出现「判为可见却没画出来」',
      );
    });
  });

  // ── 反向守卫：非 VN 模式点空白的行为必须一个字节都不变 ──────────────────
  //
  // 上面全是 VN 正向用例。只验正向不算数：这次改的是「点空白」这个**所有阅读模式
  // 共用**的手势，分页 / 连续模式必须完全不受影响。
  group('BUG-1195 非 VN 模式点空白行为不变（反向守卫）', () {
    late String webview;
    late String chrome;

    setUpAll(() {
      webview = File(
        'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
      ).readAsStringSync();
      chrome = File(
        'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
      ).readAsStringSync();
    });

    test('onVnBlankTap 只在 VN 分支里回传，非 VN 走不到', () {
      final String code = _stripLineComments(webview);
      final int callAt = code.indexOf("callHandler('onVnBlankTap')");
      expect(callAt, greaterThan(0));
      // 回传点之前最近的分支条件必须同时门控 hoshiVnMode 与 hoshiVnClickAdvance。
      final String before = code.substring(0, callAt);
      final int branchAt = before.lastIndexOf('hoshiVnMode');
      expect(branchAt, greaterThan(0),
          reason: 'onVnBlankTap 必须落在 hoshiVnMode 门控之内');
      final String guard = before.substring(branchAt);
      expect(
        guard.contains('hoshiVnClickAdvance'),
        isTrue,
        reason: 'VN 点击推进关掉时也不得回传，否则等于给非 VN 语义开了后门',
      );
      expect(
        guard.contains('_hoshiVnTapIsBlank('),
        isTrue,
        reason: '只有落在字面外的点才算空白点；点到文字仍应查词',
      );
      // 全文只有这一处回传：多一处就意味着某条非 VN 路径也在发这个信号。
      expect(
        RegExp(r"callHandler\('onVnBlankTap'\)").allMatches(code).length,
        1,
        reason: 'onVnBlankTap 只能有唯一回传点',
      );
    });

    test('onTapEmpty 通道原封不动（分页 / 连续模式唯一的唤栏路径）', () {
      expect(
        webview.contains("handlerName: 'onTapEmpty'"),
        isTrue,
        reason: '非 VN 模式点空白仍走 onTapEmpty，此通道不得被本 bug 的修复动到',
      );
      // onTapEmpty 的落点仍是既有的开关语义（可见时收起），没有被 VN 的
      // 「推进专用唤栏」替换掉。
      expect(
        chrome.contains('bool _handleFloatingChromeReveal()'),
        isTrue,
        reason: '既有悬浮唤出/收起状态机必须保留给非 VN 路径',
      );
      final int start = chrome.indexOf('bool _handleFloatingChromeReveal()');
      final int end = chrome.indexOf('\n  ///', start + 10);
      final String body =
          end > start ? chrome.substring(start, end) : chrome.substring(start);
      expect(
        body.contains('_chromeTransientVisible = false'),
        isTrue,
        reason: '非 VN 的「唤出期间再点一下立即收起」（决策#4）必须保留——'
            'VN 的修复不得把这个开关语义改成只开不关',
      );
    });

    test('VN 决策点被 VN 门控包住，非 VN 调不到', () {
      final String body = _vnBlankTapBody(chrome);
      // _handleVnBlankTap 只由 onVnBlankTap handler 触发；handler 注册处不含任何
      // 非 VN 入口。这里再钉一次：决策点里没有任何「非 VN 也走这条」的分支。
      expect(
        body.contains('hoshiContinuousMode') || body.contains('paginatedMode'),
        isFalse,
        reason: 'VN 决策点不得感知其它 view-mode——它本来就只由 VN 分支触发，'
            '出现别的模式判断就说明信号源被放宽了',
      );
    });
  });
}

/// 取 `_handleVnBlankTap` 的函数体源码（到下一个成员为止）。
String _vnBlankTapBody(String chrome) {
  final int start = chrome.indexOf('void _handleVnBlankTap()');
  expect(start, greaterThanOrEqualTo(0),
      reason: '_handleVnBlankTap must exist in chrome.part.dart');
  final int end =
      chrome.indexOf('Future<void> _reanchorContinuousForUiScale', start);
  expect(end, greaterThan(start));
  return chrome.substring(start, end);
}

/// 去掉行注释（Dart 与注入 JS 同用 `//`），使守卫只看真代码——注释里正当地引用了
/// 被修掉的旧写法。
String _stripLineComments(String source) {
  return source.split('\n').map((String line) {
    final int idx = line.indexOf('//');
    return idx >= 0 ? line.substring(0, idx) : line;
  }).join('\n');
}
