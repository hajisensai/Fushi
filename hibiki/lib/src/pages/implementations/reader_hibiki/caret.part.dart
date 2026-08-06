// GENERATED-NOTE: extracted from reader_hibiki_page.dart (TODO-589 batch6).
part of '../reader_hibiki_page.dart';

/// caret domain (keyboard / gamepad / shortcut key navigation + char-level
/// reading cursor: enter / exit / move / scroll-page / activate / lookup /
/// long-press / jump-dict / reanchor / refresh / chrome+header promotion)
/// extracted via part-of (TODO-589 batch6); shared private scope.
/// Behaviour-preserving: bodies are byte-for-byte verbatim except the three
/// `setState(` calls (in `_enterCaret` x2 and `_exitCaret`) forwarded through
/// the main shell `_rebuild(` helper (extensions cannot call the @protected
/// `State.setState` directly), plus the @protected popup-stack members
/// `topPopupState` / `topVisiblePopupIndex` / `dismissTopPopup` (same
/// invalid_use_of_protected_member restriction) routed through the shell
/// forwarders `_caretTopPopupState` / `_caretTopVisiblePopupIndex` /
/// `_caretDismissTopPopup`. The two class statics moved with this domain
/// (`_isReaderDirectCaretShortcut` / `_isRepeatableCaretMove`) and all of
/// their call sites live entirely inside this extension, so they are declared
/// as extension statics and referenced by bare name (no qualification needed).
///
/// The `@override` host-interface members (`onDictionaryStackChanged` /
/// `onDictionaryPopupRendered` and the `DictionaryCaretHost` getters/setters
/// `caretHostMounted` / `caretTopPopupState` / `caretTopVisiblePopupIndex` /
/// `caretSetState` / `caretExitPrimaryRing`) cannot live on an extension and
/// stay in the shell, reachable via the shared private class scope, as does
/// the audiobook middle-click helper `_seekToClickedSentence`.
extension _ReaderCaret on _ReaderHibikiPageState {
  /// 当前按下的修饰键集合（Ctrl/Shift/Alt/Meta）。键盘快捷解析与底栏焦点的
  /// Space 覆写共用，避免两处各自重建一份。
  /// 实现已抽到 [activeModifierKeys]（漫画页也要同一份，各自重建必漂）；
  /// 这里保留同名转发，避免改动本 part 里十余处调用点。
  Set<ModifierKey> _activeModifiers() => activeModifierKeys();

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // The popup header toolbar (sibling of the popup content). Down returns to
    // the content caret; B/Escape dismiss the popup (ascend out of it). Left/
    // Right/Enter fall through to the framework so the buttons traverse and
    // activate natively (the global HibikiFocusRing rings the focused one).
    if (_popupHeaderScope.hasFocus) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _returnToPopupContent();
        return KeyEventResult.handled;
      }
      // The header is the TOP of the popup — nothing is above it. Consume Up so
      // focus stays on the header instead of the directional fallback wrapping
      // to another button (or, in any scope edge case, escaping and stranding
      // the hidden caret). Mirrors the bottom bar handling its Up explicitly.
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.gameButtonB ||
          event.logicalKey == LogicalKeyboardKey.escape) {
        unawaited(_caretDismissOrExit()); // popup surface → dismissTopPopup()
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // TODO-700 T8: the bottom chrome bar is excluded from focus traversal
    // (ExcludeFocus in [_buildAudiobookBar]/[_buildSettingsBar]), so
    // `_chromeFocusScope.hasFocus` is permanently false and the old
    // chrome-focus key branch is unreachable. Focus stays on the reading
    // content, so Up/B/Escape and the BUG-204 bare-Space audiobook override are
    // all handled below by the normal content path (see [resolveReaderSpaceOverride]).

    final KeyEventResult? gamepadAResult =
        _focusNavEnabled ? _handleGamepadAKeyEvent(event) : null;
    if (gamepadAResult != null) return gamepadAResult;

    // Holding an arrow (or Tab) while the char cursor is active steps the cursor
    // continuously: the OS auto-repeat (KeyRepeatEvent) drives the SAME caret
    // MOVE action as the press edge does below, so the cursor advances per
    // repeat instead of one char per discrete press. Consuming it here also
    // stops the repeat from bubbling to the app-wide wrapper, which would
    // otherwise move FOCUS off the reading content ([_focusNode]) instead of
    // moving the cursor. ONLY movement actions repeat — activate (Enter/A look-
    // up) and dismissOrExit (Esc/B) must fire once per press, never on auto-
    // repeat, or a held Enter/Esc would re-look-up / re-exit every frame.
    if (_focusNavEnabled && _caretActive && event is KeyRepeatEvent) {
      final CaretAction? repeatCaret = ReaderCaretRouter.decideKeyboard(
        event.logicalKey,
        shift: HardwareKeyboard.instance.isShiftPressed,
      );
      if (repeatCaret != null && _isRepeatableCaretMove(repeatCaret)) {
        unawaited(_runCaretAction(repeatCaret));
        return KeyEventResult.handled;
      }
    }

    // TODO-1370：长按方向键连续切句。按住一个绑定到「可重复」阅读器/有声书动作
    // （翻页 或 有声书上一句/下一句）的键时，OS 自动重复的 [KeyRepeatEvent] 继续
    // 触发同一动作，使长按连续前进/切句，而不是一次按下只走一步——与视频播放器
    // （`SingleActivator(includeRepeats: true)`）、上面的字符光标重复、手柄 D-pad
    // 长按（[GamepadFrameProcessor] 自动重复）对齐。只放行移动类动作
    // （[isRepeatableReaderKeyboardShortcut]）；离散动作（查词/书签/关词典/播放暂停）
    // 仍一次一按。仅键盘：原生手柄键（含 Android D-pad 的 KeyRepeat）保持按下沿路由
    // （KeyDown 走 [_handleGamepadButton]）；字符光标激活时它自己的重复已在上面处理。
    // 必须落在 KeyDown-only 闸门之前，否则闸门会先把 KeyRepeat 拦掉。
    if (event is KeyRepeatEvent) {
      if (_focusNavEnabled && _caretActive) return KeyEventResult.ignored;
      if (GamepadButton.fromKeyEvent(event) != null) {
        return KeyEventResult.ignored;
      }
      final Set<ModifierKey> repeatModifiers = _activeModifiers();
      final PhysicalKeyboardKey? repeatImePhysicalKey =
          focusedEditableText() == null ? event.physicalKey : null;
      final ShortcutAction? repeatDirectReaderAction =
          appModel.shortcutRegistry.resolveKeyboard(
        event.logicalKey,
        modifiers: repeatModifiers,
        scope: ShortcutScope.reader,
        physicalKey: repeatImePhysicalKey,
      );
      final ShortcutAction? repeatAction = _resolveReaderKeyboardShortcut(
        event,
        modifiers: repeatModifiers,
        directReaderAction: repeatDirectReaderAction,
        imeFallbackPhysicalKey: repeatImePhysicalKey,
      );
      if (repeatAction != null &&
          isRepeatableReaderKeyboardShortcut(repeatAction)) {
        return _executeShortcutAction(
          repeatAction,
          keyboardTriggerKey: event.logicalKey,
        );
      }
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final Set<ModifierKey> modifiers = _activeModifiers();

    // BUG-402：桌面 Windows 阅读器复制兼容层。Windows WebView2 合成模式下 fork 只
    // 转发鼠标不转发键盘，Ctrl+C 到不了 WebView2 触发不了原生 copy；这里在应用层
    // 接管：取浏览器原生选区文本写系统剪贴板。仅 Windows + 纯 Ctrl+C 命中（谓词
    // readerShouldHandleDesktopCopy），其余键/平台一律不进，default 行为不变。
    if (readerShouldHandleDesktopCopy(
      key: event.logicalKey,
      modifiers: modifiers,
      isWindows: isWindowsPlatform,
    )) {
      // 已确认是 Windows 纯 Ctrl+C（我们专属的手势），且有 WebView：接管这条
      // 复制路径并吞键。空选区在 _copyNativeSelectionToClipboard 内静默跳过
      // （不覆盖剪贴板），但仍吞键——Windows 阅读器 Ctrl+C 没有其它合法语义。
      // 无 WebView 时不吞键，交回默认解析（不存在的边界情况下也不破坏行为）。
      if (_controller != null) {
        unawaited(_copyNativeSelectionToClipboard());
        return KeyEventResult.handled;
      }
    }

    // Android/native controller events can surface as KeyEvents. D-pad arrows
    // share logical keys with keyboard arrows, so controller-like sources must
    // enter the gamepad registry before keyboard arrow reversal runs.
    final GamepadButton? nativeGamepadButton =
        GamepadButton.fromKeyEvent(event);
    if (nativeGamepadButton != null) {
      return _handleGamepadButton(nativeGamepadButton)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    // TODO-847: IME 激活时 logicalKey 被改写成 process，传 physicalKey 让 registry
    // 走物理键回退；文本框 composing 时（focusedEditableText != null）传 null 关闭
    // 回退，避免 IME 打字误触快捷键。
    final PhysicalKeyboardKey? imeFallbackPhysicalKey =
        focusedEditableText() == null ? event.physicalKey : null;
    final ShortcutAction? directReaderAction =
        appModel.shortcutRegistry.resolveKeyboard(
      event.logicalKey,
      modifiers: modifiers,
      scope: ShortcutScope.reader,
      physicalKey: imeFallbackPhysicalKey,
    );

    // Char-level reading cursor (book has focus; chrome already returned above).
    // While active, the cursor owns Tab / arrows / A(Enter) / B(Esc) before the
    // registry is consulted. While inactive, A / Enter ENTER the cursor.
    if (_focusNavEnabled && _caretActive) {
      if (_isReaderDirectCaretShortcut(directReaderAction)) {
        return _executeShortcutAction(
          directReaderAction!,
          keyboardTriggerKey: event.logicalKey,
        );
      }
      final CaretAction? caretAction = ReaderCaretRouter.decideKeyboard(
        event.logicalKey,
        shift: HardwareKeyboard.instance.isShiftPressed,
      );
      if (caretAction != null) {
        unawaited(_runCaretAction(caretAction));
        return KeyEventResult.handled;
      }
    } else if (_isReaderDirectCaretShortcut(directReaderAction)) {
      return _executeShortcutAction(
        directReaderAction!,
        keyboardTriggerKey: event.logicalKey,
      );
    }

    // TODO-700 T8: the bottom bar is excluded from focus traversal, so arrow
    // Down no longer routes focus into the chrome (the old BUG-020 keyboard
    // chrome route is gone). Down falls through to normal shortcut resolution
    // below; the bar is reached by touch/mouse, never by directional keys.

    final ShortcutAction? action = _resolveReaderKeyboardShortcut(
      event,
      modifiers: modifiers,
      directReaderAction: directReaderAction,
      imeFallbackPhysicalKey: imeFallbackPhysicalKey,
    );
    if (action == null) return KeyEventResult.ignored;
    return _executeShortcutAction(
      action,
      keyboardTriggerKey: event.logicalKey,
    );
  }

  /// 把键盘 [event] 解析成它触发的阅读器/有声书 [ShortcutAction]，套用有声书裸
  /// Space 覆写、RTL/reverse 方向键翻页覆写，以及 reader→audiobook 作用域回退。由
  /// 按下沿（[KeyDownEvent]）与长按（[KeyRepeatEvent]，TODO-1370）两条路径共用，
  /// 保证长按解析出的动作与按下沿完全一致。键未绑定任何 reader/audiobook 动作时返回
  /// null。[directReaderAction] 由调用方预解析（reader scope）后传入，避免重复解析。
  ///
  /// 有声书激活时无修饰 Space 改作播放/暂停（媒体播放器惯例），先于 reader scope 的
  /// 「翻页」解析（否则 Space 被抢成翻页）；BUG-099/TODO-992 裸左右键按阅读方向翻页
  /// 且尊重用户改键。TODO-847：IME 把 logicalKey 改写成 process 时用 physicalKey 回退，
  /// 文本框 composing 时调用方传 null 关闭回退。
  ShortcutAction? _resolveReaderKeyboardShortcut(
    KeyEvent event, {
    required Set<ModifierKey> modifiers,
    required ShortcutAction? directReaderAction,
    required PhysicalKeyboardKey? imeFallbackPhysicalKey,
  }) {
    final ShortcutAction? spaceOverride = resolveReaderSpaceOverride(
      key: event.logicalKey,
      modifiers: modifiers,
      hasActiveAudiobook: _hasActiveAudiobook,
      physicalKey: imeFallbackPhysicalKey,
    );
    final ShortcutAction? bareArrowBinding =
        appModel.shortcutRegistry.resolveKeyboard(
              event.logicalKey,
              modifiers: modifiers,
              scope: ShortcutScope.reader,
              physicalKey: imeFallbackPhysicalKey,
            ) ??
            appModel.shortcutRegistry.resolveKeyboard(
              event.logicalKey,
              modifiers: modifiers,
              scope: ShortcutScope.audiobook,
              physicalKey: imeFallbackPhysicalKey,
            );
    final ShortcutAction? arrowOverride = resolveReaderArrowPageTurn(
      key: event.logicalKey,
      modifiers: modifiers,
      rtl: _isRtlReading,
      boundAction: bareArrowBinding,
      reverse: ReaderHibikiSource.instance.reverseArrowPageTurn,
      physicalKey: imeFallbackPhysicalKey,
    );
    return spaceOverride ??
        arrowOverride ??
        directReaderAction ??
        appModel.shortcutRegistry.resolveKeyboard(
          event.logicalKey,
          modifiers: modifiers,
          scope: ShortcutScope.reader,
          physicalKey: imeFallbackPhysicalKey,
        ) ??
        appModel.shortcutRegistry.resolveKeyboard(
          event.logicalKey,
          modifiers: modifiers,
          scope: ShortcutScope.audiobook,
          physicalKey: imeFallbackPhysicalKey,
        ) ??
        // 最后兜底：universal 的「返回上一级」（默认 Esc / Alt+← / 手柄 B）。
        // 必须排在 reader+audiobook **之后**：页面专属键永远优先，故书内手柄 B
        // 仍是 audiobookPrevSentence（上一句），不被返回夺舍（TODO-700 约束2/4）。
        appModel.shortcutRegistry.resolveKeyboard(
          event.logicalKey,
          modifiers: modifiers,
          scope: ShortcutScope.universal,
          physicalKey: imeFallbackPhysicalKey,
        );
  }

  /// TODO-1078：WebView 内容层捕获的裸 Space（Windows WebView2 抢走 OS 键盘焦点后
  /// _focusNode.onKeyEvent 收不到键，见 [webview.part] 的 `onSpaceKey` 桥）解析成
  /// 阅读器动作。与 [_handleKeyEvent] 的 Space 解析同款语义：有声书激活 →
  /// [ShortcutAction.audiobookPlayPause]（[resolveReaderSpaceOverride]）；否则回落
  /// 到 reader scope 注册表里裸 Space 的真实绑定（默认 [ShortcutAction.readerPageForward]，
  /// 用户改键后跟随其绑定）。返回 null 表示裸 Space 当前无绑定，调用方不执行。
  ShortcutAction? _resolveWebViewSpaceAction() {
    final ShortcutAction? override = resolveReaderSpaceOverride(
      key: LogicalKeyboardKey.space,
      modifiers: const <ModifierKey>{},
      hasActiveAudiobook: _hasActiveAudiobook,
    );
    if (override != null) return override;
    return appModel.shortcutRegistry.resolveKeyboard(
      LogicalKeyboardKey.space,
      modifiers: const <ModifierKey>{},
      scope: ShortcutScope.reader,
    );
  }

  static bool _isReaderDirectCaretShortcut(ShortcutAction? action) {
    switch (action) {
      case ShortcutAction.readerLookupAtCursor:
      case ShortcutAction.readerShiftLookup:
      case ShortcutAction.readerCreateCardFromPopup:
        return true;
      default:
        return false;
    }
  }

  KeyEventResult? _handleGamepadAKeyEvent(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.gameButtonA) return null;
    final ShortcutAction? resolvedAction =
        appModel.shortcutRegistry.resolveGamepad(
      GamepadButton.a,
      scope: ShortcutScope.reader,
    );
    if (resolvedAction != ShortcutAction.readerLookupAtCursor) return null;
    if (event is KeyDownEvent) {
      if (_gamepadAHoldTimer != null) return KeyEventResult.handled;
      _gamepadALongFired = false;
      _gamepadAHoldTimer = Timer(const Duration(milliseconds: 500), () {
        _gamepadAHoldTimer = null;
        _gamepadALongFired = true;
        if (!mounted || !_focusNavEnabled || !_caretActive) return;
        unawaited(_runCaretAction(CaretAction.longPress));
      });
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyUpEvent) {
      final bool longFired = _gamepadALongFired;
      _clearGamepadAHold();
      if (longFired) return KeyEventResult.handled;
      return _executeShortcutAction(
        ShortcutAction.readerLookupAtCursor,
        gamepadTriggerButton: GamepadButton.a,
      );
    }
    return KeyEventResult.handled;
  }

  /// BUG-402：取浏览器原生选区文本（[ReaderSelectionScripts.nativeSelectionText...]）
  /// 写入系统剪贴板。空选区不写（不覆盖剪贴板已有内容）。WebView 半销毁时
  /// evaluateJavascript 会抛 PlatformException，吞掉即可（复制是尽力而为）。
  Future<void> _copyNativeSelectionToClipboard() async {
    final InAppWebViewController? controller = _controller;
    if (controller == null) return;
    Object? raw;
    try {
      raw = await controller.evaluateJavascript(
        source: ReaderSelectionScripts.nativeSelectionTextInvocation(),
      );
    } catch (_) {
      return;
    }
    final String text =
        ReaderSelectionScripts.nativeSelectionTextFromResult(raw);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  void _clearGamepadAHold() {
    _gamepadAHoldTimer?.cancel();
    _gamepadAHoldTimer = null;
    _gamepadALongFired = false;
  }

  /// Handles a gamepad button delivered via [GamepadButtonIntent] (desktop
  /// polled path). Mirrors the gamepad branch of [_handleKeyEvent] so polled
  /// input behaves identically to Android's native gameButton key events.
  /// Returns true when consumed; false lets the GamepadService apply its
  /// directional-focus / activate / global-back fallback.
  bool _handleGamepadButton(GamepadButton button) {
    // Popup header toolbar (sibling of the popup content). Down → content caret;
    // B → dismiss the popup. Left/Right/A fall through (return false) so the
    // GamepadService traverses the buttons and activates the focused one.
    if (_popupHeaderScope.hasFocus) {
      if (button == GamepadButton.dpadDown) {
        _returnToPopupContent();
        return true;
      }
      // Header is the top of the popup — consume Up so focus stays here (don't
      // let the directional fallback in gamepadMoveFocusInDirection wrap to
      // another button or escape the scope and strand the hidden caret).
      if (button == GamepadButton.dpadUp) {
        return true;
      }
      if (button == GamepadButton.b) {
        unawaited(_caretDismissOrExit());
        return true;
      }
      return false;
    }
    // TODO-700 T8: the bottom chrome bar is excluded from focus traversal, so
    // `_chromeFocusScope.hasFocus` is permanently false here too. The old
    // gamepad chrome-focus branch (dpad Up → content, B → exit) is unreachable
    // and removed; focus stays on the reading content.

    // Char-level reading cursor — same contextual routing as the keyboard path.
    if (_focusNavEnabled && _caretActive) {
      // LB/RB flip a whole page on the cursor surface (popup scrolls, paged
      // reader turns) before the directional caret map — the shoulders are not
      // caret-directional, so they would otherwise fall through to the reader
      // scope and never reach the popup WebView.
      if (button == GamepadButton.rb) {
        unawaited(_caretScrollPage(true));
        return true;
      }
      if (button == GamepadButton.lb) {
        unawaited(_caretScrollPage(false));
        return true;
      }
      final CaretAction? caretAction = ReaderCaretRouter.decideGamepad(button);
      if (caretAction != null) {
        unawaited(_runCaretAction(caretAction));
        return true;
      }
    } else if (ReaderCaretRouter.isEnterTriggerGamepad(
      button,
      focusNavEnabled: _focusNavEnabled,
      enterButtons: _readerEnterCaretButtons(),
    )) {
      unawaited(_enterCaret());
      return true;
    }
    // TODO-700 T8: the bottom bar is excluded from focus traversal, so D-pad
    // Down no longer routes focus into the chrome. It falls through to normal
    // gamepad shortcut resolution below; the bar is operated by touch/mouse.
    final ShortcutAction? action = appModel.shortcutRegistry.resolveGamepad(
          button,
          scope: ShortcutScope.reader,
        ) ??
        appModel.shortcutRegistry.resolveGamepad(
          button,
          scope: ShortcutScope.audiobook,
        ) ??
        // 兜底「返回上一级」（universal，默认手柄 B）。排在 reader+audiobook 之后
        // ⇒ 书内 B 仍先命中 audiobookPrevSentence（上一句），不退书；只有用户把
        // B 从上一句上解绑、或把返回改绑到别的键时，这条才会真的接管。
        appModel.shortcutRegistry.resolveGamepad(
          button,
          scope: ShortcutScope.universal,
        );
    if (action == null) return false;
    return _executeShortcutAction(
          action,
          gamepadTriggerButton: button,
        ) ==
        KeyEventResult.handled;
  }

  bool _handleGamepadLongPress(GamepadButton button) {
    if (!_focusNavEnabled || button != GamepadButton.a || !_caretActive) {
      return false;
    }
    unawaited(_runCaretAction(CaretAction.longPress));
    return true;
  }

  bool _isCaretEntryTrigger({
    LogicalKeyboardKey? keyboardTriggerKey,
    GamepadButton? gamepadTriggerButton,
  }) {
    if (keyboardTriggerKey != null) {
      return ReaderCaretRouter.isEnterTriggerKeyboard(
        keyboardTriggerKey,
        focusNavEnabled: _focusNavEnabled,
        enterKeys: _readerEnterCaretKeys(),
      );
    }
    if (gamepadTriggerButton != null) {
      return ReaderCaretRouter.isEnterTriggerGamepad(
        gamepadTriggerButton,
        focusNavEnabled: _focusNavEnabled,
        enterButtons: _readerEnterCaretButtons(),
      );
    }
    return _focusNavEnabled;
  }

  /// TODO-700 T7: the live keyboard keys bound to [ShortcutAction.readerEnterCaret]
  /// (default Enter, remappable in shortcut settings). The reader's "enter the
  /// char cursor" trigger reads these instead of the old hard-coded Enter/A, so
  /// "进入选字查词" is a configurable key while staying Enter by default.
  Set<LogicalKeyboardKey> _readerEnterCaretKeys() {
    return appModel.shortcutRegistry
        .bindingsFor(ShortcutAction.readerEnterCaret)
        .keyboardBindings
        .map((b) => b.key)
        .toSet();
  }

  /// TODO-700 T7: the live gamepad buttons bound to
  /// [ShortcutAction.readerEnterCaret] (default A, remappable).
  Set<GamepadButton> _readerEnterCaretButtons() {
    return appModel.shortcutRegistry
        .bindingsFor(ShortcutAction.readerEnterCaret)
        .gamepadBindings
        .map((b) => b.button)
        .toSet();
  }

  KeyEventResult _executeShortcutAction(
    ShortcutAction action, {
    LogicalKeyboardKey? keyboardTriggerKey,
    GamepadButton? gamepadTriggerButton,
  }) {
    switch (action) {
      case ShortcutAction.readerPageForward:
        _paginate(ReaderNavigationDirection.forward);
        return KeyEventResult.handled;
      case ShortcutAction.readerPageBackward:
        _paginate(ReaderNavigationDirection.backward);
        return KeyEventResult.handled;
      case ShortcutAction.readerDismissDict:
        // 「只关词典、绝不退出」的专用动作（默认无键盘绑定，典型用法是绑鼠标侧键）。
        // 无弹窗时不消费（ignored 让事件继续冒泡），**绝不退书**——退出是
        // globalBack 的职责。
        if (isDictionaryShown) {
          clearDictionaryResult();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case ShortcutAction.globalBack:
        // 「返回上一级」在阅读器的阶梯（用户拍板：Esc 一键包办）：
        //   ① 词典弹窗可见 → 只关弹窗，留在书里；
        //   ② 否则退出书籍 —— 必须走 maybePop 触发 PopScope→onWillPop 闸门
        //      （flush 阅读位置 / closeMedia / 关书自动同步，BUG-782 同径），与底栏
        //      退出按钮同一条路。
        // 两级都在**本页**消费，不再依赖「返回 ignored → 冒泡到最外层硬编码 Esc」
        // 那条隐形链路：那条链路让退书行为与设置页显示的键位对不上（设置页写
        // Ctrl+W，实际 Esc 也能退），也让改键改不动真正生效的那个键。
        if (isDictionaryShown) {
          clearDictionaryResult();
          return KeyEventResult.handled;
        }
        unawaited(Navigator.of(context).maybePop());
        return KeyEventResult.handled;
      case ShortcutAction.readerToggleChrome:
        if (isDictionaryShown) {
          clearDictionaryResult();
          return KeyEventResult.handled;
        }
        // TODO-700 T8: showing the bar no longer moves focus into it — the bar
        // is excluded from focus traversal; focus stays on the reading content.
        // BUG-1423: route through the mode-aware helper so a floating bottom bar
        // uses the same transient-visibility + auto-hide state machine as a
        // blank-content tap instead of flipping the invisible `_showChrome` gate.
        _toggleChromeFromShortcut();
        return KeyEventResult.handled;
      case ShortcutAction.readerOpenMenu:
        // TODO-728：一键打开阅读器设置菜单（外观/进度/目录快速设置面板），免去先
        // 开底栏再把焦点移到齿轮按钮。_showAppearanceSheet 自带重入守卫。
        if (isDictionaryShown) {
          clearDictionaryResult();
          return KeyEventResult.handled;
        }
        unawaited(_showAppearanceSheet());
        return KeyEventResult.handled;
      case ShortcutAction.readerOpenNavigation:
        // TODO-1309①：Ctrl+F 直接打开阅读器导航界面（直达 location 子页：书内搜索/
        // 字符跳转/目录/书签/收藏）。与 readerOpenMenu 一样先关词典弹窗再开面板，
        // 复用 _showAppearanceSheet 的重入守卫。
        if (isDictionaryShown) {
          clearDictionaryResult();
          return KeyEventResult.handled;
        }
        unawaited(_showAppearanceSheet(initialSubPage: 'location'));
        return KeyEventResult.handled;
      case ShortcutAction.readerToggleFurigana:
        // Mirror the double-tap furigana toggle so a gamepad (R3) can show/hide
        // furigana without a pointer double-tap the WebView can't synthesise.
        _controller?.evaluateJavascript(
          source: "document.body.classList.toggle('show-all-rt');",
        );
        return KeyEventResult.handled;
      case ShortcutAction.readerLookupAtCursor:
        if (_focusNavEnabled && _caretActive) {
          unawaited(_runCaretAction(CaretAction.activate));
        } else if (_isCaretEntryTrigger(
          keyboardTriggerKey: keyboardTriggerKey,
          gamepadTriggerButton: gamepadTriggerButton,
        )) {
          unawaited(_enterCaret());
        }
        return KeyEventResult.handled;
      case ShortcutAction.readerShiftLookup:
        if (_focusNavEnabled && _caretActive) {
          unawaited(_runCaretAction(CaretAction.lookup));
        } else if (_focusNavEnabled) {
          unawaited(_enterCaret());
        }
        return KeyEventResult.handled;
      case ShortcutAction.readerCreateCardFromPopup:
        final Future<void>? mining =
            _caretTopPopupState?.mineFirstVisibleEntry();
        if (mining != null) {
          unawaited(mining);
        }
        return KeyEventResult.handled;
      case ShortcutAction.audiobookPlayPause:
        _audiobookController?.togglePlayPause();
        return KeyEventResult.handled;
      case ShortcutAction.audiobookNextSentence:
        _audiobookController?.skipToNextCue();
        return KeyEventResult.handled;
      case ShortcutAction.audiobookPrevSentence:
        _audiobookController?.skipToPrevCue();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  /// rgba() for the cursor focus ring — the reader accent (theme primary, or the
  /// highlight yellow on dark backgrounds where primary lacks contrast).
  String _caretRingColorCss() {
    final Color accent = _isReaderThemeDark
        ? HibikiColor.defaultHighlightYellow
        : Theme.of(context).colorScheme.primary;
    return readerColorToCssRgba(accent, alphaOverride: 0.98);
  }

  /// Enter the cursor on the READER content (A/Enter in the book with no cursor,
  /// or returning from a dismissed popup). The reader's own hoshiCaret restores
  /// its remembered position, so this re-shows the ring where the user left it.
  Future<void> _enterCaret() async {
    if (_controller == null || !_readerContentReady || _caretBusy) return;
    _caretBusy = true;
    try {
      final Object? raw = await _controller!.evaluateJavascript(
          source: _lyricsMode
              ? ReaderLyricsCaretScripts.enterInvocation()
              : ReaderCaretScripts.enterInvocation());
      if (!mounted) return;
      // enter() returns {ok:false} on an empty page (no visible character).
      if (ReaderCaretScripts.moveStatus(raw) != 'moved') return;
      if (_lyricsMode) {
        // 激活后暂停播放跟随滚动：setCue 只换高亮，不抢滚动。
        await _controller!
            .evaluateJavascript(source: 'window.__lyricsCaretActive = true;');
        _rebuild(() => _caretSurface = CaretSurface.lyrics);
      } else {
        _rebuild(() => _caretSurface = CaretSurface.reader);
      }
    } finally {
      _caretBusy = false;
    }
  }

  /// Fully leave cursor mode — hide the ring on whichever surface holds it.
  void _exitCaret() {
    switch (_caretSurface) {
      case CaretSurface.none:
        return;
      case CaretSurface.reader:
        _controller?.evaluateJavascript(
            source: ReaderCaretScripts.exitInvocation());
        break;
      case CaretSurface.lyrics:
        _controller?.evaluateJavascript(
            source: ReaderLyricsCaretScripts.exitInvocation());
        // 退出焦点：恢复播放跟随并立即把当前播放行重新居中。
        _controller?.evaluateJavascript(
            source: 'window.__lyricsCaretActive = false;'
                'if(window.__lyricsScrollToCue&&window.__lyricsGetCurrentIndex)'
                'window.__lyricsScrollToCue(window.__lyricsGetCurrentIndex());');
        break;
      case CaretSurface.popup:
        _caretTopPopupState?.caretExit();
        break;
      case CaretSurface.video:
        // 阅读器页面不可能持有 video 面（它属于视频页），防御性 no-op。
        break;
    }
    _rebuild(() {
      _caretSurface = CaretSurface.none;
      _caret.popupState = null;
    });
  }

  /// Whether [action] is a cursor MOVEMENT that may fire on keyboard auto-repeat
  /// (holding the key steps the cursor continuously). Activation / dismissal /
  /// lookup must stay one-per-press, so only the directional + step actions
  /// repeat.
  static bool _isRepeatableCaretMove(CaretAction action) {
    switch (action) {
      case CaretAction.stepForward:
      case CaretAction.stepBackward:
      case CaretAction.moveUp:
      case CaretAction.moveDown:
      case CaretAction.moveLeft:
      case CaretAction.moveRight:
        return true;
      case CaretAction.activate:
      case CaretAction.lookup:
      case CaretAction.longPress:
      // 跳转词典是离散跳整段，每次按一下跳一本，绝不随长按连发（否则一口气
      // 冲过所有词典段）。词条级跳转（TODO-1325 #5）同理，一按跳一条，不连发。
      case CaretAction.jumpDictNext:
      case CaretAction.jumpDictPrev:
      case CaretAction.focusEntryNext:
      case CaretAction.focusEntryPrev:
      case CaretAction.dismissOrExit:
        return false;
    }
  }

  Future<void> _runCaretAction(CaretAction action) async {
    // Leaving is always allowed, even mid-operation — it must never be dropped
    // by the in-flight guard, or the user could get stuck unable to back out.
    if (action == CaretAction.dismissOrExit) {
      await _caretDismissOrExit();
      return;
    }
    if (_caretBusy) return;
    _caretBusy = true;
    try {
      switch (action) {
        case CaretAction.stepForward:
          await _caretMove('forward');
          break;
        case CaretAction.stepBackward:
          await _caretMove('backward');
          break;
        case CaretAction.moveUp:
          await _caretMove('up');
          break;
        case CaretAction.moveDown:
          await _caretMove('down');
          break;
        case CaretAction.moveLeft:
          await _caretMove('left');
          break;
        case CaretAction.moveRight:
          await _caretMove('right');
          break;
        case CaretAction.activate:
          await _caretActivate();
          break;
        case CaretAction.lookup:
          await _caretLookup();
          break;
        case CaretAction.longPress:
          await _caretLongPress();
          break;
        case CaretAction.jumpDictNext:
          await _caretJumpDict(true);
          break;
        case CaretAction.jumpDictPrev:
          await _caretJumpDict(false);
          break;
        case CaretAction.focusEntryNext:
          await _caretFocusEntry(true);
          break;
        case CaretAction.focusEntryPrev:
          await _caretFocusEntry(false);
          break;
        case CaretAction.dismissOrExit:
          break; // handled above
      }
    } finally {
      _caretBusy = false;
    }
  }

  /// B/Esc while the cursor is active. On the popup it walks one layer back; the
  /// cursor then follows to the parent popup ([onDictionaryStackChanged]) or back
  /// to the reader ([onAllPopupsDismissed]) — the same hooks that fire on a swipe
  /// dismissal, so every back path is handled in one place. On the reader it
  /// dismisses a touch-opened popup or, with none, leaves cursor mode.
  Future<void> _caretDismissOrExit() async {
    if (_caretSurface == CaretSurface.popup) {
      _caretDismissTopPopup();
      return;
    }
    if (isDictionaryShown) {
      clearDictionaryResult();
    } else {
      _exitCaret();
    }
  }

  /// Move focus from the popup content caret UP to the Flutter header toolbar
  /// (sibling layer). Called when the caret is at the top of the popup content
  /// and Up is pressed. Hides the popup caret ring so the header's standard
  /// HibikiFocusRing is the single indicator. No-op (focus stays on content) if
  /// the header has no focusable button.
  void _focusPopupHeader() {
    if (!mounted || _caretSurface != CaretSurface.popup) return;
    // The header toolbar exists only on the bottom popup (index 0, see
    // base_source_page._buildPopupLayer). When the caret is on a deeper
    // sub-lookup popup there is no header for it — don't grab the (occluded)
    // bottom popup's toolbar; Up at the top simply blocks.
    if (_caretTopVisiblePopupIndex != 0) return;
    _popupHeaderScope.requestFocus();
    if (_popupHeaderScope.nextFocus()) {
      _caretTopPopupState
          ?.caretExit(); // header owns focus → hide the popup caret ring
    } else {
      _focusNode.requestFocus(); // nothing focusable in the header — undo
    }
  }

  /// Move focus from the header toolbar back DOWN to the popup content caret
  /// (sibling layer). Re-shows the popup caret ring at its remembered position.
  void _returnToPopupContent() {
    if (!mounted || _caretSurface != CaretSurface.popup) return;
    _focusNode.requestFocus(); // take Flutter focus off the header buttons
    unawaited(_caretTopPopupState
        ?.caretEnter()); // re-show + re-place the popup caret
  }

  /// Drive one cursor move on the active surface. On the reader, a paged
  /// page-edge ('pageForward'/'pageBackward') asks Dart to turn the page (which
  /// re-anchors the cursor). The popup has no fushiReader, so its cursor scrolls
  /// internally and only ever returns 'moved'/'blocked'.
  Future<void> _caretMove(String physicalDir) async {
    if (_caretSurface == CaretSurface.popup) {
      final String status =
          await _caretTopPopupState?.caretMove(physicalDir) ?? 'blocked';
      if (!mounted) return;
      // At the top edge of the popup content, an upward move is blocked. Treat
      // that as crossing into the sibling header layer (like reader content →
      // bottom bar, but upward). Only 'up' promotes; left/right/down that block
      // simply stay put.
      if (status == 'blocked' && physicalDir == 'up') {
        _focusPopupHeader();
      }
      return;
    }
    if (_controller == null) return;
    final Object? raw = await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.moveInvocation(physicalDir)
            : ReaderCaretScripts.moveInvocation(physicalDir));
    if (!mounted || _controller == null) return;
    // lyrics caret 只返回 moved/blocked，永不 pageForward/Backward，故下面分支天然跳过。
    final String status = ReaderCaretScripts.moveStatus(raw);
    switch (readerCaretMoveOutcome(physicalDir, status)) {
      case ReaderCaretMoveOutcome.paginateForward:
        await _paginate(ReaderNavigationDirection.forward);
        break;
      case ReaderCaretMoveOutcome.paginateBackward:
        await _paginate(ReaderNavigationDirection.backward);
        break;
      case ReaderCaretMoveOutcome.none:
        break;
    }
  }

  /// LB/RB whole-page flip on the active cursor surface. On the popup it scrolls
  /// the content one page and the ring follows; on the paged reader a returned
  /// 'pageForward'/'pageBackward' turns the page (re-anchoring the cursor), the
  /// same edge handling as a line move in [_caretMove]. Shares the [_caretBusy]
  /// guard so a mashed shoulder cannot race an in-flight move.
  Future<void> _caretScrollPage(bool forward) async {
    if (_caretBusy) return;
    _caretBusy = true;
    try {
      if (_caretSurface == CaretSurface.popup) {
        await _caretTopPopupState?.caretScrollPage(forward);
        return;
      }
      if (_controller == null) return;
      final Object? raw = await _controller!.evaluateJavascript(
          source: _caretOnLyrics
              ? ReaderLyricsCaretScripts.scrollPageInvocation(forward)
              : ReaderCaretScripts.scrollPageInvocation(forward));
      if (!mounted || _controller == null) return;
      final String status = ReaderCaretScripts.moveStatus(raw);
      if (status == 'pageForward') {
        await _paginate(ReaderNavigationDirection.forward);
      } else if (status == 'pageBackward') {
        await _paginate(ReaderNavigationDirection.backward);
      }
    } finally {
      _caretBusy = false;
    }
  }

  /// Look up the word at the cursor. On the reader it fires onTextSelected → a
  /// popup; on the popup it fires the popup's textSelected → a deeper popup.
  /// Either way the new popup's onRendered hands the cursor to it.
  Future<void> _caretLookup() async {
    if (_caretSurface == CaretSurface.popup) {
      await _caretTopPopupState?.caretLookup();
      return;
    }
    if (_controller == null) return;
    await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.lookupInvocation()
            : ReaderCaretScripts.lookupInvocation());
  }

  /// A / Enter "context click" at the cursor: follow a hyperlink, click an
  /// interactive control, or look up plain text — [ReaderCaretScripts.activate]
  /// decides. A followed link navigates the WebView (→ shouldOverrideUrlLoading);
  /// a lookup fires the existing onTextSelected pipeline. Fire-and-forget either
  /// way, like [_caretLookup].
  Future<void> _caretActivate() async {
    if (_caretSurface == CaretSurface.popup) {
      await _caretTopPopupState?.caretActivate();
      return;
    }
    if (_controller == null) return;
    await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.activateInvocation()
            : ReaderCaretScripts.activateInvocation());
  }

  Future<void> _caretLongPress() async {
    if (_caretSurface == CaretSurface.popup) {
      await _caretTopPopupState?.caretLongPress();
      return;
    }
    if (_controller == null) return;
    await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.longPressInvocation()
            : ReaderCaretScripts.longPressInvocation());
  }

  /// Jump the cursor to the next/previous dictionary section header in a
  /// multi-dictionary popup (Yomitan-style "go to dictionary"). Popup-only — the
  /// reader and lyrics surfaces have no dictionary sections, so the keys/triggers
  /// no-op there (the JS returns 'blocked'). [forward] true → next dictionary
  /// below the cursor, false → previous above.
  Future<void> _caretJumpDict(bool forward) async {
    if (_caretSurface != CaretSurface.popup) return;
    await _caretTopPopupState?.caretJumpDict(forward);
  }

  /// TODO-1325 #5 part1: move the popup's ENTRY-level focus (the blue-triangle
  /// `.entry-current` indicator) to the next/previous word entry in a
  /// multi-entry result, and scroll it into view. Popup-only — the reader and
  /// lyrics surfaces have no word entries, so this no-ops there. Distinct from
  /// [_caretJumpDict] (dictionary sections within one entry); orthogonal to the
  /// char caret ring (moves only the entry indicator + viewport).
  Future<void> _caretFocusEntry(bool forward) async {
    if (_caretSurface != CaretSurface.popup) return;
    await _caretTopPopupState?.focusEntryMove(forward);
  }

  /// Place the reader cursor at the entering edge of the freshly paginated page.
  /// Reader-only — the popup never paginates.
  Future<void> _caretReanchor(ReaderNavigationDirection direction) async {
    if (!_caretOnReader || _controller == null) return;
    final String edge =
        direction == ReaderNavigationDirection.forward ? 'forward' : 'backward';
    await _controller!.evaluateJavascript(
        source: ReaderCaretScripts.reanchorInvocation(edge));
  }

  /// Re-measure the reader ring after a relayout (chrome toggle, font/size). If
  /// the cursor's node detached, JS re-anchors to the first visible character.
  /// Reader-only.
  Future<void> _caretRefresh() async {
    if (_controller == null || (!_caretOnReader && !_caretOnLyrics)) return;
    await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.refreshInvocation()
            : ReaderCaretScripts.refreshInvocation());
  }
}
