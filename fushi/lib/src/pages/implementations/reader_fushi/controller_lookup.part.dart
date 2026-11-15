part of '../reader_fushi_page.dart';

// ── 手柄查词模式（ControllerLookupMode, S6）适配 ─────────────────────────

/// 阅读器接入统一手柄查词模式：复用本域的字级光标（`fushiCaret` /
/// `fushiLyricsCaret`）与 [_ReaderCaret._runCaretAction] 的 busy 串行化，不另写
/// 光标，焦点环就是光标的可见形态。
///
/// * 字级步进 = 逻辑前进 / 后退。JS 光标没有分词，故 [hasWordSteps] 为 false
///   （模式在 Y 切粒度时落到字级）。
/// * 行级步进用**物理方向**：正文按书的 writing-mode（竖排 = 左为下一行），歌词
///   （有声书视图）按 `lyricsVerticalWriting`（竖排歌词 = 左为下一句，横排 = 下）。
///   分页 / 连续 / VN 三种 view mode 共用同一套 JS 光标，到边时由
///   [readerCaretMoveOutcome] 翻页。
/// * 查词走光标的既有查词（JS → onTextSelected → `_handleTextSelected`），副屏在用
///   时那里已路由到副屏查词页，否则照常弹页内弹窗；单屏弹窗渲染后光标 transfer
///   进弹窗，此时 [routerOwnsInput] 为 false，按键交回页面既有弹窗光标处理。
class _ReaderControllerLookupTarget extends ControllerLookupTarget {
  _ReaderControllerLookupTarget(this._s, {required super.readPref});

  final _ReaderFushiPageState _s;

  /// The caret entry started by [onModeEntered]. A button pressed in the same
  /// instant (L1+A together) must wait for it: `_enterCaret` holds the caret
  /// busy flag, so a step / lookup run meanwhile would be silently dropped.
  Future<void>? _entering;

  /// The last step in flight. A lookup waits for it so A right after a D-pad
  /// step looks up the word the cursor moved to instead of being dropped by
  /// the caret busy flag (steps themselves keep the page's drop-while-busy
  /// rule so a held D-pad cannot queue up moves).
  Future<void>? _stepping;

  /// Set when the page detaches the target in `dispose`: the mode's reset then
  /// calls [onModeExited], which must not touch a disposing page.
  bool _detached = false;

  @override
  bool get isAvailable {
    final _ReaderFushiPageState s = _s;
    if (_detached || !s.mounted || s._book == null || !s._readerContentReady) {
      return false;
    }
    if (s._lyricsMode && !s._lyricsPageReady) return false;
    if (s._sideSheetOpen ||
        s._appearanceSheetOpen ||
        s._studyClockModalDepth > 0) {
      return false;
    }
    final ModalRoute<Object?>? route = ModalRoute.of(s.context);
    return route == null || route.isCurrent;
  }

  /// 单屏查词后光标 transfer 进弹窗：D-pad / A / B 交回页面既有弹窗光标处理。
  @override
  bool get routerOwnsInput => _s._caretSurface != CaretSurface.popup;

  @override
  bool get hasWordSteps => false;

  @override
  void onModeEntered() {
    if (_s.mounted && !_s._caretActive) unawaited(_ensureCaret());
  }

  @override
  void onModeExited() {
    if (!_detached && _s.mounted && _s._caretActive) _s._exitCaret();
  }

  Future<void> _ensureCaret() {
    if (_s._caretActive) return Future<void>.value();
    return _entering ??= _s._enterCaret().whenComplete(() => _entering = null);
  }

  /// Runs one caret move after the cursor is up; null-safe when the entry
  /// failed (empty page / lyrics not ready).
  Future<void> _step(CaretAction action) async {
    await _ensureCaret();
    if (!_s.mounted || !_s._caretActive) return;
    final Future<void> run = _s._runCaretAction(action);
    _stepping = run;
    try {
      await run;
    } finally {
      if (identical(_stepping, run)) _stepping = null;
    }
  }

  @override
  Future<void> stepCursor(int dir, {required bool word}) async {
    if (!_s.mounted) return;
    await _step(dir > 0 ? CaretAction.stepForward : CaretAction.stepBackward);
  }

  @override
  Future<void> stepLine(int dir) async {
    if (!_s.mounted) return;
    await _ensureCaret();
    if (!_s.mounted || !_s._caretActive) return;
    await _step(readerControllerLineAction(dir, vertical: _verticalLines));
  }

  /// Whether lines of the surface holding the cursor run vertically (next
  /// line = physical left).
  bool get _verticalLines {
    if (_s._caretOnLyrics) {
      return ReaderFushiSource.instance.lyricsVerticalWriting;
    }
    if (_s._caretSurface == CaretSurface.popup) return false;
    return (_s._settings?.writingMode ?? 'vertical-rl').startsWith('vertical');
  }

  @override
  Future<void> lookupAtCursor() async {
    if (!_s.mounted) return;
    await _ensureCaret();
    final Future<void>? stepping = _stepping;
    if (stepping != null) await stepping;
    if (!_s.mounted || !_s._caretActive) return;
    await _s._runCaretAction(CaretAction.lookup);
  }
}

/// The caret move of a controller line step: physical direction per writing
/// mode (vertical: next line = left; horizontal: next line = down).
@visibleForTesting
CaretAction readerControllerLineAction(int dir, {required bool vertical}) =>
    vertical
    ? (dir > 0 ? CaretAction.moveLeft : CaretAction.moveRight)
    : (dir > 0 ? CaretAction.moveDown : CaretAction.moveUp);

extension _ReaderControllerLookup on _ReaderFushiPageState {
  void _attachControllerLookup() {
    final _ReaderControllerLookupTarget target = _ReaderControllerLookupTarget(
      this,
      readPref: (String key) => appModelNoUpdate.prefsRepo.getPref(key),
    );
    _controllerLookupTarget = target;
    ControllerLookupMode.instance.attach(target);
  }

  void _detachControllerLookup() {
    final _ReaderControllerLookupTarget? target = _controllerLookupTarget;
    if (target == null) return;
    target._detached = true;
    ControllerLookupMode.instance.detach(target);
    _controllerLookupTarget = null;
  }
}
