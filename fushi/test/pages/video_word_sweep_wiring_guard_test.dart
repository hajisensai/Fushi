import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 视频暂停句「整句扫词」的接线守卫（源码扫描型）。
///
/// 这里守的是几条**行为读不出来、但坏掉会静默失效**的不变式：
///
/// 1. **单一派发点**：键盘 / 手柄 / 鼠标 / 浮层回传 token 四条通道都经
///    `_runWordSweepAction` 派发，执行体 `_sweepSubtitleWord` 只在它里面被调用——
///    各通道各写一份 `if (action == …)` 就是「某条通道漏接 / 绑到鼠标侧键无反应」的起点。
/// 2. **手柄调度序**：`tryDictionaryPopupGamepadButton`（浮层自己的键：翻词条 / 制卡 /
///    发音）< 扫词 < `_dismissTopVisiblePopup()`（已绑键先关浮层）。扫词排到关浮层之后
///    = 按一次只关浮层、推不动下一词；排到浮层键之前 = 用户把扫词绑到 X/Y/方向上下时
///    静默抢走浮层动作。所有单测仍然全绿（它们不经过页面派发）。
/// 3. **键盘解析同步放行**：`resolveVideoKeyboardShortcut` 里必须先放行扫词动作。
/// 4. **鼠标两半都接上**：浮层不可见时走 `_handleVideoPointerDown`（排在 controller
///    门之前）；浮层可见时指针被 barrier / 浮层吃掉，走 `onDictionaryPopupInputToken`
///    （排在「任一键先关浮层」之前）。
/// 5. **与字级光标互斥**：扫词执行体开头必须早退于 `_videoCaretActive`，且绝不触碰
///    光标状态机——扫词的全部价值就是「不进模态」，一旦耦合回模态，X 制卡又会不可达。
void main() {
  final String page = File(
    'lib/src/pages/implementations/video_fushi_page.dart',
  ).readAsStringSync();
  final String part = File(
    'lib/src/pages/implementations/video_fushi/word_sweep.part.dart',
  ).readAsStringSync();
  final String shortcuts = File(
    'lib/src/media/video/video_player_shortcuts.dart',
  ).readAsStringSync();

  const String dispatch = '_runWordSweepAction(';

  test('扫描规模哨兵：三份被扫描的源码都在（路径改名会让下面全绿）', () {
    expect(
      page.length,
      greaterThan(200000),
      reason: 'video_fushi_page.dart 未读到',
    );
    expect(part.length, greaterThan(1000), reason: 'word_sweep.part.dart 未读到');
    expect(
      shortcuts.length,
      greaterThan(10000),
      reason: 'video_player_shortcuts.dart 未读到',
    );
  });

  test('单一派发点：两个扫词动作都在 _runWordSweepAction 里接到同一执行体', () {
    final String body = maskComments(
      methodBody(part, 'bool _runWordSweepAction('),
    );
    expect(body.contains('ShortcutAction.videoLookupNextWord'), isTrue);
    expect(body.contains('ShortcutAction.videoLookupPrevWord'), isTrue);
    expect(
      RegExp(r'_sweepSubtitleWord\(').allMatches(body).length,
      2,
      reason: '上 / 下一词都调同一个执行体',
    );
    expect(
      maskComments(page).contains('_sweepSubtitleWord('),
      isFalse,
      reason: '页面各通道只能经 _runWordSweepAction 派发，不得直调执行体',
    );
  });

  test('手柄：浮层键 < 扫词 < 已绑键先关浮层', () {
    final String body = maskComments(
      methodBody(page, 'bool _handleVideoGamepadButton('),
    );
    final int popupKeys = body.indexOf('tryDictionaryPopupGamepadButton(');
    final int sweep = body.indexOf(dispatch);
    final int dismiss = body.indexOf('_dismissTopVisiblePopup()');
    expect(popupKeys, greaterThanOrEqualTo(0), reason: '浮层自己的键必须先处理');
    expect(sweep, greaterThanOrEqualTo(0), reason: '手柄通道必须接上扫词');
    expect(dismiss, greaterThanOrEqualTo(0));
    expect(
      sweep,
      greaterThan(popupKeys),
      reason: '扫词排在浮层键之前 = 绑到 X/Y/方向上下时静默抢走制卡 / 发音 / 翻词条',
    );
    expect(
      dismiss,
      greaterThan(sweep),
      reason: '扫词必须排在「已绑键先关浮层」之前，否则按一次只关浮层、推不动下一词',
    );
  });

  test('键盘通道经同一派发点', () {
    final String body = maskComments(
      methodBody(page, 'bool _handleVideoKeyboardShortcut('),
    );
    expect(body.contains(dispatch), isTrue);
  });

  test('鼠标（浮层不可见）：_handleVideoPointerDown 在 controller 门之前派发扫词', () {
    final String body = maskComments(
      methodBody(page, 'void _handleVideoPointerDown('),
    );
    final int sweep = body.indexOf(dispatch);
    final int controllerGate = body.indexOf('if (controller == null)');
    expect(sweep, greaterThanOrEqualTo(0), reason: '侧键绑扫词必须有执行体');
    expect(
      controllerGate,
      greaterThan(sweep),
      reason: '扫词不依赖播放器，不能被 controller 门挡掉',
    );
  });

  test('浮层回传 token（浮层持焦键盘 / 浮层上鼠标）：扫词排在关浮层之前', () {
    final String body = maskComments(
      methodBody(page, 'bool onDictionaryPopupInputToken('),
    );
    final int caret = body.indexOf('_handleCaretPopupInputToken(');
    final int sweep = body.indexOf(dispatch);
    final int dismiss = body.indexOf('_dismissTopVisiblePopup()');
    expect(sweep, greaterThanOrEqualTo(0));
    expect(sweep, greaterThan(caret), reason: '光标激活期仍由光标语义先接管');
    expect(dismiss, greaterThan(sweep), reason: '否则浮层一持焦，扫词键就退化成「关浮层」');
  });

  test('键盘解析：扫词动作绕开「浮层可见 → 先关浮层」', () {
    final String code = maskComments(
      methodBody(
        shortcuts,
        'VideoKeyboardResolution resolveVideoKeyboardShortcut(',
      ),
    );
    final int carveOut = code.indexOf('ShortcutAction.videoLookupNextWord');
    final int dismissGuard = code.indexOf(
      'if (hasVisiblePopup) return VideoKeyboardResolution.dismissPopup;',
    );
    expect(
      carveOut,
      greaterThanOrEqualTo(0),
      reason: 'resolveVideoKeyboardShortcut 必须显式放行扫词动作',
    );
    expect(
      dismissGuard,
      greaterThan(carveOut),
      reason: '放行必须排在 dismissPopup 守卫之前，否则键盘通道重演同一失效形态',
    );
  });

  test('扫词与字级光标互斥：执行体开头早退于 _videoCaretActive', () {
    expect(
      containsCodeLine(part, 'if (_videoCaretActive) return;'),
      isTrue,
      reason: '扫词执行体必须与 caret 互斥',
    );
  });

  test('扫词复用点击查词链路，不碰光标状态机', () {
    expect(
      containsCodeLine(part, '_handleSubtitleLookupTap('),
      isTrue,
      reason: '扫词必须复用既有查词链路，不得另起第二条查词路径',
    );
    expect(
      containsCodeLine(part, 'resolveSubtitleSweepStop('),
      isTrue,
      reason: '落点必须走纯函数（跳过整词无可查字的词、最多一圈），不得在页面里另写',
    );
    for (final String forbidden in <String>[
      '_enterSubtitleCaret(',
      '_exitSubtitleCaret(',
      '_runVideoCaretAction(',
      'DictionaryCaretController',
    ]) {
      expect(
        containsIdentifier(part, forbidden.replaceAll('(', '')),
        isFalse,
        reason:
            '扫词执行体不得触碰光标状态机（$forbidden）——耦合回模态后 '
            'X 制卡又会不可达',
      );
    }
  });
}
