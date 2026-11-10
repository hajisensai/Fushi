part of '../video_fushi_page.dart';

// ── 手柄查词模式（ControllerLookupMode, S6）适配 ─────────────────────────

/// 视频页接入统一手柄查词模式：复用 `subtitle_caret.part.dart` 的字幕字级光标
/// （光标环就是可见光标）与 [_handleSubtitleLookupTap] 查词链路，不另写光标。
///
/// * 词级步进用 [buildSubtitleSweepTokens]（与暂停句扫词同一分词），到句首 / 句尾
///   原地不动；取不到词时落到字级。
/// * 行级步进 = 上 / 下一条字幕（与快捷键同一执行体），暂停态下 cue 变化由
///   [_onCaretControllerTick] 把光标重锚到新字幕。
/// * 暂停 / 恢复沿用光标会话语义：进模式即进光标（在播则暂停），退模式退出光标并
///   按 `_pausedForLookup` 恢复。
/// * 查词走点击查词同链路：副屏在用时已路由到副屏查词页；否则弹页内弹窗，渲染后
///   光标 transfer 进弹窗，此时 [routerOwnsInput] 为 false。
class _VideoControllerLookupTarget extends ControllerLookupTarget {
  _VideoControllerLookupTarget(this._s, {required super.readPref});

  final _VideoFushiPageState _s;

  /// Set when the page detaches the target in `dispose`: the mode's reset then
  /// calls [onModeExited], which must not resume playback / rebuild a
  /// disposing page.
  bool _detached = false;

  @override
  bool get isAvailable {
    final _VideoFushiPageState s = _s;
    if (_detached || !s.mounted || s._controller == null) return false;
    if (!s._immersiveAllowsLookup || s._videoNavigablePanelOpen) return false;
    final ModalRoute<Object?>? owner = s._videoFullscreenActive
        ? s._videoFullscreenRoute
        : ModalRoute.of(s.context);
    return owner == null || owner.isCurrent;
  }

  /// 单屏时查词后光标 transfer 进弹窗：此时 D-pad / A / B 交回页面既有的弹窗光标
  /// 与 dictionaryPopup 手柄钩子。
  @override
  bool get routerOwnsInput => !_s._videoCaret.onPopup;

  @override
  bool get hasWordSteps => true;

  @override
  void onModeEntered() {
    final VideoPlayerController? c = _s._controller;
    if (c == null || !_s.mounted) return;
    if (!_s._videoCaretActive) _s._enterSubtitleCaret(c);
  }

  @override
  void onModeExited() {
    if (_detached || !_s.mounted) return;
    _s._exitSubtitleCaret(resume: true);
  }

  /// The caret is up (entered now if needed). False when no subtitle
  /// character is on screen (the page already told the user).
  bool _ensureCaret() {
    if (_s._videoCaretActive) return true;
    final VideoPlayerController? c = _s._controller;
    if (c == null) return false;
    _s._enterSubtitleCaret(c);
    return _s._videoCaretActive;
  }

  @override
  Future<void> stepCursor(int dir, {required bool word}) async {
    if (!_s.mounted || !_ensureCaret() || !_s._caretOnSubtitleSurface) return;
    final int? current = _s._subtitleCaretEntry;
    if (word && current != null) {
      final VideoSubtitleHitTester tester = _s._subtitleHitTester;
      final int? next = controllerLookupSubtitleWordEntry(
        current: current,
        dir: dir,
        entryCount: tester.caretEntryCount(),
        charAt: (int i) {
          final SubtitleCharHit? h = tester.caretHitAt(i);
          return h == null
              ? null
              : (
                  sentence: h.sentence,
                  graphemeIndex: h.graphemeIndex,
                  cue: h.cue,
                );
        },
      );
      if (next == -1) return; // 句首 / 句尾：原地不动（上下换句）
      if (next != null) {
        if (next != current) _s._moveSubtitleCaretTo(next);
        return;
      }
    }
    _s._runSubtitleSurfaceCaretAction(
      dir > 0 ? CaretAction.stepForward : CaretAction.stepBackward,
    );
  }

  @override
  Future<void> stepLine(int dir) async {
    if (!_s.mounted) return;
    final VideoPlayerController? c = _s._controller;
    if (c == null) return;
    videoActionCallbacks(_s._buildVideoShortcutActions(c))[dir > 0
            ? ShortcutAction.videoNextSubtitle
            : ShortcutAction.videoPreviousSubtitle]
        ?.call();
  }

  @override
  Future<void> lookupAtCursor() async {
    if (!_s.mounted || !_ensureCaret()) return;
    _s._runSubtitleSurfaceCaretAction(CaretAction.lookup);
  }
}

extension _VideoControllerLookup on _VideoFushiPageState {
  void _moveSubtitleCaretTo(int entry) =>
      setState(() => _subtitleCaretEntry = entry);

  void _attachControllerLookup() {
    final _VideoControllerLookupTarget target = _VideoControllerLookupTarget(
      this,
      readPref: (String key) => appModel.prefsRepo.getPref(key),
    );
    _controllerLookupTarget = target;
    ControllerLookupMode.instance.attach(target);
  }

  void _detachControllerLookup() {
    final _VideoControllerLookupTarget? target = _controllerLookupTarget;
    if (target == null) return;
    target._detached = true;
    ControllerLookupMode.instance.detach(target);
    _controllerLookupTarget = null;
  }
}
