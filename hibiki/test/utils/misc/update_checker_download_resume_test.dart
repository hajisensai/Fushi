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
        await updatesDir.delete(recursive: true);
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
  });
}

UpdateAsset _asset(List<int> payload) => UpdateAsset(
      name: 'hibiki-1.2.0-windows-setup.exe',
      url:
          'https://github.com/hdjsadgfwtg/hibiki/releases/download/v1.2.0/hibiki-1.2.0-windows-setup.exe',
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
