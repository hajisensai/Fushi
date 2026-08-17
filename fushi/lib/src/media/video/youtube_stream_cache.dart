import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// TODO-1314（yt-dlp 借鉴项之三）：YouTube **流解析结果的持久缓存**——Hibiki 特有概念。
///
/// 现状：每次从书架打开一本 YouTube 流媒体书都全量 resolveYoutubeSource（getManifest =
/// 多次 innertube 往返 + 跨 client 403 探测），慢网下数秒「点了没动静」。googlevideo 直链
/// 自带 expire=<unix秒> 有效期（通常 ~6h），有效期内可复用无需重解析。本缓存把 resolve 出的
/// 可复用字段 + 由 expire 派生的过期时间落到 supportRoot 的 JSON 文件，重开时先查缓存：未过期
/// 即直接重建播放客户端、跳过全量解析。过期由 [expiresAtMs] 判定；**失效**（跨会话换网致 IP
/// 锁不匹配 / 提前吊销）由 [buildStreamVideoLaunch] 命中后的轻量 liveness 探测 + [invalidate]
/// 处理——绝不把脏 URL 喂给播放器致黑屏。
///
/// 只缓存**播放**用字段（stream/audio/mining URL + header），不缓存字幕 cue（走 watch URL
/// 后置异步解析）与标题（用 book.title）。缓存可随时删除重建，故落 supportRoot 的独立 JSON
/// 文件而非 Drift 表（无 schema 迁移、不与并发建表撞车）。

/// 缓存条目：重建 [UrlStreamVideoClient] 所需的可复用字段 + 过期时间戳。
class YoutubeStreamCacheEntry {
  const YoutubeStreamCacheEntry({
    required this.streamUrl,
    required this.audioStreamUrl,
    required this.miningVideoUrl,
    required this.miningVideoHasAudio,
    required this.httpHeaders,
    required this.expiresAtMs,
    this.targetHeight,
  });

  final String streamUrl;
  final String? audioStreamUrl;
  final String? miningVideoUrl;
  final bool miningVideoHasAudio;
  final Map<String, String> httpHeaders;

  /// 解析这条缓存时的用户显式画质目标（null=自动/默认策略）。用户改设置后旧缓存的
  /// streamUrl 还是旧档位，[buildStreamVideoLaunch] 据此判缓存是否可用（不匹配=miss）。
  /// 旧缓存 JSON 无此字段 → null（当年只有默认策略，语义正确）。
  final int? targetHeight;

  /// 过期时间（unix 毫秒）= min(各流 expire) - 安全余量；此刻 >= 它即过期。
  final int expiresAtMs;

  bool isExpiredAt(DateTime now) => expiresAtMs <= now.millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'streamUrl': streamUrl,
        if (audioStreamUrl != null) 'audioStreamUrl': audioStreamUrl,
        if (miningVideoUrl != null) 'miningVideoUrl': miningVideoUrl,
        'miningVideoHasAudio': miningVideoHasAudio,
        'httpHeaders': httpHeaders,
        'expiresAtMs': expiresAtMs,
        if (targetHeight != null) 'targetHeight': targetHeight,
      };

  /// 缺 streamUrl / expiresAtMs 抛（调用方按条目跳过脏数据）。
  factory YoutubeStreamCacheEntry.fromJson(Map<String, dynamic> json) {
    final Object? streamUrl = json['streamUrl'];
    final Object? expiresAtMs = json['expiresAtMs'];
    if (streamUrl is! String || streamUrl.isEmpty || expiresAtMs is! int) {
      throw const FormatException('invalid YoutubeStreamCacheEntry json');
    }
    final Object? headers = json['httpHeaders'];
    final Map<String, String> httpHeaders = <String, String>{};
    if (headers is Map) {
      headers.forEach((Object? k, Object? v) {
        if (k is String && v is String) httpHeaders[k] = v;
      });
    }
    return YoutubeStreamCacheEntry(
      streamUrl: streamUrl,
      audioStreamUrl: json['audioStreamUrl'] as String?,
      miningVideoUrl: json['miningVideoUrl'] as String?,
      miningVideoHasAudio: json['miningVideoHasAudio'] == true,
      httpHeaders: httpHeaders,
      expiresAtMs: expiresAtMs,
      targetHeight:
          json['targetHeight'] is int ? json['targetHeight'] as int : null,
    );
  }
}

/// 纯函数：从 googlevideo 直链的 expire=<unix秒> 查询参数解出过期时间（unix 毫秒）。
/// 无 expire / 非法 / 非正数 → null（不可判定有效期，调用方不缓存）。不联网。
int? googleVideoExpiryMs(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null) return null;
  final String? expire = uri.queryParameters['expire'];
  if (expire == null) return null;
  final int? secs = int.tryParse(expire);
  if (secs == null || secs <= 0) return null;
  return secs * 1000;
}

/// 纯函数：由一组流 URL 的 expire 派生缓存过期时间（unix 毫秒），取**最早** expire 减去
/// [margin] 安全余量（默认 30 分钟——绝不在临过期时把 URL 交给播放器致中途断流）。
///
/// 无任一可解析 expire → null（不缓存，退回每次重解析）；算出的过期已 <= [now]（expire 太近）
/// → 同样 null（这条 resolve 本就快过期，缓存它没意义且危险）。不联网。
int? computeStreamCacheExpiryMs(
  Iterable<String?> urls,
  DateTime now, {
  Duration margin = const Duration(minutes: 30),
}) {
  int? minExpiry;
  for (final String? url in urls) {
    if (url == null || url.isEmpty) continue;
    final int? e = googleVideoExpiryMs(url);
    if (e == null) continue;
    if (minExpiry == null || e < minExpiry) minExpiry = e;
  }
  if (minExpiry == null) return null;
  final int withMargin = minExpiry - margin.inMilliseconds;
  if (withMargin <= now.millisecondsSinceEpoch) return null;
  return withMargin;
}

/// YouTube 流解析结果的持久缓存（JSON 文件后端）。按 canonical videoId key。
///
/// [file] = 后端 JSON（生产 `<supportRoot>/youtube_stream_cache.json`，测试注入 temp）；
/// [now] 可注入便于测过期。加载惰性、顺带 prune 已过期条目；put 时也 prune。
class YoutubeStreamCache {
  YoutubeStreamCache({required File file, DateTime Function()? now})
      : _file = file,
        _now = now ?? DateTime.now;

  final File _file;
  final DateTime Function() _now;
  final Map<String, YoutubeStreamCacheEntry> _entries =
      <String, YoutubeStreamCacheEntry>{};
  bool _loaded = false;

  static const int _schemaVersion = 1;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!await _file.exists()) return;
      final String raw = await _file.readAsString();
      if (raw.trim().isEmpty) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final Object? entries = decoded['entries'];
      if (entries is! Map) return;
      // 加载全部条目（含已过期）；过期由 [get] 命中时自愈（剔除 + 落盘）、[put] 顺带 prune。
      // 不在 load 阶段静默丢弃过期条目——否则磁盘残留脏条目直到下次 put，且与「命中即清理」
      // 两套语义打架。脏单条跳过，不阻断整份加载。
      entries.forEach((Object? key, Object? value) {
        if (key is! String || value is! Map) return;
        try {
          _entries[key] = YoutubeStreamCacheEntry.fromJson(
              Map<String, dynamic>.from(value));
        } catch (_) {
          // 单条脏数据跳过，不阻断整份缓存加载。
        }
      });
    } catch (_) {
      // 缓存文件损坏/不可读：当空缓存（缓存可重建，绝不阻断打开视频）。
    }
  }

  /// 取 [videoId] 的**未过期**条目；无 / 已过期 → null（过期即剔除并落盘）。
  Future<YoutubeStreamCacheEntry?> get(String videoId) async {
    await _ensureLoaded();
    final YoutubeStreamCacheEntry? entry = _entries[videoId];
    if (entry == null) return null;
    if (entry.isExpiredAt(_now())) {
      _entries.remove(videoId);
      await _save();
      return null;
    }
    return entry;
  }

  /// 写入 [videoId] 条目（顺带 prune 已过期），落盘。
  Future<void> put(String videoId, YoutubeStreamCacheEntry entry) async {
    await _ensureLoaded();
    _pruneExpired();
    _entries[videoId] = entry;
    await _save();
  }

  /// 主动失效 [videoId]（liveness 判定 URL 失效时），落盘。
  Future<void> invalidate(String videoId) async {
    await _ensureLoaded();
    if (_entries.remove(videoId) != null) await _save();
  }

  void _pruneExpired() {
    final DateTime now = _now();
    _entries.removeWhere(
        (String _, YoutubeStreamCacheEntry e) => e.isExpiredAt(now));
  }

  Future<void> _save() async {
    try {
      await _file.parent.create(recursive: true);
      final Map<String, dynamic> map = <String, dynamic>{
        'version': _schemaVersion,
        'entries': <String, dynamic>{
          for (final MapEntry<String, YoutubeStreamCacheEntry> e
              in _entries.entries)
            e.key: e.value.toJson(),
        },
      };
      await _file.writeAsString(jsonEncode(map), flush: true);
    } catch (_) {
      // 落盘失败非致命：内存态仍有效。
    }
  }

  static YoutubeStreamCache? _instance;

  /// 生产单例：后端 `<supportRoot>/youtube_stream_cache.json`（持久、app 内部、可丢弃重建）。
  static Future<YoutubeStreamCache> instance() async {
    final YoutubeStreamCache? existing = _instance;
    if (existing != null) return existing;
    final Directory dir = await AppPaths.supportRootDirectory();
    final YoutubeStreamCache cache = YoutubeStreamCache(
        file: File(p.join(dir.path, 'youtube_stream_cache.json')));
    _instance = cache;
    return cache;
  }
}
