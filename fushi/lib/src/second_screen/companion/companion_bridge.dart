import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/platform/widget_links.dart' show WidgetLink;
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/second_screen_controller.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';
import 'package:fushi/src/second_screen/second_screen_pipe.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// Collects the daily summary (main engine data: stats, review decks,
/// libraries). Throws when it cannot.
typedef CompanionSummaryCollector = Future<CompanionDailySummary> Function();

/// Answers one [CompanionRequestMessage] method with a JSON value; throws to
/// reply with an error.
typedef CompanionRequestHandler =
    Future<Object?> Function(Map<String, Object?> args);

/// Opens a `fushi://widget/...` deep link on the main screen.
typedef CompanionLinkOpener = Future<void> Function(String link);

/// What plays on top (music, an audiobook; a video page adds itself in S3).
abstract interface class CompanionNowPlayingSource implements Listenable {
  CompanionNowPlaying? get current;

  Future<void> toggle();
}

/// Main engine's end of the companion: mirrors the top screen's context
/// ([CompanionContextRegistry]), the daily summary and what is playing to the
/// companion panel, and carries out what the panel asks for.
///
/// Nothing is collected or sent unless [SecondScreenController.isActive] (the
/// companion panel is up and wanted) and the panel said it is ready; on
/// "ready" everything is sent again, so a new panel (relaunch after the app
/// came back, the game stream giving the screen back) catches up.
class CompanionBridge {
  CompanionBridge({
    required SecondScreenHost? host,
    required SecondScreenController controller,
    required CompanionContextRegistry contexts,
    required CompanionSummaryCollector collectSummary,
    CompanionNowPlayingSource? nowPlaying,
    Directory? spillRoot,
    Duration Function(DateTime now)? untilNextDay,
  }) : _host = host,
       _controller = controller,
       _contexts = contexts,
       _collectSummary = collectSummary,
       _nowPlaying = nowPlaying,
       _spillRoot =
           spillRoot ?? secondScreenSpillRoot('second_screen_companion'),
       _untilNextDay = untilNextDay {
    final SecondScreenHost? h = host;
    if (h != null) {
      _pipe = SecondScreenPipe(
        post: (String raw) => h.post(SecondScreenPanelMode.companion, raw),
        spillDirectory: Directory(
          '${_spillRoot.path}${Platform.pathSeparator}host',
        ),
      );
    }
    _requestHandlers[CompanionRequestMethods.refreshSummary] =
        (Map<String, Object?> _) async {
          _refreshSummary();
          return null;
        };
  }

  final SecondScreenHost? _host;
  final SecondScreenController _controller;
  final CompanionContextRegistry _contexts;
  final CompanionSummaryCollector _collectSummary;
  final CompanionNowPlayingSource? _nowPlaying;
  final Directory _spillRoot;
  final Duration Function(DateTime now)? _untilNextDay;
  SecondScreenPipe? _pipe;

  final Map<String, CompanionRequestHandler> _requestHandlers =
      <String, CompanionRequestHandler>{};
  CompanionLinkOpener? _openLink;
  StreamSubscription<SecondScreenPanelMessage>? _messages;
  bool _started = false;
  bool _disposed = false;

  /// The companion panel's Dart side said it is listening (reset when the
  /// companion stops being active: the next panel says it again).
  bool _panelReady = false;

  CompanionContext? _sentContext;
  int _sentSnapshotRevision = -1;
  CompanionNowPlaying? _sentNowPlaying;

  bool _summaryRunning = false;
  bool _summaryRerun = false;

  /// Library data changed while media was open: collect again when the Now
  /// tab shows the summary again.
  bool _summaryStale = false;
  Timer? _dayTimer;

  bool _prefsPingScheduled = false;
  bool _libraryPingScheduled = false;
  bool _settingsPingScheduled = false;

  final ValueNotifier<bool> _lookupOpen = ValueNotifier<bool>(false);

  /// Pages route lookups / controls to the second screen only while this is
  /// true; false is today's single-screen behaviour.
  bool get isActive => _controller.isActive;

  /// The companion's lookup panel is open (S3 / S6: A mines instead of
  /// looking up again).
  ValueListenable<bool> get lookupOpen => _lookupOpen;

  /// The top screen's context; pages claim it here (or with
  /// [CompanionContextClaim]) and publish their module snapshots.
  CompanionContextRegistry get contexts => _contexts;

  /// Shows a lookup on the companion. False when it is not in use (or did
  /// not take the message): the page falls back to its in-page popup.
  Future<bool> sendLookup({
    required String text,
    int charIndex = -1,
    String? sentence,
  }) async {
    final SecondScreenPipe? pipe = _pipe;
    if (pipe == null || !_canSend || !_panelReady || text.trim().isEmpty) {
      return false;
    }
    try {
      await pipe.send(
        CompanionLookupMessage(
          text: text,
          charIndex: charIndex,
          sentence: sentence,
        ).encode(),
      );
      return true;
    } catch (error, stack) {
      ErrorLogService.instance.log('CompanionBridge.lookup', error, stack);
      return false;
    }
  }

  /// Where `openOnMain` links go (main.dart's deep-link handler).
  void bindOpenLink(CompanionLinkOpener? openLink) => _openLink = openLink;

  /// Registers the handler of request [method] (S4 settings, S5 library).
  void registerRequestHandler(String method, CompanionRequestHandler handler) {
    _requestHandlers[method] = handler;
  }

  void start() {
    if (_started || _disposed || _host == null) return;
    _started = true;
    _controller.addListener(_onControllerChanged);
    _contexts.setActive(_controller.isActive);
    _contexts.bindLookupSink(sendLookup);
    _contexts.addListener(_onContextChanged);
    _nowPlaying?.addListener(_onNowPlayingChanged);
    _messages = _host.messages.listen(_onHostMessage);
    // Leftovers of a run that was killed before it could clean up.
    unawaited(SecondScreenPipe.clearSpills(_spillRoot));
  }

  // ---- Change pings from the main app -------------------------------------

  /// Preferences changed (theme, locale, dictionary settings, profile):
  /// the panel reloads its prefs. Several changes in one turn send one ping.
  void notifyPrefsChanged() {
    if (!_canSend || _prefsPingScheduled) return;
    _prefsPingScheduled = true;
    scheduleMicrotask(() {
      _prefsPingScheduled = false;
      _send(const CompanionPrefsChangedMessage());
    });
  }

  /// A setting may have changed (a preference write, a write from the
  /// companion): the Settings tab reloads what it shows. Several changes in
  /// one turn send one ping.
  void notifySettingsChanged() {
    if (!_canSend || _settingsPingScheduled) return;
    _settingsPingScheduled = true;
    scheduleMicrotask(() {
      _settingsPingScheduled = false;
      _send(const CompanionSettingsChangedMessage());
    });
  }

  /// Library / study data changed: the panel's lists refresh and the summary
  /// is collected again (now if the Now tab shows it, else when it does).
  void notifyLibraryChanged() {
    if (!_canSend || _libraryPingScheduled) return;
    _libraryPingScheduled = true;
    scheduleMicrotask(() {
      _libraryPingScheduled = false;
      _send(const CompanionLibraryChangedMessage());
      _onSummaryInputsChanged();
    });
  }

  /// Review counts changed (a card was reviewed / mined).
  void notifyReviewsChanged() => _onSummaryInputsChanged();

  // ---- Panel -> main ------------------------------------------------------

  void _onHostMessage(SecondScreenPanelMessage message) {
    if (message.mode != SecondScreenPanelMode.companion) return;
    final SecondScreenPipe? pipe = _pipe;
    if (pipe == null) return;
    pipe.receive(
      message.raw,
      (String raw) => _onPanelMessage(CompanionPanelMessage.decode(raw)),
      (Object error, StackTrace stack) =>
          ErrorLogService.instance.log('CompanionBridge.message', error, stack),
    );
  }

  void _onPanelMessage(CompanionPanelMessage message) {
    if (_disposed) return;
    switch (message) {
      case CompanionReadyMessage():
        _panelReady = true;
        _sentContext = null;
        _sentSnapshotRevision = -1;
        _sentNowPlaying = null;
        _syncContext();
        _syncNowPlaying(force: true);
        _refreshSummary();
      case CompanionCommandMessage(
        :final CompanionContextKind kind,
        :final String action,
        :final Map<String, Object?> args,
      ):
        _contexts.dispatchCommand(kind, action, args);
      case CompanionPlaybackMessage(:final CompanionPlaybackAction action):
        switch (action) {
          case CompanionPlaybackAction.toggle:
            final CompanionNowPlayingSource? source = _nowPlaying;
            if (source != null) unawaited(_guard('playback', source.toggle));
        }
      case CompanionOpenOnMainMessage(:final String link):
        final CompanionLinkOpener? open = _openLink;
        if (open != null && WidgetLink.tryParse(link) != null) {
          unawaited(_guard('openOnMain', () => open(link)));
        }
      case CompanionRequestMessage(
        :final int id,
        :final String method,
        :final Map<String, Object?> args,
      ):
        unawaited(_answer(id, method, args));
      case CompanionLookupStateMessage(:final bool open):
        _lookupOpen.value = open;
    }
  }

  Future<void> _answer(int id, String method, Map<String, Object?> args) async {
    final CompanionRequestHandler? handler = _requestHandlers[method];
    if (handler == null) {
      _send(CompanionReplyMessage(id: id, error: 'unknown method "$method"'));
      return;
    }
    try {
      _send(CompanionReplyMessage(id: id, value: await handler(args)));
    } catch (error, stack) {
      ErrorLogService.instance.log('CompanionBridge.$method', error, stack);
      _send(CompanionReplyMessage(id: id, error: '$error'));
    }
  }

  Future<void> _guard(String what, Future<void> Function() run) async {
    try {
      await run();
    } catch (error, stack) {
      ErrorLogService.instance.log('CompanionBridge.$what', error, stack);
    }
  }

  // ---- Main -> panel ------------------------------------------------------

  bool get _canSend => _started && !_disposed && _controller.isActive;

  void _send(CompanionHostMessage message) {
    final SecondScreenPipe? pipe = _pipe;
    if (pipe == null || !_canSend || !_panelReady) return;
    unawaited(
      pipe
          .send(message.encode())
          .catchError(
            (Object error, StackTrace stack) => ErrorLogService.instance.log(
              'CompanionBridge.send',
              error,
              stack,
            ),
          ),
    );
  }

  void _onControllerChanged() {
    _contexts.setActive(_controller.isActive);
    if (_controller.isActive) return;
    // The panel is gone or the screen was taken: wait for the next "ready".
    _panelReady = false;
    _lookupOpen.value = false;
    _dayTimer?.cancel();
    _dayTimer = null;
  }

  void _onContextChanged() {
    final bool wasMedia = _sentContext?.kind.isMedia ?? false;
    _syncContext();
    if (wasMedia && !_contexts.current.kind.isMedia && _summaryStale) {
      _refreshSummary();
    }
  }

  void _syncContext() {
    if (!_canSend || !_panelReady) return;
    final CompanionContext context = _contexts.current;
    if (context != _sentContext) {
      _sentContext = context;
      _sentSnapshotRevision = -1;
      _send(CompanionContextMessage(context));
    }
    final Map<String, Object?>? snapshot = _contexts.currentSnapshot;
    if (snapshot != null &&
        _contexts.snapshotRevision != _sentSnapshotRevision) {
      _sentSnapshotRevision = _contexts.snapshotRevision;
      _send(CompanionSnapshotMessage(kind: context.kind, data: snapshot));
    }
  }

  void _onNowPlayingChanged() => _syncNowPlaying();

  void _syncNowPlaying({bool force = false}) {
    final CompanionNowPlayingSource? source = _nowPlaying;
    if (!_canSend || !_panelReady) return;
    final CompanionNowPlaying? now = source?.current;
    if (!force && now == _sentNowPlaying) return;
    _sentNowPlaying = now;
    _send(CompanionNowPlayingMessage(now));
  }

  void _onSummaryInputsChanged() {
    if (!_canSend || !_panelReady) return;
    if (_contexts.current.kind.isMedia) {
      _summaryStale = true;
      return;
    }
    _refreshSummary();
  }

  /// Collects and sends the summary; one collection at a time, a request
  /// during one runs once more after it.
  void _refreshSummary() {
    if (!_canSend || !_panelReady) return;
    if (_summaryRunning) {
      _summaryRerun = true;
      return;
    }
    unawaited(_runSummary());
  }

  Future<void> _runSummary() async {
    _summaryRunning = true;
    try {
      do {
        _summaryRerun = false;
        _summaryStale = false;
        CompanionDailySummary? summary;
        try {
          summary = await _collectSummary();
        } catch (error, stack) {
          ErrorLogService.instance.log('CompanionBridge.summary', error, stack);
        }
        _send(CompanionSummaryMessage(summary));
        _armDayTimer();
      } while (_summaryRerun && _canSend && _panelReady);
    } finally {
      _summaryRunning = false;
    }
  }

  /// "Today" turns into yesterday at the statistics day boundary: collect
  /// again then.
  void _armDayTimer() {
    final Duration Function(DateTime now)? untilNextDay = _untilNextDay;
    _dayTimer?.cancel();
    _dayTimer = null;
    if (untilNextDay == null || !_canSend) return;
    _dayTimer = Timer(untilNextDay(DateTime.now()), () {
      _dayTimer = null;
      _onSummaryInputsChanged();
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _dayTimer?.cancel();
    if (_started) {
      _contexts.setActive(false);
      _contexts.bindLookupSink(null);
      _controller.removeListener(_onControllerChanged);
      _contexts.removeListener(_onContextChanged);
      _nowPlaying?.removeListener(_onNowPlayingChanged);
    }
    unawaited(_messages?.cancel());
    _lookupOpen.dispose();
  }
}
