import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:fushi/src/media/video/youtube_range_relay.dart'
    show parseContentRange;
import 'package:fushi/src/sync/obfuscating_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_obfuscator.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

/// 云盘资产的一段字节（闭区间 `[start, end]`），供不下载、按 `Range` 流播使用。
class SyncAssetRange {
  const SyncAssetRange({
    required this.start,
    required this.end,
    required this.totalBytes,
    required this.bytes,
    this.contentType,
  });

  /// 首字节偏移（含）。
  final int start;

  /// 末字节偏移（含）。
  final int end;

  /// 资产总字节数。
  final int totalBytes;

  /// 上游报的内容类型（可能是泛化的 `application/octet-stream`）。
  final String? contentType;

  /// 区间字节流；只能订阅一次。不再需要时取消订阅即中止上游传输。
  final Stream<List<int>> bytes;

  /// 区间字节数。
  int get length => end - start + 1;
}

/// 请求区间的起点落在资产末尾之后（HTTP 416 语义）。
class SyncAssetRangeNotSatisfiable implements Exception {
  const SyncAssetRangeNotSatisfiable(this.totalBytes);

  /// 资产总字节数（未知为 null）。
  final int? totalBytes;

  @override
  String toString() => 'SyncAssetRangeNotSatisfiable(total: $totalBytes)';
}

/// 「按字节区间读云端资产」的可选能力（云盘视频流播）。
///
/// 只有能廉价做 `Range` 读的后端实现：OneDrive（Graph 预签名 downloadUrl）、
/// Dropbox（`files/get_temporary_link`）、Google Drive（`alt=media` + Range）。
/// 不并进 [SyncAssetStore]：WebDAV / FTP / SFTP 与十余个测试 fake 都实现那份契约，
/// 硬扩面只会逼它们写一个抛异常的桩；消费方用 `is SyncAssetRangeReader` 判能力。
///
/// 实现给出的是**云端原样字节**（混淆产物带 header），明文视图见
/// [plainAssetRangeReaderOf]。
///
/// 直链 / 凭据都只活在实现内部：本接口只交出字节，预签名 URL、`Authorization`
/// 头永远不会离开 Dart 层、不会进 libmpv 参数，也就不会进诊断日志。
abstract interface class SyncAssetRangeReader {
  /// 打开资产 [assetId] 的 `[start, end]` 闭区间；[end] 为 null 或越过文件尾时截到
  /// 文件尾。[start] 越过文件尾抛 [SyncAssetRangeNotSatisfiable]。
  Future<SyncAssetRange> openAssetRange(
    String assetId, {
    required int start,
    int? end,
  });
}

/// [store] 的**明文**区间读视图；后端不具备区间读能力时返回 null（只能整文件下载）。
///
/// 经 [ObfuscatingSyncBackend] 上传的资产是 `magic header + XOR` 字节，libmpv 直接读
/// 会解不出轨；这里剥掉装饰层取真后端的原样区间读，再套 [DeobfuscatingAssetRangeReader]
/// 做按偏移还原。无魔数的旧明文资产由后者原样透传（与整文件下载的混读口径一致）。
SyncAssetRangeReader? plainAssetRangeReaderOf(SyncAssetStore store) {
  final Object raw = store is ObfuscatingSyncBackend ? store.inner : store;
  if (raw is! SyncAssetRangeReader) return null;
  return DeobfuscatingAssetRangeReader(raw);
}

/// 把云端原样区间读还原成明文区间读（[SyncObfuscator] 的随机访问形态）。
///
/// 混淆产物 = 8 字节魔数 + 按正文偏移 XOR 的正文，所以明文区间 `[a, b]` 对应云端
/// `[a + 8, b + 8]`，还原时从正文偏移 `a` 起 XOR。每个资产是否带魔数只探测一次
/// （读前 8 字节）并缓存在本实例内。
class DeobfuscatingAssetRangeReader implements SyncAssetRangeReader {
  DeobfuscatingAssetRangeReader(this._raw);

  final SyncAssetRangeReader _raw;
  final Map<String, Future<bool>> _obfuscated = <String, Future<bool>>{};

  @override
  Future<SyncAssetRange> openAssetRange(
    String assetId, {
    required int start,
    int? end,
  }) async {
    if (!await _isObfuscated(assetId)) {
      return _raw.openAssetRange(assetId, start: start, end: end);
    }
    final int header = SyncObfuscator.magicHeaderLength;
    final SyncAssetRange raw;
    try {
      raw = await _raw.openAssetRange(
        assetId,
        start: start + header,
        end: end == null ? null : end + header,
      );
    } on SyncAssetRangeNotSatisfiable catch (e) {
      final int? total = e.totalBytes;
      throw SyncAssetRangeNotSatisfiable(total == null ? null : total - header);
    }
    final int plainStart = raw.start - header;
    return SyncAssetRange(
      start: plainStart,
      end: raw.end - header,
      totalBytes: raw.totalBytes - header,
      contentType: raw.contentType,
      bytes: _deobfuscate(raw.bytes, plainStart),
    );
  }

  Future<bool> _isObfuscated(String assetId) {
    final Future<bool>? cached = _obfuscated[assetId];
    if (cached != null) return cached;
    final Future<bool> probe = _probe(assetId);
    _obfuscated[assetId] = probe;
    // 探测失败（网络 / 鉴权）不缓存成终身答案，下一次请求重探。
    probe.catchError((Object _) {
      _obfuscated.remove(assetId);
      return false;
    });
    return probe;
  }

  Future<bool> _probe(String assetId) async {
    final SyncAssetRange head;
    try {
      head = await _raw.openAssetRange(
        assetId,
        start: 0,
        end: SyncObfuscator.magicHeaderLength - 1,
      );
    } on SyncAssetRangeNotSatisfiable {
      return false; // 空文件：不可能带魔数。
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in head.bytes) {
      builder.add(chunk);
    }
    return SyncObfuscator.hasMagicHeader(builder.takeBytes());
  }

  static Stream<List<int>> _deobfuscate(
    Stream<List<int>> source,
    int bodyOffset,
  ) async* {
    int offset = bodyOffset;
    await for (final List<int> chunk in source) {
      yield SyncObfuscator.deobfuscateBodyAt(chunk, offset);
      offset += chunk.length;
    }
  }
}

/// 预签名直链的进程内缓存（OneDrive `@microsoft.graph.downloadUrl` / Dropbox
/// temporary link）。
///
/// 直链本身带临期签名：**只活在内存、绝不落库**。有效期内复用同一条（libmpv 每次
/// seek 都是一个新的 `Range` 请求，没有缓存就是每次 seek 多一次 API 往返）；过了
/// [ttl] 或上游拒绝（[invalidate]）就现取。并发请求共用同一次在途获取。
class PresignedLinkCache {
  PresignedLinkCache({required this.ttl, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// 本地视为有效的时长；取得比服务端真实有效期短，留出一次长 `Range` 读的余量。
  final Duration ttl;
  final DateTime Function() _clock;
  final Map<String, ({Future<Uri> link, DateTime fetchedAt})> _entries =
      <String, ({Future<Uri> link, DateTime fetchedAt})>{};

  /// 取 [assetId] 的直链；缓存缺失或过期时调 [fetch] 现取。
  Future<Uri> link(String assetId, Future<Uri> Function() fetch) {
    final DateTime now = _clock();
    final ({Future<Uri> link, DateTime fetchedAt})? cached = _entries[assetId];
    if (cached != null && now.difference(cached.fetchedAt) < ttl) {
      return cached.link;
    }
    final Future<Uri> fetched = fetch();
    _entries[assetId] = (link: fetched, fetchedAt: now);
    fetched.catchError((Object _) {
      // 获取失败不缓存：下一次请求重新取。
      if (identical(_entries[assetId]?.link, fetched)) _entries.remove(assetId);
      return Uri();
    });
    return fetched;
  }

  /// 作废 [assetId] 的缓存直链（上游已拒绝它）。
  void invalidate(String assetId) => _entries.remove(assetId);

  /// 清空全部缓存直链。直链属于签发它的账号：退出登录 / 换账号（后端的
  /// `clearCache()`）后不能再拿旧账号的直链去读同一个 id——Dropbox 的资产 id 就是
  /// 路径，新账号同一路径上是另一个文件。
  void clear() => _entries.clear();
}

/// 上游对直链的这些状态码 = 链接过期 / 被吊销 / 签名失效，值得现取一条再试一次。
bool isPresignedLinkRejected(int statusCode) =>
    statusCode == 401 ||
    statusCode == 403 ||
    statusCode == 404 ||
    statusCode == 410;

/// 经预签名直链读 `[start, end]` 区间（OneDrive / Dropbox 共用）。
///
/// 直链经 [cache] 取；上游拒绝（[isPresignedLinkRejected]）时作废缓存、现取一条再
/// 试**一次**，仍失败就抛 [SyncBackendError]。错误信息只带状态码，**不带 URL**
/// （预签名 URL 本身就是凭据）。
///
/// 传输层失败同样不许带 URL：`package:http` 的 `ClientException.toString()` 是
/// `'ClientException: <message>, uri=<完整 URL>'`，连接被拒 / 中途断开时原样冒上去，
/// Dropbox `/cd/0/get/<签名>`、OneDrive `tempauth=` 就会随中继 / 播放页的日志进
/// DebugLogService 与 logcat。这里（发请求与读响应体两处）把它换成只带 message 的
/// [SyncBackendError]。
Future<SyncAssetRange> openPresignedAssetRange({
  required http.Client client,
  required PresignedLinkCache cache,
  required String assetId,
  required Future<Uri> Function() fetchLink,
  required int start,
  int? end,
}) async {
  for (int attempt = 0;; attempt++) {
    final Uri url = await cache.link(assetId, fetchLink);
    final http.Request request = http.Request('GET', url)
      ..headers['Range'] = 'bytes=$start-${end ?? ''}';
    final http.StreamedResponse response;
    try {
      response = await client.send(request);
    } on http.ClientException catch (e) {
      throw _linkFreeTransportError(e);
    }
    final Stream<List<int>> body = _withLinkFreeErrors(response.stream);
    final int status = response.statusCode;
    if (status == 206 || status == 200) {
      return _rangeFromResponse(response, body, start: start, end: end);
    }
    await body.drain<void>();
    if (status == 416) {
      throw SyncAssetRangeNotSatisfiable(
        _unsatisfiedTotal(response.headers['content-range']),
      );
    }
    if (isPresignedLinkRejected(status) && attempt == 0) {
      cache.invalidate(assetId);
      continue;
    }
    cache.invalidate(assetId);
    throw SyncBackendError(
      'cloud asset range read failed: HTTP $status',
      isRetryable: status >= 500,
    );
  }
}

/// 传输层失败的无链接版本：只留 `ClientException.message`（连接被拒 / 重置 / 中途
/// 断开之类），丢掉 `uri`。
SyncBackendError _linkFreeTransportError(http.ClientException error) =>
    SyncBackendError(
      'cloud asset range read failed: ${error.message}',
      isRetryable: true,
    );

/// 响应体流里的 `ClientException`（读到一半连接断了）同样换成 [_linkFreeTransportError]。
Stream<List<int>> _withLinkFreeErrors(Stream<List<int>> body) =>
    body.handleError(
      (Object error) =>
          throw _linkFreeTransportError(error as http.ClientException),
      test: (Object? error) => error is http.ClientException,
    );

SyncAssetRange _rangeFromResponse(
  http.StreamedResponse response,
  Stream<List<int>> body, {
  required int start,
  int? end,
}) {
  final String? type = response.headers['content-type'];
  if (response.statusCode == 206) {
    final ({int start, int end, int? total})? range =
        parseContentRange(response.headers['content-range']);
    if (range == null) {
      // 206 却给不出可解析的 Content-Range：不知道这段字节落在文件哪儿。不能落进下面
      // 的 200 分支——那里把 Content-Length（只是这一段的长度）当总长、再按 [start]
      // 跳前段，交出去的是错位的字节。
      unawaited(body.listen(null).cancel());
      throw SyncBackendError(
        'cloud asset range read failed: HTTP 206 without a parsable '
        'Content-Range',
      );
    }
    return SyncAssetRange(
      start: range.start,
      end: range.end,
      totalBytes: range.total ?? range.end + 1,
      contentType: type,
      bytes: body,
    );
  }
  // 200：上游忽略了 Range，回的是整文件——自己跳过前段、截掉尾段。
  final int? total = response.contentLength;
  if (total == null) {
    unawaited(body.listen(null).cancel());
    throw SyncBackendError('cloud asset range read failed: unknown length');
  }
  if (start >= total) {
    // 回的是整个文件：取消而不是 drain，免得为一个越界请求把整文件下完。
    unawaited(body.listen(null).cancel());
    throw SyncAssetRangeNotSatisfiable(total);
  }
  final int last = end == null || end >= total ? total - 1 : end;
  return SyncAssetRange(
    start: start,
    end: last,
    totalBytes: total,
    contentType: type,
    bytes: sliceByteStream(body, skip: start, take: last - start + 1),
  );
}

int? _unsatisfiedTotal(String? contentRange) {
  if (contentRange == null) return null;
  final RegExpMatch? m = RegExp(r'/(\d+)\s*$').firstMatch(contentRange);
  return m == null ? null : int.parse(m.group(1)!);
}

/// 纯函数：从 [source] 跳过前 [skip] 字节、只取其后 [take] 字节；取够即取消上游。
Stream<List<int>> sliceByteStream(
  Stream<List<int>> source, {
  required int skip,
  required int take,
}) async* {
  int toSkip = skip;
  int remaining = take;
  if (remaining <= 0) return;
  await for (final List<int> chunk in source) {
    int from = 0;
    if (toSkip > 0) {
      if (chunk.length <= toSkip) {
        toSkip -= chunk.length;
        continue;
      }
      from = toSkip;
      toSkip = 0;
    }
    final int available = chunk.length - from;
    if (available <= remaining) {
      yield from == 0 ? chunk : chunk.sublist(from);
      remaining -= available;
    } else {
      yield chunk.sublist(from, from + remaining);
      remaining = 0;
    }
    if (remaining == 0) return;
  }
}

/// 以 [refresh] 刷新过期的 access token 后重试**一次** [call]（区间读前的直链获取
/// 走普通 API，access token 过期是常态：OneDrive 约 1 小时、Dropbox 约 4 小时）。
Future<T> retryAfterAuthRefresh<T>(
  Future<void> Function() refresh,
  Future<T> Function() call,
) async {
  try {
    return await call();
  } on SyncAuthError {
    await refresh();
    return call();
  }
}
