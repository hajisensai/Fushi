import 'package:flutter/foundation.dart';

/// What an open video page tells the companion's now-playing bar. Read live
/// (getters), so the bar is right whenever it is rebuilt; the page calls
/// [CompanionVideoPlaybackRegistry.changed] when the values move.
@immutable
class CompanionVideoPlayback {
  const CompanionVideoPlayback({
    required this.title,
    required this.playing,
    required this.toggle,
  });

  /// The title on show (empty = not loaded yet: the bar ignores the page).
  final String Function() title;
  final bool Function() playing;

  /// Play / pause on the page (the same path as its own play button).
  final Future<void> Function() toggle;
}

/// Open video pages (main engine). Video playback lives in the page, not in
/// an app-wide session like music / audiobooks, so the page registers itself
/// while it is open; the newest registration (the page on top of the stack)
/// is the one that plays. Registering costs nothing on single-screen devices:
/// no timers, no listeners of its own.
class CompanionVideoPlaybackRegistry extends ChangeNotifier {
  final List<(Object, CompanionVideoPlayback)> _entries =
      <(Object, CompanionVideoPlayback)>[];

  /// The newest open video page; null when none is open.
  CompanionVideoPlayback? get current =>
      _entries.isEmpty ? null : _entries.last.$2;

  /// [owner] (a video page) is open. Registering again replaces its entry
  /// (keeps its place).
  void register(Object owner, CompanionVideoPlayback playback) {
    final int at = _entries.indexWhere(
      ((Object, CompanionVideoPlayback) e) => identical(e.$1, owner),
    );
    if (at >= 0) {
      _entries[at] = (owner, playback);
    } else {
      _entries.add((owner, playback));
    }
    notifyListeners();
  }

  /// [owner]'s page closed.
  void unregister(Object owner) {
    final int before = _entries.length;
    _entries.removeWhere(
      ((Object, CompanionVideoPlayback) e) => identical(e.$1, owner),
    );
    if (_entries.length != before) notifyListeners();
  }

  /// The title / playing state of a registered page changed.
  void changed() {
    if (_entries.isNotEmpty) notifyListeners();
  }
}

/// App-wide registry, read by `AppCompanionNowPlayingSource`.
final CompanionVideoPlaybackRegistry companionVideoPlayback =
    CompanionVideoPlaybackRegistry();
