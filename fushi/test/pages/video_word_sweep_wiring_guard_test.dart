import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 视频暂停句「整句扫词」的接线守卫（源码扫描型）。
///
/// 这里守的是三条**行为读不出来、但坏掉会静默失效**的不变式：
///
/// 1. **R1 调度序**：扫词分支必须排在 `_handleVideoGamepadButton` 的
///    `if (_hasVisiblePopup)`「已绑键先关浮层」守卫**之前**。扫词每停一词都会弹/换
///    同一张浮层，浮层恒可见；排到守卫之后就会变成「按一次只关浮层、推不动下一
///    词」——功能整个失效，而所有单测仍然全绿（它们不经过页面派发）。
/// 2. **键盘通道同步放行**：`resolveVideoKeyboardShortcut` 里必须先放行扫词动作，
///    否则键盘通道重演同一个失效形态。
/// 3. **与字级光标互斥**：扫词执行体开头必须早退于 `_videoCaretActive`，且绝不触碰
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

  test('R1：手柄通道的扫词分支排在 _hasVisiblePopup 守卫之前', () {
    final String body = maskComments(
      methodBody(page, 'bool _handleVideoGamepadButton('),
    );
    final int sweepNext = body.indexOf('ShortcutAction.videoLookupNextWord');
    final int sweepPrev = body.indexOf('ShortcutAction.videoLookupPrevWord');
    final int dismissGuard = body.indexOf('if (_hasVisiblePopup)');
    expect(
      sweepNext,
      greaterThanOrEqualTo(0),
      reason: '手柄通道必须接上 videoLookupNextWord',
    );
    expect(
      sweepPrev,
      greaterThanOrEqualTo(0),
      reason: '手柄通道必须接上 videoLookupPrevWord',
    );
    expect(
      dismissGuard,
      greaterThan(sweepNext),
      reason:
          '扫词分支必须排在「已绑键先关浮层」之前，否则按一次只关浮层、'
          '推不动下一词（R1）',
    );
    expect(dismissGuard, greaterThan(sweepPrev), reason: '同上（上一词分支）');
  });

  test('键盘通道也接上扫词，且共用同一执行体', () {
    final String body = maskComments(
      methodBody(page, 'bool _handleVideoKeyboardShortcut('),
    );
    expect(body.contains('ShortcutAction.videoLookupNextWord'), isTrue);
    expect(body.contains('ShortcutAction.videoLookupPrevWord'), isTrue);
    expect(
      body.contains('_sweepSubtitleWord('),
      isTrue,
      reason: '两条通道必须调同一个执行体，不得各写一套',
    );
  });

  test('键盘解析：扫词动作绕开「浮层可见 → 先关浮层」', () {
    final String code = maskComments(shortcuts);
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
      reason: '放行必须排在 dismissPopup 守卫之前，否则键盘通道重演 R1 失效',
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
