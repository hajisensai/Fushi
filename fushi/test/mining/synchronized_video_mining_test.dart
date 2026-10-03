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
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    this.context = context;
    mediaExistedDuringImport = File(context.coverPath!).existsSync();
    return const MineOutcome.success(noteId: 1);
  }

  @override
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) {
    updatedId = noteId;
    return mineEntry(rawPayloadJson: rawPayloadJson, context: context);
  }

  /// 不带模板的后端：无法判定，保持片段偏好。
  @override
  Future<bool?> rendersSynchronizedClip() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 目标笔记类型的模板由 [back] 决定（Picture 映射 `{card-image}`）。
class _TemplateRepo extends _Repo {
  _TemplateRepo(this.back);

  final String back;
  int definitionReads = 0;

  static const AnkiNoteType _noteType = AnkiNoteType(
    id: 1,
    name: 'Target',
    fields: <String>['Expression', 'Picture', 'SentenceAudio'],
  );

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings(
    selectedNoteTypeId: 1,
    availableNoteTypes: <AnkiNoteType>[_noteType],
    fieldMappings: <String, String>{
      'Expression': '{expression}',
      'Picture': '{card-image}',
      'SentenceAudio': '{sentence-audio}',
    },
  );

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(
    String modelName,
  ) async {
    definitionReads++;
    expect(modelName, 'Target');
    return AnkiNoteTypeDefinition(
      name: modelName,
      fields: _noteType.fields,
      templates: <AnkiCardTemplate>[
        AnkiCardTemplate(name: 'Card 1', front: '{{Expression}}', back: back),
      ],
      css: '',
    );
  }

  // `implements` 型假仓库拿不到基类实现：按同一判据现场回答。
  @override
  Future<bool?> rendersSynchronizedClip() async {
    final AnkiSettings settings = await loadSettings();
    return noteTypeRendersSynchronizedClip(
      definition: (await readNoteTypeDefinition(_noteType.name))!,
      fieldMappings: settings.fieldMappings,
    );
  }
}

/// Kiku 式：字段写在 `<template>` 里由脚本二次解析，Picture 只取 `<img>`。
const String _kikuLikeBack =
    '<template id="anki-fields"><template data-field="Picture">{{Picture}}'
    '</template><template data-field="SentenceAudio">{{SentenceAudio}}'
    '</template></template>';

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

  test(
    'one MP4 carries selected sentence sound, exact padded window and pin',
    () async {
      final ImmersionMiningEngine engine = ImmersionMiningEngine(
        synchronizedVideoExtractor:
            ({
              required String videoPath,
              required String audioPath,
              required int startMs,
              required int endMs,
              required String outputPath,
              required String? tlsPinSha256,
              required Map<String, String> httpHeaders,
              required MiningClipFormat format,
            }) async {
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
          repo: repo,
        );
        expect(result.aborted, false);
        expect(repo.context!.synchronizedVideo, true);
        expect(repo.context!.coverPath, repo.context!.sentenceAudioPath);
        expect(repo.mediaExistedDuringImport, true);
        expect(File(repo.context!.coverPath!).existsSync(), false);
      }
      expect(repo.updatedId, 7);
    },
  );

  // 片段模式是默认值：导出失败（源没有视频轨、远端流超时…）退回动图阶梯并保留句子
  // 音频照常出卡，但**不声称同步**——改默认之前这些卡走 gif 模式本来就能出。
  test(
    'export failure degrades to an animated cover + separate audio',
    () async {
      final List<String> gifCalls = <String>[];
      final ImmersionMiningResult result =
          await ImmersionMiningEngine(
            gifExtractor:
                ({
                  required String inputPath,
                  required int startMs,
                  required int endMs,
                  required String outputPath,
                  int fps = 8,
                  int width = 320,
                  MiningAnimatedFormat format = MiningAnimatedFormat.gif,
                  bool diagnosticOnly = false,
                  FfmpegFailureReporter? onFailure,
                  String? tlsPinSha256,
                  Map<String, String> httpHeaders = const <String, String>{},
                }) async {
                  gifCalls.add(outputPath);
                  await File(
                    outputPath,
                  ).writeAsBytes(<int>[0x47, 0x49, 0x46, 0x38]);
                  return outputPath;
                },
            synchronizedVideoExtractor:
                ({
                  required String videoPath,
                  required String audioPath,
                  required int startMs,
                  required int endMs,
                  required String outputPath,
                  required String? tlsPinSha256,
                  required Map<String, String> httpHeaders,
                  required MiningClipFormat format,
                }) async => const VideoClipExportResult.failure(
                  VideoClipExportFailure.ffmpegFailed,
                  detail: 'H264 encoder unavailable',
                ),
          ).mine(
            request(),
            compression: MiningMediaCompression.compressed,
            tempDir: temp.path,
            repo: repo,
          );
      expect(result.aborted, false);
      expect(gifCalls, hasLength(1));
      expect(repo.context!.synchronizedVideo, false);
      expect(repo.context!.coverPath, endsWith('.gif'));
      expect(repo.context!.sentenceAudioPath, isNot(repo.context!.coverPath));
      expect(repo.context!.sentenceAudioPath, isNotNull);
      // 导出临时目录已清理，不留半截片段。
      expect(
        temp.listSync().whereType<Directory>().where(
          (Directory d) => d.path.contains('synced_video_'),
        ),
        isEmpty,
      );
    },
  );

  test('recorded audible MP4 does not require a second audio file', () async {
    final ImmersionMiningResult result = await ImmersionMiningEngine().mine(
      ImmersionMiningRequest(
        fields: const <String, String>{},
        source: AnkiMiningSource.video,
        clipStartMs: 1000,
        clipEndMs: 3000,
        sentence: 'テスト',
        imageMode: VideoMiningImageMode.videoClip,
        providedCoverBytes: Uint8List.fromList(<int>[
          0,
          0,
          0,
          24,
          102,
          116,
          121,
          112,
        ]),
        providedCoverName: 'recording.mp4',
      ),
      compression: MiningMediaCompression.compressed,
      tempDir: temp.path,
      repo: repo,
    );
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
          imageMode: VideoMiningImageMode.videoClip,
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: temp.path,
        repo: repo,
      );
      expect(result.aborted, true);
      expect(repo.context, isNull);
    },
  );

  // videoClip 是默认模式：没有字幕时间窗（无 cue）的视频制卡不能因此整张失败，按动图
  // 模式的阶梯降级到当前帧，且不声称同步。
  test(
    'no sentence window degrades to a still card instead of aborting',
    () async {
      final ImmersionMiningResult result = await ImmersionMiningEngine().mine(
        ImmersionMiningRequest(
          fields: const <String, String>{},
          source: AnkiMiningSource.video,
          clipStartMs: 0,
          clipEndMs: 0,
          sentence: 'テスト',
          imageMode: VideoMiningImageMode.videoClip,
          clipFormat: MiningClipFormat.webmVp9,
          stillFallback: () async =>
              Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: temp.path,
        repo: repo,
      );
      expect(result.aborted, false);
      expect(result.degradedToStill, false);
      expect(repo.context!.synchronizedVideo, false);
      expect(repo.context!.coverPath, endsWith('immersion_shot.jpg'));
    },
  );

  test(
    'WebM encoder missing falls back to MP4; cover follows produced format',
    () async {
      final List<MiningClipFormat> tried = <MiningClipFormat>[];
      final ImmersionMiningEngine engine = ImmersionMiningEngine(
        synchronizedVideoExtractor:
            ({
              required String videoPath,
              required String audioPath,
              required int startMs,
              required int endMs,
              required String outputPath,
              required String? tlsPinSha256,
              required Map<String, String> httpHeaders,
              required MiningClipFormat format,
            }) async {
              tried.add(format);
              expect(
                outputPath,
                endsWith(
                  'immersion_video-${format.wireName}.${format.fileExtension}',
                ),
              );
              if (format.playsInline) {
                return const VideoClipExportResult.failure(
                  VideoClipExportFailure.ffmpegFailed,
                  detail: "Unknown encoder 'libsvtav1'",
                );
              }
              await File(outputPath).writeAsBytes(<int>[9, 8, 7]);
              return VideoClipExportResult.success(outputPath);
            },
      );
      final ImmersionMiningResult result = await engine.mine(
        ImmersionMiningRequest(
          fields: const <String, String>{'expression': '走る'},
          source: AnkiMiningSource.video,
          mediaSource: 'https://video.example/video',
          clipStartMs: 1000,
          clipEndMs: 3000,
          sentence: '走り出した。',
          imageMode: VideoMiningImageMode.videoClip,
          clipFormat: MiningClipFormat.webmAv1,
          providedAudioBytes: Uint8List.fromList(<int>[1, 2, 3]),
          providedAudioName: 'selected.aac',
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: temp.path,
        repo: repo,
      );
      expect(result.aborted, false);
      expect(tried, <MiningClipFormat>[
        MiningClipFormat.webmAv1,
        MiningClipFormat.webmVp9,
        MiningClipFormat.mp4H264,
      ]);
      expect(repo.context!.synchronizedVideo, true);
      expect(repo.context!.coverPath, endsWith('.mp4'));
    },
  );

  // galgame 窗口录制片段已混进句子音频：必须按同步片段落卡（句子音频 = 片段本身），
  // 否则卡上同一句语音播两遍——WebM 内嵌时更是两路同时响。
  test(
    'game source: a provided audible WebM clip is a synchronized clip',
    () async {
      final ImmersionMiningResult result = await ImmersionMiningEngine().mine(
        ImmersionMiningRequest(
          fields: const <String, String>{},
          source: AnkiMiningSource.game,
          clipStartMs: 0,
          clipEndMs: 0,
          sentence: 'テスト',
          imageMode: VideoMiningImageMode.videoClip,
          providedCoverBytes: Uint8List.fromList(<int>[0x1A, 0x45, 0xDF, 0xA3]),
          providedCoverName: 'external_window.webm',
          providedAudioBytes: Uint8List.fromList(<int>[1, 2, 3]),
          providedAudioName: 'galgame_audio.aac',
          requireAudio: true,
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: temp.path,
        repo: repo,
      );
      expect(result.aborted, false);
      expect(repo.context!.synchronizedVideo, true);
      expect(repo.context!.coverPath, endsWith('external_window.webm'));
      expect(repo.context!.sentenceAudioPath, repo.context!.coverPath);
    },
  );

  test(
    'game source: a GIF cover (clip fell back) stays a plain cover',
    () async {
      final ImmersionMiningResult result = await ImmersionMiningEngine().mine(
        ImmersionMiningRequest(
          fields: const <String, String>{},
          source: AnkiMiningSource.game,
          clipStartMs: 0,
          clipEndMs: 0,
          sentence: 'テスト',
          imageMode: VideoMiningImageMode.videoClip,
          providedCoverBytes: Uint8List.fromList(<int>[0x47, 0x49, 0x46, 0x38]),
          providedCoverName: 'external_window.gif',
          providedAudioBytes: Uint8List.fromList(<int>[1, 2, 3]),
          providedAudioName: 'galgame_audio.aac',
          requireAudio: true,
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: temp.path,
        repo: repo,
      );
      expect(result.aborted, false);
      expect(repo.context!.synchronizedVideo, false);
      expect(repo.context!.sentenceAudioPath, endsWith('galgame_audio.aac'));
    },
  );

  // 用户报告（Kiku 模板）：同步片段卡 Picture 是 <video>、句子音频是重播按钮，Kiku 只认
  // <img> / [sound:]，卡上动图和音频都不见了。目标模板不原样渲染图片字段时，片段模式
  // 必须按动图模式出卡：动图封面 + 独立句子音频，且根本不去导出同步片段。
  for (final String template in <String>[
    _kikuLikeBack,
    File(
      '../packages/fushi_anki/test/fixtures/kiku/release-back.html',
    ).readAsStringSync(),
    File(
      '../packages/fushi_anki/test/fixtures/kiku/v1-back.html',
    ).readAsStringSync(),
  ]) {
    test(
      'scripted template ${template.length} gets animated cover + audio',
      () async {
        final _TemplateRepo kiku = _TemplateRepo(template);
        final List<String> gifCalls = <String>[];
        int syncCalls = 0;
        final ImmersionMiningResult result =
            await ImmersionMiningEngine(
              gifExtractor:
                  ({
                    required String inputPath,
                    required int startMs,
                    required int endMs,
                    required String outputPath,
                    int fps = 8,
                    int width = 320,
                    MiningAnimatedFormat format = MiningAnimatedFormat.gif,
                    bool diagnosticOnly = false,
                    FfmpegFailureReporter? onFailure,
                    String? tlsPinSha256,
                    Map<String, String> httpHeaders = const <String, String>{},
                  }) async {
                    gifCalls.add(outputPath);
                    await File(
                      outputPath,
                    ).writeAsBytes(<int>[0x47, 0x49, 0x46, 0x38]);
                    return outputPath;
                  },
              synchronizedVideoExtractor:
                  ({
                    required String videoPath,
                    required String audioPath,
                    required int startMs,
                    required int endMs,
                    required String outputPath,
                    required String? tlsPinSha256,
                    required Map<String, String> httpHeaders,
                    required MiningClipFormat format,
                  }) async {
                    syncCalls++;
                    await File(outputPath).writeAsBytes(<int>[9, 8, 7]);
                    return VideoClipExportResult.success(outputPath);
                  },
            ).mine(
              request(),
              compression: MiningMediaCompression.compressed,
              tempDir: temp.path,
              repo: kiku,
            );
        expect(result.aborted, false);
        expect(kiku.definitionReads, 1);
        expect(syncCalls, 0);
        expect(gifCalls, hasLength(1));
        expect(kiku.context!.synchronizedVideo, false);
        expect(kiku.context!.coverPath, endsWith('.gif'));
        expect(kiku.context!.sentenceAudioPath, isNotNull);
        expect(kiku.context!.sentenceAudioPath, isNot(kiku.context!.coverPath));
      },
    );
  }

  test(
    'template that renders Picture raw keeps the synchronized clip',
    () async {
      final _TemplateRepo lapisLike = _TemplateRepo(
        '<div class="image">{{Picture}}</div>',
      );
      final ImmersionMiningResult result =
          await ImmersionMiningEngine(
            synchronizedVideoExtractor:
                ({
                  required String videoPath,
                  required String audioPath,
                  required int startMs,
                  required int endMs,
                  required String outputPath,
                  required String? tlsPinSha256,
                  required Map<String, String> httpHeaders,
                  required MiningClipFormat format,
                }) async {
                  await File(outputPath).writeAsBytes(<int>[9, 8, 7]);
                  return VideoClipExportResult.success(outputPath);
                },
          ).mine(
            request(),
            compression: MiningMediaCompression.compressed,
            tempDir: temp.path,
            repo: lapisLike,
          );
      expect(result.aborted, false);
      expect(lapisLike.definitionReads, 1);
      expect(lapisLike.context!.synchronizedVideo, true);
      expect(
        lapisLike.context!.sentenceAudioPath,
        lapisLike.context!.coverPath,
      );
    },
  );
}
