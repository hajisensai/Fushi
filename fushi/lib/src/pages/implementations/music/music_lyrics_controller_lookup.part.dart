part of 'music_lyrics_page.dart';

// ── Controller lookup mode (ControllerLookupMode, S6) ─────────────────────

/// Music lyrics adapter of the shared controller lookup mode (hold L1 /
/// Select): a cursor on one character of a lyric line ([KaraokeLyricsCursor],
/// drawn by the lyrics view itself: the row stays in view, un-dimmed, the
/// glyph outlined). Line steps = previous / next lyric line with text, cursor
/// steps = word (subtitle sweep tokenizer) or character within the line. The
/// mode looks up after every stop ([lookupAtCursor]) through the page's normal
/// lyric lookup ([_MusicLyricsPageState._onLookup] with the hit a tap on that
/// glyph gives, the query cut to the mode's right-end cap): the companion's
/// Lookup tab when it is up, else the in-page popup, replacing the open one in
/// the warm slot (pausing per the page's lookup setting). The cursor stays in
/// the lyrics: the music page has no in-page popup cursor, so
/// [enterResult] keeps the default no-op and [routerOwnsInput] stays true —
/// the popup is driven by the mode's mine / audio / entry / scroll / close
/// buttons, words inside it are picked by touch or mouse. No music gamepad
/// channel is opened: the mode intercepts the buttons before page dispatch.
class _MusicControllerLookupTarget extends ControllerLookupTarget {
  _MusicControllerLookupTarget(this._s, {required super.readPref});

  final _MusicLyricsPageState _s;
  bool _detached = false;

  KaraokeLyricsCursor get _cursor => _s._lookupCursor;

  @override
  bool get hasWordSteps => true;

  @override
  bool get isAvailable {
    final _MusicLyricsPageState s = _s;
    if (_detached || !s.mounted || !_cursor.attached) return false;
    final LyricTimeline? t = s._timeline;
    if (t == null || musicControllerNextTextLine(t, -1, 1) < 0) return false;
    final ModalRoute<Object?>? route = ModalRoute.of(s.context);
    return route == null || route.isCurrent;
  }

  @override
  void onModeEntered() {
    final LyricTimeline? t = _s._timeline;
    if (t == null) return;
    final int line = _startLine(t);
    if (line >= 0) _cursor.moveTo(line, 0);
  }

  @override
  void onModeExited() {
    if (_detached) return;
    _cursor.clear();
  }

  /// The playing line, else the last looked-up line, else the first line
  /// with text.
  int _startLine(LyricTimeline t) {
    final int playing = musicLyricCurrentLine(
      t,
      _s._engine.position.inMilliseconds,
    );
    for (final int? candidate in <int?>[playing, _s._lookupLine]) {
      if (candidate != null &&
          candidate >= 0 &&
          candidate < t.lines.length &&
          t.lines[candidate].text.trim().isNotEmpty) {
        return candidate;
      }
    }
    return musicControllerNextTextLine(t, -1, 1);
  }

  /// The cursor's line, placed first when hidden (a track change cleared it)
  /// or out of range; null without lyrics.
  int? _line(LyricTimeline t) {
    final int? line = _cursor.line;
    if (line != null && line >= 0 && line < t.lines.length) return line;
    final int start = _startLine(t);
    if (start < 0) return null;
    _cursor.moveTo(start, 0);
    return start;
  }

  @override
  Future<void> stepCursor(int dir, {required bool word}) async {
    final LyricTimeline? t = _s._timeline;
    if (t == null) return;
    final int? line = _line(t);
    if (line == null) return;
    final String text = t.lines[line].text;
    if (text.isEmpty) return;
    final int at = _cursor.charIndex;
    final int? next = word
        ? controllerLookupWordStep(text, at, dir)
        : controllerLookupCharStep(text, at, dir);
    if (next != null) _cursor.moveTo(line, next);
  }

  @override
  Future<void> stepLine(int dir) async {
    final LyricTimeline? t = _s._timeline;
    if (t == null) return;
    final int? line = _line(t);
    if (line == null) return;
    final int next = musicControllerNextTextLine(t, line, dir);
    if (next >= 0) _cursor.moveTo(next, 0);
  }

  /// Graphemes from the cursor's lookup start (a Latin word's first letter,
  /// as the query) to the end of its lyric line; 0 without a cursor.
  @override
  int get graphemesFromCursor {
    final LyricTimeline? t = _s._timeline;
    final int? line = _cursor.line;
    if (t == null || line == null || line < 0 || line >= t.lines.length) {
      return 0;
    }
    return musicLyricsGraphemesFromCursor(
      t.lines[line].text,
      _cursor.charIndex,
    );
  }

  @override
  Future<int> lookupAtCursor({int? maxGraphemes}) async {
    if (!_s.mounted) return 0;
    final KaraokeLookupHit? hit = _cursor.hitAtCursor();
    if (hit == null || hit.lineText.isEmpty) return 0;
    return _s._onLookup(hit, maxGraphemes: maxGraphemes, measureMatch: true);
  }
}

/// The next (+1) / previous (-1) lyric line with text after [from]; -1 at the
/// first / last one.
int musicControllerNextTextLine(LyricTimeline t, int from, int dir) {
  for (int i = from + dir; i >= 0 && i < t.lines.length; i += dir) {
    if (t.lines[i].text.trim().isNotEmpty) return i;
  }
  return -1;
}
