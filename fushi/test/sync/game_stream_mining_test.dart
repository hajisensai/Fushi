import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/game_stream_mining.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

void main() {
  late TexthookerService text;
  late FushiGameStreamMiningAdapter adapter;
  late List<GalHookLineScreenshot> mined;
  late List<Map<String, String>> fields;
  late Future<WindowCaptureResult> Function(int) capture;

  GameStreamTextEvent event(TexthookerLineEntry line) => GameStreamTextEvent(
    sessionId: 'session',
    lineId: line.id,
    text: line.text,
    timestampMs: 1,
  );
  GameStreamMineRequest request(GameStreamTextEvent line) =>
      GameStreamMineRequest(
        sessionId: 'session',
        clientId: 'phone',
        lineId: line.lineId,
        sentence: line.text,
        fields: <String, String>{
          'expression': '猫',
          'glossary': 'cat',
          'coverPath': 'untrusted.png',
        },
      );
  setUp(() {
    text = TexthookerService.test()..foldProgressiveLines = false;
    mined = <GalHookLineScreenshot>[];
    fields = <Map<String, String>>[];
    capture = (_) async =>
        WindowCaptureResult(pngBytes: Uint8List.fromList(<int>[1, 2, 3]));
    adapter = FushiGameStreamMiningAdapter(
      repository: () => throw StateError('unexpected repository'),
      compression: () => MiningMediaCompression.compressed,
      isWindows: () => true,
      lineLookup: text.entryById,
      currentLineId: () => text.lastEntry?.id,
      lineValidator: (_) => true,
      captureStill: (int hwnd) => capture(hwnd),
      maxSnapshots: 2,
      mineSnapshot:
          (
            GameStreamMineRequest request,
            GalHookLineScreenshot screenshot,
          ) async {
            mined.add(screenshot);
            fields.add(request.fields);
            return GalHookMiningResult(outcome: MineOutcome.success(noteId: 1));
          },
    );
  });
  tearDown(() {
    adapter.clear();
    text.dispose();
  });

  test(
    'historical line uses frozen screenshot, never current screen',
    () async {
      final GameStreamTextEvent old = event(text.appendLine('old')!);
      expect(await adapter.captureLine(old, hwnd: 1), isTrue);
      text.appendLine('new');
      capture = (_) => throw StateError('must not recapture');
      expect((await adapter.mine(request(old), old)).ok, isTrue);
      expect(mined.single.lineId, old.lineId);
      expect(mined.single.pngBytes, <int>[1, 2, 3]);
      expect(fields.single['expression'], '猫');
      expect(fields.single.containsKey('coverPath'), isFalse);
    },
  );
  test('line transition during capture discards screenshot', () async {
    final Completer<WindowCaptureResult> pending =
        Completer<WindowCaptureResult>();
    capture = (_) => pending.future;
    final GameStreamTextEvent old = event(text.appendLine('old')!);
    final Future<bool> saving = adapter.captureLine(old, hwnd: 1);
    text.appendLine('new');
    pending.complete(
      WindowCaptureResult(pngBytes: Uint8List.fromList(<int>[9])),
    );
    expect(await saving, isFalse);
    expect(
      (await adapter.mine(request(old), old)).detail,
      'line_snapshot_missing',
    );
    expect(mined, isEmpty);
  });
  test(
    'stop invalidates in-flight frames and cache eviction fails closed',
    () async {
      final GameStreamTextEvent first = event(text.appendLine('first')!);
      await adapter.captureLine(first, hwnd: 1);
      for (final String value in <String>['second', 'third']) {
        await adapter.captureLine(event(text.appendLine(value)!), hwnd: 1);
      }
      expect((await adapter.mine(request(first), first)).ok, isFalse);
      final GameStreamTextEvent last = event(text.lastEntry!);
      adapter.clear();
      expect((await adapter.mine(request(last), last)).ok, isFalse);
      expect(mined, isEmpty);
    },
  );

  test(
    'progressive text recaptures the latest text for the same lineId',
    () async {
      text.foldProgressiveLines = true;
      final List<Completer<WindowCaptureResult>> captures =
          <Completer<WindowCaptureResult>>[];
      capture = (_) {
        final Completer<WindowCaptureResult> pending =
            Completer<WindowCaptureResult>();
        captures.add(pending);
        return pending.future;
      };
      final GameStreamTextEvent first = event(
        text.appendLine('Alpha text', source: TexthookerLineSource.engineHook)!,
      );
      final Future<bool> firstCapture = adapter.captureLine(first, hwnd: 1);
      final GameStreamTextEvent second = event(
        text.appendLine(
          'Alpha text expanded',
          source: TexthookerLineSource.engineHook,
        )!,
      );
      expect(second.lineId, first.lineId);
      final Future<bool> secondCapture = adapter.captureLine(second, hwnd: 1);
      expect(captures, hasLength(1));
      captures.first.complete(
        WindowCaptureResult(pngBytes: Uint8List.fromList(<int>[1])),
      );
      await Future<void>.value();
      expect(captures, hasLength(2));
      captures.last.complete(
        WindowCaptureResult(pngBytes: Uint8List.fromList(<int>[2])),
      );
      expect(await firstCapture, isFalse);
      expect(await secondCapture, isTrue);
      expect((await adapter.mine(request(second), second)).ok, isTrue);
      expect(mined.single.pngBytes, <int>[2]);
    },
  );

  test('clear prevents a queued progressive capture from restarting', () async {
    text.foldProgressiveLines = true;
    final Completer<WindowCaptureResult> pending =
        Completer<WindowCaptureResult>();
    int captureCount = 0;
    capture = (_) {
      captureCount++;
      return pending.future;
    };
    final GameStreamTextEvent first = event(
      text.appendLine('Alpha text', source: TexthookerLineSource.engineHook)!,
    );
    final Future<bool> firstCapture = adapter.captureLine(first, hwnd: 1);
    final GameStreamTextEvent second = event(
      text.appendLine(
        'Alpha text expanded',
        source: TexthookerLineSource.engineHook,
      )!,
    );
    final Future<bool> secondCapture = adapter.captureLine(second, hwnd: 1);
    adapter.clear();
    pending.complete(
      WindowCaptureResult(pngBytes: Uint8List.fromList(<int>[1])),
    );
    expect(await firstCapture, isFalse);
    expect(await secondCapture, isFalse);
    expect(captureCount, 1);
    expect(
      (await adapter.mine(request(second), second)).detail,
      'line_snapshot_missing',
    );
  });
}
