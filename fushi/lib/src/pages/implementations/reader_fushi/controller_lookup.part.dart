part of '../reader_fushi_page.dart';

// ── 手柄查词模式（ControllerLookupMode）适配 ─────────────────────────────

/// 阅读器接入统一手柄查词模式（docs/specs/2026-11-22-gamepad-lookup-unification-design.md）：
/// 复用本域的字级光标（`fushiCaret` / `fushiLyricsCaret`）与
/// [_ReaderCaret._runCaretAction] 的 busy 串行化，不另写光标，焦点环就是光标的可见形态。
///
/// * 字级步进 = 逻辑前进 / 后退；词级步进（[hasWordSteps]）先经
///   [ReaderControllerWordStepScripts.contextInvocation] 取光标所在块（正文段落 /
///   歌词行）的文本，用查词模式各页共用的分词（[controllerLookupWordStep]）算出目标，
///   再让 JS 光标逐字走到那里——到页边与字级步进一样返回翻页状态。块首 / 块尾没有
///   下一个词时退成一步字级步进，跨进相邻块。
/// * 行级步进用**物理方向**：正文按书的 writing-mode（竖排 = 左为下一行），歌词
///   （有声书视图）按 `lyricsVerticalWriting`（竖排歌词 = 左为下一句，横排 = 下）。
///   分页 / 连续 / VN 三种 view mode 共用同一套 JS 光标与 `move`，到边时由
///   [readerCaretMoveOutcome] 翻页。
/// * 查词（[lookupAtCursor]）走光标的既有查词（JS `lookup` → onTextSelected →
///   `_handleTextSelected` → `_runLookupAndHighlight`，与点按同一链路：清栈复用热槽、
///   不叠栈）。每次查词发一个令牌（[ReaderControllerLookupRequests]），JS 把它盖在这次
///   查词的 onTextSelected payload 上（`controllerLookup`），`_handleTextSelected` 按令牌
///   认领——其间夹进来的点按 / 悬停查词没有令牌，不会被误认成手柄查词：
///   按 `maxGraphemes` 截查询词（[readerControllerCappedQuery]），查完把高亮长度交回。
///   副屏在用时同一处路由到副屏查词页（截过的查询经 [readerControllerCompanionLookup]）。
/// * **查词后光标留在正文**：模式在用时弹窗渲染不再把光标 transfer 进弹窗
///   （[holdsCursorInText]，`onDictionaryPopupRendered` 读它），下一次十字键继续在正文
///   换词。[enterResult]（默认 A）才把光标交给页内弹窗光标，此后 [routerOwnsInput] 为
///   false，按键回到页面既有的弹窗光标处理（`decideGamepad`），B 关弹窗后光标回正文。
class _ReaderControllerLookupTarget extends ControllerLookupTarget {
  _ReaderControllerLookupTarget(this._s, {required super.readPref});

  final _ReaderFushiPageState _s;

  /// The caret entry started by [onModeEntered]. A button pressed in the same
  /// instant (L1 + D-pad together) must wait for it: `_enterCaret` holds the
  /// caret busy flag, so a step / lookup run meanwhile would be silently
  /// dropped.
  Future<void>? _entering;

  /// The last step in flight. A lookup waits for it so the lookup right after
  /// a D-pad step looks up the word the cursor moved to instead of being
  /// dropped by the caret busy flag (steps themselves keep the page's
  /// drop-while-busy rule so a held D-pad cannot queue up moves).
  Future<void>? _stepping;

  /// Set when the page detaches the target in `dispose`: the mode's reset then
  /// calls [onModeExited], which must not touch a disposing page.
  bool _detached = false;

  /// Between [onModeEntered] and [onModeExited].
  bool _modeActive = false;

  /// Lookups started by [lookupAtCursor] that `_handleTextSelected` has not
  /// claimed yet, by token.
  final ReaderControllerLookupRequests _requests =
      ReaderControllerLookupRequests();

  /// Graphemes of the last controller lookup's scanned query text (before the
  /// cap): what [graphemesFromCursor] reports. 0 after a step until the next
  /// lookup lands (the mode then treats any growth as unlimited).
  int _scannedGraphemes = 0;

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

  /// False once [enterResult] moved the caret onto the popup: D-pad / A / B
  /// then go to the page's existing popup caret handling.
  @override
  bool get routerOwnsInput => _s._caretSurface != CaretSurface.popup;

  @override
  bool get hasWordSteps => true;

  /// Whether a rendered popup must leave the caret in the text (the mode is on
  /// and the caret is on the book / lyrics). Read by the page's
  /// `onDictionaryPopupRendered`; a caret already on a popup (after
  /// [enterResult]) still follows nested lookups.
  bool get holdsCursorInText =>
      _modeActive &&
      !_detached &&
      (_s._caretSurface == CaretSurface.reader ||
          _s._caretSurface == CaretSurface.lyrics);

  @override
  void onModeEntered() {
    _modeActive = true;
    if (_s.mounted && !_s._caretActive) unawaited(_ensureCaret());
  }

  @override
  void onModeExited() {
    _modeActive = false;
    _scannedGraphemes = 0;
    _requests.cancelAll();
    if (!_detached && _s.mounted && _s._caretActive) _s._exitCaret();
  }

  Future<void> _ensureCaret() {
    if (_s._caretActive) return Future<void>.value();
    return _entering ??= _s._enterCaret().whenComplete(() => _entering = null);
  }

  /// Runs one caret move after the cursor is up; null-safe when the entry
  /// failed (empty page / lyrics not ready).
  Future<void> _step(Future<void> Function() move) async {
    await _ensureCaret();
    if (!_s.mounted || !_s._caretActive) return;
    _scannedGraphemes = 0;
    final Future<void> run = move();
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
    await _step(
      word
          ? () => _wordStep(dir)
          : () => _s._runCaretAction(
              dir > 0 ? CaretAction.stepForward : CaretAction.stepBackward,
            ),
    );
  }

  @override
  Future<void> stepLine(int dir) async {
    if (!_s.mounted) return;
    await _step(
      () => _s._runCaretAction(
        readerControllerLineAction(dir, vertical: _verticalLines),
      ),
    );
  }

  /// One word step on the book / lyrics caret, under the caret busy flag like
  /// every caret action ([ReaderControllerWordStepScripts.planStep]): to the
  /// next / previous word start in the caret's block; from the block's last /
  /// first word on into the next / previous block, landing on its first / last
  /// word start ([ReaderControllerWordStepScripts.entryDelta]). Falls back to a
  /// character step when the caret has no text around it.
  Future<void> _wordStep(int dir) async {
    final _ReaderFushiPageState s = _s;
    if (s._caretBusy || s._caretSurface == CaretSurface.popup) return;
    final bool lyrics = s._caretOnLyrics;
    final InAppWebViewController? web = lyrics
        ? s._lyricsController
        : s._controller;
    if (web == null) return;
    final String physicalDir = dir > 0 ? 'forward' : 'backward';
    s._caretBusy = true;
    try {
      final ReaderWordStepContext? context = await _wordStepContext(
        web,
        lyrics: lyrics,
      );
      if (!s.mounted) return;
      final ReaderWordStepMove? move = context == null
          ? null
          : ReaderControllerWordStepScripts.planStep(context, dir);
      if (move == null) {
        // No text at the caret (element stop), or the block runs past the
        // context window: one character step.
        await s._caretMove(physicalDir);
        return;
      }
      if (!await _wordStepMove(web, lyrics: lyrics, delta: move.delta)) return;
      if (!move.crossesBlock) return;
      // Entered the next / previous block (or turned the page): go on to its
      // first / last word start, skipping leading whitespace / punctuation.
      final ReaderWordStepContext? entered = await _wordStepContext(
        web,
        lyrics: lyrics,
      );
      if (!s.mounted || entered == null) return;
      final int? snap = ReaderControllerWordStepScripts.entryDelta(
        entered,
        dir,
      );
      if (snap != null) {
        await _wordStepMove(web, lyrics: lyrics, delta: snap);
      }
    } catch (e, stack) {
      // A half-torn-down WebView throws on evaluateJavascript (BUG-005 root
      // cause); the step is simply not made.
      ErrorLogService.instance.log('ReaderFushi.controllerWordStep', e, stack);
    } finally {
      s._caretBusy = false;
    }
  }

  /// The text around the caret (from
  /// [ReaderControllerWordStepScripts.contextInvocation]); null when the caret
  /// is not on text.
  Future<ReaderWordStepContext?> _wordStepContext(
    InAppWebViewController web, {
    required bool lyrics,
  }) async => ReaderControllerWordStepScripts.parseContext(
    await web.evaluateJavascript(
      source: ReaderControllerWordStepScripts.contextInvocation(lyrics: lyrics),
    ),
  );

  /// Moves the caret [delta] UTF-16 units
  /// ([ReaderControllerWordStepScripts.stepInvocation]) and turns the page
  /// when the move ran off it. False when the page went away meanwhile.
  Future<bool> _wordStepMove(
    InAppWebViewController web, {
    required bool lyrics,
    required int delta,
  }) async {
    final _ReaderFushiPageState s = _s;
    final Object? raw = await web.evaluateJavascript(
      source: ReaderControllerWordStepScripts.stepInvocation(
        lyrics: lyrics,
        delta: delta,
      ),
    );
    if (!s.mounted || s._controller == null) return false;
    switch (readerCaretMoveOutcome(
      delta > 0 ? 'forward' : 'backward',
      ReaderCaretScripts.moveStatus(raw),
    )) {
      case ReaderCaretMoveOutcome.paginateForward:
        await s._paginate(ReaderNavigationDirection.forward);
      case ReaderCaretMoveOutcome.paginateBackward:
        await s._paginate(ReaderNavigationDirection.backward);
      case ReaderCaretMoveOutcome.none:
        break;
    }
    return s.mounted;
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
  int get graphemesFromCursor => _scannedGraphemes;

  @override
  Future<int> lookupAtCursor({int? maxGraphemes}) async {
    if (!_s.mounted) return 0;
    await _ensureCaret();
    final Future<void>? stepping = _stepping;
    if (stepping != null) await stepping;
    final _ReaderFushiPageState s = _s;
    if (!s.mounted || !s._caretActive || s._caretBusy) return 0;
    if (s._caretSurface == CaretSurface.popup) return 0;
    final bool lyrics = s._caretOnLyrics;
    final InAppWebViewController? web = lyrics
        ? s._lyricsController
        : s._controller;
    if (web == null) return 0;
    final ({int token, ReaderControllerLookupRequest request}) started =
        _requests.start(maxGraphemes);
    s._caretBusy = true;
    try {
      final Object? fired = await web.evaluateJavascript(
        source: lyrics
            ? ReaderLyricsCaretScripts.lookupInvocation(token: started.token)
            : ReaderCaretScripts.lookupInvocation(token: started.token),
      );
      // Nothing to look up at the caret (no scannable text): no
      // onTextSelected will come.
      if (fired != true && fired != 'true') _requests.cancel(started.token);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderFushi.controllerLookup', e, stack);
      _requests.cancel(started.token);
    } finally {
      s._caretBusy = false;
    }
    return started.request.result;
  }

  /// `_handleTextSelected` takes the controller lookup whose token the
  /// `onTextSelected` payload carries (`controllerLookup`); null for a tap /
  /// hover / keyboard-caret lookup (no token) or a token no longer pending.
  ReaderControllerLookupRequest? _claim(Object? token) => _requests.take(token);

  /// The claimed lookup's scanned query text (after the ruby snap decision,
  /// before the cap): the upper bound of the selection's right end.
  void _recordScanned(String scannedText) {
    _scannedGraphemes = scannedText.characters.length;
  }

  /// Hands the controller cursor to the in-page popup's caret (pick a word in
  /// the result, nested lookups). Nothing to enter when no popup is shown
  /// (lookups on the companion, or nothing found) or the caret is already
  /// there.
  @override
  Future<void> enterResult() async {
    final _ReaderFushiPageState s = _s;
    if (!s.mounted || !s.isDictionaryShown) return;
    if (s._caretSurface != CaretSurface.reader &&
        s._caretSurface != CaretSurface.lyrics) {
      return;
    }
    final DictionaryPopupWebViewState? top = s._caretTopPopupState;
    if (top == null) return;
    await s._caret.transferToTopPopup(top);
  }
}

/// The reader's pending controller lookups, by token: each
/// [_ReaderControllerLookupTarget.lookupAtCursor] gets a fresh token that the
/// caret JS stamps on that lookup's `onTextSelected` payload
/// (`controllerLookup`), and `_handleTextSelected` claims by it. The claim never
/// depends on which payload arrives first, so a tap / hover lookup landing
/// between the JS call and its payload is not taken for the controller's (same
/// scheme as the manga controller cursor).
@visibleForTesting
class ReaderControllerLookupRequests {
  int _lastToken = 0;
  final Map<int, ReaderControllerLookupRequest> _pending =
      <int, ReaderControllerLookupRequest>{};

  /// Registers a lookup with its right-end cap; its token goes into the JS.
  ({int token, ReaderControllerLookupRequest request}) start(
    int? maxGraphemes,
  ) {
    final int token = ++_lastToken;
    final ReaderControllerLookupRequest request = ReaderControllerLookupRequest(
      maxGraphemes,
    );
    _pending[token] = request;
    return (token: token, request: request);
  }

  /// The pending lookup stamped with [token] (a payload's `controllerLookup`),
  /// removed; null for anything else (no token = tap / hover lookup).
  ReaderControllerLookupRequest? take(Object? token) {
    final int? key = token is num ? token.toInt() : null;
    return key == null ? null : _pending.remove(key);
  }

  /// No payload will come for [token] (nothing to look up, eval failed):
  /// completes it with no match.
  void cancel(int token) => _pending.remove(token)?.complete(0);

  /// Completes every pending lookup with no match (mode left, page leaving).
  void cancelAll() {
    for (final ReaderControllerLookupRequest r in _pending.values) {
      r.complete(0);
    }
    _pending.clear();
  }

  /// Lookups still waiting for their payload.
  int get pendingCount => _pending.length;
}

/// One controller lookup waiting for `_handleTextSelected`.
@visibleForTesting
class ReaderControllerLookupRequest {
  ReaderControllerLookupRequest(this.maxGraphemes);

  /// The mode's cap on the query (null = the dictionary's longest match).
  final int? maxGraphemes;

  final Completer<int> _done = Completer<int>();

  /// The highlighted match length (0 = nothing matched / not shown in page).
  Future<int> get result => _done.future;

  void complete(int matched) {
    if (!_done.isCompleted) _done.complete(matched);
  }
}

/// The query of a controller lookup: [text] (scanned from the cursor) cut to
/// [maxGraphemes] graphemes (null = uncut), with the ruby spans that still lie
/// inside the cut text.
@visibleForTesting
({String text, List<FushiRubySpan> rubySpans}) readerControllerCappedQuery(
  String text,
  List<FushiRubySpan> rubySpans, {
  required int? maxGraphemes,
}) {
  if (maxGraphemes == null || maxGraphemes <= 0) {
    return (text: text, rubySpans: rubySpans);
  }
  final Characters chars = text.characters;
  if (chars.length <= maxGraphemes) return (text: text, rubySpans: rubySpans);
  final String cut = chars.take(maxGraphemes).toString();
  return (
    text: cut,
    rubySpans: <FushiRubySpan>[
      for (final FushiRubySpan span in rubySpans)
        if (span.end <= cut.length) span,
    ],
  );
}

/// What a tapped (or cursor) word sends to the companion's Lookup tab: the
/// sentence with the word's index (the tab scans from it and mines the
/// sentence), or the query itself when the page reported no usable sentence.
/// A capped [query] (shorter than the scanned [text]) cuts the scanned source
/// at the cap, so the tab's scan cannot run past it; the mining sentence stays
/// whole.
@visibleForTesting
({String text, int charIndex, String sentence})
readerControllerCompanionLookup({
  required String text,
  required String sentence,
  required int sentenceOffset,
  String? query,
}) {
  final String trimmed = sentence.trim();
  final bool hasSentence =
      trimmed.isNotEmpty &&
      sentenceOffset >= 0 &&
      sentenceOffset < sentence.length;
  final String term = query ?? text;
  if (!hasSentence) return (text: term, charIndex: -1, sentence: term);
  final bool capped = term.length < text.length;
  return (
    text: capped
        ? sentence.substring(
            0,
            (sentenceOffset + term.length).clamp(0, sentence.length),
          )
        : sentence,
    charIndex: sentenceOffset,
    sentence: sentence,
  );
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
    target._requests.cancelAll();
    ControllerLookupMode.instance.detach(target);
    _controllerLookupTarget = null;
  }
}
