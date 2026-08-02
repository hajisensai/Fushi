part of '../video_hibiki_page.dart';

/// 字级选词光标（videoEnterCaret）：视频页的手柄/键盘查词入口。
///
/// 此前视频页唯一非鼠标查词入口是「Shift + 最后指针位置」（BUG-880），纯手柄下
/// 完全无法查词。本域把阅读器的字级光标架构落到字幕 overlay 上：
///
/// * 状态机复用 [DictionaryCaretController]（TODO-387 预留的跨页面复用点）：
///   `CaretSurface.video` = 光标在字幕主面（一个 overlay 登记表下标，
///   [_VideoHibikiPageState._subtitleCaretEntry]）；查词后光标 transfer 进顶层
///   弹窗（`CaretSurface.popup`），A 深查 / 移到 ＋ 按钮上 A 制卡 / B 逐层退回，
///   与阅读器共用 [DictionaryPopupWebViewState] 的整套 caret API。
/// * 输入路由复用 [ReaderCaretRouter]（D-pad/方向键=移动、A/Enter=查词或激活、
///   B/Esc=退出、LT/RT=跳词典段、,/.=切词条），手柄在
///   [_VideoHibikiPageState._handleVideoGamepadButton] 顶部**先于注册表**截获
///   （阅读器 caret.part 同款 contextual 路由）；键盘经
///   [guardVideoShortcutsWithSubtitleCaret]（注册表已绑键）+ 页面最外层
///   Focus.onKeyEvent（未绑键）两层接管。
/// * 主面几何真相源在 [VideoSubtitleOverlay] 的字符登记表（点击查词同源），经
///   [VideoSubtitleHitTester.bindCaretView] 读取；移动是纯函数
///   [moveSubtitleCaretEntry]。确认查词直接走 [_handleSubtitleLookupTap] →
///   `_lookupAt` 既有全链路，零第二条查词路径。
///
/// 暂停契约：进入光标即暂停（activeCues 随播放每帧重算，不暂停光标必失锚），
/// 复用查词的 [_VideoHibikiPageState._pausedForLookup] 单一恢复真相源——浮层
/// 全关时光标仍激活则继续持有暂停（[VideoHibikiPage.shouldResumeAfterLookupDismiss]
/// 的 caretHoldsPause），退出光标才恢复播放。外部恢复播放（触屏点画面 / 空格 /
/// 自动连播）时光标自动退出（[_onCaretControllerTick] 看到「先暂停后再播放」的
/// 迁移即退），绝不出现「光标环钉在旧字幕上、cue 已换」的僵尸态。
extension _VideoSubtitleCaret on _VideoHibikiPageState {
  bool get _videoCaretActive => _videoCaret.active;

  bool get _caretOnSubtitleSurface => _videoCaret.surface == CaretSurface.video;

  /// videoEnterCaret 动作执行体（Enter / 手柄 Select，经注册表可改键）：未激活 =
  /// 进入选词光标；已激活 = 对光标字符查词（与阅读器 readerLookupAtCursor 的双语义
  /// 一致，按第二下 Enter 直接查词）。
  void _handleEnterCaretAction(VideoPlayerController controller) {
    if (_videoCaretActive) {
      unawaited(_runVideoCaretAction(CaretAction.activate));
      return;
    }
    _enterSubtitleCaret(controller);
  }

  /// 进入字幕选词光标：暂停（若在播）→ 锚定到主字幕层首个可见字符 → 画光标环。
  /// 无可选字符（无字幕在屏 / 模糊未显形）提示后不进入。
  void _enterSubtitleCaret(VideoPlayerController controller) {
    if (!_immersiveAllowsLookup) return;
    final int anchor = _subtitleHitTester.caretAnchorEntry();
    if (anchor < 0) {
      _showOsd(t.no_sentence_selected);
      return;
    }
    // 与 _lookupAt 同款暂停语义：仅在播时置位标记，fire-and-forget 暂停。
    if (controller.isPlaying) {
      _pausedForLookup = true;
      unawaited(controller.pause());
    }
    // 迁移追踪的初值来自**进入时的播放态**（见 [SubtitleCaretPauseTracker]）：
    // 本来就暂停时进光标不会调 pause、播放态不翻转、播放器也不再通知，恒 false 的
    // 初值会让「外部恢复播放自动退光标」永久失效。
    _caretPauseTracker =
        SubtitleCaretPauseTracker(playingAtEntry: controller.isPlaying);
    _caretCueSignature = _caretCurrentCueSignature(controller);
    controller.addListener(_onCaretControllerTick);
    setState(() {
      _videoCaret.surface = CaretSurface.video;
      _subtitleCaretEntry = anchor;
    });
    _pokeControlsVisible();
  }

  /// 退出选词光标（B/Esc、或外部恢复播放的自动退出）。[resume] 为 true 且暂停确因
  /// 本会话（查词/进光标）持有、且没有浮层再接管时恢复播放。
  void _exitSubtitleCaret({required bool resume}) {
    if (!_videoCaretActive) return;
    _finishSubtitleCaretSession(resume: resume);
  }

  /// 光标会话收尾的**唯一出口**：摘播放器监听器、清光标环、复位 surface，并按
  /// [resume] 决定是否恢复播放。与 [_exitSubtitleCaret] 的唯一区别是不检查
  /// `active` —— 供「surface 已被 [DictionaryCaretController] 悄悄清成 none」的
  /// 路径补做收尾（见 [_runPopupSurfaceCaretAction]）。收尾三件事必须绑在一起，
  /// 少做任何一件就是僵尸态：留环 / 监听器重复注册 / 视频永远卡在暂停。
  void _finishSubtitleCaretSession({required bool resume}) {
    _controller?.removeListener(_onCaretControllerTick);
    _caretPauseTracker = null;
    setState(() {
      _videoCaret.surface = CaretSurface.none;
      _videoCaret.popupState = null;
      _subtitleCaretEntry = null;
    });
    if (resume &&
        _pausedForLookup &&
        !_hasVisiblePopup &&
        _controller != null) {
      _pausedForLookup = false;
      unawaited(_controller!.play());
    }
  }

  /// 光标会话期间监听播放器：
  /// 1. 外部恢复播放（触屏 / 空格 / 连播）→ 自动退出光标（不再抢暂停）；
  /// 2. 暂停态下 cue 集合变化（X/Y 跳句、Ctrl+←/→、拖进度条）→ 光标重锚到新字幕。
  void _onCaretControllerTick() {
    if (!mounted || !_videoCaretActive) return;
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final SubtitleCaretPauseTracker? tracker = _caretPauseTracker;
    if (tracker != null && tracker.onTick(playing: controller.isPlaying)) {
      // 暂停已生效过、现在又在播放 = 外部恢复：退出光标。播放恢复不是我们要撤销的
      // 操作（用户意图优先），只收光标、不再动播放态。
      _pausedForLookup = false;
      _exitSubtitleCaret(resume: false);
      return;
    }
    if (!_caretOnSubtitleSurface) return;
    final String signature = _caretCurrentCueSignature(controller);
    if (signature == _caretCueSignature) return;
    _caretCueSignature = signature;
    // cue 已换（暂停下 seek/跳句）：等 overlay 按新活动集重建登记表后重锚。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_caretOnSubtitleSurface) return;
      final int anchor = _subtitleHitTester.caretAnchorEntry();
      setState(() => _subtitleCaretEntry = anchor >= 0 ? anchor : null);
    });
  }

  /// 当前活动 cue 集合的身份签名（主 + 副，startMs 足够区分）。
  String _caretCurrentCueSignature(VideoPlayerController controller) {
    final StringBuffer sb = StringBuffer();
    for (final AudioCue c in controller.activeCues) {
      sb
        ..write(c.startMs)
        ..write(',');
    }
    sb.write('|');
    for (final AudioCue c in controller.secondaryActiveCues) {
      sb
        ..write(c.startMs)
        ..write(',');
    }
    return sb.toString();
  }

  // ── 输入接管 ────────────────────────────────────────────────────────

  /// 手柄按键的光标态接管（在 [_handleVideoGamepadButton] 顶部、注册表解析之前调）。
  /// 光标未激活返回 false（进入走注册表 videoEnterCaret 动作，不在这里）。
  ///
  /// 激活期路由：[ReaderCaretRouter.decideGamepad] 的光标键（dpad/A/B/LT/RT）走光标
  /// 动作；主面上「上一句/下一句」按用户注册表绑定放行（跳句后 [_onCaretControllerTick]
  /// 自动重锚）；**其余按键一律吞掉**——选词是模态操作，快进/音量/全屏在光标态触发
  /// 只会把用户正在选的字幕换掉（阅读器 caret 同款收敛）。
  bool _handleCaretGamepadButton(GamepadButton button) {
    if (!_videoCaretActive) return false;
    // 主面没有「词典段」语义：[ReaderCaretRouter.decideGamepad] 把 LT/RT 映射成
    // jumpDictPrev/Next，而主面对这两个动作是空 return —— 用户在光标态按 RT(全屏)
    // / LT(重听当前句) 静默无反应。主面把两个扳机整体交回注册表解析（弹窗面仍是
    // 跳词典段，那里才有词典段）。
    final bool shoulderOnSubtitleSurface = _caretOnSubtitleSurface &&
        (button == GamepadButton.lt || button == GamepadButton.rt);
    final CaretAction? caretAction = shoulderOnSubtitleSurface
        ? null
        : ReaderCaretRouter.decideGamepad(button);
    if (caretAction != null) {
      unawaited(_runVideoCaretAction(caretAction));
      return true;
    }
    final ShortcutAction? action = appModel.shortcutRegistry.resolveGamepad(
      button,
      scope: ShortcutScope.video,
    );
    // 与键盘 Enter 双语义对称：激活期再按 videoEnterCaret 绑定键（默认 Select）
    // = 对光标字符查词 / 激活。
    if (action == ShortcutAction.videoEnterCaret) {
      unawaited(_runVideoCaretAction(CaretAction.activate));
      return true;
    }
    if (_caretOnSubtitleSurface &&
        (shoulderOnSubtitleSurface ||
            action == ShortcutAction.videoPreviousSubtitle ||
            action == ShortcutAction.videoNextSubtitle ||
            action == ShortcutAction.videoReplayCurrentSubtitle)) {
      final VideoPlayerController? controller = _controller;
      if (controller != null) {
        videoActionCallbacks(_buildVideoShortcutActions(controller))[action]
            ?.call();
      }
      return true;
    }
    return true;
  }

  /// 键盘光标键执行（[guardVideoShortcutsWithSubtitleCaret] 与页面最外层
  /// Focus.onKeyEvent 共用）。返回是否已消费。
  bool _runCaretKeyboardKey(LogicalKeyboardKey key, {required bool shift}) {
    if (!_videoCaretActive) return false;
    final CaretAction? action = ReaderCaretRouter.decideKeyboard(
      key,
      shift: shift,
    );
    if (action == null) return false;
    unawaited(_runVideoCaretAction(action));
    return true;
  }

  /// 页面最外层 Focus.onKeyEvent 的光标分支：接住**未进注册表 activator 表**的光标键
  /// （Tab / [ / ] / , / . 及未被用户绑定的方向键、Esc 等；已绑键在内层
  /// [guardVideoShortcutsWithSubtitleCaret] 就被接管、不会冒泡到这里）。
  bool _handleCaretUnboundKey(KeyEvent event) {
    if (!_videoCaretActive) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (focusedEditableText() != null) return false;
    return _runCaretKeyboardKey(
      event.logicalKey,
      shift: HardwareKeyboard.instance.isShiftPressed,
    );
  }

  /// 手柄长按 A（[GamepadLongPressIntent]）：弹窗面上等价阅读器的「长按标记词典」。
  /// 主面 / 未激活返回 false 交回 [GamepadService] 全局兜底。
  bool _handleCaretGamepadLongPress(GamepadButton button) {
    if (!_videoCaret.onPopup || button != GamepadButton.a) return false;
    unawaited(_runVideoCaretAction(CaretAction.longPress));
    return true;
  }

  /// BUG-1269 输入桥（指针悬在原生弹窗上时键盘事件只到弹窗 DOM）的光标态分流：
  /// videoEnterCaret token = 对光标字符查词 / 激活；其余 video 动作在光标态一律
  /// 不再「关浮层」（那会把用户正在手柄导航的弹窗关掉），直接吞掉。
  bool _handleCaretPopupInputToken(ShortcutAction action) {
    if (!_videoCaretActive) return false;
    if (action == ShortcutAction.videoEnterCaret) {
      unawaited(_runVideoCaretAction(CaretAction.activate));
    } else if (action == ShortcutAction.globalBack) {
      unawaited(_runVideoCaretAction(CaretAction.dismissOrExit));
    }
    return true;
  }

  // ── 光标动作执行 ────────────────────────────────────────────────────

  /// 对当前表面执行一次光标动作。弹窗面的 JS 往返用 [DictionaryCaretController.busy]
  /// 串行化（D-pad 自动重复 ~9×/s，重叠调用会让光标乱跳——阅读器同款防抖）；主面
  /// 操作是同步几何运算，不占 busy。
  Future<void> _runVideoCaretAction(CaretAction action) async {
    switch (_videoCaret.surface) {
      case CaretSurface.none:
      case CaretSurface.reader:
      case CaretSurface.lyrics:
        return;
      case CaretSurface.video:
        _runSubtitleSurfaceCaretAction(action);
        return;
      case CaretSurface.popup:
        await _runPopupSurfaceCaretAction(action);
        return;
    }
  }

  void _runSubtitleSurfaceCaretAction(CaretAction action) {
    final int? current = _subtitleCaretEntry;
    switch (action) {
      case CaretAction.moveUp:
      case CaretAction.moveDown:
      case CaretAction.moveLeft:
      case CaretAction.moveRight:
        if (current == null) {
          // 字幕 gap 期光标无锚（环隐藏）：方向键尝试重锚到当前字幕。
          final int anchor = _subtitleHitTester.caretAnchorEntry();
          if (anchor >= 0) setState(() => _subtitleCaretEntry = anchor);
          return;
        }
        final List<Rect> rects = _subtitleHitTester.caretEntryRects();
        final SubtitleCaretMove move = switch (action) {
          CaretAction.moveUp => SubtitleCaretMove.up,
          CaretAction.moveDown => SubtitleCaretMove.down,
          CaretAction.moveLeft => SubtitleCaretMove.left,
          _ => SubtitleCaretMove.right,
        };
        final int next = moveSubtitleCaretEntry(rects, current, move);
        if (next != current) setState(() => _subtitleCaretEntry = next);
        return;
      case CaretAction.stepForward:
      case CaretAction.stepBackward:
        if (current == null) return;
        final List<Rect> rects = _subtitleHitTester.caretEntryRects();
        final int step = action == CaretAction.stepForward ? 1 : -1;
        int i = current + step;
        while (i >= 0 && i < rects.length && rects[i] == Rect.zero) {
          i += step;
        }
        if (i >= 0 && i < rects.length && i != current) {
          setState(() => _subtitleCaretEntry = i);
        }
        return;
      case CaretAction.activate:
      case CaretAction.lookup:
        if (current == null) return;
        final SubtitleCharHit? hit = _subtitleHitTester.caretHitAt(current);
        if (hit == null) return;
        // 与点击查词完全同链路（含沉浸门控）：弹窗渲染完成后
        // [onNestedPopupRendered] 会把光标 transfer 进弹窗。
        _handleSubtitleLookupTap(hit.sentence, hit.graphemeIndex, hit.charRect);
        return;
      case CaretAction.longPress:
      case CaretAction.jumpDictNext:
      case CaretAction.jumpDictPrev:
      case CaretAction.focusEntryNext:
      case CaretAction.focusEntryPrev:
        return; // 主面无词典段/词条语义：吞掉不下坠（LT/RT 不触发重播/全屏）。
      case CaretAction.dismissOrExit:
        _exitSubtitleCaret(resume: true);
        return;
    }
  }

  Future<void> _runPopupSurfaceCaretAction(CaretAction action) async {
    // B/Esc 永远放行（关层不该被 busy 卡住——阅读器同款：离开总是允许）。
    if (action == CaretAction.dismissOrExit) {
      _popNestedPopupAt(_topVisiblePopupIndex);
      return;
    }
    if (_videoCaret.busy) return;
    final DictionaryPopupWebViewState? popup = caretTopPopupState;
    if (popup == null || !identical(popup, _videoCaret.popupState)) {
      // 鼠标在光标会话外改了弹窗栈：按硬件导航恢复语义重校（transfer/回落）。
      _videoCaret.resumePopupCaretForHardwareNav();
      // 弹窗已整个消失时上面把 surface 直接清成 none（不经 caretSetState，那是
      // 控制器层的共享语义）。对视频页而言这就是「光标会话结束」，必须补做收尾：
      // 否则 [_exitSubtitleCaret] 首行的 `!_videoCaretActive` 早返回会让字幕上留
      // 一圈光标环、[_onCaretControllerTick] 监听器不摘（下次进光标重复注册）、
      // _pausedForLookup 不复位（视频永远卡在暂停）。
      if (!_videoCaretActive) _finishSubtitleCaretSession(resume: true);
      return;
    }
    _videoCaret.busy = true;
    try {
      switch (action) {
        case CaretAction.moveUp:
          await popup.caretMove('up');
        case CaretAction.moveDown:
          await popup.caretMove('down');
        case CaretAction.moveLeft:
          await popup.caretMove('left');
        case CaretAction.moveRight:
          await popup.caretMove('right');
        case CaretAction.stepForward:
          await popup.caretMove('forward');
        case CaretAction.stepBackward:
          await popup.caretMove('backward');
        case CaretAction.activate:
          await popup.caretActivate();
        case CaretAction.lookup:
          await popup.caretLookup();
        case CaretAction.longPress:
          await popup.caretLongPress();
        case CaretAction.jumpDictNext:
          await popup.caretJumpDict(true);
        case CaretAction.jumpDictPrev:
          await popup.caretJumpDict(false);
        case CaretAction.focusEntryNext:
          await popup.focusEntryMove(true);
        case CaretAction.focusEntryPrev:
          await popup.focusEntryMove(false);
        case CaretAction.dismissOrExit:
          break; // 已在上方处理
      }
    } finally {
      _videoCaret.busy = false;
    }
  }
}
