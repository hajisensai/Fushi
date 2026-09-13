import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// qBittorrent-compatible default public tracker subscription.
const String kDefaultTrackerSubscriptionUrl =
    'https://cf.trackerslist.com/best.txt';

const int _maxSubscriptionBytes = 1024 * 1024;
const int _maxTrackers = 512;

class TrackerSubscriptionException implements Exception {
  const TrackerSubscriptionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _TrackerCacheEntry {
  const _TrackerCacheEntry(this.trackers, this.fetchedAt);

  final List<String> trackers;
  final DateTime fetchedAt;
}

/// Fetches and caches newline-delimited tracker subscriptions.
///
/// Only HTTP(S) subscription URLs are accepted. Tracker entries are limited to
/// protocols supported by both qBittorrent and the bundled libtorrent bridge;
/// comments, malformed lines, duplicates and WebSocket trackers are ignored.
class TrackerSubscriptionService {
  TrackerSubscriptionService({
    required Future<http.Client> Function() httpClientFactory,
    this.cacheTtl = const Duration(hours: 6),
    this.requestTimeout = const Duration(seconds: 15),
  }) : _httpClientFactory = httpClientFactory;

  final Future<http.Client> Function() _httpClientFactory;
  final Duration cacheTtl;
  final Duration requestTimeout;
  final Map<String, _TrackerCacheEntry> _cache = <String, _TrackerCacheEntry>{};
  final Map<String, Future<List<String>>> _inFlight =
      <String, Future<List<String>>>{};

  Future<List<String>> fetch(String sourceUrl, {bool forceRefresh = false}) {
    final Uri source = _parseSourceUrl(sourceUrl);
    final String key = source.toString();
    final _TrackerCacheEntry? cached = _cache[key];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) < cacheTtl) {
      return Future<List<String>>.value(cached.trackers);
    }
    final Future<List<String>>? running = _inFlight[key];
    if (running != null) return running;
    final Future<List<String>> request = _fetch(source).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = request;
    return request;
  }

  Future<List<String>> _fetch(Uri source) async {
    final http.Client client = await _httpClientFactory();
    try {
      final http.Response response = await client
          .get(source)
          .timeout(requestTimeout);
      if (response.statusCode != 200) {
        throw TrackerSubscriptionException('HTTP ${response.statusCode}');
      }
      if (response.bodyBytes.length > _maxSubscriptionBytes) {
        throw const TrackerSubscriptionException('response is too large');
      }
      final List<String> trackers = parseTrackerSubscription(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      if (trackers.isEmpty) {
        throw const TrackerSubscriptionException('no supported trackers');
      }
      final List<String> immutable = List<String>.unmodifiable(trackers);
      _cache[source.toString()] = _TrackerCacheEntry(immutable, DateTime.now());
      return immutable;
    } on TrackerSubscriptionException {
      rethrow;
    } on TimeoutException {
      throw const TrackerSubscriptionException('request timed out');
    } on Object catch (error) {
      throw TrackerSubscriptionException(error.toString());
    } finally {
      client.close();
    }
  }
}

Uri _parseSourceUrl(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw const TrackerSubscriptionException(
      'subscription URL must use HTTP or HTTPS',
    );
  }
  return uri;
}

List<String> parseTrackerSubscription(String body) {
  final Set<String> seen = <String>{};
  final List<String> result = <String>[];
  for (final String rawLine in const LineSplitter().convert(body)) {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final Uri? uri = Uri.tryParse(line);
    if (uri == null || !uri.hasAuthority || !_supportedTracker(uri)) continue;
    final String tracker = uri.toString();
    if (seen.add(tracker)) result.add(tracker);
    if (result.length >= _maxTrackers) break;
  }
  return result;
}

bool _supportedTracker(Uri uri) =>
    uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'udp';

/// Adds missing `tr=` parameters while preserving the original magnet text.
String appendTrackersToMagnet(String magnetUri, Iterable<String> trackers) {
  final Uri? parsed = Uri.tryParse(magnetUri);
  if (parsed == null || parsed.scheme != 'magnet') return magnetUri;
  final Set<String> existing = Set<String>.from(
    parsed.queryParametersAll['tr'] ?? const <String>[],
  );
  final StringBuffer out = StringBuffer(magnetUri);
  bool hasQuery = magnetUri.contains('?');
  for (final String tracker in trackers) {
    if (!existing.add(tracker)) continue;
    out
      ..write(hasQuery ? '&' : '?')
      ..write('tr=')
      ..write(Uri.encodeQueryComponent(tracker));
    hasQuery = true;
  }
  return out.toString();
}
