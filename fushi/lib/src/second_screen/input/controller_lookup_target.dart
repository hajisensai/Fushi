/// How controller lookup mode is switched on (preference
/// [kControllerLookupStylePrefKey], device-local).
enum ControllerLookupStyle {
  /// Navigation is live only while L1 (LB) is held. A short tap of L1 keeps
  /// its normal page binding (fired on release).
  holdL1,

  /// Select toggles the mode on and off; a badge shows while it is on.
  selectToggle,

  /// Controller lookup mode is unavailable.
  off;

  static ControllerLookupStyle? tryParse(Object? value) {
    for (final ControllerLookupStyle s in ControllerLookupStyle.values) {
      if (s.name == value) return s;
    }
    return null;
  }

  /// The stored value, else the default: hold-L1 while the companion is up,
  /// otherwise off (single-screen controller behaviour stays exactly as it
  /// was until the user opts in).
  static ControllerLookupStyle resolve(
    Object? stored, {
    required bool companionActive,
  }) =>
      tryParse(stored) ??
      (companionActive
          ? ControllerLookupStyle.holdL1
          : ControllerLookupStyle.off);
}

/// Preference key of [ControllerLookupStyle] (`holdL1` / `selectToggle` /
/// `off`; unset = the default of [ControllerLookupStyle.resolve]).
const String kControllerLookupStylePrefKey = 'controller_lookup_style';

/// What a top page (reader / video / manga / music lyrics) exposes so the
/// shared `ControllerLookupMode` can drive its existing cursor. The mode owns
/// the buttons, key repeat, lookup-open routing and the companion; the page
/// only moves its own cursor and runs its normal lookup path (which routes to
/// the companion's Lookup tab through `routeCompanionLookup` when the
/// companion is up and to the in-page popup otherwise).
///
/// A page attaches its target while it is on screen
/// (`ControllerLookupMode.instance.attach(target)` in `initState`, `detach` in
/// `dispose`); a later attach replaces an earlier one, `detach` only clears its
/// own.
abstract class ControllerLookupTarget {
  ControllerLookupTarget({required this.readPref});

  /// Preference access (`appModel.prefsRepo.getPref`).
  final Object? Function(String key) readPref;

  /// False while the page cannot take controller lookups right now (its route
  /// is covered by another page or a dialog, no media loaded): the mode then
  /// stays out of the way and every button keeps its page binding.
  bool get isAvailable => true;

  /// False while the page's own caret sits on its in-page dictionary popup
  /// (single screen): D-pad / A / B then go to the page's existing popup
  /// controller handling untouched.
  bool get routerOwnsInput => true;

  /// Whether [stepCursor] can move by word. When false word steps fall back
  /// to characters.
  bool get hasWordSteps => false;

  /// The mode switched on: place the cursor (pause media per the page's
  /// existing lookup behaviour).
  void onModeEntered();

  /// The mode switched off: remove the cursor, resume media per the page's
  /// existing behaviour.
  void onModeExited();

  /// Moves the cursor [dir] (+1 forward, -1 back) by word or character.
  Future<void> stepCursor(int dir, {required bool word});

  /// Moves the cursor to the next (+1) / previous (-1) line (subtitle cue,
  /// text line, lyric line, OCR block).
  Future<void> stepLine(int dir);

  /// Looks up the word under the cursor through the page's normal lookup path.
  Future<void> lookupAtCursor();
}
