import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

import '../../../integration_test/helpers/game_stream_lan_fixture.dart';

void main() {
  test(
    'Anki preflight sends UTF-8 byte length without chunked encoding',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      const String runTag = '検証😀';
      int? contentLength;
      bool? chunked;
      late List<int> bodyBytes;
      final Future<void> served = server.first.then((
        HttpRequest request,
      ) async {
        contentLength = request.headers.contentLength;
        chunked = request.headers.chunkedTransferEncoding;
        bodyBytes = await request.fold<List<int>>(
          <int>[],
          (List<int> bytes, List<int> chunk) => bytes..addAll(chunk),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'result': <int>[123],
            'error': null,
          }),
        );
        await request.response.close();
      });
      final GameStreamLanEvidence evidence = GameStreamLanEvidence(
        // findRunNotes performs no filesystem writes.
        directory: Directory.systemTemp,
        runTag: runTag,
        ankiEndpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      expect(await evidence.findRunNotes(), <int>{123});
      await served;
      final String bodyText = utf8.decode(bodyBytes);
      expect(chunked, isFalse);
      expect(contentLength, bodyBytes.length);
      expect(contentLength, greaterThan(bodyText.length));
      expect(jsonDecode(bodyText), <String, Object?>{
        'action': 'findNotes',
        'version': 6,
        'params': <String, Object?>{
          'query': 'deck:"$gameStreamTestDeck" tag:$runTag',
        },
      });
    },
  );

  final GameStreamTextEvent line = GameStreamTextEvent(
    sessionId: 'fixture-session',
    lineId: 'fixture-line',
    text: 'private sentence that must not appear in diagnostic files',
    timestampMs: 123,
  );

  for (final GameStreamMiningStage stage in GameStreamMiningStage.values) {
    test(
      '${stage.name} records sanitized failure and rethrows the same error',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'gs-evidence-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final GameStreamLanEvidence evidence = GameStreamLanEvidence(
          directory: directory,
          runTag: 'fixture',
        );
        final StateError failure = StateError(
          'secret-token and private sentence',
        );
        await expectLater(
          evidence.observeMiningStage<void>(
            stage: stage,
            line: line,
            action: () async => throw failure,
          ),
          throwsA(same(failure)),
        );
        final String report = await File(
          '${directory.path}/mining-failure.json',
        ).readAsString();
        final Map<String, dynamic> data =
            jsonDecode(report) as Map<String, dynamic>;
        expect(data['stage'], stage.name);
        expect(data['failureType'], 'StateError');
        expect(data['lineId'], line.lineId);
        expect(data['sentenceSha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
        expect(report, isNot(contains('secret-token')));
        expect(report, isNot(contains('private sentence')));
        expect(evidence.failures, <String>['${stage.name}:StateError']);
      },
    );
  }

  test('completed stage preserves its return value', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'gs-evidence-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final GameStreamLanEvidence evidence = GameStreamLanEvidence(
      directory: directory,
      runTag: 'fixture',
    );
    final Set<int> notes = <int>{123};
    expect(
      await evidence.observeMiningStage<Set<int>>(
        stage: GameStreamMiningStage.preflight,
        line: line,
        action: () async => notes,
      ),
      same(notes),
    );
    final Map<String, dynamic> progress =
        jsonDecode(
              await File(
                '${directory.path}/mining-progress.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    expect(progress['status'], 'completed');
    expect(evidence.failures, isEmpty);
  });

  test(
    'diagnostic write failure does not replace the mining exception',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'gs-evidence-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final GameStreamLanEvidence evidence = _FailingDiagnosticEvidence(
        directory,
      );
      final StateError failure = StateError('private failure');
      await expectLater(
        evidence.observeMiningStage<void>(
          stage: GameStreamMiningStage.verify,
          line: line,
          action: () async => throw failure,
        ),
        throwsA(same(failure)),
      );
      expect(evidence.failures, <String>[
        'verify:StateError',
        'verify:evidence:FileSystemException',
      ]);
    },
  );

  test('recorder restores binding handler after app override', () {
    final FlutterExceptionHandler? original = FlutterError.onError;
    addTearDown(() => FlutterError.onError = original);
    final List<String> calls = <String>[];
    void bindingHandler(FlutterErrorDetails details) {
      calls.add('binding:${details.exception.runtimeType}');
    }

    final GameStreamFlutterErrorRecorder recorder =
        GameStreamFlutterErrorRecorder(bindingHandler: bindingHandler);
    FlutterError.onError = (_) => calls.add('app');
    recorder.install();

    FlutterError.reportError(
      FlutterErrorDetails(
        exception: PlatformException(code: 'window_not_foreground'),
      ),
    );
    expect(recorder.lastFailure, <String, Object?>{
      'failureType': 'PlatformException',
      'failureCode': 'window_not_foreground',
    });
    expect(calls, <String>['binding:PlatformException']);

    FlutterError.onError = (_) => calls.add('app-after-install');
    recorder.restore();
    expect(identical(FlutterError.onError, bindingHandler), isTrue);
  });
}

class _FailingDiagnosticEvidence extends GameStreamLanEvidence {
  _FailingDiagnosticEvidence(Directory directory)
    : super(directory: directory, runTag: 'fixture');

  @override
  Future<void> writeJson(String name, Object data) async {
    if (name == 'mining-failure.json') {
      throw const FileSystemException('private path');
    }
    await super.writeJson(name, data);
  }
}
