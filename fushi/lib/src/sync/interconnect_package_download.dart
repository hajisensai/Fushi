/// 互联大文件下载：断点续传 + 整体校验 + 后台 isolate 收包（反馈 Sn4fYseBt4）。
///
/// 两个用户可见的问题，各自的根因：
///
/// 1. **断了要从头来**。Range 续传骨架早就有（`.part` + `.part.etag` 侧车 +
///    `If-Range`），但：
///    - 一次传输里连接一断就整个失败，只能等下一轮同步——而下一轮（本地音频 / 词典
///      等同步阶段）用的是按序号新起的临时文件名，上一轮的 `.part` 永远对不上号；
///    - host 的导出缓存按「导出时刻」算 15 分钟过期，大包传过 15 分钟再断，续传必撞
///      重导出 → ETag 换代 → 从 0 重下。
///    本文件的 [downloadWithResumeSidecar] 负责「一次调用内断流就从断点接着拉」（每次
///    都要求真有新字节进来，零进展立即放弃，不是盲目重试），同步阶段改用稳定的
///    临时文件名（见 `SyncOrchestrator._resumableTmpFile`），host 侧改成滑动 TTL
///    （`ExportPackageCache`）。拼完之后按响应声明的总长 + `Repr-Digest`（整份
///    SHA-256）做整体校验，不符就丢弃，不把坏包交给导入。
///
/// 2. **传输中去看小说，速度掉七成以上**。旧实现在 UI isolate 上收包：TLS 解密、
///    每块 `sink.add`、每块一次进度回调（→ `syncProgress` → 所有挂着的进度条
///    rebuild）都排在 UI 事件循环里。阅读器（尤其歌词 / 有声书高亮模式）每帧都在占用
///    这个 isolate，socket 读事件被推迟、TCP 接收窗口被塞满，吞吐随之塌下去。
///    [runPinnedPackageDownloadInIsolate] 把整个收包循环搬到后台 isolate，自建一个
///    等价的钉扎 HttpClient；UI isolate 只收节流后的进度（≤ 每 [_progressInterval]
///    一次）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';

/// 一次 [downloadWithResumeSidecar] 调用内最多「断流后从断点接着拉」几次。
///
/// 每次接续都要求上一次真的收到了新字节，所以这不是对同一失败的盲目重试；上限只防
/// 「每次只进来几个字节」的病态链路把一次同步拖成无限长——到上限就把错误交给调用方，
/// `.part` 保留，下一轮同步接着续。
const int kMaxInCallResumes = 16;

/// 后台 isolate 向 UI isolate 报进度的最小间隔。
const Duration _progressInterval = Duration(milliseconds: 200);

/// 断流类错误：连接被关 / 重置 / 停顿超时。只有这类错误值得「从断点接着拉」；
/// 鉴权失败、404、完整性失败等一律直接交给调用方。
bool isResumableTransportError(Object e) =>
    e is HttpException || e is SocketException || e is TimeoutException;

/// Range 续传 + `.part.etag` 验证器侧车的共用下载骨架（库包与视频下载共用）。
///
/// 上次响应的 ETag 落到 `<dest>.part.etag`，下次续传以 `If-Range` 携带；host
/// 字节换代（验证器不匹配）时 host 回 200，[ResumableDownloader] 丢弃旧 part
/// 从 0 重写。成功后清侧车；失败 / 中断保留（与 `.part` 配对供续传）。
///
/// [requireValidatorToResume]：有 `.part` 却没有侧车验证器时直接丢弃旧 part。
/// 视频 `/stream` 为了播放器 seek 接受不带 `If-Range` 的盲 Range，旧版本留下的
/// 无验证器 `.part` 若照常续传，host 上文件一换就会拼成坏片——宁可重下。
///
/// [resumeInCall]：断流（[isResumableTransportError]）且本次确有新字节落盘时，在本次
/// 调用内直接带 Range 接着拉，最多 [kMaxInCallResumes] 次。
///
/// [verifyResponseIntegrity]：见 [ResumableDownloader.verifyResponseIntegrity]。
Future<void> downloadWithResumeSidecar({
  required String url,
  required File destination,
  required ResumableDownloadOpen open,
  required Duration firstByteTimeout,
  required Duration stallTimeout,
  bool requireValidatorToResume = false,
  bool resumeInCall = true,
  bool verifyResponseIntegrity = false,
  ResumableDownloadProgress? onProgress,
}) async {
  final File partFile = File('${destination.path}.part');
  final File etagFile = File('${destination.path}.part.etag');
  await destination.parent.create(recursive: true);
  int resumes = 0;
  while (true) {
    int? firstReceived;
    int lastReceived = 0;
    try {
      await _downloadOnce(
        url: url,
        destination: destination,
        partFile: partFile,
        etagFile: etagFile,
        open: open,
        firstByteTimeout: firstByteTimeout,
        stallTimeout: stallTimeout,
        requireValidatorToResume: requireValidatorToResume,
        verifyResponseIntegrity: verifyResponseIntegrity,
        onProgress: (int received, int? total) {
          firstReceived ??= received;
          lastReceived = received;
          onProgress?.call(received, total);
        },
      );
      return;
    } catch (e) {
      final int? start = firstReceived;
      final bool progressed = start != null && lastReceived > start;
      if (!resumeInCall ||
          !isResumableTransportError(e) ||
          !progressed ||
          resumes >= kMaxInCallResumes ||
          !partFile.existsSync()) {
        rethrow;
      }
      resumes++;
      debugPrint(
        '[interconnect-download] stream broke at $lastReceived bytes, '
        'resuming in-call ($resumes/$kMaxInCallResumes): $e',
      );
    }
  }
}

Future<void> _downloadOnce({
  required String url,
  required File destination,
  required File partFile,
  required File etagFile,
  required ResumableDownloadOpen open,
  required Duration firstByteTimeout,
  required Duration stallTimeout,
  required bool requireValidatorToResume,
  required bool verifyResponseIntegrity,
  ResumableDownloadProgress? onProgress,
}) async {
  String? storedEtag;
  try {
    if (partFile.existsSync() && etagFile.existsSync()) {
      storedEtag = etagFile.readAsStringSync().trim();
    }
  } catch (_) {
    // 侧车读不出：当无验证器处理（见下）。
  }
  if (storedEtag != null && storedEtag.isEmpty) storedEtag = null;
  if (storedEtag == null && requireValidatorToResume) {
    _deleteQuietly(partFile);
    _deleteQuietly(etagFile);
  }
  final ResumableDownloader downloader = ResumableDownloader(
    url: url,
    destination: destination,
    partFile: partFile,
    resumeState: ResumableDownloadState(etag: storedEtag),
    firstByteTimeout: firstByteTimeout,
    bodyTimeout: stallTimeout,
    verifyResponseIntegrity: verifyResponseIntegrity,
    open: open,
    onMeta: (ResumableDownloadMetaInfo meta) {
      // 把本次响应的 ETag 落侧车，供中断后（本次调用内或下次进程）的 If-Range 使用。
      try {
        final String? etag = meta.etag;
        if (etag != null && etag.isNotEmpty) {
          etagFile.writeAsStringSync(etag);
        } else if (etagFile.existsSync()) {
          etagFile.deleteSync();
        }
      } catch (_) {
        // best-effort：侧车写失败只损失续传能力，不影响本次下载。
      }
    },
    onProgress: onProgress,
  );
  try {
    await downloader.download();
  } finally {
    // 成功后清侧车；失败保留（与 .part 配对供续传）。
    if (!partFile.existsSync()) _deleteQuietly(etagFile);
  }
}

void _deleteQuietly(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } catch (_) {
    // best-effort
  }
}

/// 把 dart:io 响应包成 [ResumableDownloadResponse]（多值头以逗号拼接）。
ResumableDownloadResponse wrapResumableResponse(HttpClientResponse res) {
  final Map<String, String> responseHeaders = <String, String>{};
  // HttpClient 自动解压 gzip 时，流里是解码后的字节，而 Content-Length 描述的是
  // 编码后的线上长度（小 JSON 压缩后反而更长：109 线上 vs 99 解码）。把它交给
  // 下载器会被当成「声明总长」做截断 / 超长校验，必然误判，所以解压时不转交。
  final bool decoded =
      res.compressionState == HttpClientResponseCompressionState.decompressed;
  res.headers.forEach((String name, List<String> values) {
    if (values.isEmpty) return;
    if (decoded &&
        (name == HttpHeaders.contentLengthHeader ||
            name == HttpHeaders.contentEncodingHeader)) {
      return;
    }
    responseHeaders[name] = values.join(',');
  });
  return ResumableDownloadResponse(
    statusCode: res.statusCode,
    headers: responseHeaders,
    stream: res,
  );
}

/// 互联包端点的一次 GET（带 Range / If-Range 等 [headers]），经 [ops] 鉴权 / 钉扎。
///
/// 保留原错误契约：401/403 → [SyncAuthError]、404 → 可重试 [SyncBackendError]
/// （上层认证/重试流依赖这些类型）。416 放行给 [ResumableDownloader]——那是它
/// 「丢弃旧 part 从 0 重来」的合法信号。
Future<ResumableDownloadResponse> openInterconnectPackageGet(
  WebDavOps ops,
  Uri uri,
  Map<String, String> headers, {
  required String context,
}) async {
  final HttpClientRequest req = await ops.buildRequest('GET', uri.toString());
  for (final MapEntry<String, String> entry in headers.entries) {
    req.headers.set(entry.key, entry.value);
  }
  final HttpClientResponse res = await req.close();
  if (res.statusCode >= 400 && res.statusCode != 416) {
    await res.drain<void>().catchError((_) {});
    ops.checkStatus(res.statusCode, 'GET $context');
  }
  return wrapResumableResponse(res);
}

/// 后台 isolate 下载需要的全部输入。只含可跨 isolate 传递的值（没有回调）。
@immutable
class PinnedPackageDownloadSpec {
  const PinnedPackageDownloadSpec({
    required this.url,
    required this.destinationPath,
    required this.baseUrl,
    required this.token,
    required this.pinnedFingerprint,
    required this.connectionTimeout,
    required this.firstByteTimeout,
    required this.stallTimeout,
  });

  final String url;
  final String destinationPath;
  final String baseUrl;
  final String token;

  /// host 证书指纹；null = 明文 http 会话（测试用，见
  /// [InterconnectSyncBackend.debugIsolateUnpinnedDownloads]）。
  final String? pinnedFingerprint;
  final Duration connectionTimeout;
  final Duration firstByteTimeout;
  final Duration stallTimeout;
}

/// 在后台 isolate 里跑一次互联包下载（续传 + 整体校验），UI isolate 只收节流后的
/// 进度。错误原样（同一 isolate group 内对象可直接传回）从返回的 Future 抛出。
Future<void> runPinnedPackageDownloadInIsolate(
  PinnedPackageDownloadSpec spec, {
  ResumableDownloadProgress? onProgress,
}) async {
  final ReceivePort port = ReceivePort();
  final StreamSubscription<dynamic> sub = port.listen((dynamic msg) {
    if (msg is List && msg.length == 2) {
      onProgress?.call(msg[0] as int, msg[1] as int?);
    }
  });
  try {
    await _spawnIsolatedDownload(spec, port.sendPort);
  } finally {
    await sub.cancel();
    port.close();
  }
}

/// 单独成函数：交给 [Isolate.run] 的闭包只能捕获 [spec] 与 [progress]。写在
/// [runPinnedPackageDownloadInIsolate] 里会和 `port.listen` 的回调共享同一个闭包上下文，
/// 把调用方的 `onProgress`（往往捕获着 UI 对象）一起拖进消息，发送失败。
Future<void> _spawnIsolatedDownload(
  PinnedPackageDownloadSpec spec,
  SendPort progress,
) => Isolate.run(() => _isolatedDownloadMain(spec, progress));

Future<void> _isolatedDownloadMain(
  PinnedPackageDownloadSpec spec,
  SendPort progress,
) async {
  final WebDavOps ops = WebDavOps(
    baseUrl: spec.baseUrl,
    username: 'hibiki',
    password: spec.token,
    connectionTimeout: spec.connectionTimeout,
    pinnedFingerprint: spec.pinnedFingerprint,
    // BUG-2377：互联的凭据是配对 token，不是登录会话。
    unauthorizedKind: SyncAuthFailureKind.pairingRejected,
  );
  final Stopwatch clock = Stopwatch()..start();
  int lastSentMs = -_progressInterval.inMilliseconds;
  int lastReceived = 0;
  int? lastTotal;
  try {
    await downloadWithResumeSidecar(
      url: spec.url,
      destination: File(spec.destinationPath),
      firstByteTimeout: spec.firstByteTimeout,
      stallTimeout: spec.stallTimeout,
      verifyResponseIntegrity: true,
      open: (Uri uri, Map<String, String> headers) =>
          openInterconnectPackageGet(ops, uri, headers, context: spec.url),
      onProgress: (int received, int? total) {
        lastReceived = received;
        lastTotal = total;
        final int now = clock.elapsedMilliseconds;
        if (now - lastSentMs < _progressInterval.inMilliseconds) return;
        lastSentMs = now;
        progress.send(<Object?>[received, total]);
      },
    );
    progress.send(<Object?>[lastReceived, lastTotal]);
  } finally {
    ops.close(force: true);
  }
}
