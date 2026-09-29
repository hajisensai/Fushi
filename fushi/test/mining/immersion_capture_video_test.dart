import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/immersion_capture_channel.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/sync/immersion_mine_payload.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

void main() {
  test(
    'browser sources without a video stream degrade instead of rejecting',
    () {
      final String source = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync();
      final int youtubeStart = source.indexOf(
        'if (payload.youtubeVideoId != null',
      );
      // 番剧（bilibili-pgc）与稿件共用这一段，所以锚点取「bilibili 这个 kind 的判据」而不是
      // 整个 `if (` 前缀——写法会随判据增减而变，判据本身不会。
      final int bilibiliStart = source.indexOf(
        "payload.clipSourceKind == 'bilibili'",
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
      // videoClip 成了默认模式：bilibili（浏览器只给音轨 + 截图）若还像过去那样按模式直接
      // 报错，所有没改过设置的人网页制卡全挂。这里只许照常出「截图 + 句子音频」卡。
      expect(bilibili, isNot(contains('VideoMiningImageMode.videoClip')));
      expect(
        bilibili,
        isNot(contains('the browser resolver currently supplies audio only')),
      );
      expect(youtube, contains('clipFormat: _appModel.videoMiningClipFormat'));
    },
  );

  test('only a recorded clip that failed to export is a hard error', () {
    final String source = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync();
    final int guard = source.indexOf("'同步视频制卡失败：录制片段未能导出为音画同步视频");
    expect(guard, greaterThan(0));
    final String condition = source.substring(
      source.lastIndexOf('if (', guard),
      guard,
    );
    // 录到了片段（clipBytes）却没导出同步视频 = 真失败，不许悄悄降级成截图卡；
    // 没录到片段的来源（后台软解 / 2A 截图）不进这个错误分支。
    expect(condition, contains('VideoMiningImageMode.videoClip'));
    expect(condition, contains('payload.clipBytes != null'));
    // 后台软解不再因片段模式被跳过：没录到片段时至少还有动图。
    expect(
      source,
      isNot(
        contains(
          '_appModel.videoMiningImageMode != VideoMiningImageMode.videoClip &&',
        ),
      ),
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
        videoExporter:
            ({
              required String videoPath,
              required int startMs,
              required int endMs,
              required String outputPath,
              bool decodeFromStart = false,
              String? cropFilter,
              MiningClipFormat format = MiningClipFormat.mp4H264,
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
    'failed clip export is reported, and a request without a clip is a plain '
    'screenshot card (not synchronized)',
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
        videoExporter:
            ({
              required String videoPath,
              required int startMs,
              required int endMs,
              required String outputPath,
              bool decodeFromStart = false,
              String? cropFilter,
              MiningClipFormat format = MiningClipFormat.mp4H264,
            }) async => const VideoClipExportResult.failure(
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
      // 捕获没给出片段：用手上的截图照常出卡，不声称同步、不强求音频（截图卡本就无声）。
      // 「录到了片段却导出失败」的硬错误在 app_model 那一层（见上一条源码守卫）。
      expect(request.providedCoverBytes, <int>[9]);
      expect(request.providedCoverName, 'web_shot.jpg');
      expect(request.requireAudio, isFalse);
      expect(temp.listSync(), isEmpty);
    },
  );

  test('WebM clip format falls back to MP4 when the encoder is missing, and '
      'the cover name follows the produced format', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'capture_video_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final List<MiningClipFormat> tried = <MiningClipFormat>[];
    Future<ImmersionCaptureResult> capture({required bool webmWorks}) =>
        transcodeClipToCapture(
          Uint8List.fromList(<int>[1, 2]),
          durationMs: 1200,
          compression: MiningMediaCompression.compressed,
          tempDir: temp.path,
          imageMode: VideoMiningImageMode.videoClip,
          clipFormat: MiningClipFormat.webmVp9,
          videoExporter:
              ({
                required String videoPath,
                required int startMs,
                required int endMs,
                required String outputPath,
                bool decodeFromStart = false,
                String? cropFilter,
                MiningClipFormat format = MiningClipFormat.mp4H264,
              }) async {
                tried.add(format);
                expect(outputPath, endsWith('.${format.fileExtension}'));
                if (format.playsInline && !webmWorks) {
                  return const VideoClipExportResult.failure(
                    VideoClipExportFailure.ffmpegFailed,
                    detail: "Unknown encoder 'libvpx-vp9'",
                  );
                }
                await File(outputPath).writeAsBytes(<int>[7, 8, 9]);
                return VideoClipExportResult.success(outputPath);
              },
        );
    final ImmersionCaptureResult webm = await capture(webmWorks: true);
    expect(tried, <MiningClipFormat>[MiningClipFormat.webmVp9]);
    expect(webm.clipFormat, MiningClipFormat.webmVp9);
    ImmersionMiningRequest request(ImmersionCaptureResult cap) =>
        buildImmersionRequest(
          ImmersionMinePayload(
            fields: const <String, String>{},
            sentence: 'sentence',
            clipBytes: Uint8List.fromList(<int>[1, 2]),
          ),
          cap,
          audioExpected: true,
          imageMode: VideoMiningImageMode.videoClip,
        );
    expect(request(webm).providedCoverName, 'netflix_clip.webm');

    tried.clear();
    final ImmersionCaptureResult mp4 = await capture(webmWorks: false);
    expect(tried, <MiningClipFormat>[
      MiningClipFormat.webmVp9,
      MiningClipFormat.mp4H264,
    ]);
    expect(mp4.clipFormat, MiningClipFormat.mp4H264);
    expect(request(mp4).providedCoverName, 'netflix_clip.mp4');
  });
}
