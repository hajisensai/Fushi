part of '../video_fushi_page.dart';

// ── 手柄查词模式（ControllerLookupMode, S6）适配 ─────────────────────────

/// 视频页接入统一手柄查词模式：复用 `subtitle_caret.part.dart` 的字幕字级光标
/// （光标环就是可见光标）与 [_handleSubtitleLookupTap] → `_lookupAt` 查词链路，不另写
/// 光标、不另写查词。
///
/// * 词级步进用 [buildSubtitleSweepTokens]（统一分词），到句首 / 句尾原地不动；取不到
///   词时落到字级。行级步进 = 上 / 下一条字幕（与快捷键同一执行体），暂停态下 cue 变化
///   由 [_onCaretControllerTick] 把光标重锚到新字幕。步进本身不查词：模式在单击步进后、
///   或连发结束后调 [lookupAtCursor]（停下即查）。
/// * 查词走点击查词同链路（`replaceStack` + `reuseWarmSlot` 复用热槽、不叠栈；副屏在用
///   时路由到副屏查词页）。`maxGraphemes` 只截查询串（[capSubtitleLookupTerm]），返回
///   字幕高亮的字素长度；副屏在用时本机按同一查询量命中长度（[measureLookupMatchGraphemes]）。
/// * 查词后光标**留在字幕上**（[routerOwnsInput] 仍为 true，下一次十字键继续换词）：
///   [_VideoFushiPageState.onNestedPopupRendered] 在本模式持有光标时不 transfer。按「进入
///   结果」（[enterResult]）才把光标交给页内弹窗光标，此后 D-pad / A / B 走页面既有的弹窗
///   光标路由（[_handleCaretGamepadButton]），B 逐层关弹窗、全关后光标回落字幕。
/// * 暂停 / 恢复沿用光标会话语义：进模式即进光标（在播则暂停），退模式退出光标并按
///   `_pausedForLookup` 恢复。
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

  /// 光标在页内弹窗上（[enterResult] 之后）时为 false：D-pad / A / B 交回页面既有的
  /// 弹窗光标与 dictionaryPopup 手柄钩子。
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

  /// The subtitle character under the caret (null: no caret / caret in a
  /// subtitle gap).
  SubtitleCharHit? get _caretHit {
    final int? entry = _s._subtitleCaretEntry;
    if (entry == null) return null;
    return _s._subtitleHitTester.caretHitAt(entry);
  }

  /// 光标所在字幕句里查询串的字素数：从查词起点（[subtitleLookupSpan]，拉丁词回退到
  /// 词首、跳过前导空白 / 标点；其余即光标字）到句尾。右端上限与命中长度都按这个
  /// 起点计，故以它为上界。
  @override
  int get graphemesFromCursor {
    final SubtitleCharHit? hit = _caretHit;
    if (hit == null) return 0;
    return subtitleLookupSpan(
      hit.sentence,
      hit.graphemeIndex,
    ).term.characters.length;
  }

  @override
  Future<int> lookupAtCursor({int? maxGraphemes}) async {
    if (!_s.mounted || !_ensureCaret() || !_s._caretOnSubtitleSurface) {
      return 0;
    }
    final SubtitleCharHit? hit = _caretHit;
    if (hit == null) return 0;
    return _s._handleSubtitleLookupTap(
      hit.sentence,
      hit.graphemeIndex,
      hit.charRect,
      hit.cue,
      maxGraphemes: maxGraphemes,
      measureMatch: true,
    );
  }

  /// 把光标交给页内顶层弹窗的光标（弹窗内选词 / 嵌套查词）。查词在副屏查词页上
  /// （页内没有可见弹窗）时什么都不做。
  @override
  Future<void> enterResult() async {
    if (_detached || !_s.mounted || !_s._caretOnSubtitleSurface) return;
    final DictionaryPopupWebViewState? popup = _s.caretTopPopupState;
    if (popup == null) return;
    await _s._videoCaret.transferToTopPopup(popup);
  }
}

extension _VideoControllerLookup on _VideoFushiPageState {
  /// 手柄查词模式正持有本页光标、且光标还在字幕上：此时查词后光标留在正文
  /// （见 [onNestedPopupRendered]）。
  bool get _controllerLookupHoldsCaret {
    final _VideoControllerLookupTarget? target = _controllerLookupTarget;
    final ControllerLookupMode mode = ControllerLookupMode.instance;
    return target != null &&
        mode.active &&
        identical(mode.target, target) &&
        _caretOnSubtitleSurface;
  }

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
