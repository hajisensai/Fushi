import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

// TODO-808: "connecting is slow + cancel is also slow" fix.
//
// Root cause (cancel slow): cancel() only set a flag; in-flight HttpClient
// requests could not be aborted, so cancelling forced the user to wait out the
// current candidate's first-byte / segment timeout. Fix: the cancellation token
// now holds an "abort in-flight connection" callback (in practice
// client.close(force: true)); cancel() fires it immediately so awaiting
// connects / reads throw at once.
//
// These tests pin the cancellation CONTRACT (the callsite in release.dart wires
// () => client.close(force: true) into registerAbort) without needing real
// sockets: they assert the token actually invokes the registered abort, that
// register/clear are paired, and that a downloadUpdateAsset run whose abort
// strands the in-flight stream still surfaces as a clean cancelled exception.
void main() {
  group('UpdateDownloadCancellation abort wiring (TODO-808)', () {
    test('cancel() fires the registered abort callback exactly once', () {
      final UpdateDownloadCancellation cancellation =
          UpdateDownloadCancellation();
      var abortCalls = 0;
      cancellation.registerAbort(() => abortCalls += 1);

      expect(abortCalls, 0, reason: 'abort must not fire before cancel');
      cancellation.cancel();
      expect(abortCalls, 1, reason: 'cancel must fire the abort once');

      // Idempotent: a second cancel must not re-fire (abort consumed on first).
      cancellation.cancel();
      expect(abortCalls, 1,
          reason: 'abort fires once; cancel stays idempotent');
      expect(cancellation.isCancelled, isTrue);
    });

    test('registerAbort after an early cancel fires immediately (race cover)',
        () {
      final UpdateDownloadCancellation cancellation =
          UpdateDownloadCancellation()
            ..cancel(); // user cancelled before client was built
      var abortCalls = 0;
      cancellation.registerAbort(() => abortCalls += 1);
      expect(abortCalls, 1,
          reason: 'registering an abort while already cancelled must fire it');
    });

    test('clearAbort() unregisters: later cancel does not touch the old client',
        () {
      final UpdateDownloadCancellation cancellation =
          UpdateDownloadCancellation();
      var abortCalls = 0;
      cancellation.registerAbort(() => abortCalls += 1);
      cancellation.clearAbort();
      cancellation.cancel();
      expect(abortCalls, 0,
          reason: 'cleared abort must not fire (avoids closing reused client)');
    });

    test('abort callback throwing does not escape cancel()', () {
      final UpdateDownloadCancellation cancellation =
          UpdateDownloadCancellation();
      cancellation
          .registerAbort(() => throw StateError('client already closed'));
      // Must not throw: force-close is best-effort on the cancel path.
      expect(cancellation.cancel, returnsNormally);
      expect(cancellation.isCancelled, isTrue);
    });
  });

  group(
      'downloadUpdateAsset cancel surfaces cleanly even mid-stream (TODO-808)',
      () {
    late Directory updatesDir;

    setUp(() async {
      updatesDir =
          await Directory.systemTemp.createTemp('hibiki-update-cancel808');
    });

    tearDown(() async {
      if (updatesDir.existsSync()) {
        await _deleteDirectoryWithRetry(updatesDir);
      }
    });

    test(
      'abort strands the only candidate mid-body => cancelled, not net-failure',
      () async {
        final List<int> payload = _payload();
        final UpdateAsset asset = _asset(payload);
        final UpdateDownloadCancellation cancellation =
            UpdateDownloadCancellation();

        // openUrl returns a response whose body never completes; registerAbort
        // wires an "abort" that tears that stream down (mimicking
        // client.close(force:true) breaking the in-flight socket).
        final StreamController<List<int>> body = StreamController<List<int>>();
        cancellation.registerAbort(() {
          // Force the in-flight read to throw, exactly like a force-closed socket.
          if (!body.isClosed) {
            body.addError(const SocketException('connection closed by abort'));
          }
        });

        Object? thrown;
        final Future<File> run = downloadUpdateAsset(
          asset: asset,
          version: '1.0.0',
          updatesDir: updatesDir,
          candidateUrls: <String>[asset.url],
          connectionCount: 1,
          minSegmentBytes: _minSeg,
          openUrl: (Uri _, Map<String, String> __) async {
            // First byte arrives so we are mid-body, then it hangs until abort.
            scheduleMicrotask(() => body.add(payload.sublist(0, 1)));
            return UpdateDownloadResponse(
              statusCode: HttpStatus.ok,
              headers: <String, String>{
                HttpHeaders.contentLengthHeader: '${payload.length}',
              },
              stream: body.stream,
            );
          },
          cancellation: cancellation,
        );

        // Let the request start + first byte land, then cancel mid-stream.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        cancellation.cancel();

        try {
          await run;
        } catch (e) {
          thrown = e;
        }
        expect(thrown, isA<UpdateDownloadCancelledException>(),
            reason: 'mid-stream abort on the last candidate must surface as '
                'cancelled, not as a network failure');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}

// ---- helpers ----

const int _minSeg = 2;

UpdateAsset _asset(List<int> payload) => UpdateAsset(
      name: 'hibiki-1.0.0-windows-setup.exe',
      url:
          'https://github.com/hajisensai/hibiki/releases/download/v1.0.0/hibiki-1.0.0-windows-setup.exe',
      sizeBytes: payload.length,
      sha256Digest: _sha256Hex(payload),
    );

List<int> _payload() =>
    List<int>.generate(16, (int i) => (i * 11 + 3) & 0xFF, growable: false);

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
