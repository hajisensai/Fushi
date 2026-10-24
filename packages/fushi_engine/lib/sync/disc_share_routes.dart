/// 远端原盘的只读目录服务（第二期，`disc_share_manifest.dart`）。
///
/// ```
/// GET /api/library/videos/<id>/disc                 （Basic 鉴权）签发共享会话：
///     {token, baseUrl, manifest}；<id> 是盘上任一条标题的 bookUid
/// GET /api/library/disc/<token>/manifest.json       （会话 token 鉴权）清单
/// GET /api/library/disc/<token>/files/<相对路径>    （会话 token 鉴权）单文件，支持 Range
/// ```
///
/// 后两条豁免 Basic：它们由 libmpv 里的 libbluray / libdvdnav 直接发起（裸 GET，带
/// 不了 Authorization），门是路径里的不透明会话 token——与 `/stream` 的短时 token
/// 同一种安排，只是有效期按**空闲**计：一个菜单会话可以持续几个小时，只要还在读
/// 就一直有效；空闲 [DiscShareTokenStore.idleTimeout] 后作废。
///
/// 文件端点只认清单里列出的路径（[resolveDiscShareFilePath]），没有拼接路径这回事。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fushi_engine/media/video/disc/disc_share_manifest.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart'
    show serveFileWithRange;
import 'package:shelf/shelf.dart' as shelf;

/// 共享会话路由前缀（不含前导 `/` 的形式见 [isDiscShareSessionPath]）。
const String kDiscShareRoutePrefix = '/api/library/disc/';

/// 签发端点挂在视频路由下的后缀：`/api/library/videos/<id>/disc`。
const String kDiscShareIssueSuffix = 'disc';

/// `GET /api/capabilities` 里的能力位。
const String kDiscShareCapability = 'discShareV1';

/// 一个已签发的共享会话。
class DiscShareSession {
  DiscShareSession({
    required this.discRoot,
    required this.manifest,
    required this.createdAt,
  }) : lastUsedAt = createdAt;

  /// host 本机盘根（目录或 `.iso`）。只在 host 进程内存里，从不下发。
  final String discRoot;
  final DiscShareManifest manifest;
  final DateTime createdAt;
  DateTime lastUsedAt;
}

/// 会话 token 表：随机不透明 token → [DiscShareSession]。
///
/// 两道期限：空闲超过 [idleTimeout] 作废（读盘就续期），签发起超过 [maxAge] 无论
/// 如何作废（被泄露的 token 不能永久有效）。数量上限 [capacity]，满了淘汰最久没用
/// 的那个——在签发侧强制（与视频流 token 的 BUG-1568 同一做法）。
class DiscShareTokenStore {
  DiscShareTokenStore({
    DateTime Function()? now,
    this.idleTimeout = const Duration(minutes: 30),
    this.maxAge = const Duration(hours: 12),
    this.capacity = 32,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  final DateTime Function() _now;
  final Random _random;
  final Duration idleTimeout;
  final Duration maxAge;
  final int capacity;
  final Map<String, DiscShareSession> _sessions = <String, DiscShareSession>{};

  int get length => _sessions.length;

  /// 为 [discRoot] / [manifest] 签发一个新 token。
  String issue({
    required String discRoot,
    required DiscShareManifest manifest,
  }) {
    _prune();
    while (_sessions.length >= capacity) {
      String? oldest;
      DateTime? oldestAt;
      for (final MapEntry<String, DiscShareSession> e in _sessions.entries) {
        if (oldestAt == null || e.value.lastUsedAt.isBefore(oldestAt)) {
          oldestAt = e.value.lastUsedAt;
          oldest = e.key;
        }
      }
      _sessions.remove(oldest);
    }
    final String token = base64Url
        .encode(List<int>.generate(24, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    _sessions[token] = DiscShareSession(
      discRoot: discRoot,
      manifest: manifest,
      createdAt: _now(),
    );
    return token;
  }

  /// 取有效会话并续期；无效 / 过期返回 null（过期的顺手删掉）。
  DiscShareSession? touch(String token) {
    final DiscShareSession? session = _sessions[token];
    if (session == null) return null;
    final DateTime now = _now();
    if (_expired(session, now)) {
      _sessions.remove(token);
      return null;
    }
    session.lastUsedAt = now;
    return session;
  }

  bool _expired(DiscShareSession session, DateTime now) =>
      now.difference(session.lastUsedAt) > idleTimeout ||
      now.difference(session.createdAt) > maxAge;

  void _prune() {
    final DateTime now = _now();
    _sessions.removeWhere(
      (String _, DiscShareSession session) => _expired(session, now),
    );
  }

  void clear() => _sessions.clear();
}

/// [urlPath]（`request.url.path`，无前导 `/`）是不是共享会话路径——鉴权中间件据此
/// 豁免 Basic（门在 handler 里校验 token）。
bool isDiscShareSessionPath(String urlPath) =>
    urlPath.startsWith(kDiscShareRoutePrefix.substring(1));

/// 签发：`GET /api/library/videos/<id>/disc` 的响应体。[baseUrl] 以 `/` 结尾，
/// client 在其后拼 `manifest.json` / `files/<路径>`。
Map<String, Object?> discShareIssueBody({
  required String token,
  required Uri requestedUri,
  required DiscShareManifest manifest,
}) => <String, Object?>{
  'token': token,
  'baseUrl': discShareBaseUri(requestedUri, token).toString(),
  'manifest': manifest.toJson(),
};

/// 会话根 URL（与签发请求同一个 scheme / host / port——client 经哪条地址来的就回
/// 哪条，P2P 隧道、IPv6 都不用另想）。
Uri discShareBaseUri(Uri requestedUri, String token) => Uri(
  scheme: requestedUri.scheme,
  host: requestedUri.host,
  port: requestedUri.hasPort ? requestedUri.port : null,
  path: '$kDiscShareRoutePrefix$token/',
);

/// 处理 `/api/library/disc/<token>/...`。[reqPath] 已 URL 解码、带前导 `/`。
Future<shelf.Response> handleDiscShareRequest(
  DiscShareTokenStore store,
  shelf.Request request,
  String method,
  String reqPath,
) async {
  if (method != 'GET') return shelf.Response(405);
  final String rest = reqPath.substring(kDiscShareRoutePrefix.length);
  final int slash = rest.indexOf('/');
  if (slash <= 0) return shelf.Response.notFound('Not found');
  final String token = rest.substring(0, slash);
  final String tail = rest.substring(slash + 1);
  final DiscShareSession? session = store.touch(token);
  if (session == null) {
    return shelf.Response(
      401,
      body: 'Disc share session expired',
      headers: const <String, String>{'Content-Type': 'text/plain'},
    );
  }
  if (tail == 'manifest.json') {
    return shelf.Response.ok(
      jsonEncode(session.manifest.toJson()),
      headers: const <String, String>{'Content-Type': 'application/json'},
    );
  }
  const String filesPrefix = 'files/';
  if (!tail.startsWith(filesPrefix))
    return shelf.Response.notFound('Not found');
  final String relative = tail.substring(filesPrefix.length);
  final String? path = resolveDiscShareFilePath(
    session.discRoot,
    session.manifest,
    relative,
  );
  if (path == null) return shelf.Response.notFound('Not in disc manifest');
  final File file = File(path);
  if (!file.existsSync()) return shelf.Response.notFound('File not found');
  // ETag 取**当前**文件状态：清单签发后 host 上的文件被替换，续传验证器随之变，
  // client 手里的 `.part` 不会被接成两份文件的拼接。播放器的 Range 请求不带
  // If-Range，照常 206（ifRangeRequired: false，与视频 `/stream` 同口径）。
  final FileStat stat = file.statSync();
  final String etag = DiscShareFile(
    path: relative,
    size: stat.size,
    modifiedAt: stat.modified.millisecondsSinceEpoch,
  ).etag;
  return serveFileWithRange(file, request, etag: etag, ifRangeRequired: false);
}
