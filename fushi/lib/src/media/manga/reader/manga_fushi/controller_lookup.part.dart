part of '../manga_fushi_page.dart';

// ── Controller lookup mode (ControllerLookupMode, S6) ─────────────────────

/// Manga adapter of the shared controller lookup mode (hold L1 / Select).
///
/// The cursor is a logical position in the current page's OCR text: block
/// (payload / reading order) and UTF-16 offset into `block.lines.join()`.
/// D-pad up / down move between non-empty OCR blocks, left / right step by
/// word (the subtitle sweep tokenizer) or character inside the block. The
/// cursor is drawn in the page's own OCR layer (an outline on the `.ocr-char`
/// span, [MangaControllerCursorScripts]); A selects from that character
/// through the document's own tap path (`fushiSelection.selectFromPosition`),
/// so `onTextSelected` → [_MangaFushiPageState.processMangaSelection] runs
/// exactly as for a tap: the companion's Lookup tab when it is up, the in-page
/// popup otherwise.
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
  Future<void> lookupAtCursor() async {
    if (!_sync()) return;
    await _place(lookup: true);
  }

  Future<void> _place({bool lookup = false}) => _run(
    MangaControllerCursorScripts.place(
      page: _page,
      block: _block,
      utf16: _char,
      color: _s._controllerCursorCss(),
      lookup: lookup,
    ),
  );

  Future<void> _run(String source) async {
    final InAppWebViewController? controller = _s._controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(source: source);
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaFushiPage.controllerCursor', e, stack);
    }
  }
}

/// Text of an OCR block as the overlay renders it (UTF-16 offsets of the
/// `.ocr-char` spans index into this).
String mangaControllerBlockText(MokuroBlock block) => block.lines.join();

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
