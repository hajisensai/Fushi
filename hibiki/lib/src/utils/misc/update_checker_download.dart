part of 'update_checker.dart';

/// 单个候选 URL 的尝试超时。`HttpClient.connectionTimeout` 只管「建立 TCP 连接」
/// 那一跳；某个镜像 TCP 连上却挂起不返回时，需要这个整体超时把它判死、回退到下一个，
/// 否则一个坏镜像就能拖垮整轮检查（BUG-277）。
const Duration _kPerAttemptTimeout = Duration(seconds: 15);
const Duration _kDownloadDiagnosticsInterval = Duration(milliseconds: 500);

/// 多线程分片下载默认并发连接数（TODO-596）。clamp 1..[_kMaxDownloadConnections]。
/// 镜像/GitHub 对象存储共享出口 IP 易触发 429/403 限流，4 是经验上「加速明显但不易被
/// 限流」的折中；首版硬编码不暴露设置（YAGNI）。
const int _kDefaultDownloadConnections = 4;
const int _kMaxDownloadConnections = 8;

/// 单个分片的最小字节数（默认 4 MiB）。文件 < 2*minSegment 时多线程无收益、反而多付
/// 握手开销，门控退化单连接（见 [planDownloadSegments]）。
const int _kDefaultMinSegmentBytes = 4 * 1024 * 1024;

/// 单个分片最终下载失败前的有界重试次数（指数退避）。耗尽仍失败 → orchestrator 抛出，
/// 由 [_downloadCandidate] 整体退回单线程路径（绝不半成品 promote）。
const int _kSegmentMaxAttempts = 3;

typedef UpdateDownloadOpen = Future<UpdateDownloadResponse> Function(
  Uri uri,
  Map<String, String> headers,
);

typedef UpdateDownloadSourceFailure = void Function(
  String url,
  Object error,
  StackTrace stack,
);

typedef UpdateDownloadDiagnosticsCallback = void Function(
  UpdateDownloadDiagnostics diagnostics,
);

@visibleForTesting
class UpdateDownloadDiagnostics {
  const UpdateDownloadDiagnostics({
    required this.sourceUrl,
    required this.sourceHost,
    required this.receivedBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
    required this.resumed,
    required this.restartedFromZero,
  });

  final String sourceUrl;
  final String sourceHost;
  final int receivedBytes;
  final int? totalBytes;
  final double? bytesPerSecond;
  final bool resumed;
  final bool restartedFromZero;
}

final Map<String, Future<File>> _activeUpdateDownloads =
    <String, Future<File>>{};
var _downloadStagingCounter = 0;

@visibleForTesting
class UpdateDownloadResponse {
  const UpdateDownloadResponse({
    required this.statusCode,
    required this.headers,
    required this.stream,
  });

  factory UpdateDownloadResponse.bytes({
    required int statusCode,
    required List<int> body,
    Map<String, String> headers = const <String, String>{},
  }) {
    return UpdateDownloadResponse(
      statusCode: statusCode,
      headers: headers,
      stream: Stream<List<int>>.value(body),
    );
  }

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> stream;

  String? header(String name) => _headerValue(headers, name);
}

@visibleForTesting
class UpdateDownloadPaths {
  const UpdateDownloadPaths({
    required this.file,
    required this.partFile,
    required this.metadataFile,
    required this.ownerFile,
    required this.stagingRoot,
  });

  factory UpdateDownloadPaths.forAsset(
      Directory updatesDir, UpdateAsset asset) {
    final String fallbackName = _fileNameFromUrl(asset.url);
    final String name = safeUpdateAssetFileName(
      asset.name.isNotEmpty ? asset.name : fallbackName,
    );
    return UpdateDownloadPaths(
      file: File('${updatesDir.path}${Platform.pathSeparator}$name'),
      partFile: File('${updatesDir.path}${Platform.pathSeparator}$name.part'),
      metadataFile:
          File('${updatesDir.path}${Platform.pathSeparator}$name.meta.json'),
      ownerFile:
          File('${updatesDir.path}${Platform.pathSeparator}$name.owner.json'),
      stagingRoot: Directory(
        '${updatesDir.path}${Platform.pathSeparator}.$name.staging',
      ),
    );
  }

  final File file;
  final File partFile;
  final File metadataFile;
  final File ownerFile;
  final Directory stagingRoot;
}

class _UpdateDownloadStagingPaths {
  const _UpdateDownloadStagingPaths({
    required this.directory,
    required this.file,
    required this.partFile,
    required this.metadataFile,
  });

  final Directory directory;
  final File file;
  final File partFile;
  final File metadataFile;
}

@visibleForTesting
String safeUpdateAssetFileName(String name) {
  final String leaf = name.replaceAll(r'\', '/').split('/').last.trim();
  final String sanitized = leaf
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  return sanitized.isEmpty ? 'hibiki-update.bin' : sanitized;
}

@visibleForTesting
Future<File> downloadUpdateAsset({
  required UpdateAsset asset,
  required String version,
  required Directory updatesDir,
  required List<String> candidateUrls,
  required UpdateDownloadOpen openUrl,
  int connectionCount = _kDefaultDownloadConnections,
  int minSegmentBytes = _kDefaultMinSegmentBytes,
  void Function(double value)? onProgress,
  UpdateDownloadDiagnosticsCallback? onDiagnostics,
  UpdateDownloadSourceFailure? onSourceFailure,
}) async {
  final String activeKey = _activeDownloadKey(updatesDir, asset, version);
  final Future<File>? activeDownload = _activeUpdateDownloads[activeKey];
  if (activeDownload != null) return activeDownload;

  final Future<File> download = _downloadUpdateAssetUncoalesced(
    asset: asset,
    version: version,
    updatesDir: updatesDir,
    candidateUrls: candidateUrls,
    openUrl: openUrl,
    connectionCount: connectionCount,
    minSegmentBytes: minSegmentBytes,
    onProgress: onProgress,
    onDiagnostics: onDiagnostics,
    onSourceFailure: onSourceFailure,
  );
  _activeUpdateDownloads[activeKey] = download;
  try {
    return await download;
  } finally {
    if (identical(_activeUpdateDownloads[activeKey], download)) {
      _activeUpdateDownloads.remove(activeKey);
    }
  }
}

String _activeDownloadKey(
  Directory updatesDir,
  UpdateAsset asset,
  String version,
) =>
    '${updatesDir.absolute.path}|$version|${asset.name}|${asset.url}';

Future<File> _downloadUpdateAssetUncoalesced({
  required UpdateAsset asset,
  required String version,
  required Directory updatesDir,
  required List<String> candidateUrls,
  required UpdateDownloadOpen openUrl,
  int connectionCount = 1,
  int minSegmentBytes = _kDefaultMinSegmentBytes,
  void Function(double value)? onProgress,
  UpdateDownloadDiagnosticsCallback? onDiagnostics,
  UpdateDownloadSourceFailure? onSourceFailure,
}) async {
  await updatesDir.create(recursive: true);
  final UpdateDownloadPaths paths =
      UpdateDownloadPaths.forAsset(updatesDir, asset);
  final _UpdateDownloadMetadata? metadata =
      await _UpdateDownloadMetadata.read(paths.metadataFile);

  if (await _isReusableCompleteDownload(
    paths.file,
    asset,
    version,
    metadata,
  )) {
    onProgress?.call(1);
    return paths.file;
  }

  if (await paths.file.exists()) {
    await _deleteFile(paths.file);
  }

  if (metadata == null || !metadata.matches(asset, version)) {
    await _deleteFile(paths.partFile);
    await _deleteFile(paths.metadataFile);
  }

  final _UpdateDownloadStagingPaths stagingPaths =
      await _resolveStagingPaths(paths, asset, version);
  if (metadata != null && metadata.matches(asset, version)) {
    await _seedStagingFromLegacyPart(
      paths,
      stagingPaths,
      asset,
      version,
      metadata,
    );
  }

  Object? lastError;
  StackTrace? lastStack;
  for (final String url in candidateUrls) {
    try {
      final _UpdateDownloadMetadata? currentMetadata =
          await _UpdateDownloadMetadata.read(stagingPaths.metadataFile);
      final File? promoted = await _promotePartIfComplete(
        paths,
        stagingPaths,
        asset,
        version,
        currentMetadata,
      );
      if (promoted != null) {
        onProgress?.call(1);
        return promoted;
      }
      final int resumeOffset = await _resumeOffsetForPart(
        stagingPaths.partFile,
        asset,
        version,
        currentMetadata,
      );
      return await _downloadCandidate(
        asset: asset,
        version: version,
        paths: paths,
        stagingPaths: stagingPaths,
        url: url,
        openUrl: openUrl,
        metadata: currentMetadata,
        resumeOffset: resumeOffset,
        connectionCount: connectionCount,
        minSegmentBytes: minSegmentBytes,
        onProgress: onProgress,
        onDiagnostics: onDiagnostics,
      );
    } catch (e, stack) {
      lastError = e;
      lastStack = stack;
      onSourceFailure?.call(url, e, stack);
    }
  }

  Error.throwWithStackTrace(
    lastError ?? Exception('All download sources failed'),
    lastStack ?? StackTrace.current,
  );
}

/// **纯函数**：一个分片的闭区间字节范围 `[start, end]`。[end] 为 null 表示「到文件末尾」
/// （未知总大小时的单段开放区间，等价单线程整体下载）。
@visibleForTesting
class DownloadSegment {
  const DownloadSegment(this.start, this.end);

  /// 分片起始字节偏移（含）。
  final int start;

  /// 分片结束字节偏移（含）；null = 文件末尾（开放区间）。
  final int? end;

  /// 该段已知长度（end 非 null 时），未知返回 null。
  int? get length => end == null ? null : end! - start + 1;
}

/// **纯函数（TODO-596）**：把一个已知 [totalBytes] 的下载切成 N 个互不重叠、首尾相接、
/// 覆盖整文件的闭区间分片，供多线程 Range 并发下载。
///
/// **门控（消除特殊情况，任一命中 → 返回单段 = 退化单线程）**：
///   1. [totalBytes] == null（无 Content-Length / asset.sizeBytes）→ 单段开放区间
///      `[0, null]`，调用方按现有单连接体顺序下载。
///   2. clamp 后连接数 <= 1 → 单段闭区间 `[0, total-1]`。
///   3. [totalBytes] < 2*[minSegmentBytes]（小文件多线程无收益）→ 单段闭区间。
///
/// 否则按 `segments = clamp(connectionCount, 1, max)`，但再受 [minSegmentBytes] 约束
/// （`total / minSegmentBytes` 上限），保证不切出比 minSegment 还小的段。每段大小
/// `total ~/ segments`，末段吸收余数。这是「能切就切、不能切就退」的叠加层，不引入特例
/// 分支到调用方——单段返回值让多线程与单线程走同一聚合逻辑。
@visibleForTesting
List<DownloadSegment> planDownloadSegments({
  required int? totalBytes,
  int connectionCount = _kDefaultDownloadConnections,
  int minSegmentBytes = _kDefaultMinSegmentBytes,
}) {
  if (totalBytes == null || totalBytes <= 0) {
    return const <DownloadSegment>[DownloadSegment(0, null)];
  }
  final int safeMinSegment = minSegmentBytes < 1 ? 1 : minSegmentBytes;
  int connections = connectionCount;
  if (connections < 1) connections = 1;
  if (connections > _kMaxDownloadConnections) {
    connections = _kMaxDownloadConnections;
  }
  // 小文件 / 单连接 / 切完比 minSegment 还小 → 退化单段闭区间。
  if (connections <= 1 || totalBytes < 2 * safeMinSegment) {
    return <DownloadSegment>[DownloadSegment(0, totalBytes - 1)];
  }
  final int maxByMinSegment = totalBytes ~/ safeMinSegment;
  final int segmentCount =
      connections < maxByMinSegment ? connections : maxByMinSegment;
  if (segmentCount <= 1) {
    return <DownloadSegment>[DownloadSegment(0, totalBytes - 1)];
  }
  final int baseSize = totalBytes ~/ segmentCount;
  final List<DownloadSegment> segments = <DownloadSegment>[];
  int start = 0;
  for (int i = 0; i < segmentCount; i++) {
    final bool isLast = i == segmentCount - 1;
    final int end = isLast ? totalBytes - 1 : start + baseSize - 1;
    segments.add(DownloadSegment(start, end));
    start = end + 1;
  }
  return segments;
}

Future<File> _downloadCandidate({
  required UpdateAsset asset,
  required String version,
  required UpdateDownloadPaths paths,
  required _UpdateDownloadStagingPaths stagingPaths,
  required String url,
  required UpdateDownloadOpen openUrl,
  required _UpdateDownloadMetadata? metadata,
  required int resumeOffset,
  int connectionCount = 1,
  int minSegmentBytes = _kDefaultMinSegmentBytes,
  void Function(double value)? onProgress,
  UpdateDownloadDiagnosticsCallback? onDiagnostics,
  bool restarted = false,
}) async {
  // 多线程分片入口（TODO-596）：仅当请求并发 > 1、且不是从断点续传/重启路径进来时，
  // 先尝试对**当前 url** 分段并发。任一门控不满足或分段失败 → 返回 null，落到下方现有
  // 单连接体（restarted/resumeOffset 的精密逻辑完全不动）。源回退仍由外层
  // _downloadUpdateAssetUncoalesced 的 candidateUrls 循环负责，此处不重做源选择。
  //
  // **已知 size 预门控**：size（asset / 续传 metadata）已知且切不出多段（小文件）时，
  // 根本不进 orchestrator、不发探针——保证小文件单线程路径零额外请求（不破坏现有
  // 单线程行为与续传测试）。size 未知（纯 GFW 302 无 Content-Length）才让探针去拿
  // 总大小。
  final int? knownSize = asset.sizeBytes ?? metadata?.sizeBytes;
  final bool sizePermitsSegmentation = knownSize == null ||
      planDownloadSegments(
            totalBytes: knownSize,
            connectionCount: connectionCount,
            minSegmentBytes: minSegmentBytes,
          ).length >
          1;
  if (connectionCount > 1 &&
      resumeOffset == 0 &&
      !restarted &&
      sizePermitsSegmentation) {
    final File? segmented = await _downloadSegmented(
      asset: asset,
      version: version,
      paths: paths,
      stagingPaths: stagingPaths,
      url: url,
      openUrl: openUrl,
      metadata: metadata,
      connectionCount: connectionCount,
      minSegmentBytes: minSegmentBytes,
      onProgress: onProgress,
      onDiagnostics: onDiagnostics,
    );
    if (segmented != null) return segmented;
    // null = 门控退化或并发失败：清理可能残留的分段文件，落单线程整体重下。
    await _cleanupSegmentFiles(stagingPaths);
  }
  return _downloadCandidateSingle(
    asset: asset,
    version: version,
    paths: paths,
    stagingPaths: stagingPaths,
    url: url,
    openUrl: openUrl,
    metadata: metadata,
    resumeOffset: resumeOffset,
    onProgress: onProgress,
    onDiagnostics: onDiagnostics,
    restarted: restarted,
  );
}

Future<File> _downloadCandidateSingle({
  required UpdateAsset asset,
  required String version,
  required UpdateDownloadPaths paths,
  required _UpdateDownloadStagingPaths stagingPaths,
  required String url,
  required UpdateDownloadOpen openUrl,
  required _UpdateDownloadMetadata? metadata,
  required int resumeOffset,
  void Function(double value)? onProgress,
  UpdateDownloadDiagnosticsCallback? onDiagnostics,
  bool restarted = false,
}) async {
  final Uri uri = Uri.parse(url);
  final String sourceHost = hostLabelForUpdateUrl(url);
  final Stopwatch diagnosticsStopwatch = Stopwatch()..start();
  var lastDiagnosticsElapsed = -_kDownloadDiagnosticsInterval.inMilliseconds;
  var speedStartBytes = resumeOffset;
  var resumed = false;
  var restartedFromZero = restarted;

  void reportDiagnostics({
    required int receivedBytes,
    required int? totalBytes,
    required bool force,
  }) {
    final UpdateDownloadDiagnosticsCallback? callback = onDiagnostics;
    if (callback == null) return;

    final int elapsed = diagnosticsStopwatch.elapsedMilliseconds;
    if (!force &&
        elapsed - lastDiagnosticsElapsed <
            _kDownloadDiagnosticsInterval.inMilliseconds) {
      return;
    }
    lastDiagnosticsElapsed = elapsed;

    callback(
      UpdateDownloadDiagnostics(
        sourceUrl: url,
        sourceHost: sourceHost,
        receivedBytes: receivedBytes,
        totalBytes: totalBytes,
        bytesPerSecond: updateDownloadBytesPerSecond(
          startedBytes: speedStartBytes,
          receivedBytes: receivedBytes,
          elapsed: diagnosticsStopwatch.elapsed,
        ),
        resumed: resumed,
        restartedFromZero: restartedFromZero,
      ),
    );
  }

  reportDiagnostics(
    receivedBytes: resumeOffset,
    totalBytes: asset.sizeBytes ?? metadata?.sizeBytes,
    force: true,
  );

  final Map<String, String> headers = <String, String>{};
  if (resumeOffset > 0) {
    headers[HttpHeaders.rangeHeader] = 'bytes=$resumeOffset-';
    final String? ifRange = metadata?.etag ?? metadata?.lastModified;
    if (ifRange != null && ifRange.isNotEmpty) {
      headers[HttpHeaders.ifRangeHeader] = ifRange;
    }
  }

  final UpdateDownloadResponse response =
      await openUrl(uri, headers).timeout(_kPerAttemptTimeout);
  final bool requestedRange = resumeOffset > 0;
  var writeOffset = resumeOffset;

  if (requestedRange &&
      response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
      !restarted) {
    await response.stream.drain<void>();
    await _deleteFile(stagingPaths.partFile);
    await _deleteFile(stagingPaths.metadataFile);
    return _downloadCandidateSingle(
      asset: asset,
      version: version,
      paths: paths,
      stagingPaths: stagingPaths,
      url: url,
      openUrl: openUrl,
      metadata: null,
      resumeOffset: 0,
      onProgress: onProgress,
      onDiagnostics: onDiagnostics,
      restarted: true,
    );
  }

  if (requestedRange && response.statusCode == HttpStatus.partialContent) {
    final int? start =
        _contentRangeStart(response.header(HttpHeaders.contentRangeHeader));
    if (start != resumeOffset) {
      await response.stream.drain<void>();
      await _deleteFile(stagingPaths.partFile);
      await _deleteFile(stagingPaths.metadataFile);
      if (!restarted) {
        return _downloadCandidateSingle(
          asset: asset,
          version: version,
          paths: paths,
          stagingPaths: stagingPaths,
          url: url,
          openUrl: openUrl,
          metadata: null,
          resumeOffset: 0,
          onProgress: onProgress,
          onDiagnostics: onDiagnostics,
          restarted: true,
        );
      }
      throw HttpException('invalid content-range for resume: $url');
    }
    resumed = true;
  } else if (response.statusCode == HttpStatus.ok) {
    if (requestedRange) {
      await _deleteFile(stagingPaths.partFile);
      await _deleteFile(stagingPaths.metadataFile);
      writeOffset = 0;
      speedStartBytes = 0;
      restartedFromZero = true;
    }
  } else {
    await response.stream.drain<void>();
    throw HttpException('download failed (${response.statusCode}): $url');
  }

  final int? responseTotal = _responseTotalSize(response, writeOffset);
  final _UpdateDownloadMetadata nextMetadata = _UpdateDownloadMetadata(
    version: version,
    name: asset.name,
    url: asset.url,
    sizeBytes: asset.sizeBytes ?? responseTotal,
    etag: response.header(HttpHeaders.etagHeader) ?? metadata?.etag,
    lastModified: response.header(HttpHeaders.lastModifiedHeader) ??
        metadata?.lastModified,
    sha256Digest: asset.sha256Digest,
  );
  await nextMetadata.write(stagingPaths.metadataFile);

  final IOSink sink = stagingPaths.partFile.openWrite(
    mode: writeOffset > 0 ? FileMode.append : FileMode.write,
  );
  var received = writeOffset;
  final int? total = nextMetadata.sizeBytes;
  if (total != null && total > 0) {
    onProgress?.call(received / total);
  } else {
    onProgress?.call(0);
  }
  reportDiagnostics(
    receivedBytes: received,
    totalBytes: total,
    force: true,
  );
  Object? bodyError;
  StackTrace? bodyStack;
  try {
    await for (final List<int> chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total != null && total > 0) {
        onProgress?.call(received / total);
      }
      reportDiagnostics(
        receivedBytes: received,
        totalBytes: total,
        force: false,
      );
    }
    await sink.flush();
    reportDiagnostics(
      receivedBytes: received,
      totalBytes: total,
      force: true,
    );
  } catch (e, stack) {
    bodyError = e;
    bodyStack = stack;
  }

  Object? closeError;
  StackTrace? closeStack;
  try {
    await sink.close();
  } catch (e, stack) {
    closeError = e;
    closeStack = stack;
  }

  Object? doneError;
  StackTrace? doneStack;
  try {
    await sink.done;
  } catch (e, stack) {
    doneError = e;
    doneStack = stack;
  }

  if (bodyError != null) Error.throwWithStackTrace(bodyError, bodyStack!);
  if (closeError != null) Error.throwWithStackTrace(closeError, closeStack!);
  if (doneError != null) Error.throwWithStackTrace(doneError, doneStack!);

  final int actualSize = await stagingPaths.partFile.length();
  final _UpdateDownloadMetadata completeMetadata = nextMetadata.copyWith(
    sizeBytes: nextMetadata.sizeBytes ?? actualSize,
  );
  if (!await _isValidCompleteDownload(
    stagingPaths.partFile,
    asset,
    completeMetadata,
  )) {
    await _deleteFile(stagingPaths.partFile);
    throw Exception('download integrity check failed: ${asset.name}');
  }

  final File promoted = await _promoteCompleteDownload(
    paths,
    stagingPaths,
    completeMetadata,
  );
  onProgress?.call(1);
  return promoted;
}

/// 一段并发分片下载的临时文件 `partFile.<i>`。
File _segmentPartFile(_UpdateDownloadStagingPaths stagingPaths, int index) =>
    File('${stagingPaths.partFile.path}.$index');

/// 删除某次分段尝试可能残留的 `partFile.<i>`（退化单线程 / 重试前的清理）。
/// best-effort：扫 staging 目录里所有 `*.part.<n>` 文件，不依赖记住段数。
Future<void> _cleanupSegmentFiles(
  _UpdateDownloadStagingPaths stagingPaths,
) async {
  try {
    if (!await stagingPaths.directory.exists()) return;
    final RegExp pattern = RegExp(r'\.part\.\d+$');
    await for (final FileSystemEntity entity in stagingPaths.directory.list()) {
      if (entity is File && pattern.hasMatch(entity.path)) {
        await _deleteFile(entity);
      }
    }
  } catch (e, stack) {
    ErrorLogService.instance.log('UpdateChecker.cleanupSegments', e, stack);
    debugPrint('[Hibiki] cleanup segment files failed: $e');
  }
}

/// **多线程分片下载 orchestrator（TODO-596）**。只对**当前 [url]** 展开并发分片，
/// 不重做源选择——整体多源回退仍由外层 [_downloadUpdateAssetUncoalesced] 的
/// candidateUrls 循环负责（调用方拿到 null 时回退到单线程体；单线程体抛错时外层换源）。
///
/// 流程：
/// 1. **探针**：对 [url] 发 `Range: bytes=0-`（带 If-Range，若 [metadata] 有 etag/
///    lastModified），读其 Content-Range 总大小与 ETag。
///    - 返 200（源忽略 Range）/ 无总大小 / 切分后只剩单段（小文件、门控）→ 返回 null，
///      由调用方退回单线程（不在这里硬塞特例分支）。
/// 2. **切分**：[planDownloadSegments] 按 total + [connectionCount] + [minSegmentBytes]
///    切成 N>1 个闭区间分片。
/// 3. **并发**：每段独立请求 `Range: bytes=start-end` + 同一 `If-Range`（探针 ETag/
///    lastModified），写各自 `partFile.<i>`。每段带 [_kPerAttemptTimeout] 整体超时
///    （各段独立计时）+ [_kSegmentMaxAttempts] 有界指数退避重试。
///    - **ETag 一致性**：任一段返回 200 而非 206（If-Range 不匹配 = 镜像共享出口 IP
///      轮换到 ETag 不同的后端）→ 整体放弃分片，返回 null 退单线程，避免 concat 后
///      sha256 失败（复核要求）。
/// 4. **合并**：全段完成 → 按序 [RandomAccessFile] 流式 concat 进
///    [stagingPaths.partFile]（不整文件进内存）→ 复用 [_isValidCompleteDownload]
///    （size+sha256）→ [_promoteCompleteDownload] 原子 rename。
///
/// 任一段重试耗尽仍失败、ETag 不一致、或门控不满足 → 返回 null（绝不 promote 半成品），
/// 由调用方走单线程整体重下。
Future<File?> _downloadSegmented({
  required UpdateAsset asset,
  required String version,
  required UpdateDownloadPaths paths,
  required _UpdateDownloadStagingPaths stagingPaths,
  required String url,
  required UpdateDownloadOpen openUrl,
  required _UpdateDownloadMetadata? metadata,
  required int connectionCount,
  required int minSegmentBytes,
  void Function(double value)? onProgress,
  UpdateDownloadDiagnosticsCallback? onDiagnostics,
}) async {
  final Uri uri = Uri.parse(url);
  final String? ifRange = metadata?.etag ?? metadata?.lastModified;

  // ---- 1. 探针：拿总大小 + 该后端的 ETag（用作 If-Range 一致性验证器）----
  final Map<String, String> probeHeaders = <String, String>{
    HttpHeaders.rangeHeader: 'bytes=0-',
    if (ifRange != null && ifRange.isNotEmpty)
      HttpHeaders.ifRangeHeader: ifRange,
  };
  final UpdateDownloadResponse probe;
  try {
    probe = await openUrl(uri, probeHeaders).timeout(_kPerAttemptTimeout);
  } catch (_) {
    // 探针失败：让调用方走单线程（其错误处理/换源更完整），不在此吞掉换源职责。
    return null;
  }
  if (probe.statusCode != HttpStatus.partialContent) {
    await probe.stream.drain<void>();
    return null; // 源不支持 Range（200/其它）→ 退单线程。
  }
  final int? total =
      _contentRangeTotal(probe.header(HttpHeaders.contentRangeHeader)) ??
          asset.sizeBytes ??
          metadata?.sizeBytes;
  await probe.stream.drain<void>(); // 探针 body 丢弃；正式分段统一闭区间重取。
  // 验证器：优先探针返回的 ETag/Last-Modified，回退已有 metadata 的，让所有段 If-Range 一致。
  final String? validator = probe.header(HttpHeaders.etagHeader) ??
      probe.header(HttpHeaders.lastModifiedHeader) ??
      ifRange;

  final List<DownloadSegment> segments = planDownloadSegments(
    totalBytes: total,
    connectionCount: connectionCount,
    minSegmentBytes: minSegmentBytes,
  );
  if (total == null || segments.length <= 1) {
    return null; // 门控：未知大小 / 小文件 / 不值得切 → 退单线程。
  }

  // ---- 2. 写分段 metadata（保留校验所需的 size/etag/digest）----
  final _UpdateDownloadMetadata segMetadata = _UpdateDownloadMetadata(
    version: version,
    name: asset.name,
    url: asset.url,
    sizeBytes: asset.sizeBytes ?? total,
    etag: probe.header(HttpHeaders.etagHeader) ?? metadata?.etag,
    lastModified:
        probe.header(HttpHeaders.lastModifiedHeader) ?? metadata?.lastModified,
    sha256Digest: asset.sha256Digest,
  );

  // ---- 3. 并发下载各段 ----
  await _cleanupSegmentFiles(stagingPaths); // 清掉上一轮可能残留的分段文件。
  final String sourceHost = hostLabelForUpdateUrl(url);
  final Stopwatch stopwatch = Stopwatch()..start();
  var lastDiagnosticsMs = -_kDownloadDiagnosticsInterval.inMilliseconds;
  // 进度唯一真相源：每段当前已落盘字节数（per-segment）。进度 = 各段之和，
  // 不做「加 delta / 减 segWritten」的对称记账——重试删段时只把该段槽重置回真实
  // 落盘字节（0），从根上消除 TODO-596 的加减不对称（重复计 → >100%/135% + 闪烁）。
  // 单 isolate 顺序执行回调，写槽无需锁。
  final List<int> segmentBytes = List<int>.filled(segments.length, 0);
  var etagMismatch = false; // 任一段返回 200（If-Range 不匹配）→ 整体退化。
  var lastReported = 0.0; // 对外 onProgress 单调非减的水位线（消除回跳闪烁）。

  int receivedTotalBytes() =>
      segmentBytes.fold<int>(0, (int acc, int b) => acc + b);

  void reportProgress({bool force = false}) {
    final int receivedTotal = receivedTotalBytes();
    if (total > 0) {
      // 防御性 clamp(0,1) + 单调非减：即便上游记账异常也不会 >100% 或回跳。
      final double clamped = (receivedTotal / total).clamp(0.0, 1.0);
      if (clamped > lastReported) lastReported = clamped;
      onProgress?.call(lastReported);
    }
    final UpdateDownloadDiagnosticsCallback? callback = onDiagnostics;
    if (callback == null) return;
    final int elapsed = stopwatch.elapsedMilliseconds;
    if (!force &&
        elapsed - lastDiagnosticsMs <
            _kDownloadDiagnosticsInterval.inMilliseconds) {
      return;
    }
    lastDiagnosticsMs = elapsed;
    callback(
      UpdateDownloadDiagnostics(
        sourceUrl: url,
        sourceHost: sourceHost,
        receivedBytes: receivedTotal,
        totalBytes: total,
        bytesPerSecond: updateDownloadBytesPerSecond(
          startedBytes: 0,
          receivedBytes: receivedTotal,
          elapsed: stopwatch.elapsed,
        ),
        resumed: false,
        restartedFromZero: false,
      ),
    );
  }

  reportProgress(force: true);

  /// 下载单个分片到 `partFile.<index>`，有界重试。返回该段最终写入字节数；
  /// 抛 [_SegmentRangeUnsupported] 表示 If-Range 不匹配（200，需整体退化，不重试）。
  Future<int> downloadOneSegment(int index, DownloadSegment segment) async {
    final File segFile = _segmentPartFile(stagingPaths, index);
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < _kSegmentMaxAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: 200 * (1 << (attempt - 1))),
        );
      }
      // 分段级续传：该段已写 L 字节则从 start+L 续（沿用 If-Range 验证器）。
      var segWritten = 0;
      if (await segFile.exists()) {
        segWritten = await segFile.length();
        final int? segLen = segment.length;
        if (segLen != null && segWritten >= segLen) return segWritten; // 段满。
      }
      // 该段槽对齐到当前真实落盘字节（续传起点）；后续 onChunk 在此基础上累加。
      segmentBytes[index] = segWritten;
      final int reqStart = segment.start + segWritten;
      final Map<String, String> headers = <String, String>{
        HttpHeaders.rangeHeader:
            'bytes=$reqStart-${segment.end != null ? '${segment.end}' : ''}',
        if (validator != null && validator.isNotEmpty)
          HttpHeaders.ifRangeHeader: validator,
      };
      try {
        final int written = await _runSegmentRequest(
          openUrl: openUrl,
          uri: uri,
          headers: headers,
          segFile: segFile,
          appendOffset: segWritten,
          onChunk: (int delta) {
            segmentBytes[index] += delta;
            reportProgress();
          },
        ).timeout(_kPerAttemptTimeout);
        return written;
      } on _SegmentRangeUnsupported {
        rethrow; // 200/If-Range 不匹配：重试同后端无意义，交上层整体退化。
      } catch (e, stack) {
        lastError = e;
        lastStack = stack;
        // 删半截文件下次从头：段槽归零，反映该段真实落盘字节（重试不重复计）。
        segmentBytes[index] = 0;
        await _deleteFile(segFile);
      }
    }
    Error.throwWithStackTrace(
      lastError ?? Exception('segment $index failed'),
      lastStack ?? StackTrace.current,
    );
  }

  final List<Future<int>> futures = <Future<int>>[
    for (int i = 0; i < segments.length; i++)
      downloadOneSegment(i, segments[i]),
  ];
  try {
    await Future.wait(futures);
  } on _SegmentRangeUnsupported {
    etagMismatch = true;
  } catch (e, stack) {
    // 某段重试耗尽：整体退化单线程（清理分段，调用方重下）。
    ErrorLogService.instance.log('UpdateChecker.segmentFailed', e, stack);
    debugPrint('[Hibiki] segmented download failed, fall back single: $e');
    await _cleanupSegmentFiles(stagingPaths);
    return null;
  }
  if (etagMismatch) {
    // ETag 不一致（镜像共享 IP 轮换后端）→ 放弃分段，退单线程整体重下。
    debugPrint('[Hibiki] segment ETag/If-Range mismatch, fall back single');
    await _cleanupSegmentFiles(stagingPaths);
    return null;
  }

  // ---- 4. 按序 concat → 校验 → promote ----
  try {
    await _concatSegments(stagingPaths, segments.length);
  } catch (e, stack) {
    ErrorLogService.instance.log('UpdateChecker.concatSegments', e, stack);
    debugPrint('[Hibiki] concat segments failed, fall back single: $e');
    await _cleanupSegmentFiles(stagingPaths);
    await _deleteFile(stagingPaths.partFile);
    return null;
  }
  await _cleanupSegmentFiles(stagingPaths);

  final int actualSize = await stagingPaths.partFile.length();
  final _UpdateDownloadMetadata completeMetadata = segMetadata.copyWith(
    sizeBytes: segMetadata.sizeBytes ?? actualSize,
  );
  await completeMetadata.write(stagingPaths.metadataFile);
  if (!await _isValidCompleteDownload(
    stagingPaths.partFile,
    asset,
    completeMetadata,
  )) {
    await _deleteFile(stagingPaths.partFile);
    throw Exception('download integrity check failed: ${asset.name}');
  }

  final File promoted = await _promoteCompleteDownload(
    paths,
    stagingPaths,
    completeMetadata,
  );
  // 全段成功 + 校验 + promote 完成：各段槽对齐到末偏移使进度收尾到 1.0
  // （reportProgress 内 clamp+单调，水位线保持一致，不绕过防护层直接喂 1）。
  for (int i = 0; i < segments.length; i++) {
    final int? segLen = segments[i].length;
    if (segLen != null) segmentBytes[i] = segLen;
  }
  lastReported = 1.0;
  reportProgress(force: true);
  return promoted;
}

/// 内部哨兵异常：分片请求返回 200（服务器忽略 Range 或 If-Range 不匹配），需整体退化。
class _SegmentRangeUnsupported implements Exception {
  const _SegmentRangeUnsupported();
}

/// 发一次分片请求并把 body 流式追加写入 [segFile]（[appendOffset] > 0 时 append）。
/// 返回本次写入后该段总字节数。206 正常；200（含 If-Range 不匹配）抛
/// [_SegmentRangeUnsupported]；其它状态码抛 [HttpException]。
Future<int> _runSegmentRequest({
  required UpdateDownloadOpen openUrl,
  required Uri uri,
  required Map<String, String> headers,
  required File segFile,
  required int appendOffset,
  required void Function(int delta) onChunk,
}) async {
  final UpdateDownloadResponse response = await openUrl(uri, headers);
  if (response.statusCode == HttpStatus.ok) {
    await response.stream.drain<void>();
    throw const _SegmentRangeUnsupported();
  }
  if (response.statusCode != HttpStatus.partialContent) {
    await response.stream.drain<void>();
    throw HttpException(
        'segment request failed (${response.statusCode}): $uri');
  }
  final IOSink sink = segFile.openWrite(
    mode: appendOffset > 0 ? FileMode.append : FileMode.write,
  );
  var written = appendOffset;
  try {
    await for (final List<int> chunk in response.stream) {
      sink.add(chunk);
      written += chunk.length;
      onChunk(chunk.length);
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
  return written;
}

/// 按序把 `partFile.0..N-1` 流式 concat 进 [stagingPaths.partFile]（不整文件进内存）。
/// 缺段或某段空 → 抛异常，交调用方退化。
Future<void> _concatSegments(
  _UpdateDownloadStagingPaths stagingPaths,
  int segmentCount,
) async {
  await _deleteFile(stagingPaths.partFile);
  final IOSink sink = stagingPaths.partFile.openWrite(mode: FileMode.write);
  try {
    for (int i = 0; i < segmentCount; i++) {
      final File segFile = _segmentPartFile(stagingPaths, i);
      if (!await segFile.exists()) {
        throw FileSystemException('missing segment part', segFile.path);
      }
      await sink.addStream(segFile.openRead());
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
}

Future<UpdateDownloadResponse> _openHttpDownload(
  HttpClient client,
  Uri uri,
  Map<String, String> headers,
  String version,
) async {
  final HttpClientRequest request = await client.getUrl(uri);
  request.headers.set('User-Agent', 'Hibiki/$version');
  for (final MapEntry<String, String> entry in headers.entries) {
    request.headers.set(entry.key, entry.value);
  }
  final HttpClientResponse response = await request.close();
  final Map<String, String> responseHeaders = <String, String>{};
  response.headers.forEach((String name, List<String> values) {
    if (values.isNotEmpty) responseHeaders[name] = values.join(',');
  });
  return UpdateDownloadResponse(
    statusCode: response.statusCode,
    headers: responseHeaders,
    stream: response,
  );
}

Future<Directory> _updatesDirectoryForCurrentPlatform() async {
  if (Platform.isWindows) {
    final Directory base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}updates');
  }
  return getTemporaryDirectory();
}

Future<_UpdateDownloadStagingPaths> _resolveStagingPaths(
  UpdateDownloadPaths paths,
  UpdateAsset asset,
  String version,
) async {
  final _UpdateDownloadOwner? owner =
      await _UpdateDownloadOwner.read(paths.ownerFile);
  if (owner != null &&
      owner.matches(asset, version) &&
      _isStagingDirectoryUnderRoot(paths, owner.directoryPath)) {
    final _UpdateDownloadStagingPaths owned =
        _stagingPathsForDirectory(paths, Directory(owner.directoryPath));
    if (await owned.directory.exists()) return owned;
  }

  final _UpdateDownloadStagingPaths stagingPaths =
      await _createStagingPaths(paths);
  await _writeStagingOwnerBestEffort(
    paths,
    _UpdateDownloadOwner(
      version: version,
      name: asset.name,
      url: asset.url,
      directoryPath: stagingPaths.directory.path,
    ),
  );
  return stagingPaths;
}

Future<void> _writeStagingOwnerBestEffort(
  UpdateDownloadPaths paths,
  _UpdateDownloadOwner owner,
) async {
  try {
    await owner.write(paths.ownerFile);
  } catch (e, stack) {
    ErrorLogService.instance.log('UpdateChecker.writeDownloadOwner', e, stack);
    debugPrint('[Hibiki] write update download owner failed: $e');
  }
}

Future<_UpdateDownloadStagingPaths> _createStagingPaths(
  UpdateDownloadPaths paths,
) async {
  final int counter = _downloadStagingCounter++;
  final String id = '${DateTime.now().microsecondsSinceEpoch}-$pid-$counter';
  final Directory directory = Directory(
    '${paths.stagingRoot.path}${Platform.pathSeparator}$id',
  );
  await directory.create(recursive: true);
  return _stagingPathsForDirectory(paths, directory);
}

_UpdateDownloadStagingPaths _stagingPathsForDirectory(
  UpdateDownloadPaths paths,
  Directory directory,
) {
  final String name = _leafName(paths.file.path);
  return _UpdateDownloadStagingPaths(
    directory: directory,
    file: File('${directory.path}${Platform.pathSeparator}$name'),
    partFile: File('${directory.path}${Platform.pathSeparator}$name.part'),
    metadataFile:
        File('${directory.path}${Platform.pathSeparator}$name.meta.json'),
  );
}

bool _isStagingDirectoryUnderRoot(
  UpdateDownloadPaths paths,
  String directoryPath,
) {
  final String root = paths.stagingRoot.absolute.path;
  final String directory = Directory(directoryPath).absolute.path;
  final String normalizedRoot = Platform.isWindows ? root.toLowerCase() : root;
  final String normalizedDirectory =
      Platform.isWindows ? directory.toLowerCase() : directory;
  return normalizedDirectory == normalizedRoot ||
      normalizedDirectory.startsWith(
        '$normalizedRoot${Platform.pathSeparator}',
      );
}

Future<void> _seedStagingFromLegacyPart(
  UpdateDownloadPaths paths,
  _UpdateDownloadStagingPaths stagingPaths,
  UpdateAsset asset,
  String version,
  _UpdateDownloadMetadata metadata,
) async {
  if (!metadata.matches(asset, version)) return;
  try {
    if (!await paths.partFile.exists()) return;
    final int length = await paths.partFile.length();
    if (length <= 0) return;
    final int? expectedSize = asset.sizeBytes ?? metadata.sizeBytes;
    if (expectedSize != null && length >= expectedSize) {
      if (!await _isValidCompleteDownload(paths.partFile, asset, metadata)) {
        return;
      }
    }
    await stagingPaths.directory.create(recursive: true);
    await paths.partFile.copy(stagingPaths.partFile.path);
    await metadata.write(stagingPaths.metadataFile);
  } catch (e, stack) {
    ErrorLogService.instance
        .log('UpdateChecker.seedLegacyDownloadPart', e, stack);
    debugPrint('[Hibiki] seed legacy update part failed: $e');
  }
}

Future<File?> _promotePartIfComplete(
  UpdateDownloadPaths paths,
  _UpdateDownloadStagingPaths stagingPaths,
  UpdateAsset asset,
  String version,
  _UpdateDownloadMetadata? metadata,
) async {
  if (metadata == null || !metadata.matches(asset, version)) return null;
  if (!await _isValidCompleteDownload(
    stagingPaths.partFile,
    asset,
    metadata,
  )) {
    return null;
  }
  return _promoteCompleteDownload(paths, stagingPaths, metadata);
}

Future<int> _resumeOffsetForPart(
  File partFile,
  UpdateAsset asset,
  String version,
  _UpdateDownloadMetadata? metadata,
) async {
  if (metadata == null || !metadata.matches(asset, version)) {
    await _deleteFile(partFile);
    return 0;
  }
  if (!await partFile.exists()) return 0;
  final int length = await partFile.length();
  if (length <= 0) return 0;
  final int? expectedSize = asset.sizeBytes ?? metadata.sizeBytes;
  if (expectedSize != null && length >= expectedSize) {
    await _deleteFile(partFile);
    return 0;
  }
  return length;
}

Future<File> _promoteCompleteDownload(
  UpdateDownloadPaths paths,
  _UpdateDownloadStagingPaths stagingPaths,
  _UpdateDownloadMetadata metadata,
) async {
  await stagingPaths.file.parent.create(recursive: true);
  if (await stagingPaths.file.exists()) {
    await _deleteFile(stagingPaths.file);
  }
  final File completed =
      await stagingPaths.partFile.rename(stagingPaths.file.path);

  await paths.file.parent.create(recursive: true);
  try {
    if (await paths.file.exists()) {
      await paths.file.delete();
    }
    final File promoted = await completed.rename(paths.file.path);
    await metadata.write(paths.metadataFile);
    await _deleteFile(paths.partFile);
    await _deleteFile(paths.ownerFile);
    await _deleteFile(stagingPaths.metadataFile);
    await _deleteDirectory(stagingPaths.directory);
    return promoted;
  } catch (e, stack) {
    ErrorLogService.instance.log('UpdateChecker.promoteDownload', e, stack);
    debugPrint('[Hibiki] promote update download failed: $e');
    await metadata.write(stagingPaths.metadataFile);
    await _deleteFile(paths.partFile);
    await _deleteFile(paths.ownerFile);
    return completed;
  }
}

Future<bool> _isReusableCompleteDownload(
  File file,
  UpdateAsset asset,
  String version,
  _UpdateDownloadMetadata? metadata,
) async {
  if (metadata != null && !metadata.matches(asset, version)) return false;
  if (metadata == null && asset.sha256Digest == null) return false;
  return _isValidCompleteDownload(file, asset, metadata);
}

Future<bool> _isValidCompleteDownload(
  File file,
  UpdateAsset asset,
  _UpdateDownloadMetadata? metadata,
) async {
  if (!await file.exists()) return false;
  final int length = await file.length();
  if (length <= 0) return false;
  final int? expectedSize = asset.sizeBytes ?? metadata?.sizeBytes;
  if (expectedSize != null && length != expectedSize) return false;
  final String? expectedDigest = asset.sha256Digest ?? metadata?.sha256Digest;
  if (expectedDigest != null) {
    final String digest = await _sha256OfFile(file);
    if (digest != expectedDigest) return false;
  }
  return true;
}

Future<String> _sha256OfFile(File file) async {
  final Digest digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

int? _responseTotalSize(UpdateDownloadResponse response, int writeOffset) {
  final int? contentRangeTotal =
      _contentRangeTotal(response.header(HttpHeaders.contentRangeHeader));
  if (contentRangeTotal != null) return contentRangeTotal;
  final int? contentLength =
      _parsePositiveInt(response.header(HttpHeaders.contentLengthHeader));
  if (contentLength == null) return null;
  return response.statusCode == HttpStatus.partialContent
      ? writeOffset + contentLength
      : contentLength;
}

int? _contentRangeStart(String? value) {
  final RegExpMatch? match = _contentRangeMatch(value);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

int? _contentRangeTotal(String? value) {
  final RegExpMatch? match = _contentRangeMatch(value);
  if (match == null) return null;
  final String total = match.group(3)!;
  return total == '*' ? null : int.tryParse(total);
}

RegExpMatch? _contentRangeMatch(String? value) {
  if (value == null) return null;
  return RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$').firstMatch(value.trim());
}

String? _headerValue(Map<String, String> headers, String name) {
  final String lowerName = name.toLowerCase();
  for (final MapEntry<String, String> entry in headers.entries) {
    if (entry.key.toLowerCase() == lowerName) return entry.value;
  }
  return null;
}

int? _parsePositiveInt(String? value) {
  if (value == null) return null;
  final int? parsed = int.tryParse(value.trim());
  return parsed != null && parsed >= 0 ? parsed : null;
}

String _fileNameFromUrl(String url) {
  try {
    final Uri uri = Uri.parse(url);
    if (uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
  } catch (_) {
    // Fall through to the generic fallback.
  }
  return 'hibiki-update.bin';
}

String _leafName(String path) => path.replaceAll(r'\', '/').split('/').last;

Future<void> _deleteFile(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best-effort cleanup only.
  }
}

Future<void> _deleteDirectory(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } catch (_) {
    // Best-effort cleanup only.
  }
}

class _UpdateDownloadOwner {
  const _UpdateDownloadOwner({
    required this.version,
    required this.name,
    required this.url,
    required this.directoryPath,
  });

  final String version;
  final String name;
  final String url;
  final String directoryPath;

  bool matches(UpdateAsset asset, String version) {
    return this.version == version && name == asset.name && url == asset.url;
  }

  static Future<_UpdateDownloadOwner?> read(File file) async {
    try {
      if (!await file.exists()) return null;
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final Object? version = decoded['version'];
      final Object? name = decoded['name'];
      final Object? url = decoded['url'];
      final Object? directoryPath = decoded['directoryPath'];
      if (version is! String ||
          name is! String ||
          url is! String ||
          directoryPath is! String ||
          directoryPath.isEmpty) {
        return null;
      }
      return _UpdateDownloadOwner(
        version: version,
        name: name,
        url: url,
        directoryPath: directoryPath,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(File file) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, Object?>{
        'version': version,
        'name': name,
        'url': url,
        'directoryPath': directoryPath,
      }),
      flush: true,
    );
  }
}

class _UpdateDownloadMetadata {
  const _UpdateDownloadMetadata({
    required this.version,
    required this.name,
    required this.url,
    required this.sizeBytes,
    required this.etag,
    required this.lastModified,
    required this.sha256Digest,
  });

  factory _UpdateDownloadMetadata.fromJson(Map<String, dynamic> json) {
    return _UpdateDownloadMetadata(
      version: json['version'] as String? ?? '',
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      sizeBytes: _jsonInt(json['sizeBytes']),
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
      sha256Digest: _normalizeSha256(json['sha256Digest']),
    );
  }

  final String version;
  final String name;
  final String url;
  final int? sizeBytes;
  final String? etag;
  final String? lastModified;
  final String? sha256Digest;

  static Future<_UpdateDownloadMetadata?> read(File file) async {
    try {
      if (!await file.exists()) return null;
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return _UpdateDownloadMetadata.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  bool matches(UpdateAsset asset, String expectedVersion) {
    if (version != expectedVersion) return false;
    if (name != asset.name) return false;
    if (url != asset.url) return false;
    if (asset.sizeBytes != null && sizeBytes != asset.sizeBytes) return false;
    if (asset.sha256Digest != null && sha256Digest != asset.sha256Digest) {
      return false;
    }
    return true;
  }

  _UpdateDownloadMetadata copyWith({
    int? sizeBytes,
    String? etag,
    String? lastModified,
    String? sha256Digest,
  }) {
    return _UpdateDownloadMetadata(
      version: version,
      name: name,
      url: url,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      etag: etag ?? this.etag,
      lastModified: lastModified ?? this.lastModified,
      sha256Digest: sha256Digest ?? this.sha256Digest,
    );
  }

  Future<void> write(File file) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, Object?>{
        'version': version,
        'name': name,
        'url': url,
        'sizeBytes': sizeBytes,
        'etag': etag,
        'lastModified': lastModified,
        'sha256Digest': sha256Digest,
      }),
      flush: true,
    );
  }
}

int? _jsonInt(Object? value) {
  if (value is int && value >= 0) return value;
  if (value is num && value >= 0) return value.toInt();
  if (value is String) return _parsePositiveInt(value);
  return null;
}

String? _normalizeSha256(Object? value) {
  if (value is! String) return null;
  final String normalized = value.trim().toLowerCase();
  final String digest = normalized.startsWith('sha256:')
      ? normalized.substring('sha256:'.length)
      : normalized;
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ? digest : null;
}
