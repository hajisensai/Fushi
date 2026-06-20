import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

void main() {
  group('planDownloadSegments (纯函数：分段策略 + 门控)', () {
    test('null totalBytes → 退化单段（无 Content-Length 不能切）', () {
      final List<DownloadSegment> segments = planDownloadSegments(
        totalBytes: null,
        connectionCount: 4,
      );
      expect(segments, hasLength(1));
      expect(segments.single.start, 0);
      expect(segments.single.end, isNull, reason: '未知总大小时末段开放区间，等价单线程整体下载');
    });

    test('小文件（< 2*minSegmentBytes）→ 退化单段（多线程无收益）', () {
      final List<DownloadSegment> segments = planDownloadSegments(
        totalBytes: 3 * 1024 * 1024, // 3 MiB < 2*4MiB
        connectionCount: 4,
        minSegmentBytes: 4 * 1024 * 1024,
      );
      expect(segments, hasLength(1));
      expect(segments.single.start, 0);
      expect(segments.single.end, 3 * 1024 * 1024 - 1);
    });

    test('connectionCount 被 clamp 到 1..8', () {
      // 0 → 1（单段）
      expect(
        planDownloadSegments(totalBytes: 100 * 1024 * 1024, connectionCount: 0),
        hasLength(1),
      );
      // 大于 8 → 8 段（足够大文件）
      final List<DownloadSegment> many = planDownloadSegments(
        totalBytes: 800 * 1024 * 1024,
        connectionCount: 99,
        minSegmentBytes: 4 * 1024 * 1024,
      );
      expect(many, hasLength(8));
    });

    test('正常切分：闭区间、首尾相接、末段含余数、覆盖整文件', () {
      const int total = 100; // 故意用小 min 让它真切
      final List<DownloadSegment> segments = planDownloadSegments(
        totalBytes: total,
        connectionCount: 4,
        minSegmentBytes: 10,
      );
      expect(segments, hasLength(4));
      // 首段从 0 起，末段到 total-1 止
      expect(segments.first.start, 0);
      expect(segments.last.end, total - 1);
      // 段间无缝、无重叠
      for (int i = 1; i < segments.length; i++) {
        expect(segments[i].start, segments[i - 1].end! + 1);
      }
      // 总字节数 = total
      final int covered = segments.fold<int>(
        0,
        (int acc, DownloadSegment s) => acc + (s.end! - s.start + 1),
      );
      expect(covered, total);
    });

    test('段数受 minSegmentBytes 约束：不会切出比 minSegment 还小的段', () {
      // 10 MiB，min 4 MiB，请求 4 段 → 实际只能切 2 段（10/4=2）
      final List<DownloadSegment> segments = planDownloadSegments(
        totalBytes: 10 * 1024 * 1024,
        connectionCount: 4,
        minSegmentBytes: 4 * 1024 * 1024,
      );
      expect(segments.length, lessThanOrEqualTo(2));
      expect(segments.first.start, 0);
      expect(segments.last.end, 10 * 1024 * 1024 - 1);
    });
  });

  group('downloadUpdateAsset 多线程分片', () {
    late Directory updatesDir;

    setUp(() async {
      updatesDir = await Directory.systemTemp.createTemp('hibiki-update-seg');
    });

    tearDown(() async {
      if (updatesDir.existsSync()) {
        await _deleteDirectoryWithRetry(updatesDir);
      }
    });

    test('总大小足够时并发多段 206 → 正确 Range 头 + concat 正确 + promote', () async {
      final List<int> payload = _largePayload();
      final UpdateAsset asset = _asset(payload);

      final List<String> rangeHeaders = <String>[];
      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        connectionCount: 4,
        minSegmentBytes: _minSeg,
        openUrl: (Uri _, Map<String, String> headers) async {
          final String? range = headers[HttpHeaders.rangeHeader];
          rangeHeaders.add(range ?? '<none>');
          return _rangeResponse(payload, range);
        },
      );

      // 4 段 → 4 个 Range 请求（外加探针复用首段，不额外请求）
      expect(rangeHeaders.length, greaterThanOrEqualTo(4));
      // 每个请求都带 Range 头（分段必须显式 Range）
      expect(
        rangeHeaders.where((String r) => r.startsWith('bytes=')).length,
        greaterThanOrEqualTo(4),
      );
      // concat 正确 = 整文件按字节序还原
      expect(await file.readAsBytes(), payload);
      expect(
          file.path, UpdateDownloadPaths.forAsset(updatesDir, asset).file.path);
    });

    test('并发各段写独立 partFile.<i>，全成后 concat，临时分段文件清理', () async {
      final List<int> payload = _largePayload();
      final UpdateAsset asset = _asset(payload);
      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        connectionCount: 4,
        minSegmentBytes: _minSeg,
        openUrl: (Uri _, Map<String, String> headers) async =>
            _rangeResponse(payload, headers[HttpHeaders.rangeHeader]),
      );
      expect(await file.readAsBytes(), payload);
      // staging 根下不应残留 .part.<i> 分段文件
      final UpdateDownloadPaths paths =
          UpdateDownloadPaths.forAsset(updatesDir, asset);
      if (paths.stagingRoot.existsSync()) {
        final List<String> leftover = paths.stagingRoot
            .listSync(recursive: true)
            .whereType<File>()
            .map((File f) => f.path)
            .where((String p) => RegExp(r'\.part\.\d+$').hasMatch(p))
            .toList();
        expect(leftover, isEmpty, reason: '分段临时文件必须在 concat 后清理');
      }
    });

    test('progress 单调升至 1.0，diagnostics.receivedBytes 汇总各段', () async {
      final List<int> payload = _largePayload();
      final UpdateAsset asset = _asset(payload);
      final List<double> progressValues = <double>[];
      final List<UpdateDownloadDiagnostics> diagnostics =
          <UpdateDownloadDiagnostics>[];

      await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        connectionCount: 4,
        minSegmentBytes: _minSeg,
        openUrl: (Uri _, Map<String, String> headers) async =>
            _rangeResponse(payload, headers[HttpHeaders.rangeHeader]),
        onProgress: progressValues.add,
        onDiagnostics: diagnostics.add,
      );

      expect(progressValues, isNotEmpty);
      expect(progressValues.last, closeTo(1.0, 1e-9));
      // 单调不减
      for (int i = 1; i < progressValues.length; i++) {
        expect(progressValues[i], greaterThanOrEqualTo(progressValues[i - 1]),
            reason: '进度不应回退');
      }
      // 最终 diagnostics 的 receivedBytes 应等于整文件大小（Σ各段）
      expect(diagnostics.last.receivedBytes, payload.length);
      expect(diagnostics.last.totalBytes, payload.length);
    });

    test('首段探针返 200（源不支持 Range）→ 退化单线程，仍下完整文件', () async {
      final List<int> payload = _largePayload();
      final UpdateAsset asset = _asset(payload);
      var requestCount = 0;

      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        connectionCount: 4,
        minSegmentBytes: _minSeg,
        openUrl: (Uri _, Map<String, String> headers) async {
          requestCount += 1;
          // 服务器忽略 Range，始终返回 200 整文件
          return UpdateDownloadResponse(
            statusCode: HttpStatus.ok,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${payload.length}',
            },
            stream: Stream<List<int>>.value(payload),
          );
        },
      );

      expect(await file.readAsBytes(), payload);
      // 退化单线程不应发起 4 段并发；最多 探针(1) + 单线程(1) = 2 次
      expect(requestCount, lessThanOrEqualTo(2));
    });

    test('某段持续失败（有界重试耗尽）→ 整体退化单线程 → 仍成功无半成品', () async {
      final List<int> payload = _largePayload();
      final UpdateAsset asset = _asset(payload);
      var segmentedMode = true;

      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        connectionCount: 4,
        minSegmentBytes: _minSeg,
        openUrl: (Uri _, Map<String, String> headers) async {
          final String? range = headers[HttpHeaders.rangeHeader];
          // 分段阶段：探针成功（让它判定可分段），但某个非首段一律抛错。
          if (segmentedMode && range != null && range.startsWith('bytes=')) {
            final int start =
                int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
            if (start > 0) {
              throw const SocketException('segment connection reset');
            }
            return _rangeResponse(payload, range);
          }
          // 退化后单线程从零整文件
          segmentedMode = false;
          return UpdateDownloadResponse(
            statusCode: HttpStatus.ok,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${payload.length}',
            },
            stream: Stream<List<int>>.value(payload),
          );
        },
      );

      // 整体退化单线程后仍拿到完整正确文件（无半成品 promote）
      expect(await file.readAsBytes(), payload);
    });

    test('分段间 ETag 不一致（镜像共享 IP 轮换后端）→ 整体放弃分段回退单线程', () async {
      final List<int> payload = _largePayload();
      final UpdateAsset asset = _asset(payload);
      var probeServed = false;
      var fellBackToSingle = false;

      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        connectionCount: 4,
        minSegmentBytes: _minSeg,
        openUrl: (Uri _, Map<String, String> headers) async {
          final String? range = headers[HttpHeaders.rangeHeader];
          if (range != null && range.startsWith('bytes=')) {
            final int start =
                int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
            if (start == 0 && !probeServed) {
              probeServed = true;
              // 探针段返回 etag "v1"
              return _rangeResponse(payload, range, etag: '"server-v1"');
            }
            // 后续段：If-Range 不再匹配（后端换了），服务器返回 200 整文件
            // = If-Range 语义下 ETag 变更的表现，必须触发整体作废重切/退单线程。
            return UpdateDownloadResponse(
              statusCode: HttpStatus.ok,
              headers: <String, String>{
                HttpHeaders.contentLengthHeader: '${payload.length}',
                HttpHeaders.etagHeader: '"server-v2"',
              },
              stream: Stream<List<int>>.value(payload),
            );
          }
          // 退化单线程整文件
          fellBackToSingle = true;
          return UpdateDownloadResponse(
            statusCode: HttpStatus.ok,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${payload.length}',
              HttpHeaders.etagHeader: '"server-v2"',
            },
            stream: Stream<List<int>>.value(payload),
          );
        },
      );

      // concat 后 sha256 一致（因为退单线程重下整文件），最终文件正确
      expect(await file.readAsBytes(), payload);
      expect(fellBackToSingle, isTrue, reason: 'ETag 不一致必须放弃并发分段、退回单线程整体重下');
    });

    test('size 不符 → 抛 integrity 错并删脏文件（不 promote 半成品）', () async {
      final List<int> payload = _largePayload();
      final UpdateAsset asset = _asset(payload);

      await expectLater(
        downloadUpdateAsset(
          asset: asset,
          version: '1.2.0',
          updatesDir: updatesDir,
          candidateUrls: <String>[asset.url],
          connectionCount: 4,
          minSegmentBytes: _minSeg,
          openUrl: (Uri _, Map<String, String> headers) async {
            final String? range = headers[HttpHeaders.rangeHeader];
            // 每段都少返 1 字节 → concat 后总长 < 期望 size
            if (range != null && range.startsWith('bytes=')) {
              final UpdateDownloadResponse full =
                  _rangeResponse(payload, range);
              return UpdateDownloadResponse(
                statusCode: full.statusCode,
                headers: full.headers,
                stream: full.stream.map((List<int> b) =>
                    b.isEmpty ? b : b.sublist(0, b.length - 1)),
              );
            }
            return _rangeResponse(payload, range);
          },
        ),
        throwsA(isA<Exception>()),
      );

      // 最终包不应存在（半成品绝不 promote）
      final UpdateDownloadPaths paths =
          UpdateDownloadPaths.forAsset(updatesDir, asset);
      expect(paths.file.existsSync(), isFalse);
    });

    test('单线程默认路径不受影响：未传 connectionCount 时小文件走老逻辑', () async {
      // 小 payload（< 2*minSeg 默认值），即使隐式开多线程也门控退化单线程。
      final List<int> payload = <int>[0x4D, 0x5A, 1, 2, 3, 4, 5, 6, 7, 8];
      final UpdateAsset asset = _asset(payload);
      final List<Map<String, String>> requests = <Map<String, String>>[];
      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        openUrl: (Uri _, Map<String, String> headers) async {
          requests.add(headers);
          return UpdateDownloadResponse.bytes(
            statusCode: HttpStatus.ok,
            body: payload,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${payload.length}',
            },
          );
        },
      );
      expect(await file.readAsBytes(), payload);
      // 小文件单连接：恰好 1 次请求，无 Range（与原单线程行为一致）
      expect(requests, hasLength(1));
      expect(requests.single, isNot(contains(HttpHeaders.rangeHeader)));
    });
  });

  group('分片下载进度记账（TODO-628/650：重试不超 100%、不回跳）', () {
    late Directory updatesDir;

    setUp(() async {
      updatesDir = await Directory.systemTemp.createTemp('hibiki-update-prog');
    });

    tearDown(() async {
      if (updatesDir.existsSync()) {
        await _deleteDirectoryWithRetry(updatesDir);
      }
    });

    test('某段先吐部分字节再抛 SocketException 重试成功：onProgress 全程 ≤1.0 单调非减、末值==1.0',
        () async {
      // 直击 TODO-596 加减不对称：首次 attempt 已加 delta，回退却减 segWritten(=0)，
      // 删段后重下整段又加一遍 → 重复计 → receivedTotal/total >1.0(135%) + 回跳闪烁。
      final List<int> payload = _largePayload();
      final UpdateAsset asset = _asset(payload);
      final List<double> progressValues = <double>[];
      // 每个非探针请求按 (起点) 计数，让「第二段第一次」中途抛错、第二次成功。
      final Map<int, int> attemptByStart = <int, int>{};
      var probeServed = false;

      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        connectionCount: 4,
        minSegmentBytes: _minSeg,
        onProgress: progressValues.add,
        openUrl: (Uri _, Map<String, String> headers) async {
          final String? range = headers[HttpHeaders.rangeHeader];
          if (range == null || !range.startsWith('bytes=')) {
            return _rangeResponse(payload, range);
          }
          final RegExpMatch m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
          final int start = int.parse(m.group(1)!);
          // 第一个 bytes=0- 是探针（drain 丢弃），放行真实 206。
          if (start == 0 && !probeServed) {
            probeServed = true;
            return _rangeResponse(payload, range);
          }
          final int attempt = (attemptByStart[start] ?? 0) + 1;
          attemptByStart[start] = attempt;
          // 选一个非首段：首次 attempt 先吐若干字节，再抛 SocketException。
          if (start > 0 && attempt == 1) {
            return _failMidStreamResponse(payload, start, m.group(2)!);
          }
          // 其它（含重试的第二次）正常完整返回该段。
          return _rangeResponse(payload, range);
        },
      );

      expect(await file.readAsBytes(), payload, reason: '重试后仍还原整文件');
      expect(progressValues, isNotEmpty);
      // 核心断言 1：全程绝不 >1.0（直击 135% 溢出）。
      for (final double p in progressValues) {
        expect(p, lessThanOrEqualTo(1.0 + 1e-9),
            reason: '进度永不超过 100%（TODO-628 溢出 135%）');
        expect(p, greaterThanOrEqualTo(0.0));
      }
      // 核心断言 2：单调非减（直击重试回退导致的向下跳变闪烁）。
      for (int i = 1; i < progressValues.length; i++) {
        expect(progressValues[i], greaterThanOrEqualTo(progressValues[i - 1]),
            reason: 'TODO-650：进度不应回跳（闪烁）');
      }
      // 核心断言 3：末值收尾到 1.0。
      expect(progressValues.last, closeTo(1.0, 1e-9));
    });

    test('多段各重试一次：receivedTotal/total 永不 >1.0（直击 135%）', () async {
      final List<int> payload = _largePayload();
      final UpdateAsset asset = _asset(payload);
      final List<double> progressValues = <double>[];
      final Map<int, int> attemptByStart = <int, int>{};
      var probeServed = false;

      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        connectionCount: 4,
        minSegmentBytes: _minSeg,
        onProgress: progressValues.add,
        openUrl: (Uri _, Map<String, String> headers) async {
          final String? range = headers[HttpHeaders.rangeHeader];
          if (range == null || !range.startsWith('bytes=')) {
            return _rangeResponse(payload, range);
          }
          final RegExpMatch m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
          final int start = int.parse(m.group(1)!);
          if (start == 0 && !probeServed) {
            probeServed = true;
            return _rangeResponse(payload, range);
          }
          final int attempt = (attemptByStart[start] ?? 0) + 1;
          attemptByStart[start] = attempt;
          // 每一段（含首段正式下载）第一次都中途失败一次，第二次成功。
          if (attempt == 1) {
            return _failMidStreamResponse(payload, start, m.group(2)!);
          }
          return _rangeResponse(payload, range);
        },
      );

      expect(await file.readAsBytes(), payload);
      expect(progressValues, isNotEmpty);
      for (final double p in progressValues) {
        expect(p, lessThanOrEqualTo(1.0 + 1e-9), reason: '多段各重试一次仍不溢出 100%');
      }
      for (int i = 1; i < progressValues.length; i++) {
        expect(progressValues[i], greaterThanOrEqualTo(progressValues[i - 1]));
      }
      expect(progressValues.last, closeTo(1.0, 1e-9));
    });
  });
}

// minSegment 用很小的值，让小 payload 也能真正切成多段做测试。
const int _minSeg = 2;

UpdateAsset _asset(List<int> payload) => UpdateAsset(
      name: 'hibiki-1.2.0-windows-setup.exe',
      url:
          'https://github.com/hdjsadgfwtg/hibiki/releases/download/v1.2.0/hibiki-1.2.0-windows-setup.exe',
      sizeBytes: payload.length,
      sha256Digest: _sha256Hex(payload),
    );

// 32 字节 payload，配合 _minSeg=2 可切成 4+ 段。
List<int> _largePayload() =>
    List<int>.generate(32, (int i) => (i * 7 + 0x4D) & 0xFF, growable: false);

/// 模拟 S3 风格 Range 服务器：解析 `bytes=start-` 或 `bytes=start-end`，返回 206 +
/// Content-Range + 对应字节片段。无 Range → 200 整文件。
UpdateDownloadResponse _rangeResponse(
  List<int> payload,
  String? range, {
  String etag = '"payload-v1"',
}) {
  if (range == null || !range.startsWith('bytes=')) {
    return UpdateDownloadResponse(
      statusCode: HttpStatus.ok,
      headers: <String, String>{
        HttpHeaders.contentLengthHeader: '${payload.length}',
        HttpHeaders.etagHeader: etag,
      },
      stream: Stream<List<int>>.value(payload),
    );
  }
  final RegExpMatch m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
  final int start = int.parse(m.group(1)!);
  final int end =
      m.group(2)!.isEmpty ? payload.length - 1 : int.parse(m.group(2)!);
  final List<int> slice = payload.sublist(start, end + 1);
  return UpdateDownloadResponse(
    statusCode: HttpStatus.partialContent,
    headers: <String, String>{
      HttpHeaders.contentRangeHeader: 'bytes $start-$end/${payload.length}',
      HttpHeaders.contentLengthHeader: '${slice.length}',
      HttpHeaders.etagHeader: etag,
    },
    stream: Stream<List<int>>.value(slice),
  );
}

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

Future<void> _deleteDirectoryWithRetry(Directory directory) async {
  for (var attempt = 0; attempt < 5; attempt += 1) {
    try {
      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
      return;
    } on FileSystemException {
      if (attempt == 4) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

/// 模拟「某段先吐若干字节再断流」的 206 响应：取该段一半字节后 addError，
/// 触发 [_runSegmentRequest] 流抛错 → downloadOneSegment 重试。
UpdateDownloadResponse _failMidStreamResponse(
  List<int> payload,
  int start,
  String endGroup,
) {
  final int end = endGroup.isEmpty ? payload.length - 1 : int.parse(endGroup);
  final List<int> slice = payload.sublist(start, end + 1);
  final int half = slice.length > 1 ? slice.length ~/ 2 : 0;
  final StreamController<List<int>> controller = StreamController<List<int>>();
  // 先吐前半段（让 onChunk 累加进度），再断流抛错（让重试回退路径生效）。
  scheduleMicrotask(() {
    if (half > 0) controller.add(slice.sublist(0, half));
    controller.addError(const SocketException('mid-stream reset'));
    controller.close();
  });
  return UpdateDownloadResponse(
    statusCode: HttpStatus.partialContent,
    headers: <String, String>{
      HttpHeaders.contentRangeHeader: 'bytes $start-$end/${payload.length}',
      HttpHeaders.contentLengthHeader: '${slice.length}',
      HttpHeaders.etagHeader: '"payload-v1"',
    },
    stream: controller.stream,
  );
}
