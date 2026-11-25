part of '../manga_fushi_page.dart';

// ── Controller lookup mode (ControllerLookupMode, S6) ─────────────────────

/// Manga adapter of the shared controller lookup mode (hold L1 / Select;
/// docs/specs/2026-11-22-gamepad-lookup-unification-design.md).
///
/// The cursor is a logical position in the current page's OCR text: block
/// (payload / reading order) and UTF-16 offset into the overlay's block text.
/// D-pad up / down move between non-empty OCR blocks, left / right step by
/// word (the subtitle sweep tokenizer) or character inside the block. The
/// cursor is drawn in the page's own OCR layer (an outline on the `.ocr-char`
/// span, [MangaControllerCursorScripts]); steps only move it — the mode looks
/// up once the cursor stops ([lookupAtCursor]).
///
/// A lookup selects from the cursor character through the document's own tap
/// path (`fushiSelection.selectFromPosition`), so `onTextSelected` →
/// [_MangaFushiPageState.processMangaSelection] runs exactly as for a tap
/// (the companion's Lookup tab when it is up, the in-page popup otherwise,
/// reusing the warm popup slot instead of stacking). The payload carries a
/// token matching it to its [_MangaControllerLookupRequest]: the page cuts the
/// query to the request's right-end cap (`maxGraphemes`) and completes it with
/// the highlighted match length.
///
/// The cursor stays in the text after a lookup: the in-page popup never takes
/// it, so the next D-pad press picks the next word. Manga has no in-page popup
/// cursor (no `DictionaryCaretController` on this page), so [enterResult]
/// keeps the default no-op; mine / audio / entry buttons reach the popup
/// through the mode's popup hooks.
///
/// Without OCR text on the current page (not recognised yet) the target is
/// unavailable and every button keeps its page binding; "OCR this page" on the
/// companion (or the reader's own OCR) makes it available.
///
/// Manga has only the keyboard shortcut channel (focus-ownership.md): the mode
/// intercepts controller buttons before page dispatch, so no gamepad channel
/// is opened here and no focus is requested.
class _MangaControllerLookupTarget extends ControllerLookupTarget {
  _MangaControllerLookupTarget(this._s, {required super.readPref});

  final _MangaFushiPageState _s;

  bool _active = false;
  bool _detached = false;

  /// Controller lookups whose `onTextSelected` payload has not been handled
  /// yet, by the token stamped on that payload.
  final Map<int, _MangaControllerLookupRequest> _requests =
      <int, _MangaControllerLookupRequest>{};
  int _lookupToken = 0;

  /// Page the cursor position belongs to; a page turn resets the cursor.
  int _page = -1;
  int _block = 0;
  int _char = 0;

  @override
  bool get hasWordSteps => true;

  @override
  bool get isAvailable {
    final _MangaFushiPageState s = _s;
    if (_detached || !s.mounted || s._controller == null) return false;
    final ModalRoute<Object?>? route = ModalRoute.of(s.context);
    if (route != null && !route.isCurrent) return false;
    return mangaControllerFirstTextBlock(_blocks) >= 0;
  }

  List<MokuroBlock> get _blocks {
    final MokuroPayload? payload = _s._payload;
    final int page = _s._currentPage;
    if (payload == null || page < 0 || page >= payload.images.length) {
      return const <MokuroBlock>[];
    }
    return payload.images[page].blocks;
  }

  /// Puts the cursor on the first OCR block of the current page when the page
  /// changed since it was placed. False when the page has no OCR text.
  bool _sync() {
    final List<MokuroBlock> blocks = _blocks;
    final int first = mangaControllerFirstTextBlock(blocks);
    if (first < 0) return false;
    if (_page != _s._currentPage ||
        _block >= blocks.length ||
        mangaControllerBlockText(blocks[_block]).isEmpty) {
      _page = _s._currentPage;
      _block = first;
      _char = 0;
    }
    return true;
  }

  @override
  void onModeEntered() {
    _active = true;
    _page = -1; // always start at the page's first block
    if (_sync()) unawaited(_place());
  }

  @override
  void onModeExited() {
    _active = false;
    if (_detached || !_s.mounted) return;
    unawaited(_run(MangaControllerCursorScripts.clear()));
  }

  /// A page turn while the mode is on: the cursor follows to the new page.
  void onPageChanged() {
    if (!_active || _detached || !_s.mounted) return;
    if (_sync()) {
      unawaited(_place());
    } else {
      unawaited(_run(MangaControllerCursorScripts.clear()));
    }
  }

  @override
  Future<void> stepCursor(int dir, {required bool word}) async {
    if (!_sync()) return;
    final String text = mangaControllerBlockText(_blocks[_block]);
    if (word) {
      final int? next = controllerLookupWordStep(text, _char, dir);
      if (next == null) return; // first / last word of the block
      _char = next;
    } else {
      _char = controllerLookupCharStep(text, _char, dir);
    }
    await _place();
  }

  @override
  Future<void> stepLine(int dir) async {
    if (!_sync()) return;
    final int next = mangaControllerNextTextBlock(_blocks, _block, dir);
    if (next < 0) return;
    _block = next;
    _char = 0;
    await _place();
  }

  @override
  int get graphemesFromCursor {
    final List<MokuroBlock> blocks = _blocks;
    if (_page != _s._currentPage || _block >= blocks.length) return 0;
    return mangaControllerGraphemesFromCursor(
      mangaControllerBlockText(blocks[_block]),
      _char,
    );
  }

  @override
  Future<int> lookupAtCursor({int? maxGraphemes}) async {
    if (_detached || !_s.mounted || !_sync()) return 0;
    final int token = ++_lookupToken;
    final _MangaControllerLookupRequest request = _MangaControllerLookupRequest(
      maxGraphemes,
    );
    _requests[token] = request;
    final Object? status = await _place(lookup: true, lookupToken: token);
    // No payload went out (nothing selectable there, page gone, eval failed):
    // no handler call will complete the request.
    if (status != 'lookup' && _requests.remove(token) != null) {
      request.complete(0);
    }
    return request.matched;
  }

  /// The controller lookup an `onTextSelected` payload belongs to (its
  /// `controllerLookup` token), removed from the pending set; null for a tap /
  /// hover payload.
  _MangaControllerLookupRequest? takeRequest(Object? token) =>
      token is int ? _requests.remove(token) : null;

  /// Completes every pending lookup with no match (page leaving).
  void _cancelRequests() {
    for (final _MangaControllerLookupRequest r in _requests.values) {
      r.complete(0);
    }
    _requests.clear();
  }

  Future<Object?> _place({bool lookup = false, int lookupToken = 0}) => _run(
    MangaControllerCursorScripts.place(
      page: _page,
      block: _block,
      utf16: _char,
      color: _s._controllerCursorCss(),
      lookup: lookup,
      lookupToken: lookupToken,
    ),
  );

  /// Evaluates a cursor script; its status string, or null when the WebView is
  /// gone or the eval failed.
  Future<Object?> _run(String source) async {
    final InAppWebViewController? controller = _s._controller;
    if (controller == null) return null;
    try {
      return await controller.evaluateJavascript(source: source);
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaFushiPage.controllerCursor', e, stack);
      return null;
    }
  }
}

/// One controller lookup in flight: the right-end cap the page applies to the
/// query and the highlighted match length it reports back (0 = no match, or
/// the lookup went to the companion, whose match length the page never sees).
class _MangaControllerLookupRequest {
  _MangaControllerLookupRequest(this.maxGraphemes);

  /// Graphemes the query may take from the cursor; null = unlimited.
  final int? maxGraphemes;

  final Completer<int> _matched = Completer<int>();

  Future<int> get matched => _matched.future;

  void complete(int matched) {
    if (!_matched.isCompleted) _matched.complete(matched);
  }
}

/// The query text of a controller lookup: [text] cut to [maxGraphemes]
/// graphemes (null = unchanged, the dictionary's longest match decides).
String mangaControllerLookupQuery(String text, int? maxGraphemes) {
  if (maxGraphemes == null) return text;
  return text.characters.take(math.max(0, maxGraphemes)).toString();
}

/// Graphemes of [text] from the UTF-16 offset [utf16] to the end (the
/// character at [utf16] included); 0 past the end.
int mangaControllerGraphemesFromCursor(String text, int utf16) {
  if (utf16 < 0 || utf16 >= text.length) return 0;
  return text.substring(utf16).characters.length;
}

/// Text of an OCR block as the overlay renders it (UTF-16 offsets of the
/// `.ocr-char` spans index into this).
String mangaControllerBlockText(MokuroBlock block) =>
    mangaBlockTextLayout(block).text;

/// First block with text; -1 when the page has none.
int mangaControllerFirstTextBlock(List<MokuroBlock> blocks) =>
    blocks.indexWhere((MokuroBlock b) => b.lines.join().trim().isNotEmpty);

/// The next (+1) / previous (-1) block with text after [from]; -1 at the
/// page's first / last text block.
int mangaControllerNextTextBlock(List<MokuroBlock> blocks, int from, int dir) {
  for (int i = from + dir; i >= 0 && i < blocks.length; i += dir) {
    if (blocks[i].lines.join().trim().isNotEmpty) return i;
  }
  return -1;
}

extension _MangaControllerLookup on _MangaFushiPageState {
  void _attachControllerLookup() {
    final _MangaControllerLookupTarget target = _MangaControllerLookupTarget(
      this,
      readPref: (String key) => appModelNoUpdate.prefsRepo.getPref(key),
    );
    _controllerLookupTarget = target;
    ControllerLookupMode.instance.attach(target);
  }

  void _detachControllerLookup() {
    final _MangaControllerLookupTarget? target = _controllerLookupTarget;
    if (target == null) return;
    target._detached = true;
    target._cancelRequests();
    ControllerLookupMode.instance.detach(target);
    _controllerLookupTarget = null;
  }

  /// Cursor outline colour: the theme primary, like the reader's caret ring.
  String _controllerCursorCss() {
    final Color c = Theme.of(context).colorScheme.primary;
    int channel(double v) => (v * 255).round().clamp(0, 255);
    return 'rgba(${channel(c.r)},${channel(c.g)},${channel(c.b)},0.95)';
  }
}
