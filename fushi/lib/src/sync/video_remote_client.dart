import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:http/http.dart' as http;

export 'package:fushi/src/sync/interconnect_host_client.dart'
    show InterconnectHostError, InterconnectPinRefused;

/// A video remote failure (the shared [InterconnectHostError] shape).
typedef VideoRemoteError = InterconnectHostError;

/// A request was refused locally because it would bypass the host's pin.
typedef VideoRemotePinRefused = InterconnectPinRefused;

/// Video remote control of one paired host (credential and pin rules in
/// [InterconnectHostClient]).
class VideoRemoteClient extends InterconnectHostClient
    implements RemoteCoverFetcher {
  VideoRemoteClient({
    required super.repository,
    required super.peer,
    super.httpClient,
    super.pinnedClientFactory,
  });

  Future<Map<String, dynamic>> call(
    String operation, [
    Map<String, dynamic> body = const <String, dynamic>{},
  ]) => postJson(
    '/api/video-remote/$operation',
    body: body,
    authErrorMessage: 'Video remote authentication rejected',
  );

  Future<Map<String, dynamic>> snapshot() => call('snapshot');
  Future<Map<String, dynamic>> events(int revision) => call(
    'events',
    <String, dynamic>{'afterRevision': revision, 'waitMs': 25000},
  );
  Future<Map<String, dynamic>> disconnect() =>
      call('disconnect', <String, dynamic>{'requestId': requestId()});

  /// Whether the selected host declares `videoRemoteControlV1` on
  /// `GET /api/capabilities`. Null when no address answered (unknown).
  Future<bool?> supportsVideoRemote({
    Duration timeout = const Duration(seconds: 5),
  }) => declaresCapability('videoRemoteControlV1', timeout: timeout);

  /// Cover bytes behind [coverUrl], a host-relative path such as
  /// [videoRemoteCoverPath] (the interconnect library's own cover endpoint),
  /// fetched over the same pinned candidates as every other request.
  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async {
    final http.Response? response = await getFromHost(
      coverUrl,
      timeout: const Duration(seconds: 15),
    );
    if (response == null) {
      throw const VideoRemoteError(VideoRemoteError.unreachableCode);
    }
    return response.bodyBytes;
  }

  /// Pairing identity of the host: another host or a re-pairing (new token)
  /// must not reuse cached covers; a changed address must. A content digest,
  /// not `Object.hash` (seeded per process): the disk cache outlives restarts.
  @override
  String get coverCacheNamespace {
    final String host = peer.hostId ?? '${peer.url}|${peer.fingerprintSha256}';
    final Digest digest = sha256.convert(utf8.encode('$host|${peer.token}'));
    return 'vr${digest.toString().substring(0, 16)}';
  }

  final Map<String, _SubtitleChunks> _subtitleCache =
      <String, _SubtitleChunks>{};

  /// Cached subtitle pages keyed by (sessionId, subtitleVersion). A version is
  /// immutable on the host, so loaded chunks are reused across reconnects and
  /// track flips; an interrupted load resumes from the first missing chunk.
  /// Returns null when [active] turns false before the list is complete.
  Future<List<Map<String, dynamic>>?> subtitles({
    required String sessionId,
    required int subtitleVersion,
    required int expectedTotal,
    required bool Function() active,
    int chunkSize = 200,
  }) async {
    final String key = '$sessionId|$subtitleVersion';
    final _SubtitleChunks cache =
        _subtitleCache.remove(key) ?? _SubtitleChunks(expectedTotal);
    // Keep the most recently used versions last; evict the oldest beyond 3.
    _subtitleCache[key] = cache;
    while (_subtitleCache.length > 3) {
      _subtitleCache.remove(_subtitleCache.keys.first);
    }
    int offset = 0;
    while (offset < cache.total) {
      List<Map<String, dynamic>>? chunk = cache.chunks[offset];
      if (chunk == null) {
        if (!active()) return null;
        final Map<String, dynamic> page =
            await call('subtitles', <String, dynamic>{
              'sessionId': sessionId,
              'subtitleVersion': subtitleVersion,
              'offset': offset,
              'limit': chunkSize,
            });
        chunk = <Map<String, dynamic>>[
          for (final dynamic e in page['cues'] as List? ?? <dynamic>[])
            Map<String, dynamic>.from(e as Map),
        ];
        cache.total = (page['total'] as num?)?.toInt() ?? cache.total;
        if (chunk.isEmpty) {
          cache.total = offset;
          break;
        }
        cache.chunks[offset] = chunk;
      }
      offset += chunk.length;
    }
    final List<Map<String, dynamic>> cues = <Map<String, dynamic>>[];
    while (cues.length < cache.total) {
      final List<Map<String, dynamic>>? chunk = cache.chunks[cues.length];
      if (chunk == null) break;
      cues.addAll(chunk);
    }
    return cues;
  }
}

/// Host-relative path of a library video's cover (the interconnect library's
/// `GET /api/library/videos/<bookUid>/cover`).
String videoRemoteCoverPath(String bookUid) =>
    '/api/library/videos/${Uri.encodeFull(bookUid)}/cover';

class _SubtitleChunks {
  _SubtitleChunks(this.total);
  int total;
  final Map<int, List<Map<String, dynamic>>> chunks =
      <int, List<Map<String, dynamic>>>{};
}
