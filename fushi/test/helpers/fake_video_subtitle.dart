/// 视频字幕管线 app 层测试共用的替身（服务 / 面板 / 专名表页 / ctl 路由）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_model_ports.dart';
import 'package:fushi_asr_core/asr_core.dart' show ModelDownloadEvent;
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:path/path.dart' as p;

import 'fake_ai_text_completer.dart';

/// 识别器替身：每个视频给 4 句稿。
class FakeVideoRecognizer implements VideoSubtitleRecognizer {
  FakeVideoRecognizer({this.id = 'sliding_mixed'});

  @override
  final String id;
  final List<String> calls = <String>[];

  @override
  Future<List<SubtitleDraftCue>> recognize({
    required String videoPath,
    required Directory workDir,
    required VideoSubtitleRecognizeProgress onProgress,
    required SubtitleCancelToken cancel,
  }) async {
    calls.add(p.basename(videoPath));
    onProgress(0.5, 'half');
    return <SubtitleDraftCue>[
      for (int i = 0; i < 4; i++)
        SubtitleDraftCue(
          startMs: 1000 + i * 3000,
          endMs: 3000 + i * 3000,
          text: <String>['結衣が来た', 'こんにちは', 'ありがとう', 'またね'][i],
        ),
    ];
  }
}

class FakeVideoSubtitleSettings implements AppVideoSubtitleSettings {
  AiProviderConfig? provider;

  @override
  AiProviderConfig? get proofreadProvider => provider;

  @override
  List<WebKnowledgeSite> get webKnowledgeSites => const <WebKnowledgeSite>[];
}

class MemoryGlossaryStore implements SubtitleGlossaryStore {
  final Map<String, SubtitleGlossary> rows = <String, SubtitleGlossary>{};

  @override
  Future<SubtitleGlossary?> load(String workKey) async => rows[workKey];

  @override
  Future<void> save(String workKey, SubtitleGlossary glossary) async =>
      rows[workKey] = glossary;
}

class ReadyModels implements VideoSubtitleAsrModelPort, VideoSubtitleMossPort {
  const ReadyModels();

  @override
  Future<bool> isReady() async => true;

  @override
  Stream<ModelDownloadEvent> download() =>
      const Stream<ModelDownloadEvent>.empty();

  @override
  Future<VideoSubtitleMossState> status(MossBackendPreference backend) async =>
      const VideoSubtitleMossState(ready: true);

  @override
  Stream<ModelDownloadEvent> ensure(MossBackendPreference backend) =>
      const Stream<ModelDownloadEvent>.empty();
}

AiProviderConfig testProvider() => AiProviderConfig(
  id: 'p1',
  presetId: 'openai',
  name: 'Test AI',
  baseUrl: Uri.parse('https://example.invalid/v1'),
  model: 'm1',
);

/// 专名表 / 校对 / 写法统一都按提示词答出合法回复。
String answerAll(String prompt, int call) {
  if (prompt.contains('誤認識されやすい固有名詞の表')) {
    return jsonEncode(<Map<String, Object?>>[
      <String, Object?>{
        'ja': '唯',
        'reading': 'ゆい',
        'kind': '人名',
        'misrecognitions': <String>['結衣'],
      },
    ]);
  }
  final List<int> ids = targetIdsOf(prompt);
  if (ids.isNotEmpty) return replyForIds(prompt, (int id) => '唯が来た');
  final RegExp main = RegExp(r'^id=(\d+) \[[^\]]*\] 主: (.*)$', multiLine: true);
  return jsonEncode(<String, String>{
    for (final RegExpMatch m in main.allMatches(prompt))
      m.group(1)!: m.group(2)!,
  });
}
