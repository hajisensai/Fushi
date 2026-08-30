import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';
import '../helpers/win32_interactivity_guard.dart';

/// BUG-951 — source-scan guards for the galgame hook overlay's pass-through
/// design.
///
/// Why a source scan: the load-bearing code is a pair of Win32 windows in
/// `windows/runner/`. It cannot be instantiated from `flutter test` (no message
/// loop, no Direct2D, and the failure is defined by another PROCESS receiving a
/// click). These guards therefore pin the wiring whose loss would silently
/// re-introduce one of the two failure modes we have already shipped:
///
///  1. HTTRANSPARENT-only pass-through — swallowed the click entirely, because
///     that hit-test result only walks same-thread windows and the game is a
///     different process (the original BUG-951).
///  2. Timer-driven WS_EX_TRANSPARENT flipping — a starved timer leaves the bit
///     set while the cursor is already over the toolbar, so the click falls
///     into the game and advances dialogue / picks a branch (PR#460, reverted).
///
/// The shipped design has no state to lose a race over: the body window is
/// click-through for exactly as long as the user keeps pass-through on, and the
/// toolbar is a separate window that is never transparent.
///
/// Limitation, stated plainly: a text scan pins the WIRING, not the runtime
/// behaviour. Cross-process click delivery and the "toolbar always clickable"
/// property still need the Windows real-device pass recorded in
/// `docs/bugs/BUG-951-gal-overlay-click-through-cross-process.md`.
void main() {
  late String body;
  late String toolbar;
  late String toolbarHeader;
  late String bodyHeader;
  late String cmake;
  late String host;
  late String dartChannel;

  setUpAll(() {
    dartChannel = File('lib/src/platform/gal_hook_text_overlay_channel.dart')
        .readAsStringSync();
    body = File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
    bodyHeader =
        File('windows/runner/floating_lyric_window.h').readAsStringSync();
    toolbar = File('windows/runner/hook_toolbar_window.cpp').readAsStringSync();
    toolbarHeader =
        File('windows/runner/hook_toolbar_window.h').readAsStringSync();
    cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
    host = File('windows/runner/flutter_window.cpp').readAsStringSync();
  });

  /// Returns the body of `signature { ... }`, brace-matched, so an assertion
  /// about "inside function X" cannot be satisfied by a match elsewhere.
  String functionBody(String source, String signature) {
    final int start = source.indexOf(signature);
    expect(start, isNot(-1), reason: 'missing $signature');
    int i = source.indexOf('{', start);
    expect(i, isNot(-1), reason: 'no opening brace after $signature');
    int depth = 0;
    for (int j = i; j < source.length; j++) {
      if (source[j] == '{') depth++;
      if (source[j] == '}') {
        depth--;
        if (depth == 0) return source.substring(i, j + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  int countOf(String haystack, String needle) =>
      needle.allMatches(haystack).length;

  /// Drops `// ...` comments so a call-site count cannot be thrown off (in
  /// either direction) by prose that mentions the symbol.
  String stripLineComments(String source) => maskComments(source);

  group('BUG-951 · the body window is really click-through', () {
    test('WS_EX_TRANSPARENT is applied, and only from one function', () {
      // The whole point of the fix: HTTRANSPARENT does not cross a process
      // boundary, WS_EX_TRANSPARENT does. The bit must actually be used.
      expect(body.contains('WS_EX_TRANSPARENT'), isTrue,
          reason: 'Cross-process pass-through needs the ex-style bit.');

      // ...but from exactly one place, so there can never be a second code path
      // that strips clicks without also putting the escape hatch on screen.
      // Count the *expression*, not the word: the token also appears in
      // explanatory comments, which are harmless. The cast is the only way the
      // bit reaches an ex-style, and it must exist exactly once, inside the
      // single setter.
      const String applyExpr = 'static_cast<LONG_PTR>(WS_EX_TRANSPARENT)';
      final String setter = functionBody(
          body, 'void FloatingLyricWindow::SetBodyExTransparent(bool enabled)');
      expect(countOf(setter, applyExpr), 1);
      expect(countOf(body, applyExpr), 1,
          reason: 'The ex-style bit must only be applied inside '
              'SetBodyExTransparent.');
      expect(setter.contains('SetWindowLongPtr(hwnd_, GWL_EXSTYLE'), isTrue);
      expect(setter.contains('SWP_FRAMECHANGED'), isTrue,
          reason: 'Without SWP_FRAMECHANGED the window keeps hit-testing with '
              'the old ex-style.');
    });

    test('SetBodyExTransparent is only ever called by ApplyPassThroughExStyle',
        () {
      final String applier = functionBody(
          body, 'void FloatingLyricWindow::ApplyPassThroughExStyle()');
      // 3 call sites total: the two inside ApplyPassThroughExStyle (off-path,
      // failure-path) plus the enable at its end. Any call from elsewhere means
      // some other code path can take clicks away.
      expect(countOf(applier, 'SetBodyExTransparent('), 3,
          reason: 'off-path, toolbar-failed path, enable path');
      expect(countOf(body, 'SetBodyExTransparent('), 3 + 1 /* definition */,
          reason: 'unexpected extra caller outside ApplyPassThroughExStyle');
      expect(bodyHeader.contains('void SetBodyExTransparent(bool enabled);'),
          isTrue);
    });

    test('the discredited HTTRANSPARENT mechanism is gone', () {
      expect(body.contains('return HTTRANSPARENT;'), isFalse,
          reason: 'HTTRANSPARENT never reaches another process — that IS '
              'BUG-951.');
      expect(toolbar.contains('return HTTRANSPARENT;'), isFalse);
    });

    test('pass-through is not driven by a timer (PR#460 regression)', () {
      // PR#749 UPDATE — this used to ban the token `Timer(` outright. That
      // judged the KEYWORD, not the BEHAVIOUR, and it was wrong in both
      // directions: a `TIMERPROC` callback rebuilds PR#460 verbatim without the
      // body ever containing `WM_TIMER`, while a timer that merely reads the
      // cursor to dispatch a word lookup — which is what the Shift-hover lookup
      // poll does, and it explicitly stands down under `pass_through_` — was
      // failed on sight.
      //
      // The predicate is now the invariant itself: from every timer callback,
      // walk the real call graph and fail if anything reachable WRITES the
      // window's mouse interactivity. It also pins that the callbacks are
      // enumerable at all (TIMERPROC must be nullptr), so the reachability
      // analysis cannot be dodged by installing a timer with its own callback.
      expectTimerCannotFlipInteractivity(body,
          className: 'FloatingLyricWindow', label: 'floating_lyric_window.cpp');
      expectTimerCannotFlipInteractivity(toolbar,
          className: 'HookToolbarWindow', label: 'hook_toolbar_window.cpp');
      // The toolbar is the escape hatch; it has no pass-through state to flip
      // and no reason to own a timer at all, so the stricter ban still applies
      // there. Losing this would mean the one always-clickable window grew a
      // way to stop being clickable.
      expect(stripLineComments(toolbar).contains('Timer('), isFalse,
          reason: 'The escape-hatch toolbar has no legitimate timer.');
      // Symbol-level tombstones for PR#460's own helpers, in either file. Cheap
      // belt-and-braces on top of the behavioural predicate: a resurrection by
      // copy-paste is caught by name even before the call graph is walked.
      for (final String source in <String>[body, toolbar]) {
        final String code = stripLineComments(source);
        expect(code.contains('PollCursorInteractivity'), isFalse);
        expect(code.contains('ApplyPassThroughHitTest'), isFalse);
        expect(code.contains('UpdatePassThroughFromCursor'), isFalse);
      }
    });

    test('only the three lifecycle edges may re-apply pass-through', () {
      // SetBodyExTransparent being funnelled through ApplyPassThroughExStyle is
      // worth nothing if some cursor-driven poller may call the funnel itself.
      // Show / Hide / SetPassThrough are the only legal callers; anything else
      // means the "no state to race over" property has been given up.
      final String code = stripLineComments(body);
      expect(countOf(code, 'ApplyPassThroughExStyle()'), 3 + 1 /* definition */,
          reason: 'Callers must stay exactly Show(), Hide(), SetPassThrough(). '
              'A fourth caller is how a hover race gets back in.');
    });

    test('show / hide both route through the single applier', () {
      expect(
          functionBody(body, 'bool FloatingLyricWindow::Show(HWND owner)')
              .contains('ApplyPassThroughExStyle()'),
          isTrue);
      expect(
          functionBody(body, 'void FloatingLyricWindow::Hide()')
              .contains('ApplyPassThroughExStyle()'),
          isTrue);
      expect(
          functionBody(body,
                  'void FloatingLyricWindow::SetPassThrough(bool enabled)')
              .contains('ApplyPassThroughExStyle()'),
          isTrue);
    });
  });

  group('BUG-951 · the user can always get back out', () {
    // BUG-1480 起，正文**不再整体**停止接收点击：穿透改成逐像素命中
    // （背景强制 alpha 0 → OS 把那些像素的点击直接给游戏；字形像素仍归我们，
    // 所以「穿透态下点字查词」才成立）。于是原来那条「Show() 必须排在
    // SetBodyExTransparent(true) 之前」的顺序断言失去了被守对象。
    //
    // 但逃生工具条本身仍然是必需的，理由换了：穿透态下正文内工具条不再绘制
    // （Render 里的 draw_body_toolbar），关掉穿透的唯一入口就只剩那个独立小窗。
    // 所以不变量重述为「建不出工具条就必须取消穿透」，顺序由 early-return 保证。
    test('建不出逃生工具条就必须取消穿透（正文内工具条此时已不绘制）', () {
      final String applier = functionBody(
          body, 'void FloatingLyricWindow::ApplyPassThroughExStyle()');
      // 建窗现在收口在 ApplyToolbarVisibility()（它同时管自动隐藏），
      // 返回值语义不变：false = 期望显示却没能上屏。
      final int show = applier.indexOf('if (!ApplyToolbarVisibility()');
      expect(show, isNot(-1), reason: '建窗结果必须被检查，不能忽略');
      final String afterShow = applier.substring(show);
      expect(afterShow.contains('pass_through_ = false;'), isTrue,
          reason: '建不出工具条就必须把穿透翻回 false，否则用户被困在'
              '「正文内工具条不画、独立工具条又没建出来」的无出口态');
      // 判据从 `!(hook_text_mode_ && pass_through_)` 收紧成 `!hook_text_mode_`：
      // hook 台词浮窗现在**无论穿不穿透**都只用那个独立短药丸窗，正文里一颗按钮
      // 都不画。逃生窗因此更不可省——旧写法下非穿透态还有正文内工具条兜着。
      expect(
        body.contains('draw_body_toolbar = !hook_text_mode_'),
        isTrue,
        reason: '正文内工具条在 hook 台词模式一律不绘制，正是逃生窗不可省的原因',
      );
    });

    test('穿透态必须把背景强制成 alpha 0（BUG-1480 的命中机制前提）', () {
      // 逐像素命中只在**真 alpha 0** 时把点击透给下面的窗口。用户若设了可见底色，
      // 整块 rect 就会变成不透明 → OS 把每一次点击都给我们、游戏什么都收不到。
      // 这是老「逐像素」实现唯一的真缺陷，必须由代码强制而不是靠用户碰巧设对。
      expect(body.contains('body_bg &= 0x00FFFFFF'), isTrue,
          reason: '穿透态背景必须无条件清零 alpha');
    });

    // BUG-1853 — 穿透态的碰撞箱是「文字行矩形并集」，不是字形轮廓。
    // 整窗 alpha 0 + 逐像素命中 = 只有字形像素归我们；口/国/目 的内部、笔画之间、
    // 字距行距的镂空全透给游戏，点字查词变成看运气。修法是在每行文字的行盒里铺
    // 一层 kHookTextMinCatchAlpha 的不可见 catch fill：行盒内任何一点都算点在字
    // 上，行盒外仍是真 alpha 0（「点背景推台词」的不变式不动）。
    test('穿透态必须在文字行矩形内铺不可见 catch fill（BUG-1853）', () {
      final String render =
          functionBody(body, 'void FloatingLyricWindow::Render()');
      // 判据多了一维 `passthrough_blocks_mouse_`（「穿透时是否仍拦鼠标」可配），
      // 所以锚点只取到那一维之前；后面 `contains` 再确认它确实在同一个条件里。
      final int catchFill =
          render.indexOf('if (hook_text_mode_ && pass_through_ &&');
      expect(catchFill, isNot(-1),
          reason: '穿透态行矩形 catch fill 的守门条件必须存在，且只在'
              'hook 台词 + 穿透态下生效（歌词条 / 非穿透态整窗兜底已经可点）');
      // 行盒必须来自 DirectWrite 自己的排版（HitTestTextRange 全文范围），
      // 不能手算——手算行高会和有注音时 SetLineSpacing 加高后的真实行盒漂移。
      final String block = render.substring(catchFill, catchFill + 2200);
      expect(
        block.contains('HitTestTextRange(0, static_cast<UINT32>(text_.size())'),
        isTrue,
        reason: '行矩形必须取自 HitTestTextRange(0, text_.size())，'
            '即 DirectWrite 排好版的逐行行盒',
      );
      expect(block.contains('kHookTextMinCatchAlpha << 24'), isTrue,
          reason: 'catch fill 必须用 kHookTextMinCatchAlpha（不可见但可命中），'
              '不能用可见 alpha——否则穿透态多出一块底色');
      expect(block.contains('FillRectangle('), isTrue,
          reason: '行矩形要真的填进 layered 位图，命中判定才会把它算成窗口像素');
      // 铺在 PushAxisAlignedClip(text_clip) 之后：滚出视口的行不能吃点击。
      final int clip = render.indexOf('PushAxisAlignedClip(text_clip');
      expect(clip, isNot(-1));
      expect(clip < catchFill, isTrue,
          reason: 'catch fill 必须在 text_clip 裁剪之内绘制，'
              '否则滚出视口的行仍会拦截本该给游戏的点击');
    });

    test('a toolbar that cannot be created cancels pass-through', () {
      final String applier = functionBody(
          body, 'void FloatingLyricWindow::ApplyPassThroughExStyle()');
      expect(applier.contains('if (!ApplyToolbarVisibility()'), isTrue,
          reason: 'The result must be checked, not ignored. Window creation is '
              'now funnelled through ApplyToolbarVisibility(), which also owns '
              'the auto-hide decision; the false = "wanted on screen but is '
              'not" contract is unchanged.');
      expect(applier.contains('pass_through_ = false;'), isTrue,
          reason: 'Better to drop the toggle than to strand the user behind '
              'an overlay they can no longer click.');
      // ...and the veto must be reported, or Dart's own flag stays true and the
      // user's next press on the button is a press that does nothing visible.
      expect(applier.contains('on_pass_through_(false)'), isTrue,
          reason: 'A silently vetoed toggle desyncs Dart and eats the next '
              'press on the escape-hatch button.');
      expect(host.contains('"passThroughChanged"'), isTrue,
          reason: 'The veto must reach Dart over the gal_hook_text channel.');
    });

    test('the toolbar window is never mouse-transparent', () {
      final int create = toolbar.indexOf('CreateWindowExW(');
      expect(create, isNot(-1));
      final String flags = toolbar.substring(
          create, toolbar.indexOf('kWindowClassName', create));
      expect(flags.contains('WS_EX_TRANSPARENT'), isFalse,
          reason: 'This window IS the escape hatch; it must always be '
              'clickable.');
      expect(flags.contains('WS_EX_NOACTIVATE'), isTrue,
          reason: 'Clicking a button must not steal focus from the game.');
      expect(flags.contains('WS_EX_TOPMOST'), isTrue,
          reason: 'It has to float above both the game and the overlay body.');
      // Nowhere else either — not even a later SetWindowLongPtr.
      expect(toolbar.contains('SetWindowLongPtr(hwnd_, GWL_EXSTYLE'), isFalse);
    });

    test('the overlay can still be moved while the body takes no input', () {
      // With the body click-through, dragging it is impossible; the toolbar
      // carries the drag and asks the owner to move (which clamps to the work
      // area, so the overlay cannot be dragged off-screen).
      expect(toolbar.contains('on_drag_('), isTrue);
      expect(toolbarHeader.contains('using DragCallback'), isTrue);
      expect(
          body.contains('void FloatingLyricWindow::MoveBodyTo(int x, int y)'),
          isTrue);
      expect(
          functionBody(
                  body, 'void FloatingLyricWindow::MoveBodyTo(int x, int y)')
              .contains('ClampOriginToWorkArea('),
          isTrue);
    });
  });

  group('BUG-951 · the two windows cannot drift apart', () {
    test('slot -> action is one shared table per profile', () {
      // 两个窗口都通过 SlotAction(profile, slot) 取 action，所以同一个 profile 下
      // 第 3 颗按钮在两窗里要么都是 togglePassThrough，要么都不是。
      expect(body.contains('hook_toolbar::SlotAction(toolbar_profile_, slot)'),
          isTrue,
          reason: 'The body must not keep a private copy of the mapping.');
      expect(toolbar.contains('hook_toolbar::SlotAction(profile_, slot)'),
          isTrue);

      final String dispatcher = functionBody(body,
          'void FloatingLyricWindow::DispatchControlAction(const std::string& action)');

      /// 一张槽表的完整检查：顺序字面量、声明槽数、无死键。
      void checkTable({
        required String countName,
        required String tableName,
        required List<String> expected,
        required String dartConsumer,
        required String dartExecutor,
        required String executorRegisterCall,
      }) {
        final int tableStart = toolbarHeader.indexOf('$tableName[');
        expect(tableStart, greaterThan(0), reason: 'missing table $tableName');
        final String table = toolbarHeader.substring(
            tableStart, toolbarHeader.indexOf('};', tableStart));
        final List<String> found = RegExp('"([a-zA-Z]+)"')
            .allMatches(table)
            .map((RegExpMatch m) => m.group(1)!)
            .toList();
        // Spelled out on purpose: the row's left-to-right order is muscle
        // memory (rightmost is always 关闭), so a reorder must be a deliberate
        // edit here and not something a refactor can do quietly.
        expect(found, expected,
            reason: 'Slot order is the wire contract with the Dart controller.');
        // Derived, not a second literal to keep in sync: a table that grows
        // while its count does not is an out-of-bounds read in both windows.
        expect(
            toolbarHeader
                .contains('constexpr int $countName = ${expected.length}'),
            isTrue,
            reason: '$countName must equal the $tableName length.');

        // No dead buttons. Every slot must actually be executed somewhere:
        // either natively in DispatchControlAction (`lock` / `topmost`
        // deliberately skip the Dart round-trip) or by the Dart side's action
        // switch. Without this, adding a slot to the table draws a button that
        // does nothing — and the hardcoded list above would happily bless it.
        // 判据必须落在**执行方**，不能只到 channel 的转发层。
        //
        // 原来只查 `dartConsumer.contains("case '$action':")` —— 那是 channel 里
        // 一行 `_onX?.call()`，无论上游注册的是真实现还是一行 debugPrint 都命中。
        // 有声书的 togglePassThrough / toggleTransparency 就是这么绿着的：画得出、
        // 点得到、按下去什么也不发生。所以在「channel 有 case」之上再要求
        // 「注册方真的把这个 handler 传进去了」。
        final int registerAt = dartExecutor.indexOf(executorRegisterCall);
        expect(registerAt, isNonNegative,
            reason: '找不到 $executorRegisterCall 的注册点，判据会退化成恒真');
        final String registration = dartExecutor.substring(
            registerAt, dartExecutor.indexOf('\n    );', registerAt));
        for (final String action in expected) {
          final bool nativelyHandled = dispatcher.contains('== "$action"');
          if (nativelyHandled) continue;
          expect(dartConsumer.contains("case '$action':"), isTrue,
              reason: 'Slot "$action" 在 channel 里没有转发分支。');
          // channel 的字段名是 `_on<Action 首字母大写>`，注册参数名去掉下划线。
          final String handler =
              'on${action[0].toUpperCase()}${action.substring(1)}:';
          expect(registration.contains(handler), isTrue,
              reason: 'Slot "$action" 画得出、点得到，但注册方没给 $handler —— '
                  'channel 那一行 `?.call()` 命中的是 null，按下去什么也不发生。'
                  '要么接上真实现，要么把它从槽表里删掉。');
        }
      }

      checkTable(
        countName: 'kGalHookSlotCount',
        tableName: 'kGalHookSlotActions',
        expected: const <String>[
          'replayVoice',
          'recaptureVoice',
          'toggleFollow',
          'togglePassThrough',
          'toggleTransparency',
          'lock',
          'openWorkbench',
          'topmost',
          'close',
        ],
        dartConsumer: dartChannel,
        dartExecutor:
            File('lib/src/lookup/gal_hook_text_overlay_controller.dart')
                .readAsStringSync(),
        executorRegisterCall: 'GalHookTextOverlayChannel.setEventHandlers(',
      );
      checkTable(
        countName: 'kAudiobookSlotCount',
        tableName: 'kAudiobookSlotActions',
        expected: const <String>[
          'previousCue',
          'playPause',
          'nextCue',
          'lock',
          'topmost',
          'close',
        ],
        dartConsumer:
            File('lib/src/media/audiobook/floating_lyric_channel.dart')
                .readAsStringSync(),
        dartExecutor: File('lib/src/media/audiobook/audiobook_session.dart')
            .readAsStringSync(),
        executorRegisterCall: 'FloatingLyricChannel.setEventHandlers(',
      );
    });

    test('glyph + active tint are shared too', () {
      expect(
          body.contains(
              'hook_toolbar::SlotGlyph(toolbar_profile_, slot, tb_states)'),
          isTrue);
      expect(
          body.contains(
              'hook_toolbar::SlotActive(toolbar_profile_, slot,'),
          isTrue);
      expect(toolbar.contains('hook_toolbar::SlotGlyph(profile_, slot, states_)'),
          isTrue);
    });

    test('one dispatcher runs a button, whichever window was clicked', () {
      expect(bodyHeader.contains('void DispatchControlAction('), isTrue);
      // The binding moved out of ApplyPassThroughExStyle into its own
      // BindToolbarCallbacks() (the toolbar is no longer pass-through-only, so
      // the wiring can no longer live in the pass-through applier). The
      // invariant is unchanged: whoever binds it must forward to the shared
      // dispatcher.
      final String binder = functionBody(
          body, 'void FloatingLyricWindow::BindToolbarCallbacks()');
      expect(binder.contains('DispatchControlAction(action)'), isTrue,
          reason: 'The toolbar action callback must reuse the body dispatcher, '
              'not a second copy of the lock / topmost logic.');
      // The lock + topmost toggles live in the dispatcher only.
      final String dispatcher = functionBody(body,
          'void FloatingLyricWindow::DispatchControlAction(const std::string& action)');
      expect(dispatcher.contains('on_lock_'), isTrue);
      // PR#749 UPDATE — this used to be `contains('topmost_ = !topmost_')`,
      // an inline write that PR#749 correctly extracted into SetTopmost() so
      // the pin button and Dart's session reset drive the same code. Pinning
      // the literal would have punished the better structure, so pin the
      // structure instead: the dispatcher toggles through the single applier,
      // and the applier is the ONLY writer of topmost_. Every window-Z
      // SetWindowPos reads that member, so a second writer is how the pin ends
      // up lit while the window is no longer topmost.
      expect(dispatcher.contains('SetTopmost(!topmost_)'), isTrue,
          reason: 'The pin button must toggle through the single applier.');
      expect(countOf(stripLineComments(body), 'topmost_ ='), 1,
          reason: 'SetTopmost() must be the only writer of topmost_.');
      expect(
          functionBody(
                  body, 'void FloatingLyricWindow::SetTopmost(bool enabled)')
              .contains('topmost_ = enabled'),
          isTrue,
          reason: 'That one writer must be SetTopmost().');
    });

    test('geometry is pushed from the body, not recomputed in the toolbar', () {
      expect(
          body.contains(
              'hook_toolbar::Layout FloatingLyricWindow::ComputePassThroughToolbarLayout()'),
          isTrue);
      // The toolbar hit-tests against the layout it was given; if it grew its
      // own dip constants the two toolbars could disagree about where a button
      // is, which is exactly the class of bug that makes a click land on the
      // wrong function.
      expect(toolbar.contains('layout_.button_px'), isTrue);
      expect(toolbar.contains('kButtonSizeDip'), isFalse);
      expect(toolbar.contains('kControlsTopDip'), isFalse);
    });

    test('the in-body toolbar is not painted while the body is click-through',
        () {
      // Tightened from `!(hook_text_mode_ && pass_through_)`: the hook-text
      // overlay now always uses the standalone pill window, click-through or
      // not, so the body paints no buttons at all in that mode.
      expect(
          body.contains('const bool draw_body_toolbar = !hook_text_mode_;'),
          isTrue,
          reason: 'Two toolbars drawn at the same spot, one of them dead, is '
              'the UI lie this design exists to remove.');
    });
  });

  test('the new translation unit is actually built', () {
    expect(cmake.contains('"hook_toolbar_window.cpp"'), isTrue,
        reason: 'A file missing from CMakeLists silently never ships.');
  });

  group('BUG-1926 · 移动正文窗只有一条原语，顶栏不可能掉队', () {
    // 用户报的是「按住浮窗的文字拖，窗跟着动了，顶栏没跟上」。
    //
    // 穿透态下顶栏是**另一个顶层窗口**（正文窗必须整窗 click-through，单窗做不到
    // 「正文穿透、顶栏可点」），它的位置由正文窗单向下推。而唯一的下推入口
    // SyncPassThroughToolbar 从前只挂在 Render() 末尾 —— 拖窗分支自己裸调
    // SetWindowPos 之后直接 return 0，而 layered 窗的 SWP_NOSIZE 移动既不产生
    // WM_PAINT 也不产生 WM_SIZE，HandleMessage 里也没有 WM_MOVE 分支，于是整个
    // 拖动过程一次 Render 都不发生，顶栏原地不动，直到下一句台词才瞬移过去。
    //
    // 必须剥注释：上面这段说明和 C++ 里的修复注释都写了 SetWindowPos / MoveBodyTo，
    // 裸 indexOf 会先命中注释里那一份，守卫恒绿。
    late String masked;
    setUpAll(() => masked = maskComments(body));

    test('MoveBodyTo 是那条原语：钳制 + 顶栏同步都在里面', () {
      final String moveBody =
          functionBody(masked, 'void FloatingLyricWindow::MoveBodyTo(int x, int y)');
      expect(moveBody.contains('SyncPassThroughToolbar();'), isTrue,
          reason: '移动正文窗后不同步顶栏，两个窗就会漂开。');
      expect(moveBody.contains('ClampOriginToWorkArea('), isTrue,
          reason: 'TODO-832 的工作区钳制也归这条原语，不该再被抄一份出去。');
    });

    test('拖正文的分支走 MoveBodyTo，不再自己裸 SetWindowPos', () {
      final String dragBranch = functionBody(masked, 'if (dragging_)');
      expect(dragBranch.contains('MoveBodyTo('), isTrue,
          reason: '拖窗必须复用同一条原语，否则收尾的顶栏同步又会被抄漏。');
      expect(dragBranch.contains('SetWindowPos('), isFalse,
          reason: '裸 SetWindowPos 正是让顶栏掉队的那行 —— 它绕过了同步漏斗。');
    });

    test('WM_EXITSIZEMOVE 的边界钳制同样要把顶栏带上', () {
      expect(
          functionBody(masked,
                  'void FloatingLyricWindow::ClampCurrentPositionToWindowMonitor()')
              .contains('SyncPassThroughToolbar();'),
          isTrue,
          reason: '「凡是挪了正文窗的地方都同步顶栏」必须是个不变式，'
              '而不是逐个调用点各记各的。');
    });
  });
}
