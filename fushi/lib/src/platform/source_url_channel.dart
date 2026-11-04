import 'package:flutter/services.dart';

/// macOS source links from Launch Services, including links queued during launch.
///
/// Besides card-source links it carries the home-widget / menu-bar links
/// ([routedHosts]: review, stats, continue, widget actions, shortcut, lookup);
/// main.dart routes every event through `handleIncomingUrl`.
///
/// Android uses ReceiveIntent, iOS uses IosUrlEventChannel and Windows uses the
/// existing process-argument channel. Subscribe only on macOS to avoid competing
/// with those platforms' single URL consumers (including AnkiMobile callbacks).
class SourceUrlChannel {
  const SourceUrlChannel._();

  static const EventChannel _events = EventChannel(
    'app.fushi.reader/source_urls/stream',
  );

  static final Stream<String> _urls = _events
      .receiveBroadcastStream()
      .where((dynamic event) => event is String && isRoutedUrl(event))
      .cast<String>();

  /// Native drains its launch queue once on listen, then sends live events.
  static Stream<String> get urls => _urls;

  /// `fushi://` hosts that macOS hands to Dart on this stream (mirrored by
  /// `FushiRoutedUrlHosts` in macos/Runner/AppDelegate.swift). OAuth / AnkiMobile
  /// callbacks are not here: they stay with their own plugins.
  static const Set<String> routedHosts = <String>{
    'source',
    'srs',
    'stats',
    'continue',
    'widget',
    'shortcut',
    'lookup',
  };

  static bool isRoutedUrl(String value) {
    final Uri? uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'fushi' &&
        routedHosts.contains(uri.host);
  }

  /// Transport routing only; the source parser must still validate the payload.
  static bool isSourceUrl(String value) {
    final Uri? uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'fushi' && uri.host == 'source';
  }
}
