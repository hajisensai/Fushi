import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

class ShortcutDefaults {
  ShortcutDefaults._();

  static Map<ShortcutAction, ShortcutBindingSet> forPlatform(
    TargetPlatform platform,
  ) {
    switch (platform) {
      case TargetPlatform.macOS:
        return _macOS;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return _mobile;
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return _desktop;
    }
  }

  static ShortcutBindingSet _kb(
    List<InputBinding> keyboard, [
    List<GamepadBinding> gamepad = const [],
  ]) =>
      ShortcutBindingSet(
        keyboardBindings: keyboard,
        gamepadBindings: gamepad,
      );

  static InputBinding _key(LogicalKeyboardKey key,
          [Set<ModifierKey> modifiers = const {}]) =>
      InputBinding(key: key, modifiers: modifiers);

  static const _gRB = GamepadBinding(GamepadButton.rb);
  static const _gLB = GamepadBinding(GamepadButton.lb);
  static const _gLT = GamepadBinding(GamepadButton.lt);
  static const _gRT = GamepadBinding(GamepadButton.rt);
  static const _gB = GamepadBinding(GamepadButton.b);
  static const _gX = GamepadBinding(GamepadButton.x);
  static const _gY = GamepadBinding(GamepadButton.y);
  static const _gDpadRight = GamepadBinding(GamepadButton.dpadRight);
  static const _gDpadLeft = GamepadBinding(GamepadButton.dpadLeft);
  static const _gL3 = GamepadBinding(GamepadButton.thumbLeft);
  static const _gR3 = GamepadBinding(GamepadButton.thumbRight);

  static final Map<ShortcutAction, ShortcutBindingSet> _desktop = {
    ShortcutAction.readerPageForward: _kb([
      _key(LogicalKeyboardKey.pageDown),
      _key(LogicalKeyboardKey.arrowRight),
      _key(LogicalKeyboardKey.arrowDown),
      _key(LogicalKeyboardKey.space),
    ], [
      _gRB,
      _gDpadRight
    ]),
    ShortcutAction.readerPageBackward: _kb([
      _key(LogicalKeyboardKey.pageUp),
      _key(LogicalKeyboardKey.arrowLeft),
      _key(LogicalKeyboardKey.arrowUp),
      _key(LogicalKeyboardKey.space, {ModifierKey.shift}),
    ], [
      _gLB,
      _gDpadLeft
    ]),
    // 底栏开关只负责「打开/切换」底栏，键盘走 M（Esc 已让位给 readerDismissDict
    // 的「返回」语义，见下）；手柄走 Y。Esc 不再绑这里，避免与 readerDismissDict
    // 双绑同一键、被枚举顺序抢成「切底栏」而永远退不出书。
    ShortcutAction.readerToggleChrome: _kb([
      _key(LogicalKeyboardKey.keyM),
    ], [
      _gY
    ]),
    // 阅读器内的「返回」键：有词典弹窗就关弹窗，否则直接退出书籍（执行体见
    // reader_hibiki_page 的 _executeShortcutAction）。键盘 Esc、手柄 B，与桌面
    // 「Esc=上一级」直觉一致；绝不切换底栏。
    ShortcutAction.readerDismissDict: _kb([
      _key(LogicalKeyboardKey.escape),
    ], [
      _gB
    ]),
    ShortcutAction.readerToggleBookmark: _kb([
      _key(LogicalKeyboardKey.keyD, {ModifierKey.ctrl}),
    ], [
      _gX
    ]),
    // R3 toggles furigana (gamepad-only; keyboard furigana stays in settings).
    ShortcutAction.readerToggleFurigana: _kb([], [_gR3]),
    // Reader lookup/card actions now live in the remappable registry instead
    // of being only hard-wired in the page. Enter/A keep the old "activate at
    // cursor" feel; Shift+Enter is an explicit plain lookup; Ctrl+Enter mines
    // the top dictionary popup entry when one is visible.
    ShortcutAction.readerLookupAtCursor: _kb([
      _key(LogicalKeyboardKey.enter),
    ], [
      GamepadBinding(GamepadButton.a),
    ]),
    ShortcutAction.readerShiftLookup: _kb([
      _key(LogicalKeyboardKey.enter, {ModifierKey.shift}),
    ]),
    ShortcutAction.readerCreateCardFromPopup: _kb([
      _key(LogicalKeyboardKey.enter, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.homeTabBooks: _kb([
      _key(LogicalKeyboardKey.digit1, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.homeTabDict: _kb([
      _key(LogicalKeyboardKey.digit2, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.homeTabSettings: _kb([
      _key(LogicalKeyboardKey.digit3, {ModifierKey.ctrl}),
    ]),
    // LT/RT cycle the three home tabs (prev/next), per the global key map.
    // Keyboard stays on Ctrl+1/2/3 absolute jumps above.
    ShortcutAction.homeTabPrev: _kb([], [_gLT]),
    ShortcutAction.homeTabNext: _kb([], [_gRT]),
    ShortcutAction.homeFocusSearch: _kb([
      _key(LogicalKeyboardKey.keyF, {ModifierKey.ctrl}),
    ], [
      _gY
    ]),
    ShortcutAction.globalBack: _kb([
      _key(LogicalKeyboardKey.arrowLeft, {ModifierKey.alt}),
    ]),
    // LB/RB = 整页翻屏（gamepad-only；键盘留空，避免与 reader PageDown 在不同
    // scope 的重复语义）。global scope，对所有非阅读器页通用；reader 页只解析
    // reader+audiobook，不会被遮蔽。执行体见 wrapWithGlobalNavigation。
    ShortcutAction.globalScrollPageDown: _kb([], [_gRB]),
    ShortcutAction.globalScrollPageUp: _kb([], [_gLB]),
    // Play/pause moved off controller A → L3: on the reader page A is now
    // "enter the char-level reading cursor" (and, once inside, "look up the word
    // at the cursor"), which the page intercepts before the audiobook scope is
    // consulted. Keeping A here would be a permanently shadowed binding. Keyboard
    // stays on Ctrl+Space.
    ShortcutAction.audiobookPlayPause: _kb([
      _key(LogicalKeyboardKey.space, {ModifierKey.ctrl}),
    ], [
      _gL3
    ]),
    // No gamepad default: RB/LB are already reader page-turn, and the reader
    // page resolves the reader scope before audiobook, so an RB/LB binding here
    // would be permanently shadowed (never fire). Sentence navigation stays on
    // the keyboard Ctrl+Arrow bindings. Same philosophy as globalBack leaving
    // its gamepad empty to avoid a shadowed/double-trigger binding.
    ShortcutAction.audiobookNextSentence: _kb([
      _key(LogicalKeyboardKey.arrowRight, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.audiobookPrevSentence: _kb([
      _key(LogicalKeyboardKey.arrowLeft, {ModifierKey.ctrl}),
    ]),
    // 中键点句 → 跳到该句并播放。鼠标键是位置型动作，运行时不走
    // _executeShortcutAction，而是 onPointerSeek 经 resolveMouse 判定后定位执行。
    ShortcutAction.audiobookSeekToClickedSentence: const ShortcutBindingSet(
      mouseBindings: [MouseBinding(1)],
    ),
    // Video player defaults (TODO-134). Mirror the previous hard-coded
    // buildVideoPlayerShortcuts map exactly so migrating into the registry does
    // not change any default behaviour (Never break userspace). The video page
    // resolves only the video scope, so there is no cross-scope shadowing here.
    ShortcutAction.videoTogglePlayPause: _kb([
      _key(LogicalKeyboardKey.space),
      _key(LogicalKeyboardKey.keyP),
      _key(LogicalKeyboardKey.mediaPlayPause),
    ]),
    ShortcutAction.videoPlay: _kb([
      _key(LogicalKeyboardKey.mediaPlay),
    ]),
    ShortcutAction.videoPause: _kb([
      _key(LogicalKeyboardKey.mediaPause),
    ]),
    // Ctrl+Arrow = previous/next subtitle sentence (asbplayer style); bare
    // arrows are time seek below.
    ShortcutAction.videoPreviousSubtitle: _kb([
      _key(LogicalKeyboardKey.arrowLeft, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.videoNextSubtitle: _kb([
      _key(LogicalKeyboardKey.arrowRight, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.videoSeekBackward: _kb([
      _key(LogicalKeyboardKey.arrowLeft),
      _key(LogicalKeyboardKey.keyA),
      _key(LogicalKeyboardKey.keyJ),
    ]),
    ShortcutAction.videoSeekForward: _kb([
      _key(LogicalKeyboardKey.arrowRight),
      _key(LogicalKeyboardKey.keyD),
      _key(LogicalKeyboardKey.keyI),
      _key(LogicalKeyboardKey.keyF, {ModifierKey.shift}),
    ]),
    ShortcutAction.videoToggleShaderCompare: _kb([
      _key(LogicalKeyboardKey.keyC),
    ]),
    ShortcutAction.videoVolumeUp: _kb([
      _key(LogicalKeyboardKey.arrowUp),
      _key(LogicalKeyboardKey.digit0),
    ]),
    ShortcutAction.videoVolumeDown: _kb([
      _key(LogicalKeyboardKey.arrowDown),
      _key(LogicalKeyboardKey.digit9),
    ]),
    ShortcutAction.videoToggleMute: _kb([
      _key(LogicalKeyboardKey.keyM),
    ]),
    ShortcutAction.videoSpeedUp: _kb([
      _key(LogicalKeyboardKey.bracketRight),
      _key(LogicalKeyboardKey.equal),
    ]),
    ShortcutAction.videoSpeedDown: _kb([
      _key(LogicalKeyboardKey.bracketLeft),
      _key(LogicalKeyboardKey.minus),
    ]),
    ShortcutAction.videoResetSpeed: _kb([
      _key(LogicalKeyboardKey.backspace),
    ]),
    ShortcutAction.videoPreviousFrame: _kb([
      _key(LogicalKeyboardKey.comma),
    ]),
    ShortcutAction.videoNextFrame: _kb([
      _key(LogicalKeyboardKey.period),
    ]),
    ShortcutAction.videoScreenshot: _kb([
      _key(LogicalKeyboardKey.keyS),
    ]),
    ShortcutAction.videoToggleFullscreen: _kb([
      _key(LogicalKeyboardKey.keyF),
      _key(LogicalKeyboardKey.f12),
    ]),
    ShortcutAction.videoToggleSubtitleList: _kb([
      _key(LogicalKeyboardKey.keyL),
    ]),
    ShortcutAction.videoToggleImmersiveLock: _kb([
      _key(LogicalKeyboardKey.keyL, {ModifierKey.shift}),
    ]),
    ShortcutAction.videoToggleSubtitleBlur: _kb([
      _key(LogicalKeyboardKey.keyB),
    ]),
    ShortcutAction.videoToggleFavoriteSentence: _kb([
      _key(LogicalKeyboardKey.keyD, {ModifierKey.ctrl}),
    ]),
    ShortcutAction.videoReplayCurrentSubtitle: _kb([
      _key(LogicalKeyboardKey.keyR),
    ]),
    // 重播上一句（TODO-378，BUG-287）：Shift+R，纯句子后退到上一条 cue 起点（不退化）。
    ShortcutAction.videoReplayPreviousSubtitle: _kb([
      _key(LogicalKeyboardKey.keyR, {ModifierKey.shift}),
    ]),
    // 内封章节上/下一章（TODO-424）：PageUp / PageDown。video 是独立 co-active 组，
    // 与 reader 的 PageUp/PageDown 不冲突（不同页面绝不同时激活）。
    ShortcutAction.videoPreviousChapter: _kb([
      _key(LogicalKeyboardKey.pageUp),
    ]),
    ShortcutAction.videoNextChapter: _kb([
      _key(LogicalKeyboardKey.pageDown),
    ]),
    ShortcutAction.videoEscape: _kb([
      _key(LogicalKeyboardKey.escape),
    ]),
  };

  static final Map<ShortcutAction, ShortcutBindingSet> _macOS = {
    for (final entry in _desktop.entries)
      entry.key: ShortcutBindingSet(
        keyboardBindings: entry.value.keyboardBindings.map((b) {
          if (b.modifiers.contains(ModifierKey.ctrl)) {
            final newMods = Set<ModifierKey>.of(b.modifiers)
              ..remove(ModifierKey.ctrl)
              ..add(ModifierKey.meta);
            return InputBinding(key: b.key, modifiers: newMods);
          }
          return b;
        }).toList(growable: false),
        gamepadBindings: entry.value.gamepadBindings,
        mouseBindings: entry.value.mouseBindings,
      ),
  };

  static final Map<ShortcutAction, ShortcutBindingSet> _mobile = {
    for (final action in ShortcutAction.values)
      action: () {
        final desktop = _desktop[action]!;
        switch (action.scope) {
          case ShortcutScope.reader:
          case ShortcutScope.video:
            return ShortcutBindingSet(
              keyboardBindings: desktop.keyboardBindings,
              gamepadBindings: desktop.gamepadBindings,
            );
          case ShortcutScope.audiobook:
            return ShortcutBindingSet(
              gamepadBindings: desktop.gamepadBindings,
              // Android 可接鼠标，保留中键 seek 绑定（移动端无害）。
              mouseBindings: desktop.mouseBindings,
            );
          case ShortcutScope.home:
          case ShortcutScope.global:
            return ShortcutBindingSet(
              gamepadBindings: desktop.gamepadBindings,
            );
        }
      }(),
  };
}
