import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:image/image.dart' as img;

import '../../../integration_test/helpers/game_stream_lan_fixture.dart';

void main() {
  test(
    'adapter freezes after the host-stage await and preserves rejection',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'gs-frame-stage-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final Uint8List pngA = _syntheticPng(255);
      final Uint8List pngB = _syntheticPng(64);
      Uint8List captureBytes = pngA;
      final _StageBarrierEvidence evidence = _StageBarrierEvidence(
        directory: directory,
        captureWindow: (_) async => WindowCaptureResult(pngBytes: captureBytes),
      );
      await evidence.capture(1);
      final GameStreamEvidenceMiningAdapter adapter =
          GameStreamEvidenceMiningAdapter(
            repo: _UnusedAnkiRepository(),
            evidence: evidence,
          );
      addTearDown(adapter.clear);
      final GameStreamTextEvent line = _lineEvent('A');
      final Future<GameStreamMineResult> mining = adapter.mine(
        GameStreamMineRequest(
          sessionId: line.sessionId,
          clientId: 'fixture-client',
          lineId: line.lineId,
          sentence: line.text,
          fields: const <String, String>{'expression': 'A'},
        ),
        line,
      );
      await evidence.hostStageStarted.future;
      // A same-ID, same-text recapture must also retain a distinct PNG file.
      expect(evidence.frozenFrames, isEmpty);
      captureBytes = pngB;
      await evidence.capture(1);
      evidence.resumeHostStage.complete();
      final GameStreamMineResult result = await mining;
      expect(
        evidence.frozenFrames.single!.pngSha256,
        sha256.convert(pngB).toString(),
      );
      expect(
        await File(
          '${directory.path}/frame-${sha256.convert(pngA)}.png',
        ).readAsBytes(),
        pngA,
      );
      // The synthetic line is absent from the production session. The observer
      // must preserve that rejection without trying to read or write real Anki.
      expect(result.ok, isFalse);
      expect(
        result.detail,
        Platform.isWindows ? 'line_expired' : 'windows_only',
      );
      expect(evidence.verifiedNotes, isEmpty);
    },
  );

  test(
    'mine verification retains frame A while the same lineId advances to B',
    () => _verifyWhileTextAdvances(wrongPicture: false),
  );

  test(
    'mine verification rejects frame B for the mined text version A',
    () => _verifyWhileTextAdvances(wrongPicture: true),
  );

  test('capture crossing a text change provides no frozen evidence', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'gs-frame-evidence-',
    );
    addTearDown(() => directory.delete(recursive: true));
    TexthookerLineEntry current = _lineEntry('A');
    final Completer<WindowCaptureResult> capture =
        Completer<WindowCaptureResult>();
    final GameStreamLanEvidence evidence = GameStreamLanEvidence(
      directory: directory,
      runTag: 'fixture',
      currentLine: () => current,
      captureWindow: (_) => capture.future,
    );
    final Future<WindowCaptureResult> pending = evidence.capture(1);
    current = _lineEntry('B');
    capture.complete(WindowCaptureResult(pngBytes: _syntheticPng(255)));
    await pending;
    expect(evidence.freezeFrame(_lineEvent('A')), isNull);
    expect(evidence.freezeFrame(_lineEvent('B')), isNull);
    expect(directory.listSync(), isEmpty);
  });

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

TexthookerLineEntry _lineEntry(String text) => TexthookerLineEntry(
  id: 'progressive-line',
  text: text,
  source: TexthookerLineSource.engineHook,
  receivedAt: DateTime.utc(2026),
);

GameStreamTextEvent _lineEvent(String text) => GameStreamTextEvent(
  sessionId: 'fixture-session',
  lineId: 'progressive-line',
  text: text,
  timestampMs: 123,
);

Uint8List _syntheticPng(int red) {
  final img.Image image = img.Image(width: 2, height: 2);
  img.fill(image, color: img.ColorRgb8(red, 0, 0));
  return img.encodePng(image);
}

Future<void> _verifyWhileTextAdvances({required bool wrongPicture}) async {
  final Directory directory = await Directory.systemTemp.createTemp(
    'gs-frame-evidence-',
  );
  addTearDown(() => directory.delete(recursive: true));
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  addTearDown(() => server.close(force: true));
  final Uint8List pngA = _syntheticPng(255);
  final Uint8List pngB = _syntheticPng(64);
  final Uint8List audio = Uint8List.fromList(<int>[1, 2, 3, 4]);
  final Completer<void> verificationStarted = Completer<void>();
  final Completer<void> newerFrameCaptured = Completer<void>();
  final List<String> actions = <String>[];
  final StreamSubscription<HttpRequest> requests = server.listen((
    HttpRequest request,
  ) async {
    final Map<String, dynamic> body =
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
    final String action = body['action'] as String;
    actions.add(action);
    Object? result;
    switch (action) {
      case 'findNotes':
        verificationStarted.complete();
        await newerFrameCaptured.future;
        result = <int>[123];
      case 'notesInfo':
        result = <Object>[
          <String, Object>{
            'fields': <String, Object>{
              'Sentence': <String, String>{'value': 'A'},
              'SentenceAudio': <String, String>{'value': '[sound:voice.wav]'},
              'Picture': <String, String>{'value': '<img src="picture.png">'},
            },
          },
        ];
      case 'retrieveMediaFile':
        final String filename =
            (body['params'] as Map<String, dynamic>)['filename'] as String;
        result = base64Encode(
          filename == 'voice.wav' ? audio : (wrongPicture ? pngB : pngA),
        );
      default:
        fail('Unexpected fixture Anki action $action');
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode(<String, Object?>{'result': result, 'error': null}),
    );
    await request.response.close();
  });
  addTearDown(requests.cancel);
  TexthookerLineEntry current = _lineEntry('A');
  Uint8List captureBytes = pngA;
  final GameStreamLanEvidence evidence = GameStreamLanEvidence(
    directory: directory,
    runTag: 'fixture',
    ankiEndpoint: Uri.parse('http://127.0.0.1:${server.port}'),
    currentLine: () => current,
    captureWindow: (_) async => WindowCaptureResult(pngBytes: captureBytes),
    captureAudio:
        ({
          required String lineId,
          required String sentence,
          required String outputExtension,
        }) async => audio,
  );
  await evidence.capture(1);
  final GameStreamTextEvent lineA = _lineEvent('A');
  final GameStreamFrozenFrame? frozen = evidence.freezeFrame(lineA);
  expect(frozen, isNotNull);
  await evidence.captureAudio(
    lineId: lineA.lineId,
    sentence: lineA.text,
    outputExtension: 'wav',
  );
  final Future<void> verifying = evidence.verifyMine(
    lineA,
    <int>{},
    frame: frozen,
  );
  final Future<void> verification = wrongPicture
      ? expectLater(
          verifying,
          throwsA(
            isA<StateError>().having(
              (StateError error) => error.message,
              'message',
              'Anki picture differs from compressed frozen line PNG',
            ),
          ),
        )
      : verifying;
  await verificationStarted.future;
  current = _lineEntry('B');
  captureBytes = pngB;
  await evidence.capture(1);
  expect(evidence.freezeFrame(lineA), isNull);
  final GameStreamFrozenFrame? newer = evidence.freezeFrame(_lineEvent('B'));
  expect(newer, isNotNull);
  expect(newer!.pngSha256, isNot(frozen!.pngSha256));
  expect(
    await File('${directory.path}/frame-${frozen.pngSha256}.png').readAsBytes(),
    pngA,
  );
  newerFrameCaptured.complete();
  await verification;
  expect(actions, <String>[
    'findNotes',
    'notesInfo',
    'retrieveMediaFile',
    'retrieveMediaFile',
  ]);
  expect(evidence.verifiedNotes, wrongPicture ? isEmpty : <int>[123]);
  final File report = File('${directory.path}/note-123.json');
  expect(report.existsSync(), !wrongPicture);
  if (!wrongPicture) {
    final Map<String, dynamic> data =
        jsonDecode(await report.readAsString()) as Map<String, dynamic>;
    expect(data['frozenFrameSha256'], sha256.convert(pngA).toString());
    expect(data['pictureMatchesCompressedFrozenFrame'], isTrue);
    expect(data['audioMatchesLineCaptureBytes'], isTrue);
  }
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

class _UnusedAnkiRepository extends Fake implements BaseAnkiRepository {}

class _StageBarrierEvidence extends GameStreamLanEvidence {
  _StageBarrierEvidence({
    required super.directory,
    required super.captureWindow,
  }) : super(runTag: 'fixture', currentLine: () => _lineEntry('A'));

  final Completer<void> hostStageStarted = Completer<void>();
  final Completer<void> resumeHostStage = Completer<void>();
  final List<GameStreamFrozenFrame?> frozenFrames = <GameStreamFrozenFrame?>[];

  @override
  Future<Set<int>> findRunNotes() async => <int>{};

  @override
  Future<void> writeJson(String name, Object data) async {
    if (name == 'mining-progress.json' &&
        data is Map<String, Object?> &&
        data['stage'] == 'hostMine' &&
        data['status'] == 'started') {
      hostStageStarted.complete();
      await resumeHostStage.future;
    }
    await super.writeJson(name, data);
  }

  @override
  GameStreamFrozenFrame? freezeFrame(GameStreamTextEvent line) {
    final GameStreamFrozenFrame? frame = super.freezeFrame(line);
    frozenFrames.add(frame);
    return frame;
  }
}
