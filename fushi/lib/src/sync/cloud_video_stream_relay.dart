import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/diagnostics/video_diag_log.dart'
    show redactVideoDiagSecrets;
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

  /// 登记表上限。每条只是一个 reader 引用 + 资产身份，要防的是「只增不删」：视频页
  /// 每次刷新都会新建 client / reader，同一资产被反复登记。超出时淘汰最久没用过的
  /// 一条；在播的流每个 `Range` 请求都会把自己挪到最新，不会被挤掉。
  static const int maxEntries = 64;

  /// 每写出这么多字节就等一次 [HttpResponse.flush]，见 [_stream] 的背压说明。
  static const int flushThresholdBytes = 1024 * 1024;

  final HttpServer _server;

  /// token → 登记项；插入序即「最近使用」序（登记 / 请求都会挪到末尾）。
  final LinkedHashMap<String, _CloudRelayEntry> _entries =
      LinkedHashMap<String, _CloudRelayEntry>();

  /// `(source, assetId)` → token：同一云盘的同一资产无论经哪个 reader 实例登记，
  /// 都复用同一个本地地址。
  final Map<String, String> _tokensByAsset = <String, String>{};
  final Random _random = Random.secure();
  bool _closed = false;

  bool get isRunning => !_closed;

  int get port => _server.port;

  /// 当前登记项数（测试用）。
  @visibleForTesting
  int get entryCount => _entries.length;

  /// 登记一个云端资产，返回交给播放内核的本地地址。
  ///
  /// [source] 是云盘身份（如 `cloud:oneDrive`，见 `cloudRemoteLibrarySourceId`）：
  /// 同一 [source] + [assetId] 重复登记复用同一 token，并把登记项的 reader 换成这次
  /// 传入的（最新的 reader 带着最新的账号状态）。不能按 reader 实例去重——视频页每次
  /// 刷新都会新建 reader，那样去重永远落空、登记表只增不删。
  ///
  /// [fileName] 只用于地址末段（带扩展名，便于内核按后缀猜格式）。
  Uri register({
    required SyncAssetRangeReader reader,
    required String source,
    required String assetId,
    required String fileName,
  }) {
    final String assetKey = '$source\n$assetId';
    final String token = _tokensByAsset[assetKey] ??
        base64Url
            .encode(List<int>.generate(18, (int _) => _random.nextInt(256)));
    _tokensByAsset[assetKey] = token;
    _entries.remove(token);
    _entries[token] = _CloudRelayEntry(
      reader: reader,
      assetKey: assetKey,
      assetId: assetId,
      fileName: fileName,
    );
    while (_entries.length > maxEntries) {
      final String oldest = _entries.keys.first;
      final _CloudRelayEntry evicted = _entries.remove(oldest)!;
      _tokensByAsset.remove(evicted.assetKey);
    }
    return _localUri(token, fileName);
  }

  /// 取 [token] 的登记项并把它标成最近使用。
  _CloudRelayEntry? _touch(String token) {
    final _CloudRelayEntry? entry = _entries.remove(token);
    if (entry != null) _entries[token] = entry;
    return entry;
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
              ? _touch(segments[1])
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
      // 区间读的错误按约定不带直链 / 凭据（见 openPresignedAssetRange）；这里再兜一道
      // 脱敏，任何漏网的预签名 URL（`tempauth=`、Dropbox `/cd/0/get/<签名>`、OneDrive
      // 个人版路径签名）都不会原样进 DebugLogService / logcat。
      debugPrint(
        '[cloud-stream-relay] ${request.method} failed: '
        '${redactVideoDiagSecrets('$error')}',
      );
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
    // 背压：`HttpResponse.add` 只往一个同步 controller 里塞字节，socket 写不动时暂停
    // 的是那个 controller 的订阅，controller 自己的缓冲没有上限，上游订阅也从不暂停
    // （dart:io `_HttpOutgoing.addStream`）。libmpv / ffmpeg 发的是开区间
    // `bytes=N-`，前向缓存满了（移动端 32MiB）就不再读，不加背压的话中继会继续全速
    // 把整个文件的剩余部分拉下来、解混淆、堆进 Dart 堆——iOS jetsam / Android LMK、
    // 流量等于整文件、逐字节 XOR 占着 UI isolate。
    //
    // 所以每写出约 [flushThresholdBytes] 就 `await flush()`：它要等已写的字节被
    // socket 收下才返回，内核不读时就一直挂着；`await for` 的循环体在 await 期间会
    // 暂停上游订阅 → 上游 HTTP 响应停读 → TCP 流控传回云盘。选它而不是按 2MiB 分块
    // 重新请求上游，理由：
    // - 一次内核请求仍只对应一次上游请求，吞吐等于直连（分块每块多一次 RTT，高码率
    //   远程流会被拖慢）；上游忽略 Range 回 200 整文件时也仍是线性的（分块会让每块都
    //   从文件头重下一遍）。
    // - 暂停太久被云盘掐掉的上游连接，恢复读时表现为中途出错 → 下面断开内核连接；
    //   libmpv 对 http 默认开着 ffmpeg 的 `reconnect`，会从断点带 `Range` 重新请求，
    //   那一次又经 reader 现取直链 / 现刷 token——过期续上的语义不变。
    int unflushed = 0;
    await for (final List<int> chunk in upstream.bytes) {
      if (clientGone) return;
      response.add(chunk);
      unflushed += chunk.length;
      if (unflushed >= flushThresholdBytes) {
        unflushed = 0;
        await response.flush();
        if (clientGone) return;
      }
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
    required this.assetKey,
    required this.assetId,
    required this.fileName,
  });

  final SyncAssetRangeReader reader;

  /// `_tokensByAsset` 的键（淘汰时一并删）。
  final String assetKey;
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
