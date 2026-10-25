/// MusicBrainz 之外的三个音乐资料源：AcoustID（声纹）、Cover Art Archive（封面）、
/// VGMdb（动画 / 游戏唱片补充）。出站一律 `createAppHttpIoClient`，各自一个进程内闸门
/// （[MusicRequestThrottle]）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_provider.dart';
import 'package:fushi_engine/media/music/metadata/musicbrainz_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';
import 'package:http/http.dart' as http;

// ── AcoustID ─────────────────────────────────────────────────────────

/// AcoustID 服务端拒绝了应用 key（`error.code == 4`）。设置页据此提示「key 无效」，
/// 识别器把它当成本次不可用（不是网络抖动，重试没有意义）。
class AcoustidKeyRejected implements Exception {
  const AcoustidKeyRejected(this.message);

  final String message;

  @override
  String toString() => 'AcoustidKeyRejected: $message';
}

/// AcoustID 声纹查询（https://acoustid.org/webservice）。需要**应用** API key：本仓不内置
/// 任何 key，由用户在设置里填；没填时 [isAvailable] 为 false，识别器跳过这一步，设置页
/// 说明原因。只上传声纹串与时长，音频本身不出本机。
class AcoustidProvider implements MusicFingerprintProvider {
  AcoustidProvider({
    required String apiKey,
    http.Client? client,
    MusicRequestThrottle? throttle,
    Uri? baseUri,
    this.onRawResponse,
  }) : apiKey = apiKey.trim(),
       _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _throttle = throttle ?? MusicRequestThrottle.acoustid,
       _base = baseUri ?? Uri.parse('https://api.acoustid.org/v2/lookup');

  final String apiKey;
  final http.Client _client;
  final bool _ownsClient;

  /// 单次请求上限。
  final Duration timeout = const Duration(seconds: 20);
  final MusicRequestThrottle _throttle;
  final Uri _base;
  final MusicRawResponseSink? onRawResponse;

  @override
  MusicMetadataProviderKind get providerKind =>
      MusicMetadataProviderKind.acoustid;

  @override
  bool get isAvailable => apiKey.isNotEmpty;

  @override
  String? get unavailableReason =>
      isAvailable ? null : 'AcoustID application API key is not configured';

  @override
  Future<List<AcoustidResult>> lookup({
    required String fingerprint,
    required int durationSec,
  }) async {
    if (!isAvailable) {
      throw MusicMetadataProviderUnavailable(providerKind, unavailableReason!);
    }
    if (fingerprint.isEmpty || durationSec <= 0) {
      return const <AcoustidResult>[];
    }
    final Map<String, String> form = <String, String>{
      'client': apiKey,
      'duration': '$durationSec',
      'fingerprint': fingerprint,
      'meta': 'recordingids',
      'format': 'json',
    };
    // 不走传输层的「非 2xx 即抛」：AcoustID 的业务错误（key 无效 = code 4、声纹非法 =
    // code 3 …）是 HTTP 400 + JSON 正文，要读正文才分得清。
    final http.Response res = await _throttle.run(
      () => _client
          .post(
            _base,
            headers: <String, String>{'User-Agent': fushiUserAgent('acoustid')},
            body: form,
          )
          .timeout(timeout),
    );
    final String body = utf8.decode(res.bodyBytes, allowMalformed: true);
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw VideoMetadataNetworkException(
        'acoustid lookup returned non-JSON (HTTP ${res.statusCode})',
        statusCode: res.statusCode,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw VideoMetadataNetworkException(
        'acoustid lookup response is not an object',
        statusCode: res.statusCode,
      );
    }
    if (res.statusCode >= 500 || res.statusCode == 429) {
      throw VideoMetadataNetworkException(
        'acoustid lookup HTTP ${res.statusCode}',
        statusCode: res.statusCode,
      );
    }
    onRawResponse?.call(
      provider: providerKind,
      kind: 'lookup',
      externalId: '${fingerprint.hashCode.toUnsigned(32)}:$durationSec',
      rawJson: body,
    );
    return parseAcoustidResponse(decoded, statusCode: res.statusCode);
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

/// AcoustID `lookup` 响应 → 结果（按分数降序）。`status != ok` 抛 [AcoustidKeyRejected]
/// （key 问题）或 [VideoMetadataNetworkException]（其它服务端错误）。
List<AcoustidResult> parseAcoustidResponse(
  Map<String, Object?> json, {
  int? statusCode,
}) {
  if (json['status'] != 'ok') {
    final Object? err = json['error'];
    final int? code = err is Map<String, Object?> && err['code'] is int
        ? err['code']! as int
        : null;
    final String message =
        err is Map<String, Object?> && err['message'] is String
        ? err['message']! as String
        : 'acoustid error';
    if (code == 4) throw AcoustidKeyRejected(message);
    throw VideoMetadataNetworkException(
      'acoustid: $message',
      statusCode: statusCode,
    );
  }
  final List<AcoustidResult> out = <AcoustidResult>[];
  final Object? results = json['results'];
  if (results is List<Object?>) {
    for (final Object? r in results) {
      if (r is! Map<String, Object?>) continue;
      final Object? id = r['id'];
      final Object? score = r['score'];
      if (id is! String || score is! num) continue;
      out.add(
        AcoustidResult(
          acoustid: id,
          score: score.toDouble(),
          recordingIds: <String>[
            if (r['recordings'] is List<Object?>)
              for (final Object? rec in r['recordings']! as List<Object?>)
                if (rec is Map<String, Object?>)
                  if (normalizeMusicBrainzId(rec['id'] as String?)
                      case final String rid)
                    rid,
          ],
        ),
      );
    }
  }
  out.sort((AcoustidResult a, AcoustidResult b) => b.score.compareTo(a.score));
  return out;
}

// ── Cover Art Archive ────────────────────────────────────────────────

/// Cover Art Archive（https://musicbrainz.org/doc/Cover_Art_Archive/API）：与 MusicBrainz
/// 一体，JSON 索引经 307 跳到 archive.org，图片字节同样在 archive.org。
class CoverArtArchiveProvider implements MusicCoverProvider {
  CoverArtArchiveProvider({
    http.Client? client,
    MusicRequestThrottle? throttle,
    Uri? baseUri,
    this.onRawResponse,
    this.downloadTimeout = const Duration(seconds: 30),
  }) : _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _throttle = throttle ?? MusicRequestThrottle.musicBrainz,
       _base = baseUri ?? Uri.parse('https://coverartarchive.org/') {
    _transport = VideoMetadataHttpClient(client: _client);
  }

  final http.Client _client;
  final bool _ownsClient;
  late final VideoMetadataHttpClient _transport;
  final MusicRequestThrottle _throttle;
  final Uri _base;
  final MusicRawResponseSink? onRawResponse;
  final Duration downloadTimeout;

  @override
  MusicMetadataProviderKind get providerKind =>
      MusicMetadataProviderKind.coverArtArchive;

  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<List<MusicCoverImage>> fetchReleaseCovers(String mbReleaseId) async {
    final String? id = normalizeMusicBrainzId(mbReleaseId);
    if (id == null) return const <MusicCoverImage>[];
    final Uri uri = _base.resolve('release/$id');
    final VideoMetadataHttpResponse res;
    try {
      res = await _throttle.run(
        () => _transport.get(
          uri,
          headers: <String, String>{
            'User-Agent': fushiUserAgent('cover-art-archive'),
            'Accept': 'application/json',
          },
          operation: 'cover art archive release',
          cacheKey: uri.toString(),
        ),
      );
    } on VideoMetadataNetworkException catch (e) {
      if (e.statusCode == 404) return const <MusicCoverImage>[];
      rethrow;
    }
    onRawResponse?.call(
      provider: providerKind,
      kind: 'release',
      externalId: id,
      rawJson: res.body,
    );
    return parseCoverArtArchive(
      res.decodeJsonObject(operation: 'cover art archive release'),
    );
  }

  @override
  Future<List<int>> download(String url) async {
    final http.Response res = await _client
        .get(
          Uri.parse(url),
          headers: <String, String>{
            'User-Agent': fushiUserAgent('cover-art-archive'),
          },
        )
        .timeout(downloadTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw VideoMetadataNetworkException(
        'cover download HTTP ${res.statusCode}',
        statusCode: res.statusCode,
      );
    }
    return res.bodyBytes;
  }

  @override
  void close() {
    _transport.close();
    if (_ownsClient) _client.close();
  }
}

/// CAA JSON → 图（front 排最前，未审核的排后）。
List<MusicCoverImage> parseCoverArtArchive(Map<String, Object?> json) {
  final List<MusicCoverImage> out = <MusicCoverImage>[];
  final Object? images = json['images'];
  if (images is! List<Object?>) return out;
  for (final Object? i in images) {
    if (i is! Map<String, Object?>) continue;
    final Object? image = i['image'];
    if (image is! String || image.isEmpty) continue;
    final Map<String, String> thumbs = <String, String>{
      if (i['thumbnails'] is Map<String, Object?>)
        for (final MapEntry<String, Object?> e
            in (i['thumbnails']! as Map<String, Object?>).entries)
          if (e.value is String) e.key: e.value! as String,
    };
    out.add(
      MusicCoverImage(
        imageUrl: _https(image),
        thumbnails: thumbs.map(
          (String k, String v) => MapEntry<String, String>(k, _https(v)),
        ),
        types: <String>[
          if (i['types'] is List<Object?>)
            for (final Object? t in i['types']! as List<Object?>)
              if (t is String) t,
        ],
        front: i['front'] == true,
        approved: i['approved'] != false,
      ),
    );
  }
  out.sort((MusicCoverImage a, MusicCoverImage b) {
    if (a.front != b.front) return a.front ? -1 : 1;
    if (a.approved != b.approved) return a.approved ? -1 : 1;
    return 0;
  });
  return out;
}

/// CAA 老数据给 `http://`，archive.org 支持 https——一律升级，不发明文请求。
String _https(String url) =>
    url.startsWith('http://') ? 'https://${url.substring(7)}' : url;

// ── VGMdb ────────────────────────────────────────────────────────────

/// VGMdb（动画 / 游戏 / 声优唱片：日文原名、Catalog No.）。VGMdb 没有官方 API，走社区
/// JSON 镜像 vgmdb.info；频率保守（[MusicRequestThrottle.vgmdb]，1 次 / 3 s）、只在有
/// 目录编号时按编号查一次，且由用户开关控制（[enabled]，默认关）。
class VgmdbProvider implements MusicAlbumCatalogProvider {
  VgmdbProvider({
    required this.enabled,
    VideoMetadataHttpClient? transport,
    MusicRequestThrottle? throttle,
    Uri? baseUri,
    this.onRawResponse,
  }) : _transport = transport ?? VideoMetadataHttpClient(),
       _ownsTransport = transport == null,
       _throttle = throttle ?? MusicRequestThrottle.vgmdb,
       _base = baseUri ?? Uri.parse('https://vgmdb.info/');

  final bool enabled;
  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;
  final MusicRequestThrottle _throttle;
  final Uri _base;
  final MusicRawResponseSink? onRawResponse;

  @override
  MusicMetadataProviderKind get providerKind => MusicMetadataProviderKind.vgmdb;

  @override
  bool get isAvailable => enabled;

  @override
  String? get unavailableReason => enabled ? null : 'VGMdb is turned off';

  @override
  Future<VgmdbAlbum?> findAlbumByCatalog(String catalog) async {
    if (!enabled) {
      throw MusicMetadataProviderUnavailable(providerKind, unavailableReason!);
    }
    final String c = catalog.trim();
    if (c.isEmpty) return null;
    final Uri uri = _base
        .resolve('search/albums/${Uri.encodeComponent(c)}')
        .replace(queryParameters: <String, String>{'format': 'json'});
    final VideoMetadataHttpResponse res;
    try {
      res = await _throttle.run(
        () => _transport.get(
          uri,
          headers: <String, String>{
            'User-Agent': fushiUserAgent('vgmdb'),
            'Accept': 'application/json',
          },
          operation: 'vgmdb catalog search',
          cacheKey: uri.toString(),
          cacheTtl: const Duration(hours: 6),
        ),
      );
    } on VideoMetadataNetworkException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
    onRawResponse?.call(
      provider: providerKind,
      kind: 'catalog_search',
      externalId: c,
      rawJson: res.body,
    );
    return parseVgmdbCatalogSearch(
      res.decodeJsonObject(operation: 'vgmdb catalog search'),
      catalog: c,
    );
  }

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }
}

String _catalogKey(String s) =>
    s.toUpperCase().replaceAll(RegExp(r'[\s\-‐‑–—_~～]'), '');

/// vgmdb.info `search/albums/<q>` → 目录编号**唯一精确**相等的那张（多张同号 = 不认）。
VgmdbAlbum? parseVgmdbCatalogSearch(
  Map<String, Object?> json, {
  required String catalog,
}) {
  final Object? results = json['results'];
  final Object? albums = results is Map<String, Object?>
      ? results['albums']
      : null;
  if (albums is! List<Object?>) return null;
  final String want = _catalogKey(catalog);
  final List<VgmdbAlbum> hits = <VgmdbAlbum>[];
  for (final Object? a in albums) {
    if (a is! Map<String, Object?>) continue;
    final Object? cat = a['catalog'];
    final Object? link = a['link'];
    if (cat is! String || link is! String) continue;
    if (_catalogKey(cat) != want) continue;
    final String id = link.split('/').last;
    if (id.isEmpty) continue;
    final Object? titles = a['titles'];
    hits.add(
      VgmdbAlbum(
        id: id,
        link: 'https://vgmdb.net/album/$id',
        catalog: cat,
        names: <String, String>{
          if (titles is Map<String, Object?>)
            for (final MapEntry<String, Object?> e in titles.entries)
              if (e.value is String && (e.value! as String).trim().isNotEmpty)
                e.key: (e.value! as String).trim(),
        },
        releaseDate: a['release_date'] is String
            ? a['release_date']! as String
            : null,
      ),
    );
  }
  return hits.length == 1 ? hits.single : null;
}
