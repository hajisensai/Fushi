import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/video/youtube_range_relay.dart'
    show parseRelayRange;
import 'package:fushi/src/sync/sync_asset_range_reader.dart';

/// 本地 loopback 中继：把云盘资产的**明文区间读**（[SyncAssetRangeReader]）翻成
/// 普通可 seek 的 HTTP 流交给 libmpv / ffmpeg，实现云盘视频不下载直接流播。
///
/// ## 为什么不能把直链直接交给 libmpv
///
/// 1. 云盘里的视频是经 `ObfuscatingSyncBackend` 上传的（`magic header + XOR`），
///    原样字节 libmpv 解不出轨；还原必须按偏移做（[DeobfuscatingAssetRangeReader]）。
/// 2. 直链是临期的（OneDrive downloadUrl 约 1 小时、Dropbox temporary link 4 小时），
///    Google Drive 还要 `Authorization: Bearer`（token 约 1 小时过期）。交给 libmpv 的
///    URL / 头在整场播放里是固定的：看到一半暂停、过一小时再 seek 就 403。中继让
///    **每一个** `Range` 请求（起播、seek、断线重连）都经 reader 现取直链 / 现刷
///    token，过期后自动续上。
/// 3. 凭据不出 Dart 层：libmpv 只见 `http://127.0.0.1:<port>/cloud/<token>/<name>`，
///    预签名 URL 与 Bearer 头不会进 mpv 参数、mpv 日志和视频诊断日志。
///
/// 登记表与端口只活在进程内；进度等持久化状态一律按云端资产身份（manifest uid）记，
/// 不记本地地址。
class CloudVideoStreamRelay {
  CloudVideoStreamRelay._(this._server);

  static Future<CloudVideoStreamRelay>? _shared;

  /// 进程内单例。监听 socket 死了（移动端挂起后被系统回收）就另起一个，与
  /// [YoutubeRangeRelay.instance] 同一口径。
  static Future<CloudVideoStreamRelay> instance() async {
    final Future<CloudVideoStreamRelay>? cached = _shared;
    if (cached != null) {
      try {
        final CloudVideoStreamRelay relay = await cached;
        if (relay.isRunning) return relay;
      } on Object catch (error) {
        debugPrint('[cloud-stream-relay] restarting after $error');
      }
    }
    final Future<CloudVideoStreamRelay> started = start();
    _shared = started;
    return started;
  }

  /// 起一个绑定 loopback 随机端口的中继（测试直接调；生产走 [instance]）。
  static Future<CloudVideoStreamRelay> start() async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final CloudVideoStreamRelay relay = CloudVideoStreamRelay._(server);
    server.listen(
      (HttpRequest request) => unawaited(relay._serve(request)),
      onDone: () => relay._closed = true,
      onError: (Object error) {
        relay._closed = true;
        debugPrint('[cloud-stream-relay] listener failed: $error');
      },
    );
    return relay;
  }

  final HttpServer _server;
  final Map<String, _CloudRelayEntry> _entries = <String, _CloudRelayEntry>{};
  final Random _random = Random.secure();
  bool _closed = false;

  bool get isRunning => !_closed;

  int get port => _server.port;

  /// 登记一个云端资产，返回交给播放内核的本地地址。同一 reader + 资产重复登记复用
  /// 同一 token。[fileName] 只用于地址末段（带扩展名，便于内核按后缀猜格式）。
  Uri register({
    required SyncAssetRangeReader reader,
    required String assetId,
    required String fileName,
  }) {
    for (final MapEntry<String, _CloudRelayEntry> e in _entries.entries) {
      if (identical(e.value.reader, reader) && e.value.assetId == assetId) {
        return _localUri(e.key, e.value.fileName);
      }
    }
    final String token = base64Url
        .encode(List<int>.generate(18, (int _) => _random.nextInt(256)));
    _entries[token] = _CloudRelayEntry(
      reader: reader,
      assetId: assetId,
      fileName: fileName,
    );
    return _localUri(token, fileName);
  }

  Uri _localUri(String token, String fileName) => Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: _server.port,
        pathSegments: <String>['cloud', token, fileName],
      );

  Future<void> close() async {
    _closed = true;
    await _server.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    final HttpResponse response = request.response;
    try {
      final List<String> segments = request.uri.pathSegments;
      final _CloudRelayEntry? entry =
          segments.length >= 2 && segments.first == 'cloud'
              ? _entries[segments[1]]
              : null;
      if (entry == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      final String? rangeHeader =
          request.headers.value(HttpHeaders.rangeHeader);
      final ({int start, int? end})? range = parseRelayRange(rangeHeader);
      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }
      await _stream(request, entry, range, ranged: rangeHeader != null);
    } on Object catch (error) {
      // 只记异常类型与消息：区间读的错误信息按约定不带直链 / 凭据。
      debugPrint('[cloud-stream-relay] ${request.method} failed: $error');
      await _abort(response);
    }
  }

  Future<void> _stream(
    HttpRequest request,
    _CloudRelayEntry entry,
    ({int start, int? end}) range, {
    required bool ranged,
  }) async {
    final HttpResponse response = request.response;
    final bool head = request.method == 'HEAD';
    final SyncAssetRange upstream;
    try {
      upstream = await entry.reader.openAssetRange(
        entry.assetId,
        start: range.start,
        // HEAD 只要总长：读一个字节就够，不拉整段。
        end: head ? range.start : range.end,
      );
    } on SyncAssetRangeNotSatisfiable catch (e) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      final int? total = e.totalBytes;
      if (total != null) {
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
      }
      await response.close();
      return;
    }
    final int end = head
        ? (range.end == null || range.end! >= upstream.totalBytes
            ? upstream.totalBytes - 1
            : range.end!)
        : upstream.end;
    response.statusCode = ranged ? HttpStatus.partialContent : HttpStatus.ok;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      _contentTypeFor(entry.fileName, upstream.contentType),
    );
    response.headers.contentLength = end - upstream.start + 1;
    if (ranged) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${upstream.start}-$end/${upstream.totalBytes}',
      );
    }
    if (head) {
      await upstream.bytes.listen(null).cancel();
      await response.close();
      return;
    }
    // 内核断连信号：mpv 每次 seek 都会关掉旧连接，此时必须停掉上游，否则旧区间会
    // 被继续整段拉完（与 YoutubeRangeRelay 同一教训）。
    bool clientGone = false;
    unawaited(response.done.then<void>(
      (_) => clientGone = true,
      onError: (Object _) => clientGone = true,
    ));
    await for (final List<int> chunk in upstream.bytes) {
      if (clientGone) return;
      response.add(chunk);
    }
    if (clientGone) return;
    await response.close();
  }

  /// 出错收尾：头没发出给 502；头已发出时断连（Content-Length 已承诺，留着连接
  /// 内核会一直等到超时）。
  Future<void> _abort(HttpResponse response) async {
    try {
      response.statusCode = HttpStatus.badGateway;
    } on Object {
      // 头已发出。
    }
    try {
      await response.close();
    } on Object {
      try {
        (await response.detachSocket(writeHeaders: false)).destroy();
      } on Object {
        // 连接已经不在了。
      }
    }
  }
}

class _CloudRelayEntry {
  const _CloudRelayEntry({
    required this.reader,
    required this.assetId,
    required this.fileName,
  });

  final SyncAssetRangeReader reader;
  final String assetId;
  final String fileName;
}

/// 纯函数：云盘上游常回泛化的 `application/octet-stream`，按资产扩展名补一个视频
/// 类型给内核；认不出扩展名就沿用上游值。
String _contentTypeFor(String fileName, String? upstream) {
  final int dot = fileName.lastIndexOf('.');
  final String ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  const Map<String, String> known = <String, String>{
    'mp4': 'video/mp4',
    'm4v': 'video/mp4',
    'mkv': 'video/x-matroska',
    'webm': 'video/webm',
    'mov': 'video/quicktime',
    'avi': 'video/x-msvideo',
    'ts': 'video/mp2t',
    'm2ts': 'video/mp2t',
    'flv': 'video/x-flv',
  };
  return known[ext] ?? upstream ?? 'application/octet-stream';
}
