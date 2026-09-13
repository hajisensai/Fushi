import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

class _Repo implements BaseAnkiRepository {
  AnkiMiningContext? context;
  bool mediaExistedDuringImport = false;
  int? updatedId;

  @override
  Future<MineOutcome> mineEntry(
      {required String rawPayloadJson,
      required AnkiMiningContext context}) async {
    this.context = context;
    mediaExistedDuringImport = File(context.coverPath!).existsSync();
    return const MineOutcome.success(noteId: 1);
  }

  @override
  Future<MineOutcome> updateMinedNote(
      {required int noteId,
      required String rawPayloadJson,
      required AnkiMiningContext context}) {
    updatedId = noteId;
    return mineEntry(rawPayloadJson: rawPayloadJson, context: context);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late _Repo repo;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('synced_mining_test_');
    repo = _Repo();
  });
  tearDown(() async => temp.delete(recursive: true));

  ImmersionMiningRequest request({int? updateId}) => ImmersionMiningRequest(
        fields: const <String, String>{'expression': '走る'},
        source: AnkiMiningSource.video,
        mediaSource: 'https://video.example/video',
        audioSource: 'https://audio.example/selected-track',
        mediaSourceTlsPinSha256: 'pinned',
        clipStartMs: 850,
        clipEndMs: 3250,
        sentence: '走り出した。',
        imageMode: VideoMiningImageMode.videoClip,
        updateNoteId: updateId,
        providedAudioBytes: Uint8List.fromList(<int>[1, 2, 3]),
        providedAudioName: 'selected.aac',
      );

  test('one MP4 carries selected sentence sound, exact padded window and pin',
      () async {
    final ImmersionMiningEngine engine = ImmersionMiningEngine(
      synchronizedVideoExtractor: (
          {required String videoPath,
          required String audioPath,
          required int startMs,
          required int endMs,
          required String outputPath,
          required String? tlsPinSha256}) async {
        expect(videoPath, 'https://video.example/video');
        expect(File(audioPath).readAsBytesSync(), <int>[1, 2, 3]);
        expect(startMs, 850);
        expect(endMs, 3250);
        expect(tlsPinSha256, 'pinned');
        await File(outputPath).writeAsBytes(<int>[9, 8, 7]);
        return VideoClipExportResult.success(outputPath);
      },
    );
    for (int i = 0; i < 2; i++) {
      final ImmersionMiningResult result = await engine.mine(
          request(updateId: i == 1 ? 7 : null),
          compression: MiningMediaCompression.compressed,
          tempDir: temp.path,
          repo: repo);
      expect(result.aborted, false);
      expect(repo.context!.synchronizedVideo, true);
      expect(repo.context!.coverPath, repo.context!.sentenceAudioPath);
      expect(repo.mediaExistedDuringImport, true);
      expect(File(repo.context!.coverPath!).existsSync(), false);
    }
    expect(repo.updatedId, 7);
  });

  test('encoder failure aborts without silently exporting a mute image',
      () async {
    final ImmersionMiningResult result = await ImmersionMiningEngine(
      synchronizedVideoExtractor: (
              {required String videoPath,
              required String audioPath,
              required int startMs,
              required int endMs,
              required String outputPath,
              required String? tlsPinSha256}) async =>
          const VideoClipExportResult.failure(
              VideoClipExportFailure.ffmpegFailed,
              detail: 'H264 encoder unavailable'),
    ).mine(request(),
        compression: MiningMediaCompression.compressed,
        tempDir: temp.path,
        repo: repo);
    expect(result.aborted, true);
    expect(result.abortReason, contains('H264 encoder unavailable'));
    expect(repo.context, isNull);
    expect(temp.listSync().whereType<Directory>(), isEmpty);
  });

  test('recorded audible MP4 does not require a second audio file', () async {
    final ImmersionMiningResult result = await ImmersionMiningEngine().mine(
        ImmersionMiningRequest(
            fields: const <String, String>{},
            source: AnkiMiningSource.video,
            clipStartMs: 1000,
            clipEndMs: 3000,
            sentence: 'テスト',
            imageMode: VideoMiningImageMode.videoClip,
            providedCoverBytes:
                Uint8List.fromList(<int>[0, 0, 0, 24, 102, 116, 121, 112]),
            providedCoverName: 'recording.mp4'),
        compression: MiningMediaCompression.compressed,
        tempDir: temp.path,
        repo: repo);
    expect(result.aborted, false);
    expect(repo.context!.synchronizedVideo, true);
    expect(repo.context!.sentenceAudioPath, repo.context!.coverPath);
  });

  test(
      'missing source or missing sentence window cannot claim synchronized output',
      () async {
    final ImmersionMiningResult result = await ImmersionMiningEngine().mine(
        const ImmersionMiningRequest(
            fields: <String, String>{},
            source: AnkiMiningSource.video,
            clipStartMs: 0,
            clipEndMs: 0,
            sentence: 'テスト',
            imageMode: VideoMiningImageMode.videoClip),
        compression: MiningMediaCompression.compressed,
        tempDir: temp.path,
        repo: repo);
    expect(result.aborted, true);
    expect(repo.context, isNull);
  });
}
