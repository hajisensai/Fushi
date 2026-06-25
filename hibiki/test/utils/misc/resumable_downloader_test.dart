import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/resumable_downloader.dart';

void main() {
  group('ResumableDownloader', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('hibiki-resumable-dl');
    });

    tearDown(() async {
      if (dir.existsSync()) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    List<int> payload() => utf8.encode('hibiki-resumable-payload-0123456789');

    String sha(List<int> bytes) => sha256.convert(bytes).toString();

    File dest() => File('${dir.path}/out.bin');
    File part() => File('${dir.path}/out.bin.part');

    test('downloads a fresh file with no Range and validates size+sha',
        () async {
      final List<int> body = payload();
      final List<Map<String, String>> requests = <Map<String, String>>[];
      final File file = await ResumableDownloader(
        url: 'http://host/stream',
        destination: dest(),
        partFile: part(),
        expectedSize: body.length,
        expectedSha256: sha(body),
        open: (Uri uri, Map<String, String> headers) async {
          requests.add(headers);
          return ResumableDownloadResponse.bytes(
            statusCode: HttpStatus.ok,
            body: body,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${body.length}',
            },
          );
        },
      ).download();

      expect(requests, hasLength(1));
      expect(requests.single.containsKey(HttpHeaders.rangeHeader), isFalse);
      expect(await file.readAsBytes(), body);
      expect(part().existsSync(), isFalse);
    });

    test('reuses an existing .part with Range offset and concatenates',
        () async {
      final List<int> body = payload();
      await part().writeAsBytes(body.sublist(0, 10), flush: true);

      final List<Map<String, String>> requests = <Map<String, String>>[];
      final File file = await ResumableDownloader(
        url: 'http://host/stream',
        destination: dest(),
        partFile: part(),
        expectedSize: body.length,
        resumeState: const ResumableDownloadState(etag: '"v1"'),
        open: (Uri uri, Map<String, String> headers) async {
          requests.add(headers);
          return ResumableDownloadResponse.bytes(
            statusCode: HttpStatus.partialContent,
            body: body.sublist(10),
            headers: <String, String>{
              HttpHeaders.contentRangeHeader: 'bytes 10-${body.length - 1}/'
                  '${body.length}',
            },
          );
        },
      ).download();

      expect(requests, hasLength(1));
      expect(requests.single[HttpHeaders.rangeHeader], 'bytes=10-');
      expect(requests.single[HttpHeaders.ifRangeHeader], '"v1"');
      expect(await file.readAsBytes(), body);
      expect(part().existsSync(), isFalse);
    });

    test('416 on resume restarts from zero with a full GET', () async {
      final List<int> body = payload();
      await part().writeAsBytes(<int>[9, 9, 9, 9], flush: true);

      final List<int?> statuses = <int?>[];
      var call = 0;
      final File file = await ResumableDownloader(
        url: 'http://host/stream',
        destination: dest(),
        partFile: part(),
        expectedSize: body.length,
        resumeState: const ResumableDownloadState(etag: '"v2"'),
        open: (Uri uri, Map<String, String> headers) async {
          call += 1;
          if (call == 1) {
            statuses.add(HttpStatus.requestedRangeNotSatisfiable);
            return ResumableDownloadResponse.bytes(
              statusCode: HttpStatus.requestedRangeNotSatisfiable,
              body: const <int>[],
            );
          }
          expect(headers.containsKey(HttpHeaders.rangeHeader), isFalse);
          return ResumableDownloadResponse.bytes(
            statusCode: HttpStatus.ok,
            body: body,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${body.length}',
            },
          );
        },
      ).download();

      expect(call, 2);
      expect(await file.readAsBytes(), body);
    });

    test('200 on a Range request discards old part and writes full body',
        () async {
      final List<int> body = payload();
      await part().writeAsBytes(<int>[7, 7, 7], flush: true);

      final List<bool> restarted = <bool>[];
      final File file = await ResumableDownloader(
        url: 'http://host/stream',
        destination: dest(),
        partFile: part(),
        expectedSize: body.length,
        resumeState: const ResumableDownloadState(lastModified: 'yesterday'),
        onMeta: (ResumableDownloadMetaInfo info) =>
            restarted.add(info.restartedFromZero),
        open: (Uri uri, Map<String, String> headers) async {
          expect(headers[HttpHeaders.rangeHeader], 'bytes=3-');
          return ResumableDownloadResponse.bytes(
            statusCode: HttpStatus.ok,
            body: body,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${body.length}',
            },
          );
        },
      ).download();

      expect(restarted, <bool>[true]);
      expect(await file.readAsBytes(), body);
    });

    test('sha256 mismatch deletes part and throws integrity error', () async {
      final List<int> body = payload();
      File? thrownPartExists;
      await expectLater(
        ResumableDownloader(
          url: 'http://host/stream',
          destination: dest(),
          partFile: part(),
          expectedSize: body.length,
          expectedSha256: sha(<int>[1, 2, 3]), // wrong digest
          open: (Uri uri, Map<String, String> headers) async =>
              ResumableDownloadResponse.bytes(
            statusCode: HttpStatus.ok,
            body: body,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${body.length}',
            },
          ),
        ).download(),
        throwsA(isA<ResumableDownloadIntegrityException>()),
      );
      thrownPartExists = part();
      expect(thrownPartExists.existsSync(), isFalse);
      expect(dest().existsSync(), isFalse);
    });

    test('size mismatch deletes part and throws integrity error', () async {
      final List<int> body = payload();
      await expectLater(
        ResumableDownloader(
          url: 'http://host/stream',
          destination: dest(),
          partFile: part(),
          expectedSize: body.length + 5, // never satisfied
          open: (Uri uri, Map<String, String> headers) async =>
              ResumableDownloadResponse.bytes(
            statusCode: HttpStatus.ok,
            body: body,
            headers: <String, String>{
              HttpHeaders.contentLengthHeader: '${body.length}',
            },
          ),
        ).download(),
        throwsA(isA<ResumableDownloadIntegrityException>()),
      );
      expect(part().existsSync(), isFalse);
    });

    test('reports resumed=true on accepted 206 resume', () async {
      final List<int> body = payload();
      await part().writeAsBytes(body.sublist(0, 6), flush: true);
      final List<bool> resumedFlags = <bool>[];
      await ResumableDownloader(
        url: 'http://host/stream',
        destination: dest(),
        partFile: part(),
        expectedSize: body.length,
        onMeta: (ResumableDownloadMetaInfo info) =>
            resumedFlags.add(info.resumed),
        open: (Uri uri, Map<String, String> headers) async =>
            ResumableDownloadResponse.bytes(
          statusCode: HttpStatus.partialContent,
          body: body.sublist(6),
          headers: <String, String>{
            HttpHeaders.contentRangeHeader:
                'bytes 6-${body.length - 1}/${body.length}',
          },
        ),
      ).download();
      expect(resumedFlags, <bool>[true]);
    });
  });
}
