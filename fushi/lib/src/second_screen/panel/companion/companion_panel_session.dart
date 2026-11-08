import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';

/// Where the panel is with the daily summary.
enum CompanionSummaryStatus {
  /// Nothing received yet.
  loading,
  ready,

  /// The main engine could not collect it.
  failed,
}

/// The request the panel sent never got an answer (the main engine went
/// away) or was answered with an error.
class CompanionRequestException implements Exception {
  const CompanionRequestException(this.message);

  final String message;

  @override
  String toString() => 'CompanionRequestException: $message';
}

/// The companion panel's state: only what the main engine pushed (context,
/// module snapshot, summary, what is playing, lookups), plus the panel's
/// side of the pipe (commands, requests).
class CompanionPanelSession extends ChangeNotifier {
  CompanionPanelSession({required Future<void> Function(String raw) send})
    : _send = send;

  final Future<void> Function(String raw) _send;

  CompanionContext _context = CompanionContext.none;
  Map<String, Object?>? _snapshot;
  CompanionSummaryStatus _summaryStatus = CompanionSummaryStatus.loading;
  CompanionDailySummary? _summary;
  CompanionNowPlaying? _nowPlaying;
  CompanionLookupMessage? _lookup;
  int _lookupGeneration = 0;
  int _libraryRevision = 0;
  int _settingsRevision = 0;
  bool _disposed = false;

  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextId = 1;
  final StreamController<void> _prefsChanges =
      StreamController<void>.broadcast();

  /// The top screen's context.
  CompanionContext get context => _context;

  /// The context owner's last module snapshot (S3); null until it publishes.
  Map<String, Object?>? get snapshot => _snapshot;

  CompanionSummaryStatus get summaryStatus => _summaryStatus;

  /// Set when [summaryStatus] is [CompanionSummaryStatus.ready].
  CompanionDailySummary? get summary => _summary;

  /// What plays on top; null when nothing does.
  CompanionNowPlaying? get nowPlaying => _nowPlaying;

  /// The latest lookup from the top screen (S3); null when none / closed.
  CompanionLookupMessage? get lookup => _lookup;

  /// Bumps on every lookup, so the same word twice still refreshes.
  int get lookupGeneration => _lookupGeneration;

  /// Bumps when the main engine says library data changed; lists keyed on it
  /// reload.
  int get libraryRevision => _libraryRevision;

  /// Bumps when the main engine says a setting may have changed; the
  /// Settings tab reloads what it shows.
  int get settingsRevision => _settingsRevision;

  /// Fires when the main process changed preferences.
  Stream<void> get prefsChanges => _prefsChanges.stream;

  /// Tells the main engine the panel listens; it answers with everything.
  Future<void> start() => _sendMessage(const CompanionReadyMessage());

  /// Feeds one message from the main engine.
  void receive(String raw) {
    if (_disposed) return;
    final CompanionHostMessage message = CompanionHostMessage.decode(raw);
    switch (message) {
      case CompanionContextMessage(:final CompanionContext context):
        _context = context;
        _snapshot = null;
      case CompanionSnapshotMessage(
        :final CompanionContextKind kind,
        :final Map<String, Object?> data,
      ):
        // A snapshot of a context that is already gone is dropped.
        if (kind != _context.kind) return;
        _snapshot = data;
      case CompanionSummaryMessage(:final CompanionDailySummary? summary):
        _summary = summary;
        _summaryStatus = summary == null
            ? CompanionSummaryStatus.failed
            : CompanionSummaryStatus.ready;
      case CompanionNowPlayingMessage(:final CompanionNowPlaying? nowPlaying):
        _nowPlaying = nowPlaying;
      case CompanionLookupMessage():
        _lookup = message;
        _lookupGeneration++;
      case CompanionPrefsChangedMessage():
        _prefsChanges.add(null);
        return;
      case CompanionLibraryChangedMessage():
        _libraryRevision++;
      case CompanionSettingsChangedMessage():
        _settingsRevision++;
      case CompanionReplyMessage(
        :final int id,
        :final Object? value,
        :final String? error,
      ):
        final Completer<Object?>? pending = _pending.remove(id);
        if (pending == null) return;
        if (error != null) {
          pending.completeError(CompanionRequestException(error));
        } else {
          pending.complete(value);
        }
        return;
    }
    notifyListeners();
  }

  /// A control on the context's module panel (S3).
  Future<void> command(
    String action, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) => _sendMessage(
    CompanionCommandMessage(kind: _context.kind, action: action, args: args),
  );

  /// Play / pause whatever plays on top.
  Future<void> togglePlayback() => _sendMessage(
    const CompanionPlaybackMessage(CompanionPlaybackAction.toggle),
  );

  /// Opens a `fushi://widget/...` link on the main screen.
  Future<void> openOnMain(String link) =>
      _sendMessage(CompanionOpenOnMainMessage(link));

  /// Asks the main engine to collect the summary again (after a failure).
  Future<void> retrySummary() async {
    _summaryStatus = CompanionSummaryStatus.loading;
    notifyListeners();
    try {
      await request(CompanionRequestMethods.refreshSummary);
    } on Object {
      _summaryStatus = CompanionSummaryStatus.failed;
      if (!_disposed) notifyListeners();
    }
  }

  /// Tells the top screen whether the lookup panel is open (S3 / S6).
  Future<void> reportLookupState({
    required bool open,
    String? term,
    bool mined = false,
  }) => _sendMessage(
    CompanionLookupStateMessage(open: open, term: term, mined: mined),
  );

  /// Closes the lookup panel.
  void clearLookup() {
    if (_lookup == null) return;
    _lookup = null;
    notifyListeners();
  }

  /// Sends request [method] and waits for the main engine's reply value.
  /// Throws [CompanionRequestException] on an error reply, or when the
  /// message could not be sent.
  Future<Object?> request(
    String method, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) async {
    final int id = _nextId++;
    final Completer<Object?> completer = Completer<Object?>();
    _pending[id] = completer;
    try {
      await _send(
        CompanionRequestMessage(id: id, method: method, args: args).encode(),
      );
    } catch (error) {
      _pending.remove(id);
      throw CompanionRequestException('$error');
    }
    return completer.future;
  }

  Future<void> _sendMessage(CompanionPanelMessage message) =>
      _send(message.encode());

  @override
  void dispose() {
    _disposed = true;
    final List<Completer<Object?>> pending = _pending.values.toList();
    _pending.clear();
    for (final Completer<Object?> c in pending) {
      c.completeError(const CompanionRequestException('panel closed'));
    }
    unawaited(_prefsChanges.close());
    super.dispose();
  }
}

/// The panel's session; overridden in `runCompanionPanel` (and tests).
final ChangeNotifierProvider<CompanionPanelSession>
companionPanelSessionProvider = ChangeNotifierProvider<CompanionPanelSession>(
  (Ref ref) => throw UnimplementedError(
    'companionPanelSessionProvider is overridden by runCompanionPanel',
  ),
);
