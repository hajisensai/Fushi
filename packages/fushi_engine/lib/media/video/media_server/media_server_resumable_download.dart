/// 媒体服务器（Jellyfin / Emby / Plex）整片下载：`.part` + Range 续传 + 空闲超时。
///
/// 此前两家都是「一次 GET 写到底」：暂停、断网、进程被杀之后半截文件被删，重试从 0
/// 开始（几个 GB 的片子等于白下）；正文流也没有空闲超时，服务器接了连接不送数据时
/// 永远挂着。现在走与在线源整集下载同一个 [ResumableDownloader]：
///
/// - 断点身份记在 `<dest>.part.resume` 侧车里，**键是条目身份**（调用方给的
///   [downloadMediaServerFileResumable] 的 `resumeKey`，如条目 id + 版本 id），不是
///   URL——媒体服务器的取流 URL 带 `api_key` / `X-Plex-Token`，每次会话也可能不同，
///   拿它当键既续不上、又会把令牌落进侧车。侧车只存键与响应验证器
///   （ETag / Last-Modified / 总长），**绝不存 URL**；错误文本一律经
///   [redactCredentialsInText] 脱敏。
/// - 只在有**强验证器**（强 ETag / Last-Modified，见 [ResumeValidator]）时续传：
///   总长相同不是版本身份（BUG-5117 / HBK-AUDIT-033），没有强验证器的 `.part`
///   直接从 0 重下。
/// - 续传时带 `If-Range`；服务器（或不支持 Range 的兼容层）回 200 时
///   [ResumableDownloader] 丢弃旧 `.part` 从 0 写；回了 206 但没回显 If-Range 用的
///   验证器、或验证器 / 总长对不上（无视 If-Range 的服务器）就作废这条响应、不带
///   Range 重开，不把两份字节拼成坏片。
/// - 只下原始文件：调用方只给直出 / 原文件端点；转码流每次字节都不同，不续传。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'package:fushi_engine/media/metadata/credential_redaction.dart'
    show redactCredentialsInText;
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';
import 'package:fushi_engine/utils/misc/resume_validator.dart';

/// 发请求到拿到响应头的上限（与 JellyfinApi / PlexApi 的小请求超时同口径）。
const Duration kMediaServerDownloadFirstByteTimeout = Duration(seconds: 15);

/// 正文两个数据块之间的最长空闲（与在线源整集下载 / 互联下载同口径）。
const Duration kMediaServerDownloadStallTimeout = Duration(seconds: 45);

/// 断点侧车后缀：`<dest>.part.resume`。
const String kMediaServerResumeSidecarSuffix = '.part.resume';

/// `.part` 的断点身份：条目键 + 上次响应的验证器。
@immutable
class MediaServerResumeSidecar {
  const MediaServerResumeSidecar({
    required this.resumeKey,
    this.etag,
    this.lastModified,
    this.totalBytes,
  });

  final String resumeKey;
  final String? etag;
  final String? lastModified;
  final int? totalBytes;

  ResumeValidator get validator => ResumeValidator(
    etag: etag,
    lastModified: lastModified,
    totalBytes: totalBytes,
  );

  /// 有强验证器（强 ETag / Last-Modified）：凭它才能确认续上的是同一版本。只有
  /// 总长 / 只有弱 ETag 不算（BUG-5117）。
  bool get hasStrongValidator => validator.hasStrongValidator;

  String encode() => jsonEncode(<String, Object?>{
    'key': resumeKey,
    'etag': etag,
    'lastModified': lastModified,
    'totalBytes': totalBytes,
  });

  /// 坏 JSON / 缺键返回 null，**绝不抛**（当作没有侧车）。
  static MediaServerResumeSidecar? tryParse(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final Object? key = decoded['key'];
      if (key is! String || key.isEmpty) return null;
      final Object? etag = decoded['etag'];
      final Object? lastModified = decoded['lastModified'];
      final Object? total = decoded['totalBytes'];
      return MediaServerResumeSidecar(
        resumeKey: key,
        etag: etag is String && etag.isNotEmpty ? etag : null,
        lastModified: lastModified is String && lastModified.isNotEmpty
            ? lastModified
            : null,
        totalBytes: total is int && total >= 0 ? total : null,
      );
    } on Object {
      return null;
    }
  }

  /// 续传响应（206）是否证明仍是侧车记下的那个版本：If-Range 用的强验证器必须
  /// 回显且相等，其余共有字段任一不同即不是；缺证据算不是（宁可重下，不拼坏片）。
  bool sameStreamAs(ResumableDownloadResponse response) =>
      validator.provesSameRepresentation(response);
}

/// 下载 [url] 到 [dest]，中断（暂停 / 断网 / 空闲超时 / 进程被杀）后留 `.part` 与
/// 侧车，下一次同一 [resumeKey] + 同一 [dest] 的调用从断点接着拉。
///
/// - [headers]：鉴权等请求头（Range / If-Range 由本函数加）。
/// - [statusError]：非 200 / 206 / 416 时抛的异常（调用方的 API 异常类型，不带 URL）。
/// - [cancelSignal] 完成即中止在途传输，抛 [cancelledError] 的返回值，`.part` 保留。
/// - 成功后 `.part` 换名成 [dest]，侧车删除。
Future<void> downloadMediaServerFileResumable({
  required http.Client client,
  required String url,
  required Map<String, String> headers,
  required String resumeKey,
  required File dest,
  required Exception Function(int statusCode) statusError,
  required Exception Function() cancelledError,
  void Function(double progress)? onProgress,
  void Function(int received, int? total)? onBytes,
  Future<void>? cancelSignal,
  Duration firstByteTimeout = kMediaServerDownloadFirstByteTimeout,
  Duration stallTimeout = kMediaServerDownloadStallTimeout,
}) async {
  final File part = File('${dest.path}.part');
  final File sidecarFile = File('${dest.path}$kMediaServerResumeSidecarSuffix');
  await dest.parent.create(recursive: true);

  MediaServerResumeSidecar? stored = await _readSidecar(sidecarFile);
  if (stored != null &&
      (stored.resumeKey != resumeKey || !stored.hasStrongValidator)) {
    stored = null;
  }
  if (stored == null) {
    // 没有可证明同一版本的身份（别的条目留下的 / 旧版本留下的 / 上次只给了总长或
    // 弱 ETag）：
    // 宁可从 0 重下，也不冒把两份字节拼成坏片的险。
    await _deleteQuietly(part);
    await _deleteQuietly(sidecarFile);
  }
  final MediaServerResumeSidecar? resumeFrom = stored;

  bool cancelled = false;
  final Completer<void> cancel = Completer<void>();
  if (cancelSignal != null) {
    void onCancel() {
      cancelled = true;
      if (!cancel.isCompleted) cancel.complete();
    }

    unawaited(cancelSignal.then((_) => onCancel(), onError: (_) => onCancel()));
  }

  Future<ResumableDownloadResponse> send(Map<String, String> extra) async {
    if (cancelled) throw cancelledError();
    // 每次尝试一个中止闸：用户暂停、或首字节超时都真正中止底层传输。
    final Completer<void> abort = Completer<void>();
    unawaited(
      cancel.future.then((_) {
        if (!abort.isCompleted) abort.complete();
      }),
    );
    bool timedOut = false;
    final Timer timer = Timer(firstByteTimeout, () {
      timedOut = true;
      if (!abort.isCompleted) abort.complete();
    });
    final http.AbortableRequest request = http.AbortableRequest(
      'GET',
      Uri.parse(url),
      abortTrigger: abort.future,
    );
    request.headers
      ..addAll(headers)
      // 长度与 Range 偏移都按线上字节算：不让中间层压缩。
      ..[HttpHeaders.acceptEncodingHeader] = 'identity'
      ..addAll(extra);
    final http.StreamedResponse res;
    try {
      res = await client.send(request);
    } on http.RequestAbortedException {
      if (cancelled) throw cancelledError();
      if (timedOut) {
        throw TimeoutException(
          'media server download: no response headers',
          firstByteTimeout,
        );
      }
      rethrow;
    } finally {
      timer.cancel();
    }
    final int code = res.statusCode;
    if (code != HttpStatus.ok &&
        code != HttpStatus.partialContent &&
        code != HttpStatus.requestedRangeNotSatisfiable) {
      await res.stream.drain<void>().catchError((Object _) {});
      throw statusError(code);
    }
    return ResumableDownloadResponse(
      statusCode: code,
      headers: res.headers,
      stream: res.stream.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (List<int> chunk, EventSink<List<int>> sink) {
            if (cancelled) {
              sink
                ..addError(cancelledError())
                ..close();
              return;
            }
            sink.add(chunk);
          },
          // 不依赖「中止后响应流是报错还是静默结束」：静默结束会让下载器把截断的
          // `.part` 当完整文件换名。
          handleDone: (EventSink<List<int>> sink) {
            if (cancelled) sink.addError(cancelledError());
            sink.close();
          },
        ),
      ),
    );
  }

  final ResumableDownloader downloader = ResumableDownloader(
    url: url,
    destination: dest,
    partFile: part,
    resumeState: resumeFrom?.validator.ifRangeState,
    bodyTimeout: stallTimeout,
    open: (Uri _, Map<String, String> rangeHeaders) async {
      final ResumableDownloadResponse response = await send(rangeHeaders);
      final bool resumed =
          rangeHeaders.containsKey(HttpHeaders.rangeHeader) &&
          response.statusCode == HttpStatus.partialContent;
      if (!resumed || resumeFrom == null || resumeFrom.sameStreamAs(response)) {
        return response;
      }
      // 服务器无视 If-Range 照回 206，且没回显 If-Range 的验证器或验证器 / 总长
      // 已经变了：作废这条响应，不带
      // Range 重开——下载器见到 200 就丢弃旧 part 从 0 写。
      await _abandon(response);
      return send(const <String, String>{});
    },
    onMeta: (ResumableDownloadMetaInfo meta) {
      _writeSidecarSync(
        sidecarFile,
        MediaServerResumeSidecar(
          resumeKey: resumeKey,
          etag: meta.etag,
          lastModified: meta.lastModified,
          totalBytes: meta.totalBytes,
        ),
      );
    },
    onProgress: (int received, int? total) {
      if (cancelled) return;
      onBytes?.call(received, total);
      if (total != null && total > 0) onProgress?.call(received / total);
    },
  );
  try {
    await downloader.download();
  } on http.ClientException catch (e) {
    if (cancelled) throw cancelledError();
    // 网络层异常的文本带完整 URL（含令牌）：构造侧脱敏。
    throw HttpException(redactCredentialsInText(e.message));
  } on HttpException catch (e) {
    if (cancelled) throw cancelledError();
    // 下载器自己的 HttpException（坏 Content-Range 等）文本里带 URL。
    throw HttpException(redactCredentialsInText(e.message));
  } on Object {
    if (cancelled) throw cancelledError();
    rethrow;
  } finally {
    // 下完（part 已换名成 dest）清侧车；失败 / 中断保留（与 .part 配对供续传）。
    if (!await part.exists()) await _deleteQuietly(sidecarFile);
  }
}

Future<MediaServerResumeSidecar?> _readSidecar(File file) async {
  try {
    if (!await file.exists()) return null;
    return MediaServerResumeSidecar.tryParse(await file.readAsString());
  } on Object {
    return null;
  }
}

/// onMeta 是同步回调：侧车很小，同步写保证它先于 body 落盘。写失败只损失续传
/// 能力（下次没有侧车 → 从 0），不影响本次下载。
void _writeSidecarSync(File file, MediaServerResumeSidecar sidecar) {
  try {
    if (!sidecar.hasStrongValidator) {
      if (file.existsSync()) file.deleteSync();
      return;
    }
    file.writeAsStringSync(sidecar.encode(), flush: true);
  } on Object {
    // best-effort
  }
}

Future<void> _abandon(ResumableDownloadResponse response) async {
  try {
    await response.stream.listen(null).cancel();
  } on Object {
    // 丢弃中的响应出什么错都无所谓。
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on Object {
    // best-effort
  }
}
