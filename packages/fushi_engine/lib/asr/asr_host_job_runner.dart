/// `kind = asr`：把一段音频/视频转成 SRT（+ 逐 token 时间 sidecar）。
///
/// 参数：
/// - `language`（必填）：`AsrLanguage.tag`（`ja` / `en` / `zh` …）；
/// - `input`（可选）：输入文件名（默认取上传的第一个）；
/// - `videoId`（可选）：改用 host 库里的视频（经注入的 [resolveVideoPath]）。
///
/// 产物：`transcript.srt`（primary）、`transcript.tokens.jsonl`（有则带）。
/// 与本机链路产物完全一致，客户端拿回去走既有 SRT 导入（`attachAsrCueTokenTiming`
/// 挂 token 时间）。
library;

import 'dart:async';
import 'dart:io';

import 'package:asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:path/path.dart' as p;

class AsrHostJobRunner implements HostJobRunner {
  AsrHostJobRunner({
    required this.serviceFactory,
    this.resolveVideoPath,
    this.preference = asr.AsrAccelerationPreference.auto,
  });

  /// 每个任务新建一份服务（隔离 isolate 生命周期）。
  final asr.AsrTranscriptionService Function() serviceFactory;

  /// `videoId` → 本机视频文件路径（host 库）；null = 不支持 videoId。
  final Future<String?> Function(String videoId)? resolveVideoPath;
  final asr.AsrAccelerationPreference preference;

  @override
  String get kind => 'asr';

  @override
  Future<Map<String, Object?>> capability() async {
    final asr.AsrTranscriptionService service = serviceFactory();
    final Map<String, Object?> models = <String, Object?>{};
    for (final asr.AsrLanguage language in asr.AsrLanguage.registered) {
      try {
        final asr.AsrTranscribePlan plan =
            await service.plan(language: language, preference: preference);
        models[language.tag] = <String, Object?>{
          'ready': plan.modelReady,
          'variant': plan.variant.name,
          'provider': plan.expectedProvider.name,
        };
      } catch (_) {
        models[language.tag] = <String, Object?>{'ready': false};
      }
    }
    return <String, Object?>{
      'supported': asr.isLocalOnnxRuntimeAvailable,
      'languages': models,
      'acceptsVideoId': resolveVideoPath != null,
      'outputs': <String>[asr.AsrJobFiles.srt, asr.AsrJobFiles.cueTokens],
    };
  }

  @override
  void validateParams(Map<String, Object?> params) {
    final String? tag = params['language']?.toString();
    if (tag == null || tag.isEmpty) {
      throw const FormatException('asr: params.language is required');
    }
    if (asr.AsrLanguage.fromBookLanguage(tag) == null) {
      throw FormatException('asr: unsupported language "$tag"');
    }
  }

  @override
  String contentTypeFor(String outputName) {
    if (outputName.endsWith('.srt')) return 'application/x-subrip; charset=utf-8';
    if (outputName.endsWith('.jsonl')) return 'application/x-ndjson';
    return 'application/octet-stream';
  }

  @override
  Future<HostJobOutcome> run(HostJobContext ctx) async {
    final asr.AsrLanguage language =
        asr.AsrLanguage.fromBookLanguage(ctx.params['language'].toString())!;
    final String audioPath = await _resolveAudio(ctx);
    final asr.AsrTranscriptionService service = serviceFactory();
    final asr.AsrTranscribePlan plan =
        await service.plan(language: language, preference: preference);
    if (!plan.modelReady) {
      throw StateError(
        'asr models for ${language.tag} are not downloaded on this host '
        '(run `fushi_server models pull --language ${language.tag}`)',
      );
    }
    ctx.onProgress(0, 'loading model');
    final asr.AsrRunningTranscription running = await service.start(
      audioPaths: <String>[audioPath],
      language: language,
      variant: plan.variant,
      preference: preference,
    );
    ctx.cancel.onCancel(running.requestPause);
    asr.AsrTranscribeResult? result;
    try {
      await for (final asr.AsrTranscribeEvent e in running.run()) {
        switch (e) {
          case asr.AsrTranscribeProgressEvent(progress: final asr.AsrTranscribeProgress pr):
            ctx.onProgress(pr.fraction ?? 0, 'transcribing');
          case asr.AsrTranscribePausedEvent():
            if (ctx.cancel.isCancelled) throw const HostJobCancelledException();
          case asr.AsrTranscribeFinishedEvent(result: final asr.AsrTranscribeResult r):
            result = r;
        }
      }
    } finally {
      await running.dispose();
    }
    if (ctx.cancel.isCancelled) throw const HostJobCancelledException();
    final asr.AsrTranscribeResult done = result ??
        (throw StateError('asr transcription ended without a result'));
    final File srt = File(done.srtPath);
    await srt.copy(ctx.output(asr.AsrJobFiles.srt).path);
    final Map<String, String> outputs = <String, String>{
      asr.AsrJobFiles.srt: asr.AsrJobFiles.srt,
    };
    final File tokens = File(p.join(p.dirname(done.srtPath), asr.AsrJobFiles.cueTokens));
    if (await tokens.exists()) {
      await tokens.copy(ctx.output(asr.AsrJobFiles.cueTokens).path);
      outputs[asr.AsrJobFiles.cueTokens] = asr.AsrJobFiles.cueTokens;
    }
    // 服务端的中间产物（segments/state）用完即弃：同一音频再来一次会重新转。
    await service.discard(<String>[audioPath], language);
    return HostJobOutcome(
      outputs: outputs,
      primaryOutput: asr.AsrJobFiles.srt,
      message: 'cues ${done.cueCount}',
    );
  }

  Future<String> _resolveAudio(HostJobContext ctx) async {
    final String? videoId = ctx.params['videoId']?.toString();
    if (videoId != null && videoId.isNotEmpty) {
      final Future<String?> Function(String)? resolve = resolveVideoPath;
      if (resolve == null) throw const FormatException('asr: videoId not supported on this host');
      final String? path = await resolve(videoId);
      if (path == null) throw FormatException('asr: unknown videoId $videoId');
      return path;
    }
    final String? named = ctx.params['input']?.toString();
    if (named != null && named.isNotEmpty) {
      final File f = ctx.input(named);
      if (!await f.exists()) throw FormatException('asr: input "$named" not uploaded');
      return f.path;
    }
    final List<File> uploaded = ctx.inputsDir
        .listSync()
        .whereType<File>()
        .toList()
      ..sort((File a, File b) => a.path.compareTo(b.path));
    if (uploaded.isEmpty) throw const FormatException('asr: no input uploaded');
    return uploaded.first.path;
  }
}
