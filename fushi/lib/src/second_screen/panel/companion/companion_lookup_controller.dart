import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';

/// One lookup the Lookup tab showed.
@immutable
class CompanionLookupEntry {
  const CompanionLookupEntry({
    required this.text,
    required this.charIndex,
    required this.sentence,
    required this.term,
    required this.at,
    this.source,
  });

  /// The source text handed to the dictionary (a line / sentence, or the
  /// query itself when [charIndex] is -1).
  final String text;

  /// Tapped UTF-16 index in [text]; -1 = [text] is the query.
  final int charIndex;

  /// Mining sentence (null = [text]).
  final String? sentence;

  /// Best guess of the looked-up word (history label).
  final String term;

  /// Title of what was open on top when it was looked up ("from こころ").
  final String? source;
  final DateTime at;
}

final RegExp _termRun = RegExp(r'^[^\s、。，,.!?！？「」『』（）()\[\]【】…‥・]{1,8}');

/// The history label of a lookup: the whole text when it has no tapped index,
/// else the run of non-space, non-punctuation characters from the tapped
/// index (capped), which is roughly what the dictionary scans. Never a
/// reading guess: only characters of the source text.
String companionLookupTerm(String text, int charIndex) {
  if (charIndex < 0 || charIndex >= text.length) return text.trim();
  final Match? m = _termRun.firstMatch(text.substring(charIndex));
  return m?.group(0) ?? text.trim();
}

/// The Lookup tab's state in the companion panel: the lookup on show (from
/// the main screen, a history entry, or a line tapped on a module panel),
/// the in-memory history of this run, and what the main screen is told
/// (`lookupState`: open / term / mined).
class CompanionLookupController extends ChangeNotifier {
  CompanionLookupController({required CompanionPanelSession session})
    : _session = session {
    _seenGeneration = session.lookupGeneration;
    session.addListener(_onSession);
    final CompanionLookupMessage? pending = session.lookup;
    if (pending != null) _fromTop(pending);
  }

  /// History entries kept (newest first).
  static const int maxHistory = 50;

  final CompanionPanelSession _session;
  int _seenGeneration = 0;
  final List<CompanionLookupEntry> _history = <CompanionLookupEntry>[];
  CompanionLookupEntry? _current;
  int _generation = 0;
  int _arrivals = 0;
  bool _reportedOpen = false;
  bool _disposed = false;

  /// The lookup on show; null = none (the tab shows the history).
  CompanionLookupEntry? get current => _current;

  /// Bumps on every lookup shown (also the same word again), so the
  /// dictionary page searches again.
  int get generation => _generation;

  /// Bumps only for lookups made on the **main screen**: the shell switches
  /// to the Lookup tab on these (lookups surface on the bottom screen), not
  /// on lookups started from the panel itself.
  int get arrivals => _arrivals;

  /// This run's lookups, newest first.
  List<CompanionLookupEntry> get history =>
      List<CompanionLookupEntry>.unmodifiable(_history);

  void _onSession() {
    if (_session.lookupGeneration == _seenGeneration) return;
    _seenGeneration = _session.lookupGeneration;
    final CompanionLookupMessage? message = _session.lookup;
    if (message != null) _fromTop(message);
  }

  void _fromTop(CompanionLookupMessage message) {
    _arrivals++;
    _show(
      text: message.text,
      charIndex: message.charIndex,
      sentence: message.sentence,
    );
  }

  /// Looks [text] up on the panel itself (a subtitle / transcript / OCR line
  /// tapped on a module panel). [charIndex] is the tapped UTF-16 index in
  /// [text] (-1 = [text] is the query); [sentence] the mining sentence.
  void lookUp({required String text, int charIndex = -1, String? sentence}) {
    if (text.trim().isEmpty) return;
    _show(text: text, charIndex: charIndex, sentence: sentence);
  }

  /// Looks a history entry up again (it moves to the top).
  void replay(CompanionLookupEntry entry) => _show(
    text: entry.text,
    charIndex: entry.charIndex,
    sentence: entry.sentence,
    source: entry.source,
  );

  void _show({
    required String text,
    required int charIndex,
    required String? sentence,
    String? source,
  }) {
    if (_disposed) return;
    final String term = companionLookupTerm(text, charIndex);
    final String? title = _session.context.title;
    final CompanionLookupEntry entry = CompanionLookupEntry(
      text: text,
      charIndex: charIndex,
      sentence: sentence,
      term: term,
      source: source ?? (title == null || title.isEmpty ? null : title),
      at: DateTime.now(),
    );
    _history.removeWhere(
      (CompanionLookupEntry e) =>
          e.term == entry.term && (e.sentence ?? e.text) == (sentence ?? text),
    );
    _history.insert(0, entry);
    if (_history.length > maxHistory) {
      _history.removeRange(maxHistory, _history.length);
    }
    _current = entry;
    _generation++;
    _reportedOpen = true;
    unawaited(_session.reportLookupState(open: true, term: term));
    notifyListeners();
  }

  /// Closes the dictionary (its close button / back): the tab shows the
  /// history again.
  void close() {
    if (_current == null) return;
    _current = null;
    _session.clearLookup();
    if (_reportedOpen) {
      _reportedOpen = false;
      unawaited(_session.reportLookupState(open: false));
    }
    notifyListeners();
  }

  /// A card was mined from the current lookup (tells the main screen; S6's
  /// controller mode shows it).
  void reportMined() {
    final CompanionLookupEntry? entry = _current;
    if (entry == null) return;
    unawaited(
      _session.reportLookupState(open: true, term: entry.term, mined: true),
    );
  }

  /// The dictionary started one lookup (the shown one, a nested one): the
  /// main engine counts it for the media on top, through the same counter its
  /// in-page popup uses. The panel's own popup writes no counter.
  void countLookup() {
    if (_disposed) return;
    unawaited(_session.reportLookupCounted());
  }

  void removeFromHistory(CompanionLookupEntry entry) {
    if (_history.remove(entry)) notifyListeners();
  }

  void clearHistory() {
    if (_history.isEmpty) return;
    _history.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _session.removeListener(_onSession);
    super.dispose();
  }
}

/// The panel's lookup controller (one per panel run).
final ChangeNotifierProvider<CompanionLookupController>
companionLookupControllerProvider =
    ChangeNotifierProvider<CompanionLookupController>(
      (Ref ref) => CompanionLookupController(
        session: ref.read(companionPanelSessionProvider),
      ),
    );
