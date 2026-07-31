import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// TODO-728 source-scan focus guards (TODO-700 invariant must not regress):
///  - The bottom chrome bars stay wrapped in ExcludeFocus (out of the focus
///    traversal pool).
///  - The top-progress tap-to-toggle GestureDetector is NOT wrapped in Focus /
///    canRequestFocus (it must remain a pure pointer surface, not a focus node).
void main() {
  final String chrome = File(
    'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
  ).readAsStringSync();

  // Strips '//' line comments so a guard inspects only real code (doc comments
  // legitimately mention the very tokens we forbid in code).
  String codeOnly(String segment) => segment
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  test('bottom chrome bars remain ExcludeFocus', () {
    // 底栏外壳已收敛到单一 _wrapBottomChromeBar helper（清理 wave2）：
    // ExcludeFocus 唯一落在 helper 内、两条底栏都经它包装——不变量（两条底栏
    // 都被排出焦点遍历池）不变且更强（与 reader_focus_chrome_excluded 一致）。
    expect(chrome, contains('Widget _wrapBottomChromeBar('));
    expect('ExcludeFocus('.allMatches(chrome).length, 1);
    expect(
      '_wrapBottomChromeBar('.allMatches(chrome).length,
      greaterThanOrEqualTo(3),
    );
  });

  test('_toggleChrome only flips chrome + insets + focus reclaim', () {
    final int start = chrome.indexOf('void _toggleChrome()');
    expect(start, isNonNegative);
    final int end = chrome.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = codeOnly(chrome.substring(start, end));
    expect(body, contains('_showChrome = !_showChrome'));
    expect(body, contains('_applyChromeInsets()'));
    // 底栏是本页自己的 chrome，不是压在页上的覆盖层：必须用自证的 chromeToggled，
    // 不得复用 overlayClosed —— 后者带着「内容未就绪 / 歌词态 / 光标态 / 弹窗态一律
    // 不抢」的严格门控，套到切底栏上就成了「歌词模式下切一次底栏，键盘再也回不来」。
    expect(
      body,
      contains('_focusOwnership.reclaim(FocusReclaimCause.chromeToggled)'),
    );
    expect(body, isNot(contains('FocusReclaimCause.overlayClosed')));
    // Must NOT resurrect the removed moveFocusToChrome path or touch the chrome
    // focus scope directly.
    expect(body, isNot(contains('moveFocusToChrome')));
    expect(body, isNot(contains('_chromeFocusScope')));
  });

  test('chromeToggled 判据不吃 overlayClosed 那组严格门控', () {
    final String page = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();
    final int start = page.indexOf('bool _canOwnReaderFocus(');
    expect(start, isNonNegative);
    final int end = page.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = codeOnly(page.substring(start, end));

    final int chromeCase =
        body.indexOf('case FocusReclaimCause.chromeToggled:');
    final int overlayCase =
        body.indexOf('case FocusReclaimCause.overlayClosed:');
    expect(chromeCase, isNonNegative, reason: '切底栏必须有自己的分支，否则又会被并进严格门控组');
    expect(overlayCase, isNonNegative);
    expect(chromeCase, lessThan(overlayCase),
        reason: 'chromeToggled 必须在自己的分支里 return，不得 fall-through 到严格组');
    // chromeToggled 分支体：到下一个 case 为止，必须是无条件 return true。
    final int chromeBodyStart =
        chromeCase + 'case FocusReclaimCause.chromeToggled:'.length;
    final int nextCase =
        body.indexOf('case FocusReclaimCause.', chromeBodyStart);
    expect(nextCase, greaterThan(chromeBodyStart));
    final String branch = body.substring(chromeBodyStart, nextCase).trim();
    expect(branch, 'return true;',
        reason: '统一前这里是无条件 requestFocus；加门控等于改用户可感知行为，'
            '要改必须单独立 bug 号。实际命中：$branch');
  });

  test('top-progress tap GestureDetector has no Focus wrapper', () {
    final int start = chrome.indexOf('Widget _buildTopProgressBar()');
    expect(start, isNonNegative);
    final int end = chrome.indexOf('// ── Theme Colors', start);
    expect(end, greaterThan(start));
    final String body = codeOnly(chrome.substring(start, end));
    expect(body, contains('HitTestBehavior.opaque'));
    // TODO-975：挤压态仍 onTap:_toggleChrome；悬浮态点进度条立即收起
    // （_handleFloatingChromeReveal）。两者都不是 focus 节点 —— 仍是纯指针面。
    expect(
      body.contains('_toggleChrome') &&
          body.contains('_handleFloatingChromeReveal'),
      isTrue,
      reason: '顶部进度点击必须路由到 _toggleChrome（挤压）或悬浮唤出/收起',
    );
    // 裸子串 'Focus(' 会被任何**以 Focus 结尾**的更长标识符命中——本仓真实存在
    // `requestFocus(` / `ensureFocus(` / `nextFocus(` / `ExcludeFocus(` 等一堆，
    // 顶部进度条一旦正常调一次 `node.requestFocus()` 这条守卫就假红。
    // 契约是「不得包一层 Focus widget」，故只匹配裸构造：`Focus.of(context)` 是读取
    // 祖先节点、不是包装，不该判违规（allowNamedConstructor: false）。
    expect(
      containsIdentifierCall(body, 'Focus', allowNamedConstructor: false),
      isFalse,
      reason: '顶部进度点击面必须保持纯指针面，不得包 Focus',
    );
    expect(body, isNot(contains('canRequestFocus')));
  });
}
