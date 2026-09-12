import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/immersion_capture_channel.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/sync/immersion_mine_payload.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

void main() {
  test('browser audio-only rejection is scoped to Bilibili, not YouTube', () {
    final String source = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync();
    final int youtubeStart = source.indexOf(
      'if (payload.youtubeVideoId != null',
    );
    final int bilibiliStart = source.indexOf(
      "if (payload.clipSourceKind == 'bilibili'",
    );
    final int captureStart = source.indexOf(
      'ImmersionCaptureResult cap =',
      bilibiliStart,
    );
    expect(youtubeStart, greaterThanOrEqualTo(0));
    expect(bilibiliStart, greaterThan(youtubeStart));
    expect(captureStart, greaterThan(bilibiliStart));
    final String youtube = source.substring(youtubeStart, bilibiliStart);
    final String bilibili = source.substring(bilibiliStart, captureStart);
    expect(youtube, contains('imageMode: _appModel.videoMiningImageMode'));
    expect(
      youtube,
      isNot(contains('VideoMiningImageMode.videoClip')),
      reason:
          'YouTube supplies a video stream and must forward the selected mode',
    );
    expect(
      youtube,
      isNot(contains('the browser resolver currently supplies audio only')),
    );
    expect(bilibili, contains('VideoMiningImageMode.videoClip'));
    expect(
      bilibili,
      contains('the browser resolver currently supplies audio only'),
    );
  });

  test(
    'recorded clip stays one audible MP4 through the request boundary',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'capture_video_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final ImmersionCaptureResult cap = await transcodeClipToCapture(
        Uint8List.fromList(<int>[1, 2]),
        durationMs: 1200,
        compression: MiningMediaCompression.compressed,
        tempDir: temp.path,
        imageMode: VideoMiningImageMode.videoClip,
        videoExporter: ({
          required String videoPath,
          required int startMs,
          required int endMs,
          required String outputPath,
          bool decodeFromStart = false,
          String? cropFilter,
        }) async {
          expect(await File(videoPath).readAsBytes(), <int>[1, 2]);
          expect(startMs, 0);
          expect(endMs, 1200);
          expect(decodeFromStart, isTrue);
          await File(outputPath).writeAsBytes(<int>[7, 8, 9]);
          return VideoClipExportResult.success(outputPath);
        },
      );
      expect(cap.ok, isTrue);
      expect(cap.coverIsVideo, isTrue);
      expect(cap.audioBytes, isNull);
      expect(
        temp.listSync(),
        isEmpty,
        reason: 'transcode temporary files are cleaned',
      );
      final ImmersionMiningRequest request = buildImmersionRequest(
        ImmersionMinePayload(
          fields: const <String, String>{},
          sentence: 'sentence',
          clipBytes: Uint8List.fromList(<int>[1, 2]),
        ),
        cap,
        audioExpected: true,
        imageMode: VideoMiningImageMode.videoClip,
      );
      expect(request.imageMode, VideoMiningImageMode.videoClip);
      expect(request.providedCoverName, 'netflix_clip.mp4');
      expect(request.providedCoverBytes, <int>[7, 8, 9]);
      expect(request.providedAudioBytes, isNull);
    },
  );

  test(
    'video encoder failure cannot silently become a screenshot card',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'capture_video_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final ImmersionCaptureResult cap = await transcodeClipToCapture(
        Uint8List.fromList(<int>[1]),
        durationMs: 1200,
        compression: MiningMediaCompression.compressed,
        tempDir: temp.path,
        imageMode: VideoMiningImageMode.videoClip,
        videoExporter: ({
          required String videoPath,
          required int startMs,
          required int endMs,
          required String outputPath,
          bool decodeFromStart = false,
          String? cropFilter,
        }) async =>
            const VideoClipExportResult.failure(
          VideoClipExportFailure.ffmpegFailed,
          detail: 'no audio stream',
        ),
      );
      expect(cap.ok, isFalse);
      expect(cap.error, contains('no audio stream'));
      final ImmersionMiningRequest request = buildImmersionRequest(
        ImmersionMinePayload(
          fields: const <String, String>{},
          sentence: 'sentence',
          screenshotBytes: Uint8List.fromList(<int>[9]),
        ),
        cap,
        audioExpected: false,
        imageMode: VideoMiningImageMode.videoClip,
      );
      expect(request.providedCoverBytes, isNull);
      expect(request.requireAudio, isTrue);
      expect(request.imageMode, VideoMiningImageMode.videoClip);
      expect(temp.listSync(), isEmpty);
    },
  );
}
