import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_hibiki_page.dart';

import '../helpers/source_guard.dart';
import 'reader_hibiki_page_source_corpus.dart';

/// 合并守卫：阅读器焦点系统（reader_focus_guards）。
/// 本文件是该家族的 host：除本身的 BUG-161（焦点导航分支门控在全局开关上）外，
/// 逐字吸收了两个同族源码守卫——
///   - reader_content_ready_focus_static_test.dart（TODO-700 T3 内容就绪确定性落焦）
///   - reader_esc_focus_reclaim_static_test.dart（BUG-136 手势翻页后 ESC 夺回焦点）。
/// 每个源文件的全部 test() 块**逐字**搬进来（断言与 reason 文案原样保留），用 group()
/// 或原有 group 名保失败隔离。refuted 同族成员（reader_popup_focus /
/// reader_resumed_focus_reclaim / reader_focus_chrome_excluded）保持独立文件，未并入。
///
/// BUG-161 — 书籍阅读器的键盘/手柄焦点导航不跟随全局「键盘/手柄焦点导航」开关。
///
/// 全局开关 `AppModel.experimentalFocusNavigationEnabled`（默认关闭）原本只在
/// `main.dart`（挂 FushiFocusRoot/Ring + wrapWithGlobalNavigation）和
/// `global_navigation.dart`（手柄分发/方向键移焦/手柄 B）被消费。阅读器页面自带一套
/// 独立的 WebView 字符光标（hoshiCaret）焦点导航，挂在自己的 `Focus.onKeyEvent`
/// 与 `GamepadButtonIntent` action 上，与开关解耦 —— 所以开关关闭时书里仍能用
/// 键盘/手柄进光标查词、显示焦点环、方向键跳底栏。
///
/// 根因修复：阅读器所有「焦点导航」分支（进光标、光标动作、方向键/手柄跳底栏、
/// 焦点环）都先判 `_focusNavEnabled`（= appModel.experimentalFocusNavigationEnabled）；
/// 「阅读控制类」（翻页/空格/快捷键）不受影响。
///
/// 进光标的门控在纯函数 `ReaderCaretRouter.isEnterTrigger*` 上有行为单测
/// （reader_caret_router_test.dart）。inline 的焦点环/跳底栏门控涉及真实焦点树与
/// WebView，无法脱离设备单测行为，故用源码守卫锁住接线（最强可落地层，见
/// docs/BUGS.md，与 reader_esc_focus_reclaim_static_test 同范式）。
void main() {
  group('BUG-161 · 源码守卫：阅读器焦点导航分支门控在开关上', () {
    final File file =
        File('lib/src/pages/implementations/reader_hibiki_page.dart');
    // 掩码注释（避免匹配记录守卫的散文）+ 折叠空白，便于跨行匹配。
    final String code =
        _collapse(maskCommentsAndScriptLines(readReaderPageSource()));

    test('阅读器页面源文件存在', () {
      expect(file.existsSync(), isTrue);
    });

    test('_focusNavEnabled getter 读全局开关', () {
      expect(
        code.contains(
            'bool get _focusNavEnabled => appModel.experimentalFocusNavigationEnabled;'),
        isTrue,
        reason:
            '_focusNavEnabled 必须等于 appModel.experimentalFocusNavigationEnabled，'
            '否则阅读器焦点导航不会跟随全局开关（BUG-161）。',
      );
    });

    test('手柄 A 进/操作光标的处理门控在开关上', () {
      expect(
        code.contains(
            '_focusNavEnabled ? _handleGamepadAKeyEvent(event) : null'),
        isTrue,
        reason: '手柄 A 是焦点导航（进/操作光标），开关关闭时不应运行（BUG-161）。',
      );
    });

    test('进光标的 enter-trigger 把开关透传给纯函数 router（键盘 + 手柄两处）', () {
      final int count =
          'focusNavEnabled: _focusNavEnabled'.allMatches(code).length;
      expect(
        count,
        greaterThanOrEqualTo(2),
        reason: 'isEnterTriggerKeyboard / isEnterTriggerGamepad 必须收到 '
            'focusNavEnabled: _focusNavEnabled，开关关闭时不进光标（BUG-161）。',
      );
    });

    test('光标激活分支（键盘 + 手柄两处）以 _focusNavEnabled 短路', () {
      final int count =
          'if (_focusNavEnabled && _caretActive)'.allMatches(code).length;
      expect(
        count,
        greaterThanOrEqualTo(2),
        reason: '光标动作是焦点导航；开关关闭（含中途关闭）时必须短路回退到翻页（BUG-161）。',
      );
    });

    // TODO-700 T8：底栏被 ExcludeFocus 排出焦点遍历池后，「↓ 跳底栏」的焦点搬运整段
    // 删除（底栏不再是焦点目标）。原 BUG-161 的「↓ 跳底栏要门控在开关上」诉求随之
    // 消失 —— 没有可门控的搬运分支了。两条原断言改为断言「搬运分支已删」，防回退。
    test('TODO-700 T8：方向键 ↓ 跳底栏的焦点搬运分支已删', () {
      expect(
        code.contains(
            'if (_focusNavEnabled && !_caretActive && event.logicalKey == LogicalKeyboardKey.arrowDown'),
        isFalse,
        reason: '底栏退出焦点遍历后，方向键 ↓ 把焦点塞进底栏的分支必须删除（T8）。',
      );
    });

    test('TODO-700 T8：手柄 D-pad ↓ 跳底栏的焦点搬运分支已删', () {
      expect(
        code.contains(
            'if (_focusNavEnabled && button == GamepadButton.dpadDown && _showChrome)'),
        isFalse,
        reason: '底栏退出焦点遍历后，手柄 D-pad ↓ 把焦点塞进底栏的分支必须删除（T8）。',
      );
    });

    test('阅读内容焦点环门控在开关上', () {
      expect(
        code.contains('final bool show = _focusNavEnabled &&'),
        isTrue,
        reason: '阅读内容焦点环属于焦点导航；关闭时不应显示（BUG-161）。',
      );
    });
  });

  // ─── merged verbatim from reader_content_ready_focus_static_test.dart ───
  /// TODO-700 T3 源码守卫：WebView 内容就绪时确定性把 Flutter 焦点落到正文 _focusNode，
  /// 使首开书第一次按 B/上下句/播放就作用在书内（消解「点两下播放」「首开 B 退书」）。
  /// 必须门控：光标态 / 词典弹窗态 / 歌词态都不抢焦点（否则覆盖光标焦点）。整页
  /// autofocus 仍保留作冷启动兜底。
  group('reader_content_ready_focus', () {
    String read(String rel) {
      final File f = File(rel);
      expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
      return f.readAsStringSync();
    }

    test('reader_hibiki_page 定义 _canOwnReaderFocus 且正确门控内容就绪落焦', () {
      final String src =
          read('lib/src/pages/implementations/reader_hibiki_page.dart');
      expect(src.contains('bool _canOwnReaderFocus(FocusReclaimCause cause)'),
          isTrue,
          reason: '缺统一焦点判据');
      expect(src.contains('PageFocusOwnership _focusOwnership'), isTrue,
          reason: '缺确定性落焦的单一所有者');
      // 门控：光标态 / 弹窗 / 歌词态不抢。
      final int start =
          src.indexOf('bool _canOwnReaderFocus(FocusReclaimCause cause)');
      final int end = src.indexOf('\n  }', start);
      final String body = src.substring(start, end);
      expect(body.contains('_caretActive') || body.contains('_caretSurface'),
          isTrue,
          reason: 'helper 必须门控光标态');
      expect(body.contains('_lyricsMode'), isTrue, reason: 'helper 必须门控歌词态');
      expect(
          body.contains('isDictionaryShown') ||
              body.contains('_hasVisiblePopup'),
          isTrue,
          reason: 'helper 必须门控弹窗态');
      expect(body.contains('_readerContentReady'), isTrue);
    });

    test('内容就绪三落点回收焦点（不含歌词路径）', () {
      final String nav = read(
          'lib/src/pages/implementations/reader_hibiki/navigation.part.dart');
      final String web =
          read('lib/src/pages/implementations/reader_hibiki/webview.part.dart');
      expect(
          nav.contains(
              '_focusOwnership.reclaim(FocusReclaimCause.contentReady)'),
          isTrue,
          reason: 'navigation.part 内容就绪点应落焦');
      expect(
          web.contains(
              '_focusOwnership.reclaim(FocusReclaimCause.contentReady)'),
          isTrue,
          reason: 'webview.part spreadReady 应落焦');
    });
  });

  // ─── merged verbatim from reader_esc_focus_reclaim_static_test.dart ───
  /// BUG-136 — 翻页（手势/滚轮）后 ESC 不退出书籍。
  ///
  /// 退出书籍依赖 Flutter 阅读器 `_focusNode`（挂 `Focus.onKeyEvent:
  /// _handleKeyEvent`）持有键盘焦点：ESC → readerDismissDict → Navigator.maybePop()
  /// → onWillPop()（恒 true）→ 退出。进书时 `autofocus: true` 给了焦点，所以一开始
  /// ESC 能退。但用**指针手势翻页**（滑动 / 鼠标滚轮 / 边界翻章），手势先落在原生
  /// WebView 上，WebView 抢走 OS 键盘焦点，没有任何代码把焦点还给 `_focusNode`
  /// （不像 popup 路径的 `onAllPopupsDismissed` 会 `_focusNode.requestFocus()`）。
  /// 此后 ESC 进了 WebView 被吞，到不了 `_handleKeyEvent` → 翻页后退不出书。
  /// 键盘/手柄翻页不经这些 JS 手势回调、不丢焦点，所以 bug 只在触摸/鼠标翻页后出现。
  ///
  /// 决策逻辑抽成纯谓词 [shouldReclaimReaderFocusAfterGesture] 可脱离 WebView 单测；
  /// 「真实焦点树 / 原生 WebView 抢焦点」只能在设备复测，故用源码守卫锁住接线
  /// （最强可落地层 — 见 docs/BUGS.md，与 reader_webview_com_focus_guard 同范式）。
  group('BUG-136 · 纯谓词：何时该夺回阅读器焦点', () {
    test('正常翻页（无弹窗、底栏未持焦点）→ 夺回焦点', () {
      expect(
        shouldReclaimReaderFocusAfterGesture(
          popupVisible: false,
          chromeHasFocus: false,
        ),
        isTrue,
      );
    });

    test('词典弹窗可见 → 不夺（弹窗合法持有焦点）', () {
      expect(
        shouldReclaimReaderFocusAfterGesture(
          popupVisible: true,
          chromeHasFocus: false,
        ),
        isFalse,
      );
    });

    test('底栏持有焦点 → 不夺（避免把焦点从底栏抢走，不破坏手柄/键盘导航）', () {
      expect(
        shouldReclaimReaderFocusAfterGesture(
          popupVisible: false,
          chromeHasFocus: true,
        ),
        isFalse,
      );
    });

    test('两者都成立 → 不夺', () {
      expect(
        shouldReclaimReaderFocusAfterGesture(
          popupVisible: true,
          chromeHasFocus: true,
        ),
        isFalse,
      );
    });
  });

  group('BUG-136 · 源码守卫：每个指针手势回调都夺回焦点', () {
    // TODO-589 batch8: 指针手势 handler(onSwipe/onBoundarySwipe/onTap/onTapEmpty)
    // 已搬到 reader_hibiki/webview.part.dart，改读「主壳 + 全部 part」合并语料。
    final String code = maskCommentsAndScriptLines(readReaderPageSource());

    test('阅读器页面合并语料含 WebView 注入', () {
      // 合并语料(主壳 + part)必须真正含 reader WebView 构建点，否则下面的
      // handler 守卫会静默空跑（reader_hibiki_page.dart 已拆主壳 + part）。
      expect(code.contains('InAppWebView('), isTrue);
    });

    // 每个纯指针手势 JS 回调（用户触摸 WebView 触发 → WebView 抢焦点）都必须在
    // 回调体内夺回阅读器焦点，否则该手势之后 ESC / 快捷键失效（BUG-136）。
    for (final String handler in <String>[
      'onSwipe', // 滑动 + 鼠标滚轮翻页（JS wheel 也 callHandler('onSwipe')）
      'onBoundarySwipe', // 边界手势 → 翻章
      'onTapEmpty', // 点空白切底栏
    ]) {
      test("'$handler' 回调体内回收焦点（FocusReclaimCause.gesture）", () {
        final String body = _handlerCallbackBody(code, handler);
        expect(
          body.contains('_focusOwnership.reclaim(FocusReclaimCause.gesture)'),
          isTrue,
          reason: "'$handler' 回调丢了夺回焦点的调用 —— 该手势翻页/切栏后 ESC "
              '将无法退出书籍（BUG-136）。',
        );
      });
    }

    test("'onTap' 回调（切栏/无选区分支）夺回焦点", () {
      final String body = _handlerCallbackBody(code, 'onTap');
      expect(
        body.contains('_focusOwnership.reclaim(FocusReclaimCause.gesture)'),
        isTrue,
        reason: 'onTap 点击切底栏后 ESC 必须仍能退出书籍（BUG-136）。',
      );
    });

    test('夺回焦点的 helper 经纯谓词把关（弹窗/底栏持焦点时不夺）', () {
      // helper 必须把决策委托给可单测的纯谓词，而不是无条件 requestFocus。
      expect(
        code.contains('shouldReclaimReaderFocusAfterGesture('),
        isTrue,
        reason: '_canOwnReaderFocus 的 gesture 分支应调用纯谓词 '
            'shouldReclaimReaderFocusAfterGesture 决定是否夺回焦点。',
      );
    });
  });
}

/// 取某个 `handlerName: '<name>'` 之后、到下一个 `handlerName:`（或文件末尾）之前的
/// 源码片段，作为该回调体的近似范围，用于断言夺回焦点的调用确实接在该回调里。
String _handlerCallbackBody(String code, String handlerName) {
  final int start = code.indexOf("handlerName: '$handlerName'");
  expect(start, isNonNegative,
      reason: "找不到 handlerName: '$handlerName' —— 回调被改名/移除，更新此守卫");
  final int next = code.indexOf('handlerName:', start + 1);
  return next < 0 ? code.substring(start) : code.substring(start, next);
}

/// 折叠所有连续空白为单个空格，便于匹配被 dart format 折行的多行表达式。
///
/// 上游的注释剥离改用共享的 [maskCommentsAndScriptLines]：本语料是「主壳 + 全部
/// part」，其中 `reader_hibiki/webview.part.dart` 把大段 JS 放在三引号串里，所以
/// 既要 Dart 词法掩码（吃掉 `/* */` 块注释与行尾注释——原来的本地
/// `_stripDartLineComments` 只丢整行 `//`，把被守的接线整段包进 `/* */` 就能骗绿），
/// 又要保留「整行 `//`」规则来吃掉串内的 JS 注释。掩码是**等长**的，配合本函数的
/// 空白折叠，注释位置只会塌成一个空格，跨行匹配的行为与原来一致。
String _collapse(String source) =>
    source.replaceAll(RegExp(r'\s+'), ' ').trim();
