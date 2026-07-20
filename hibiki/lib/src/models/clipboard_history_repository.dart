import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/startup/exit_flush_registry.dart';

/// A single in-memory clipboard-copy history entry (deduped text + copy time).
@immutable
class ClipboardHistoryEntry {
  const ClipboardHistoryEntry({required this.text, required this.copiedAt});

  final String text;
  final DateTime copiedAt;
}

/// Desktop clipboard-copy history repository.
///
/// In-memory `List` (tail = newest) backed by the Drift `clipboard_history`
/// table via debounced write-through, mirroring [DictionaryRepository]'s
/// two-layer dictionary-history pattern: `add` only mutates memory, persistence
/// runs on a trailing debounce (capped by [_persistMaxDelay] so a burst of
/// copies cannot postpone the flush forever), and [ExitFlushRegistry] flushes
/// before the process exits. The panel / transient popup "history" button reads
/// [entries]; the capture point is `DesktopLookupService` (origin=clipboard).
class ClipboardHistoryRepository {
  ClipboardHistoryRepository(this._db) {
    _exitFlush = ExitFlushRegistry.instance.register(flushNow);
  }

  final HibikiDatabase _db;
  late final ExitFlushCallback _exitFlush;

  final List<ClipboardHistoryEntry> _entries = <ClipboardHistoryEntry>[];

  /// History cap (tail = newest; trim from the head past this). Clipboard text
  /// is far smaller than dictionary results, so this is looser than the
  /// 10-item dictionary history.
  static const int kMaxItems = 50;

  static const Duration _persistDebounce = Duration(milliseconds: 300);
  static const Duration _persistMaxDelay = Duration(seconds: 2);

  Timer? _persistTimer;
  DateTime? _dirtySince;

  List<ClipboardHistoryEntry> get entries =>
      List<ClipboardHistoryEntry>.unmodifiable(_entries);

  Future<void> loadFromDb() async {
    // Like dictionary history: flush pending before a reload so a stale
    // snapshot cannot resurrect just-cleared rows.
    await flushNow();
    _entries.clear();
    final List<ClipboardHistoryRow> rows = await _db.getAllClipboardHistory();
    for (final ClipboardHistoryRow row in rows) {
      _entries.add(ClipboardHistoryEntry(
        text: row.content,
        copiedAt: DateTime.fromMillisecondsSinceEpoch(row.copiedAt),
      ));
    }
  }

  /// Record one clipboard-copied text. Empty (after trim) is ignored; an
  /// existing identical text is removed and re-appended (dedupe-to-newest);
  /// over the cap, trim from the head. Schedules a debounced persist.
  void add(String text, DateTime copiedAt) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _entries.removeWhere((ClipboardHistoryEntry e) => e.text == trimmed);
    _entries.add(ClipboardHistoryEntry(text: trimmed, copiedAt: copiedAt));
    while (_entries.length > kMaxItems) {
      _entries.removeAt(0);
    }
    _schedulePersist();
  }

  Future<void> clear() async {
    // Cancel pending flush first: a stale snapshot written after the clear
    // would resurrect the just-cleared history.
    _cancelPending();
    await _db.clearClipboardHistory();
    _entries.clear();
  }

  void _schedulePersist() {
    final DateTime now = DateTime.now();
    _dirtySince ??= now;
    _persistTimer?.cancel();
    final bool capReached =
        now.difference(_dirtySince!) >= _persistMaxDelay;
    _persistTimer = Timer(
      capReached ? Duration.zero : _persistDebounce,
      () => unawaited(_flush()),
    );
  }

  void _cancelPending() {
    _persistTimer?.cancel();
    _persistTimer = null;
    _dirtySince = null;
  }

  /// Flush pending changes immediately; no-op when nothing is pending. Used by
  /// exit flush and by [loadFromDb] before a reload.
  Future<void> flushNow() async {
    if (_persistTimer == null && _dirtySince == null) return;
    await _flush();
  }

  Future<void> _flush() async {
    _cancelPending();
    final List<ClipboardHistoryCompanion> items = <ClipboardHistoryCompanion>[];
    for (int i = 0; i < _entries.length; i++) {
      items.add(ClipboardHistoryCompanion.insert(
        position: i,
        content: _entries[i].text,
        copiedAt: _entries[i].copiedAt.millisecondsSinceEpoch,
      ));
    }
    await _db.replaceAllClipboardHistory(items);
  }

  void dispose() {
    _cancelPending();
    ExitFlushRegistry.instance.unregister(_exitFlush);
    _entries.clear();
  }
}

/// Bumped by AppModel after the clipboard history changes (add/clear) so a popup
/// currently showing the history list refreshes. Mirrors the home dictionary
/// tab's `DictionaryHistoryNotifier` minimal [ChangeNotifier].
class ClipboardHistoryNotifier extends ChangeNotifier {
  void bump() => notifyListeners();
}
