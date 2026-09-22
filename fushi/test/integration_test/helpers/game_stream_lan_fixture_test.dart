import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

import '../../../integration_test/helpers/game_stream_lan_fixture.dart';

void main() {
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
