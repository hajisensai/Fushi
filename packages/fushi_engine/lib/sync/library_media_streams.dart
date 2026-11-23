/// 互联 host 唯一的一套媒体流票（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §3.5 /
/// §4.3）。
///
/// 播放器（mpv / media_kit）只拿裸 URL、带不了 Basic 头，所以要流的东西都先用 Basic 签一张短时票，
/// 再凭票免 Basic 取字节。以前视频一套（`_VideoStreamToken`）、盘共享一套、插件中继一套，吊销
/// （BUG-4393）、释放（BUG-4461）、TTL、数量上限（BUG-1568）只修在视频那一套上。现在视频与音乐
/// （曲目 / MV）共用这一份：签发、按凭据指纹吊销、按票释放、TTL、上限淘汰都只写一次。
///
/// 本类不碰 HTTP：路由在 `fushi_sync_server/media_streams.part.dart`（统一路径
/// `/api/library/media/{streamurl,stream,streamrelease}`）与视频的老路径别名里，二者查同一张表。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// 流的种类。wire 名出现在 `POST /api/library/media/streamurl` 的 `kind` 字段里，**冻结**。
final class LibraryMediaStreamKind {
  const LibraryMediaStreamKind._(this.wireName);

  /// 视频库（老路径 `/api/library/videos/<id>/stream` 等别名；不经统一 `streamurl` 签发，因为
  /// 视频签发要带转码档 / 集号 / 蓝光段表，仍由视频路由签）。
  static const LibraryMediaStreamKind video = LibraryMediaStreamKind._('video');

  /// 音乐曲目（id = host 的 `track_uid`）。
  static const LibraryMediaStreamKind musicTrack = LibraryMediaStreamKind._(
    'musicTrack',
  );

  /// 曲目绑定的 MV 视频（id = host 的 `music_videos.id`）。
  static const LibraryMediaStreamKind musicVideo = LibraryMediaStreamKind._(
    'musicVideo',
  );

  static const List<LibraryMediaStreamKind> values = <LibraryMediaStreamKind>[
    video,
    musicTrack,
    musicVideo,
  ];

  final String wireName;

  static LibraryMediaStreamKind? fromWire(String? name) {
    for (final LibraryMediaStreamKind k in values) {
      if (k.wireName == name) return k;
    }
    return null;
  }

  @override
  String toString() => wireName;
}

/// 一次签发 / 取流要的东西：票上绑定的 id + 签发时 client 给的种类专属参数（如音乐的码率上限）。
typedef LibraryMediaRequest = ({String id, Map<String, Object?> options});

/// 解析出来的字节来源。
sealed class LibraryMediaSource {
  const LibraryMediaSource({this.info = const <String, Object?>{}});

  /// 签发时随 `url` / `ticket` 一起回给 client 的说明（如 `transcoded` / `segmentApplied`）。
  final Map<String, Object?> info;
}

/// host 本机的一个文件（含按需转码 / 截段后落在缓存里的文件），按 Range 直出。
final class LibraryMediaFile extends LibraryMediaSource {
  const LibraryMediaFile(this.file, {super.info});

  final File file;
}

/// host 代读的上游 HTTP(S) 地址（网络音乐来源，design-imusic-q4）：Range 原样透传。
final class LibraryMediaUpstream extends LibraryMediaSource {
  const LibraryMediaUpstream(
    this.url, {
    this.headers = const <String, String>{},
    super.info,
  });

  final Uri url;
  final Map<String, String> headers;
}

/// 「请求 → 字节来源」：模块只提供这个，签发 / 取流 / 吊销都归 [LibraryMediaStreams]。null = 找不到（404）。
/// 签发时调一次（校验存在、可预热缓存），取流时再调一次（实现应缓存，第二次即时）。
typedef LibraryMediaResolver =
    Future<LibraryMediaSource?> Function(LibraryMediaRequest request);

/// 一张已签发的票。
class LibraryMediaGrant {
  const LibraryMediaGrant({
    required this.kind,
    required this.id,
    required this.issuer,
    required this.createdAt,
    this.ticket,
    this.options,
  });

  final LibraryMediaStreamKind kind;

  /// 绑定的对象 id（视频 bookUid / 曲目 uid / MV id）。取流时只认票上的，不认 URL 里的。
  final String id;

  /// 签发请求所用凭据的指纹。每次取流都对照当前凭据快照，签发凭据被吊销即作废（BUG-4393）。
  final String issuer;
  final DateTime createdAt;

  /// 随哪张流票一起释放（BUG-4461）。null = 这张票本身就是流票（回给 client 的 `ticket` 即它的值）；
  /// 附属票（光盘制卡 token）填主票的值，client 释放主票时一并作废。
  final String? ticket;

  /// 种类专属的签发参数（视频的集号 / 转码档等），由签发方自己解释。
  final Object? options;
}

/// 流票表。
class LibraryMediaStreams {
  LibraryMediaStreams({
    required DateTime Function() now,
    this.ttl = const Duration(hours: 6),
    this.capacity = kLibraryMediaStreamCapacity,
    void Function(String token)? onDrop,
    Random? random,
  }) : _now = now,
       _onDrop = onDrop,
       _random = random ?? Random.secure();

  final DateTime Function() _now;

  /// 票的有效期。视频播放时间长，6 小时；曲目与 MV 同一套（一张票就是一次播放会话）。
  final Duration ttl;

  /// 表的上限（BUG-1568：只签发不取流的调用者不能让表无界增长）。
  final int capacity;

  /// 票被摘掉时的回调（视频用它清转码分段缓存 / 取消没人等的预取）。所有摘票路径都经 [drop]。
  final void Function(String token)? _onDrop;
  final Random _random;

  final Map<String, LibraryMediaGrant> _grants = <String, LibraryMediaGrant>{};
  final Map<LibraryMediaStreamKind, LibraryMediaResolver> _resolvers =
      <LibraryMediaStreamKind, LibraryMediaResolver>{};

  int get length => _grants.length;

  /// [kind] 种类的票数。
  int countOf(LibraryMediaStreamKind kind) =>
      _grants.values.where((LibraryMediaGrant g) => g.kind == kind).length;

  /// 注册某种流的解析器。同一种只能注册一次（两个模块抢同一种流是装配错误）。
  void registerResolver(
    LibraryMediaStreamKind kind,
    LibraryMediaResolver resolver,
  ) {
    if (_resolvers.containsKey(kind)) {
      throw StateError('流种类 $kind 的解析器已注册');
    }
    _resolvers[kind] = resolver;
  }

  /// [kind] 的解析器；没有模块提供这种流时 null。
  LibraryMediaResolver? resolverFor(LibraryMediaStreamKind kind) =>
      _resolvers[kind];

  /// 签发一张票：先按 TTL 清过期、再收束到上限内（淘汰最旧者），保证插入后总数 ≤ [capacity]。
  String issue({
    required LibraryMediaStreamKind kind,
    required String id,
    required String issuer,
    String? ticket,
    Object? options,
  }) {
    prune();
    _enforceCapacity();
    final String token = _generateToken();
    _grants[token] = LibraryMediaGrant(
      kind: kind,
      id: id,
      issuer: issuer,
      createdAt: _now(),
      ticket: ticket,
      options: options,
    );
    return token;
  }

  /// 按值取票（不判过期，调用方先 [prune]）。
  LibraryMediaGrant? operator [](String token) => _grants[token];

  bool contains(String token) => _grants.containsKey(token);

  /// 摘掉一张票（释放 / 吊销 / TTL / 上限淘汰都经这里）。
  void drop(String token) {
    if (_grants.remove(token) == null) return;
    _onDrop?.call(token);
  }

  /// 释放流票 [ticket]（BUG-4461）：作废它本身与随它签发的附属票。只认 [kind] + [id] 下的票——拿别的
  /// 对象的路径释放不动这张票。返回被摘掉的票值（调用方据此取消它们名下在跑的工作）。
  List<String> release({
    required LibraryMediaStreamKind kind,
    required String id,
    required String ticket,
  }) {
    final List<String> keys = <String>[
      for (final MapEntry<String, LibraryMediaGrant> e in _grants.entries)
        if (e.value.kind == kind &&
            e.value.id == id &&
            (e.key == ticket || e.value.ticket == ticket))
          e.key,
    ];
    keys.forEach(drop);
    return keys;
  }

  /// 按 TTL 清过期。
  void prune() {
    final DateTime cutoff = _now().subtract(ttl);
    final List<String> expired = <String>[
      for (final MapEntry<String, LibraryMediaGrant> e in _grants.entries)
        if (e.value.createdAt.isBefore(cutoff)) e.key,
    ];
    expired.forEach(drop);
  }

  /// 停机：全部摘掉。
  void clear() => _grants.keys.toList().forEach(drop);

  void _enforceCapacity() {
    while (_grants.length >= capacity) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final MapEntry<String, LibraryMediaGrant> e in _grants.entries) {
        if (oldestAt == null || e.value.createdAt.isBefore(oldestAt)) {
          oldestAt = e.value.createdAt;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) break;
      drop(oldestKey);
    }
  }

  String _generateToken() {
    final List<int> bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes);
  }
}

/// 流票表上限（BUG-1568 定的 128，合表后视频与音乐共用；一次播放会话只占一两张，128 足够，且被
/// 淘汰的只是最旧的票，播放器重取即可）。
const int kLibraryMediaStreamCapacity = 128;

/// 统一签发路径（Basic）：`POST {kind, id}` → `{url, ticket}`。
const String kLibraryMediaStreamUrlPath = '/api/library/media/streamurl';

/// 统一取流路径（免 Basic，门是 `?token=`）：GET / HEAD，Range / ETag / If-Range。
const String kLibraryMediaStreamPath = '/api/library/media/stream';

/// 统一释放路径（Basic）：`POST ?ticket=` → 204，幂等。
const String kLibraryMediaStreamReleasePath =
    '/api/library/media/streamrelease';

/// 解析器明确拒绝（带 HTTP 状态）：如上游来源连不上（502）、转码失败（500）。
class LibraryMediaUnavailable implements Exception {
  const LibraryMediaUnavailable(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'LibraryMediaUnavailable($status $message)';
}
