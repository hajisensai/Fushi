import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/immersion_capture_channel.dart';
import 'package:hibiki/src/sync/immersion_mine_payload.dart';

ImmersionMinePayload _payload({Uint8List? shot}) => ImmersionMinePayload(
      fields: const {'expression': '走る'},
      sentence: 's',
      netflixVideoId: '81',
      clipStartMs: 1000,
      clipEndMs: 3000,
      screenshotBytes: shot,
    );

void main() {
  group('buildImmersionRequest', () {
    test('capture ok with gif+audio -> uses gif cover + audio, requireAudio true', () {
      final req = buildImmersionRequest(
        _payload(),
        ImmersionCaptureResult(gifBytes: Uint8List.fromList([1]), audioBytes: Uint8List.fromList([2])),
      );
      expect(req.providedCoverName, 'netflix_clip.gif');
      expect(req.providedCoverBytes, [1]);
      expect(req.providedAudioBytes, [2]);
      expect(req.requireAudio, true);
      expect(req.mediaSource, isNull);
      expect(req.documentTitle, 'Netflix');
    });

    test('capture error -> degrades to screenshot cover, no audio, requireAudio false', () {
      final req = buildImmersionRequest(
        _payload(shot: Uint8List.fromList([9])),
        const ImmersionCaptureResult(error: 'black frame'),
      );
      expect(req.providedCoverName, 'netflix_shot.jpg');
      expect(req.providedCoverBytes, [9]);
      expect(req.providedAudioBytes, isNull);
      expect(req.requireAudio, false);
    });

    test('capture ok but gif missing -> falls back to screenshot cover', () {
      final req = buildImmersionRequest(
        _payload(shot: Uint8List.fromList([7])),
        ImmersionCaptureResult(audioBytes: Uint8List.fromList([2])),
      );
      expect(req.providedCoverName, 'netflix_shot.jpg');
      expect(req.providedCoverBytes, [7]);
      expect(req.providedAudioBytes, [2]);
      expect(req.requireAudio, true);
    });

    test('2A only (skip capture) -> screenshot cover, no audio', () {
      final req = buildImmersionRequest(
        _payload(shot: Uint8List.fromList([5])),
        const ImmersionCaptureResult(error: 'skip'),
      );
      expect(req.providedCoverBytes, [5]);
      expect(req.providedAudioBytes, isNull);
      expect(req.requireAudio, false);
    });
  });
}
