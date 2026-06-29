import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

void main() {
  group('downloadUpdateAsset cache and resume', () {
    late Directory updatesDir;

    setUp(() async {
      updatesDir = await Directory.systemTemp.createTemp('hibiki-update-cache');
    });

    tearDown(() async {
      if (updatesDir.existsSync()) {
        await _deleteDirectoryWithRetry(updatesDir);
      }
    });

    test('reuses a complete package when metadata and digest match', () async {
      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final UpdateDownloadPaths paths =
          UpdateDownloadPaths.forAsset(updatesDir, asset);
      await paths.file.writeAsBytes(payload, flush: true);
      await _writeMetadata(paths.metadataFile, asset,
          sizeBytes: payload.length);

      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        openUrl: (_, __) async {
          fail('complete matching package should be reused without network');
        },
      );

      expect(file.path, paths.file.path);
      expect(await file.readAsBytes(), payload);
    });

    test('resumes an existing part file with Range and promotes atomically',
        () async {
      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final UpdateDownloadPaths paths =
          UpdateDownloadPaths.forAsset(updatesDir, asset);
      await paths.partFile.writeAsBytes(payload.sublist(0, 4), flush: true);
      await _writeMetadata(paths.metadataFile, asset,
          sizeBytes: payload.length);

      final List<Map<String, String>> requests = <Map<String, String>>[];
      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        openUrl: (_, Map<String, String> headers) async {
          requests.add(headers);
          return UpdateDownloadResponse.bytes(
            statusCode: HttpStatus.partialContent,
            body: payload.sublist(4),
            headers: <String, String>{
              HttpHeaders.contentRangeHeader: 'bytes 4-9/10',
              HttpHeaders.etagHeader: '"payload-v1"',
            },
          );
        },
      );

      expect(requests, hasLength(1));
      expect(requests.single[HttpHeaders.rangeHeader], 'bytes=4-');
      expect(await file.readAsBytes(), payload);
      expect(paths.partFile.existsSync(), isFalse);
      expect(paths.metadataFile.existsSync(), isTrue);
    });

    test('reports diagnostics for source switch and chunk progress', () async {
      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final String failedUrl =
          'https://bad.example/releases/download/v1.2.0/${asset.name}';
      final List<UpdateDownloadDiagnostics> diagnostics =
          <UpdateDownloadDiagnostics>[];
      final List<String> sourceFailures = <String>[];

      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[failedUrl, asset.url],
        openUrl: (Uri uri, Map<String, String> headers) async {
          if (uri.host == 'bad.example') {
            throw const SocketException('offline');
          }
          expect(headers, isNot(contains(HttpHeaders.rangeHeader)));
          return UpdateDownloadResponse(
            statusCode: HttpStatus.ok,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${payload.length}',
            },
            stream: Stream<List<int>>.fromIterable(<List<int>>[
              payload.sublist(0, 4),
              payload.sublist(4),
            ]),
          );
        },
        onDiagnostics: diagnostics.add,
        onSourceFailure: (String url, Object _, StackTrace __) {
          sourceFailures.add(url);
        },
      );

      expect(await file.readAsBytes(), payload);
      expect(sourceFailures, <String>[failedUrl]);
      expect(
        diagnostics.where((UpdateDownloadDiagnostics d) {
          return d.receivedBytes == 0;
        }).map((UpdateDownloadDiagnostics d) => d.sourceUrl),
        containsAllInOrder(<String>[failedUrl, asset.url]),
      );

      final UpdateDownloadDiagnostics last = diagnostics.last;
      expect(last.sourceUrl, asset.url);
      expect(last.sourceHost, hostLabelForUpdateUrl(asset.url));
      expect(last.receivedBytes, payload.length);
      expect(last.totalBytes, payload.length);
      expect(last.bytesPerSecond, isNotNull);
      expect(last.resumed, isFalse);
      expect(last.restartedFromZero, isFalse);
    });

    test('reports diagnostics for accepted resume and restart-from-zero',
        () async {
      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final UpdateDownloadPaths resumePaths =
          UpdateDownloadPaths.forAsset(updatesDir, asset);
      await resumePaths.partFile
          .writeAsBytes(payload.sublist(0, 4), flush: true);
      await _writeMetadata(resumePaths.metadataFile, asset,
          sizeBytes: payload.length);

      final List<UpdateDownloadDiagnostics> resumedDiagnostics =
          <UpdateDownloadDiagnostics>[];
      await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        openUrl: (_, Map<String, String> headers) async {
          expect(headers[HttpHeaders.rangeHeader], 'bytes=4-');
          return UpdateDownloadResponse.bytes(
            statusCode: HttpStatus.partialContent,
            body: payload.sublist(4),
            headers: <String, String>{
              HttpHeaders.contentRangeHeader: 'bytes 4-9/10',
              HttpHeaders.etagHeader: '"payload-v1"',
            },
          );
        },
        onDiagnostics: resumedDiagnostics.add,
      );

      expect(
        resumedDiagnostics
            .lastWhere(
              (UpdateDownloadDiagnostics d) =>
                  d.receivedBytes == payload.length,
            )
            .resumed,
        isTrue,
      );
      expect(resumedDiagnostics.last.restartedFromZero, isFalse);

      final Directory restartDir =
          await Directory.systemTemp.createTemp('hibiki-update-restart');
      addTearDown(() => _deleteDirectoryWithRetry(restartDir));
      final UpdateDownloadPaths restartPaths =
          UpdateDownloadPaths.forAsset(restartDir, asset);
      await restartPaths.partFile
          .writeAsBytes(<int>[99, 98, 97, 96], flush: true);
      await _writeMetadata(restartPaths.metadataFile, asset,
          sizeBytes: payload.length);

      final List<UpdateDownloadDiagnostics> restartDiagnostics =
          <UpdateDownloadDiagnostics>[];
      await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: restartDir,
        candidateUrls: <String>[asset.url],
        openUrl: (_, Map<String, String> headers) async {
          expect(headers[HttpHeaders.rangeHeader], 'bytes=4-');
          return UpdateDownloadResponse.bytes(
            statusCode: HttpStatus.ok,
            body: payload,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${payload.length}',
            },
          );
        },
        onDiagnostics: restartDiagnostics.add,
      );

      final UpdateDownloadDiagnostics restartLast = restartDiagnostics.last;
      expect(restartLast.receivedBytes, payload.length);
      expect(restartLast.totalBytes, payload.length);
      expect(restartLast.resumed, isFalse);
      expect(restartLast.restartedFromZero, isTrue);
    });

    test('formats diagnostic byte sizes, speeds, and speed samples', () {
      expect(formatUpdateDownloadByteCount(null), '—');
      expect(formatUpdateDownloadByteCount(0), '0 B');
      expect(formatUpdateDownloadByteCount(1536), '1.5 KB');
      expect(formatUpdateDownloadByteCount(5 * 1024 * 1024), '5.0 MB');
      expect(formatUpdateDownloadSpeed(null), '—');
      expect(formatUpdateDownloadSpeed(1536), '1.5 KB/s');
      expect(
        updateDownloadBytesPerSecond(
          startedBytes: 4,
          receivedBytes: 10,
          elapsed: const Duration(seconds: 3),
        ),
        2,
      );
    });

    test('restarts from zero when server ignores Range with HTTP 200',
        () async {
      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final UpdateDownloadPaths paths =
          UpdateDownloadPaths.forAsset(updatesDir, asset);
      await paths.partFile.writeAsBytes(<int>[99, 98, 97, 96], flush: true);
      await _writeMetadata(paths.metadataFile, asset,
          sizeBytes: payload.length);

      final List<Map<String, String>> requests = <Map<String, String>>[];
      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        openUrl: (_, Map<String, String> headers) async {
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

      expect(requests.single[HttpHeaders.rangeHeader], 'bytes=4-');
      expect(await file.readAsBytes(), payload);
      expect(paths.partFile.existsSync(), isFalse);
    });

    test('does not reuse a truncated final package even with an MZ header',
        () async {
      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final UpdateDownloadPaths paths =
          UpdateDownloadPaths.forAsset(updatesDir, asset);
      await paths.file.writeAsBytes(<int>[0x4D, 0x5A], flush: true);
      await _writeMetadata(paths.metadataFile, asset,
          sizeBytes: payload.length);

      var requestCount = 0;
      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        openUrl: (_, Map<String, String> headers) async {
          requestCount += 1;
          expect(headers, isNot(contains(HttpHeaders.rangeHeader)));
          return UpdateDownloadResponse.bytes(
            statusCode: HttpStatus.ok,
            body: payload,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${payload.length}',
            },
          );
        },
      );

      expect(requestCount, 1);
      expect(await file.readAsBytes(), payload);
    });

    test('uses unique staging when the previous final exe is locked', () async {
      if (!Platform.isWindows) return;

      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final UpdateDownloadPaths paths =
          UpdateDownloadPaths.forAsset(updatesDir, asset);
      await paths.file.writeAsBytes(<int>[0x4D, 0x5A, 99], flush: true);
      await _writeMetadata(paths.metadataFile, asset,
          sizeBytes: payload.length);
      final RandomAccessFile lockedFinal =
          await paths.file.open(mode: FileMode.read);
      addTearDown(lockedFinal.close);

      final List<Object> sourceFailures = <Object>[];
      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        openUrl: (_, Map<String, String> headers) async {
          expect(headers, isNot(contains(HttpHeaders.rangeHeader)));
          return UpdateDownloadResponse.bytes(
            statusCode: HttpStatus.ok,
            body: payload,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${payload.length}',
            },
          );
        },
        onSourceFailure: (_, Object error, __) {
          sourceFailures.add(error);
        },
      );

      expect(file.path, isNot(paths.file.path));
      expect(await file.readAsBytes(), payload);
      expect(await paths.file.readAsBytes(), <int>[0x4D, 0x5A, 99]);
      expect(sourceFailures, isEmpty);
    });

    test('ignores an unavailable legacy fixed part path and stages freshly',
        () async {
      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final UpdateDownloadPaths paths =
          UpdateDownloadPaths.forAsset(updatesDir, asset);
      await Directory(paths.partFile.path).create(recursive: true);
      await _writeMetadata(paths.metadataFile, asset,
          sizeBytes: payload.length);

      final List<Map<String, String>> requests = <Map<String, String>>[];
      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        openUrl: (_, Map<String, String> headers) async {
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

      expect(requests, hasLength(1));
      expect(requests.single, isNot(contains(HttpHeaders.rangeHeader)));
      expect(await file.readAsBytes(), payload);
      expect(Directory(paths.partFile.path).existsSync(), isTrue);
    });

    test('resumes the same unique staging owner after a failed download',
        () async {
      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final Object networkLoss = Exception('network lost');

      await expectLater(
        downloadUpdateAsset(
          asset: asset,
          version: '1.2.0',
          updatesDir: updatesDir,
          candidateUrls: <String>[asset.url],
          openUrl: (_, Map<String, String> headers) async {
            expect(headers, isNot(contains(HttpHeaders.rangeHeader)));
            return UpdateDownloadResponse(
              statusCode: HttpStatus.ok,
              headers: <String, String>{
                HttpHeaders.contentLengthHeader: '${payload.length}',
                HttpHeaders.etagHeader: '"payload-v1"',
              },
              stream: Stream<List<int>>.fromFutures(<Future<List<int>>>[
                Future<List<int>>.value(payload.sublist(0, 4)),
                Future<List<int>>.error(networkLoss),
              ]),
            );
          },
        ),
        throwsA(same(networkLoss)),
      );

      final List<Map<String, String>> requests = <Map<String, String>>[];
      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        openUrl: (_, Map<String, String> headers) async {
          requests.add(headers);
          return UpdateDownloadResponse.bytes(
            statusCode: HttpStatus.partialContent,
            body: payload.sublist(4),
            headers: <String, String>{
              HttpHeaders.contentRangeHeader: 'bytes 4-9/10',
              HttpHeaders.etagHeader: '"payload-v1"',
            },
          );
        },
      );

      expect(requests, hasLength(1));
      expect(requests.single[HttpHeaders.rangeHeader], 'bytes=4-');
      expect(await file.readAsBytes(), payload);
    });

    test('coalesces concurrent downloads for the same asset and version',
        () async {
      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final Completer<void> firstRequestStarted = Completer<void>();
      final Completer<void> secondRequestStarted = Completer<void>();
      final Completer<void> releaseResponse = Completer<void>();
      var requestCount = 0;

      Future<UpdateDownloadResponse> openUrl(
        Uri _,
        Map<String, String> __,
      ) async {
        requestCount += 1;
        if (!firstRequestStarted.isCompleted) {
          firstRequestStarted.complete();
        } else if (!secondRequestStarted.isCompleted) {
          secondRequestStarted.complete();
        }
        await releaseResponse.future;
        return UpdateDownloadResponse.bytes(
          statusCode: HttpStatus.ok,
          body: payload,
          headers: <String, String>{
            HttpHeaders.contentLengthHeader: '${payload.length}',
          },
        );
      }

      final Future<File> first = downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        openUrl: openUrl,
      );
      await firstRequestStarted.future;

      final Future<File> second = downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        openUrl: openUrl,
      );
      final bool secondRequestObserved = await Future.any(<Future<bool>>[
        secondRequestStarted.future.then((_) => true),
        Future<bool>.delayed(const Duration(milliseconds: 50), () => false),
      ]);

      expect(
        secondRequestObserved,
        isFalse,
        reason: 'same-version update triggers must share one active download',
      );
      expect(requestCount, 1);

      releaseResponse.complete();
      final List<File> files = await Future.wait(<Future<File>>[first, second]);
      expect(files[0].path, files[1].path);
      expect(await files[0].readAsBytes(), payload);
    });

    test('awaits IOSink.done so open/write/close errors stay catchable', () {
      // TODO-819：单连接续传写盘逻辑已下沉到通用 ResumableDownloader，IOSink 错误
      // 可捕获契约也随之搬到该引擎；守卫跟随真实代码位置。
      final String source = File(
        'lib/src/utils/misc/resumable_downloader.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('await sink.done'),
        reason:
            'openWrite and IOSink close failures must remain in the awaited '
            'download Future instead of escaping to UncaughtZone',
      );
    });

    test('downloadAndInstall active flow shares one in-flight operation',
        () async {
      final Completer<void> releaseFirstFlow = Completer<void>();
      var starts = 0;
      var activeNotices = 0;

      final Future<void> first = UpdateChecker.runExclusiveUpdateFlowForTest(
        'same-update',
        () async {
          starts += 1;
          await releaseFirstFlow.future;
        },
        onAlreadyActive: () {
          activeNotices += 1;
        },
      );
      await Future<void>.delayed(Duration.zero);

      final Future<void> second = UpdateChecker.runExclusiveUpdateFlowForTest(
        'same-update',
        () async {
          starts += 1;
        },
        onAlreadyActive: () {
          activeNotices += 1;
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(starts, 1);
      expect(activeNotices, 1);

      releaseFirstFlow.complete();
      await Future.wait(<Future<void>>[first, second]);

      await UpdateChecker.runExclusiveUpdateFlowForTest(
        'same-update',
        () async {
          starts += 1;
        },
      );
      expect(starts, 2);
    });
  });
}

UpdateAsset _asset(List<int> payload) => UpdateAsset(
      name: 'hibiki-1.2.0-windows-setup.exe',
      url:
          'https://github.com/hajisensai/hibiki/releases/download/v1.2.0/hibiki-1.2.0-windows-setup.exe',
      sizeBytes: payload.length,
      sha256Digest: _sha256Hex(payload),
    );

List<int> _payload() => <int>[0x4D, 0x5A, 1, 2, 3, 4, 5, 6, 7, 8];

Future<void> _writeMetadata(
  File file,
  UpdateAsset asset, {
  required int sizeBytes,
}) async {
  await file.writeAsString(
    jsonEncode(<String, Object?>{
      'version': '1.2.0',
      'name': asset.name,
      'url': asset.url,
      'sizeBytes': sizeBytes,
      'sha256Digest': asset.sha256Digest,
      'etag': '"payload-v1"',
      'lastModified': 'Tue, 16 Jun 2026 00:00:00 GMT',
    }),
    flush: true,
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
