import 'package:flutter/services.dart';

import 'package:fushi/src/platform/incoming_fushi_link.dart';

/// macOS source links from Launch Services, including links queued during launch.
///
/// Besides card-source links it carries the home-widget / menu-bar links
/// ([routedHosts]: card sources, pairing links, widget links, shortcuts,
/// leaderboard share-page links, lookup);
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
  /// `fushiRoutedUrlHosts` in macos/Runner/AppDelegate.swift; the two are kept
  /// equal by source_url_native_contract_test). Derived from
  /// [FushiIncomingLinkKind], the same classification `handleIncomingUrl`
  /// dispatches on, so a link kind Dart handles cannot be left out here.
  /// OAuth / AnkiMobile callbacks are not here: they stay with their own plugins.
  static final Set<String> routedHosts = Set<String>.unmodifiable(<String>{
    for (final FushiIncomingLinkKind kind in FushiIncomingLinkKind.values)
      if (kind.routedByNativeShell) kind.host,
  });

  /// Whether [value] is a link this stream delivers: exactly the links
  /// [FushiIncomingLink.classify] accepts as a natively routed kind.
  static bool isRoutedUrl(String value) =>
      FushiIncomingLink.classify(value)?.kind.routedByNativeShell ?? false;

  /// Transport routing only; the source parser must still validate the payload.
  static bool isSourceUrl(String value) {
    final Uri? uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'fushi' && uri.host == 'source';
  }
}
