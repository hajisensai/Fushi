/// MusicBrainz（音乐刮削主源，WS/2 JSON）。
///
/// 纪律（https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting）：每 IP 平均 ≤ 1 req/s
/// （[MusicRequestThrottle.musicBrainz]，进程内所有调用共享一个闸门）、带规范 User-Agent
/// （`fushi/musicbrainz (https://fushi.moe)`，单一真相源 [fushiUserAgent]）。出站一律经
/// [VideoMetadataHttpClient] → `createAppHttpIoClient`（全应用代理装配）。
///
/// JSON 两种形态都吃：搜索结果的 `media[].track[]` 与详情的 `media[].tracks[]`。
library;

import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';

/// 原始响应的落点（识别结束后写 `music_metadata_raw_snapshots`）。
typedef MusicRawResponseSink =
    void Function({
      required MusicMetadataProviderKind provider,
      required String kind,
      required String externalId,
      required String rawJson,
    });

/// MusicBrainz 的 MBID 形态（小写 UUID）。
final RegExp kMusicBrainzIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// 规范化一个标签里的 MBID（去空白、转小写）；不是 UUID 形态返回 null。
String? normalizeMusicBrainzId(String? raw) {
  final String? v = raw?.trim().toLowerCase();
  if (v == null || !kMusicBrainzIdPattern.hasMatch(v)) return null;
  return v;
}

/// Lucene 短语转义（MusicBrainz 搜索语法）：短语里只有 `\` 与 `"` 需要转义。
String musicBrainzPhrase(String value) =>
    '"${value.trim().replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// 标签精确查的查询串（纯函数，测试钉死）。
String buildMusicBrainzRecordingQuery(
  MusicRecordingSearchQuery q, {
  bool withAlbum = true,
}) {
  final List<String> parts = <String>[
    'recording:${musicBrainzPhrase(q.title)}',
  ];
  final String? artist = q.artist?.trim();
  if (artist != null && artist.isNotEmpty) {
    parts.add('artist:${musicBrainzPhrase(artist)}');
  }
  final String? album = q.album?.trim();
  if (withAlbum && album != null && album.isNotEmpty) {
    parts.add('release:${musicBrainzPhrase(album)}');
  }
  // 只要音频录音：MV（video=true）另走 MV 关系，不参与「这首歌是哪条录音」。
  parts.add('video:false');
  return parts.join(' AND ');
}

class MusicBrainzProvider implements MusicRecordingProvider {
  MusicBrainzProvider({
    VideoMetadataHttpClient? transport,
    MusicRequestThrottle? throttle,
    Uri? baseUri,
    String? userAgent,
    this.onRawResponse,
  }) : _transport =
           transport ??
           // 503 = MusicBrainz 限流：退避必须比 1 req/s 的闸门更长，否则重试本身又撞限流
           // （实测：默认 400 ms 退避下 200 首里 3 首三连 503）。
           VideoMetadataHttpClient(baseBackoff: const Duration(seconds: 2)),
       _ownsTransport = transport == null,
       _throttle = throttle ?? MusicRequestThrottle.musicBrainz,
       _base = baseUri ?? Uri.parse('https://musicbrainz.org/ws/2/'),
       _userAgent = userAgent ?? fushiUserAgent('musicbrainz');

  final VideoMetadataHttpClient _transport;
  final bool _ownsTransport;
  final MusicRequestThrottle _throttle;
  final Uri _base;
  final String _userAgent;
  final MusicRawResponseSink? onRawResponse;

  @override
  MusicMetadataProviderKind get providerKind =>
      MusicMetadataProviderKind.musicbrainz;

  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  Future<Map<String, Object?>?> _get(
    String path,
    Map<String, String> query, {
    required String operation,
    String? rawKind,
    String? rawId,
  }) async {
    final Uri uri = _base
        .resolve(path)
        .replace(queryParameters: <String, String>{...query, 'fmt': 'json'});
    try {
      final VideoMetadataHttpResponse res = await _throttle.run(
        () => _transport.get(
          uri,
          headers: <String, String>{
            'User-Agent': _userAgent,
            'Accept': 'application/json',
          },
          operation: operation,
          cacheKey: uri.toString(),
        ),
      );
      final Map<String, Object?> json = res.decodeJsonObject(
        operation: operation,
      );
      if (rawKind != null && rawId != null) {
        onRawResponse?.call(
          provider: providerKind,
          kind: rawKind,
          externalId: rawId,
          rawJson: res.body,
        );
      }
      return json;
    } on VideoMetadataNetworkException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<List<MusicRecording>> searchRecordings(
    MusicRecordingSearchQuery query,
  ) async {
    if (query.title.trim().isEmpty) return const <MusicRecording>[];
    final bool hasAlbum = (query.album?.trim().isNotEmpty ?? false);
    List<MusicRecording> found = await _search(query, withAlbum: hasAlbum);
    // 专辑名常与 MusicBrainz 的发行名写法不同（「Lemon」vs「Lemon - Single」、全角括号）：
    // 带专辑查不到时去掉专辑条件再查一次。专辑仍在打分里参与（识别器）。
    if (found.isEmpty && hasAlbum) {
      found = await _search(query, withAlbum: false);
    }
    return found;
  }

  Future<List<MusicRecording>> _search(
    MusicRecordingSearchQuery query, {
    required bool withAlbum,
  }) async {
    final Map<String, Object?>? json = await _get('recording', <String, String>{
      'query': buildMusicBrainzRecordingQuery(query, withAlbum: withAlbum),
      'limit': '${query.limit.clamp(1, 100)}',
    }, operation: 'musicbrainz recording search');
    final Object? list = json?['recordings'];
    if (list is! List<Object?>) return const <MusicRecording>[];
    return <MusicRecording>[
      for (final Object? r in list)
        if (r is Map<String, Object?>) ?parseMusicBrainzRecording(r),
    ];
  }

  @override
  Future<MusicRecording?> fetchRecording(String mbRecordingId) async {
    final String? id = normalizeMusicBrainzId(mbRecordingId);
    if (id == null) return null;
    final Map<String, Object?>? json = await _get(
      'recording/$id',
      <String, String>{
        'inc':
            'artist-credits+releases+release-groups+media+isrcs+labels+'
            'work-rels+recording-rels+url-rels',
      },
      operation: 'musicbrainz recording lookup',
      rawKind: 'recording',
      rawId: id,
    );
    return json == null ? null : parseMusicBrainzRecording(json);
  }

  @override
  Future<MusicWork?> fetchWork(String mbWorkId) async {
    final String? id = normalizeMusicBrainzId(mbWorkId);
    if (id == null) return null;
    // 关系属性（cover / live …）只在 work 详情的 recording-rels 里；首发日期只在录音
    // 实体（browse）里。两次请求合并成一份。
    final Map<String, Object?>? work = await _get(
      'work/$id',
      <String, String>{'inc': 'recording-rels+artist-credits'},
      operation: 'musicbrainz work lookup',
      rawKind: 'work',
      rawId: id,
    );
    if (work == null) return null;
    final Map<String, Object?>? browse = await _get(
      'recording',
      <String, String>{'work': id, 'inc': 'artist-credits', 'limit': '100'},
      operation: 'musicbrainz work recordings',
      rawKind: 'work_recordings',
      rawId: id,
    );
    return parseMusicBrainzWork(work, browse);
  }

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }
}

String? _str(Object? v) {
  if (v is! String) return null;
  final String t = v.trim();
  return t.isEmpty ? null : t;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

List<Map<String, Object?>> _maps(Object? v) => <Map<String, Object?>>[
  if (v is List<Object?>)
    for (final Object? e in v)
      if (e is Map<String, Object?>) e,
];

List<String> _strings(Object? v) => <String>[
  if (v is List<Object?>)
    for (final Object? e in v)
      if (_str(e) case final String s) s,
];

List<MusicArtistCredit> parseMusicBrainzArtistCredit(
  Object? v,
) => <MusicArtistCredit>[
  for (final Map<String, Object?> c in _maps(v))
    MusicArtistCredit(
      name:
          _str(c['name']) ??
          _str((c['artist'] as Map<String, Object?>?)?['name']) ??
          '',
      mbArtistId: _str((c['artist'] as Map<String, Object?>?)?['id']),
      sortName: _str((c['artist'] as Map<String, Object?>?)?['sort-name']),
      joinPhrase: c['joinphrase'] is String ? c['joinphrase']! as String : '',
    ),
];

/// 一张发行 + 这首在里面的位置（搜索结果 `media[].track[]`，详情 `media[].tracks[]`）。
MusicReleaseRef? parseMusicBrainzRelease(
  Map<String, Object?> r, {
  String? mbRecordingId,
}) {
  final String? id = _str(r['id']);
  if (id == null) return null;
  final Map<String, Object?>? group = r['release-group'] is Map<String, Object?>
      ? r['release-group']! as Map<String, Object?>
      : null;
  int? discPosition;
  int? trackPosition;
  int? trackCount;
  for (final Map<String, Object?> medium in _maps(r['media'])) {
    final List<Map<String, Object?>> tracks = <Map<String, Object?>>[
      ..._maps(medium['track']),
      ..._maps(medium['tracks']),
    ];
    Map<String, Object?>? hit;
    for (final Map<String, Object?> t in tracks) {
      final Object? rec = t['recording'];
      final String? recId = rec is Map<String, Object?>
          ? _str(rec['id'])
          : null;
      // 搜索结果的 track 不带 recording（命中的就是本录音）；详情里一张盘可能多首，
      // 按 recording id 认。
      if (recId == null || mbRecordingId == null || recId == mbRecordingId) {
        hit = t;
        break;
      }
    }
    if (hit != null) {
      discPosition = _int(medium['position']);
      trackPosition = _int(hit['position']) ?? _int(hit['number']);
      trackCount = _int(medium['track-count']);
      break;
    }
  }
  return MusicReleaseRef(
    mbReleaseId: id,
    title: _str(r['title']) ?? '',
    releaseGroupId: _str(group?['id']),
    primaryType: _str(group?['primary-type']),
    secondaryTypes: _strings(group?['secondary-types']),
    status: _str(r['status']),
    date: _str(r['date']),
    country: _str(r['country']),
    discPosition: discPosition,
    trackPosition: trackPosition,
    trackCount: trackCount,
    catalogNumbers: <String>[
      for (final Map<String, Object?> li in _maps(r['label-info']))
        if (_str(li['catalog-number']) case final String c) c,
    ],
    barcode: _str(r['barcode']),
    artistCredit: parseMusicBrainzArtistCredit(r['artist-credit']),
  );
}

MusicRecording? parseMusicBrainzRecording(Map<String, Object?> r) {
  final String? id = _str(r['id']);
  final String? title = _str(r['title']);
  if (id == null || title == null) return null;
  final List<MusicWorkLink> works = <MusicWorkLink>[];
  final List<String> mv = <String>[];
  final List<String> mvOf = <String>[];
  final List<MusicUrlRelation> urls = <MusicUrlRelation>[];
  for (final Map<String, Object?> rel in _maps(r['relations'])) {
    final String type = _str(rel['type']) ?? '';
    final String direction = _str(rel['direction']) ?? 'forward';
    switch (_str(rel['target-type'])) {
      case 'work':
        final Map<String, Object?>? w = rel['work'] is Map<String, Object?>
            ? rel['work']! as Map<String, Object?>
            : null;
        final String? wid = _str(w?['id']);
        if (type == 'performance' && wid != null) {
          works.add(
            MusicWorkLink(
              mbWorkId: wid,
              title: _str(w?['title']) ?? '',
              attributes: _strings(rel['attributes']),
            ),
          );
        }
      case 'recording':
        final String? rid = _str(
          (rel['recording'] as Map<String, Object?>?)?['id'],
        );
        if (type == 'music video' && rid != null) {
          // 关系方向：音频录音 →（music video）→ 视频录音。
          (direction == 'forward' ? mv : mvOf).add(rid);
        }
      case 'url':
        final String? res = _str(
          (rel['url'] as Map<String, Object?>?)?['resource'],
        );
        if (res != null) urls.add(MusicUrlRelation(type: type, url: res));
    }
  }
  return MusicRecording(
    mbRecordingId: id,
    title: title,
    durationMs: _int(r['length']),
    artistCredit: parseMusicBrainzArtistCredit(r['artist-credit']),
    firstReleaseDate: _str(r['first-release-date']),
    isVideo: r['video'] == true,
    disambiguation: _str(r['disambiguation']),
    releases: <MusicReleaseRef>[
      for (final Map<String, Object?> rel in _maps(r['releases']))
        ?parseMusicBrainzRelease(rel, mbRecordingId: id),
    ],
    isrcs: _strings(r['isrcs']),
    works: works,
    musicVideoRecordingIds: mv,
    musicVideoOfRecordingIds: mvOf,
    urls: urls,
    searchScore: _int(r['score']),
  );
}

/// work 详情（关系属性）+ recording browse（首发日期 / 是否视频）→ [MusicWork]。
MusicWork? parseMusicBrainzWork(
  Map<String, Object?> work,
  Map<String, Object?>? browse,
) {
  final String? id = _str(work['id']);
  if (id == null) return null;
  final Map<String, Map<String, Object?>> byId = <String, Map<String, Object?>>{
    for (final Map<String, Object?> r in _maps(browse?['recordings']))
      if (_str(r['id']) case final String rid) rid: r,
  };
  final Map<String, MusicWorkRecording> out = <String, MusicWorkRecording>{};
  for (final Map<String, Object?> rel in _maps(work['relations'])) {
    if (_str(rel['type']) != 'performance') continue;
    final Map<String, Object?>? rec = rel['recording'] is Map<String, Object?>
        ? rel['recording']! as Map<String, Object?>
        : null;
    final String? rid = _str(rec?['id']);
    if (rec == null || rid == null) continue;
    final Map<String, Object?> full = byId[rid] ?? rec;
    out[rid] = MusicWorkRecording(
      mbRecordingId: rid,
      title: _str(full['title']) ?? _str(rec['title']) ?? '',
      artistCreditText: musicArtistCreditText(
        parseMusicBrainzArtistCredit(
          full['artist-credit'] ?? rec['artist-credit'],
        ),
      ),
      durationMs: _int(full['length'] ?? rec['length']),
      firstReleaseDate: _str(full['first-release-date']),
      attributes: _strings(rel['attributes']),
      isVideo: (full['video'] ?? rec['video']) == true,
    );
  }
  // browse 里有、work 关系里没列（关系分页截断）的录音也收进来，属性未知按空。
  for (final MapEntry<String, Map<String, Object?>> e in byId.entries) {
    out.putIfAbsent(
      e.key,
      () => MusicWorkRecording(
        mbRecordingId: e.key,
        title: _str(e.value['title']) ?? '',
        artistCreditText: musicArtistCreditText(
          parseMusicBrainzArtistCredit(e.value['artist-credit']),
        ),
        durationMs: _int(e.value['length']),
        firstReleaseDate: _str(e.value['first-release-date']),
        isVideo: e.value['video'] == true,
      ),
    );
  }
  return MusicWork(
    mbWorkId: id,
    title: _str(work['title']) ?? '',
    type: _str(work['type']),
    language: _str(work['language']),
    recordings: out.values.toList(),
  );
}
