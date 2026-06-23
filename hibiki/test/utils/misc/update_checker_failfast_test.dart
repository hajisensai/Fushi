import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

// TODO-738: fail-fast guards for the Windows auto-update connecting hang.
// Root cause A: race returns null (all dead) then serial fallback used 15s for
// the connect-to-first-response of every candidate => N candidates pile into
// minutes. Fix: serial fallback uses 5s first-byte timeout; body streaming after
// the first byte still gets 15s/segment so a slow-but-alive source is not killed.
// Direction 2: cancellation token, candidate loop breaks early at each boundary.
void main() {
  group('Direction 1 serial fallback fail-fast (5s first byte, no 15s pileup)',
      () {
    late Directory updatesDir;

    setUp(() async {
      updatesDir = await Directory.systemTemp.createTemp('hibiki-update-ff');
    });

    tearDown(() async {
      if (updatesDir.existsSync()) {
        await _deleteDirectoryWithRetry(updatesDir);
      }
    });

    test(
      'all-dead (TCP up, never first byte): serial fallback < 15s (was 30s)',
      () async {
        final List<int> payload = _payload();
        final UpdateAsset asset = _asset(payload);
        final String direct = asset.url;
        final String mirror = 'https://mirror.example/$direct';

        var openCount = 0;
        final Stopwatch sw = Stopwatch()..start();
        Object? thrown;
        try {
          await downloadUpdateAsset(
            asset: asset,
            version: '1.0.0',
            updatesDir: updatesDir,
            candidateUrls: <String>[direct, mirror],
            connectionCount: 1,
            minSegmentBytes: _minSeg,
            openUrl: (Uri _, Map<String, String> __) {
              openCount += 1;
              return Completer<UpdateDownloadResponse>().future;
            },
          );
        } catch (e) {
          thrown = e;
        }
        sw.stop();

        expect(thrown, isNotNull, reason: 'all-dead must fail-fast, not hang');
        expect(openCount, 2, reason: 'each of 2 candidates requested once');
        expect(
          sw.elapsed,
          lessThan(const Duration(seconds: 15)),
          reason: 'serial fallback 5s first-byte: 2 candidates ~10s, under 30s',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'segmented all-dead (connectionCount>1, race + probe) < 40s',
      () async {
        final List<int> payload = _payload();
        final UpdateAsset asset = _asset(payload);
        final String direct = asset.url;
        final String mirror = 'https://mirror.example/$direct';

        final Stopwatch sw = Stopwatch()..start();
        Object? thrown;
        try {
          await downloadUpdateAsset(
            asset: asset,
            version: '1.0.0',
            updatesDir: updatesDir,
            candidateUrls: <String>[direct, mirror],
            connectionCount: 4,
            minSegmentBytes: _minSeg,
            openUrl: (Uri _, Map<String, String> __) =>
                Completer<UpdateDownloadResponse>().future,
          );
        } catch (e) {
          thrown = e;
        }
        sw.stop();

        expect(thrown, isNotNull);
        expect(
          sw.elapsed,
          lessThan(const Duration(seconds: 40)),
          reason: 'race + probe + single fallback all use 5s first-byte (~25s)',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'slow body not killed by 5s: first byte arrives, chunks 8s apart, ok',
      () async {
        final List<int> payload = _payload();
        final UpdateAsset asset = _asset(payload);

        final File file = await downloadUpdateAsset(
          asset: asset,
          version: '1.0.0',
          updatesDir: updatesDir,
          candidateUrls: <String>[asset.url],
          connectionCount: 1,
          minSegmentBytes: _minSeg,
          openUrl: (Uri _, Map<String, String> __) async =>
              _slowBodyResponse(payload, gapMs: 8000),
        );

        expect(await file.readAsBytes(), payload,
            reason: 'slow body (8s/chunk < 15s) must not be killed');
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('Direction 2 cancellation token (early break at candidate boundary)',
      () {
    late Directory updatesDir;

    setUp(() async {
      updatesDir =
          await Directory.systemTemp.createTemp('hibiki-update-cancel');
    });

    tearDown(() async {
      if (updatesDir.existsSync()) {
        await _deleteDirectoryWithRetry(updatesDir);
      }
    });

    test('cancelled before download => throws immediately, no request sent',
        () async {
      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final UpdateDownloadCancellation cancellation =
          UpdateDownloadCancellation()..cancel();

      var openCount = 0;
      Object? thrown;
      try {
        await downloadUpdateAsset(
          asset: asset,
          version: '1.0.0',
          updatesDir: updatesDir,
          candidateUrls: <String>[asset.url, 'https://m.example/${asset.url}'],
          connectionCount: 1,
          minSegmentBytes: _minSeg,
          openUrl: (Uri _, Map<String, String> __) async {
            openCount += 1;
            return _slowBodyResponse(payload, gapMs: 0);
          },
          cancellation: cancellation,
        );
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<UpdateDownloadCancelledException>());
      expect(openCount, 0, reason: 'cancelled => break before any request');
    });

    test('cancel after first candidate fails => second candidate skipped',
        () async {
      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final String direct = asset.url;
      final String mirror = 'https://m.example/$direct';
      final UpdateDownloadCancellation cancellation =
          UpdateDownloadCancellation();

      final List<String> attemptedHosts = <String>[];
      Object? thrown;
      try {
        await downloadUpdateAsset(
          asset: asset,
          version: '1.0.0',
          updatesDir: updatesDir,
          candidateUrls: <String>[direct, mirror],
          connectionCount: 1,
          minSegmentBytes: _minSeg,
          openUrl: (Uri uri, Map<String, String> __) async {
            attemptedHosts.add(uri.host);
            cancellation.cancel();
            throw const SocketException('dead source');
          },
          cancellation: cancellation,
        );
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<UpdateDownloadCancelledException>(),
          reason: 'whole run ends with the cancellation exception');
      expect(attemptedHosts, <String>['github.com'],
          reason: 'only first candidate tried; second cut off after cancel');
    });

    test(
        'no cancel => downloads whole file (token does not affect normal path)',
        () async {
      final List<int> payload = _payload();
      final UpdateAsset asset = _asset(payload);
      final UpdateDownloadCancellation cancellation =
          UpdateDownloadCancellation();

      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.0.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[asset.url],
        connectionCount: 1,
        minSegmentBytes: _minSeg,
        openUrl: (Uri _, Map<String, String> __) async =>
            _slowBodyResponse(payload, gapMs: 0),
        cancellation: cancellation,
      );

      expect(await file.readAsBytes(), payload);
      expect(cancellation.isCancelled, isFalse);
    });
  });
}

// ---- helpers ----

const int _minSeg = 2;

UpdateAsset _asset(List<int> payload) => UpdateAsset(
      name: 'hibiki-1.0.0-windows-setup.exe',
      url:
          'https://github.com/hdjsadgfwtg/hibiki/releases/download/v1.0.0/hibiki-1.0.0-windows-setup.exe',
      sizeBytes: payload.length,
      sha256Digest: _sha256Hex(payload),
    );

List<int> _payload() =>
    List<int>.generate(16, (int i) => (i * 11 + 3) & 0xFF, growable: false);

// 200 full-file response: body in two chunks, gapMs apart (for the
// "slow body but < 15s => not killed" guard).
UpdateDownloadResponse _slowBodyResponse(List<int> payload,
    {required int gapMs}) {
  final StreamController<List<int>> controller = StreamController<List<int>>();
  final int half = payload.length ~/ 2;
  Future<void>(() async {
    controller.add(payload.sublist(0, half));
    if (gapMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: gapMs));
    }
    controller.add(payload.sublist(half));
    await controller.close();
  });
  return UpdateDownloadResponse(
    statusCode: HttpStatus.ok,
    headers: <String, String>{
      HttpHeaders.contentLengthHeader: '${payload.length}',
    },
    stream: controller.stream,
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
