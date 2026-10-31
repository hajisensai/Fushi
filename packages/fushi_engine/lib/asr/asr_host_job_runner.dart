/// `kind = asr`：把一段音频/视频转成 SRT（+ 逐 token 时间 sidecar）。
///
/// 参数：
/// - `language`（必填）：`AsrLanguage.tag`（`ja` / `en` / `zh` …）；
/// - `input`（可选）：只转这一个输入文件；缺省时转**全部**输入（上传的 + host 本地
///   按内容哈希命中的，见 `HostJobContext.hostInputs`），按输入名排序 = 客户端提交
///   顺序（多文件有声书）。此前缺省只取排序后的第一个，多文件有声书在 host 上只转了
///   第一个文件；
/// - `videoId`（可选）：改用 host 库里的视频（经注入的 [resolveVideoPath]）；
/// - `audioProfile`（可选）：`cleanSpeech`（有声书朗读）/ `mixedAudio`（视频混音）。
///   缺省时按输入判：`videoId` 或视频扩展名 → `mixedAudio`，其余 → `cleanSpeech`。
///   此前服务工厂无参、两端都写死 `cleanSpeech`，视频转写永远走不到 Parakeet
///   滑窗（spec `2026-10-19-video-asr-llm-subtitle-pipeline` P0）。
///
/// 产物：`transcript.srt`（primary）、`transcript.tokens.jsonl`（有则带）。
/// 与本机链路产物完全一致，客户端拿回去走既有 SRT 导入（`attachAsrCueTokenTiming`
/// 挂 token 时间）。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:path/path.dart' as p;

class AsrHostJobRunner implements HostJobRunner {
  AsrHostJobRunner({
    required this.serviceFactory,
    this.resolveVideoPath,
    this.preference = asr.AsrAccelerationPreference.auto,
  });

  /// 每个任务按素材新建一份服务（隔离 isolate 生命周期）。素材是服务实例级
  /// 字段（任务目录哈希也含它），所以由任务参数决定、不能在装配时写死。
  final asr.AsrTranscriptionService Function(asr.AsrAudioProfile profile)
      serviceFactory;

  /// `videoId` → 本机视频文件路径（host 库）；null = 不支持 videoId。
  final Future<String?> Function(String videoId)? resolveVideoPath;
  final asr.AsrAccelerationPreference preference;

  @override
  String get kind => 'asr';

  @override
  Future<Map<String, Object?>> capability() async {
    final asr.AsrTranscriptionService service =
        serviceFactory(asr.AsrAudioProfile.cleanSpeech);
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
      'audioProfiles': <String>[
        for (final asr.AsrAudioProfile profile in asr.AsrAudioProfile.values)
          profile.name,
      ],
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
    final String? profile = params['audioProfile']?.toString();
    if (profile != null &&
        profile.isNotEmpty &&
        parseAsrAudioProfile(profile) == null) {
      throw FormatException('asr: unsupported audioProfile "$profile"');
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
    final _ResolvedAudio audio = await _resolveAudio(ctx);
    final List<String> audioPaths = audio.paths;
    final asr.AsrAudioProfile profile = asrAudioProfileForJob(
      explicit: ctx.params['audioProfile']?.toString(),
      fromLibraryVideo: (ctx.params['videoId']?.toString() ?? '').isNotEmpty,
      path: audioPaths.first,
    );
    final asr.AsrTranscriptionService service = serviceFactory(profile);
    final asr.AsrTranscribePlan plan =
        await service.plan(language: language, preference: preference);
    if (!plan.modelReady) {
      throw StateError(
        'asr models for ${language.tag} are not downloaded on this host '
        '(run `fushi_server models pull --language ${language.tag}`)',
      );
    }
    // 输入是 host 库里的文件（库视频 / 按哈希命中的有声书音频）时，转录服务的任务
    // 目录与 host 自己在本机转这组文件时是同一个（目录哈希按路径算）。那份目录原本
    // 就在（host 用户自己转过 / 正在转）就不能在结束时删掉，否则把人家的转录稿一起
    // 删了；只有本任务新建的才当中间产物清掉。
    final bool keepServiceJobDir = audio.fromHostLibrary &&
        await (await service.jobDirFor(audioPaths, language)).exists();
    ctx.onProgress(0, 'loading model');
    final asr.AsrRunningTranscription running = await service.start(
      audioPaths: audioPaths,
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
    // 成功后中间产物（segments/state）即弃：同一音频再来一次会重新转。取消 /
    // 进程重启时走不到这里，任务目录保留，HostJobManager 重跑同一任务即从断点续。
    if (!keepServiceJobDir) await service.discard(audioPaths, language);
    return HostJobOutcome(
      outputs: outputs,
      primaryOutput: asr.AsrJobFiles.srt,
      message: 'cues ${done.cueCount}',
    );
  }

  Future<_ResolvedAudio> _resolveAudio(HostJobContext ctx) async {
    final String? videoId = ctx.params['videoId']?.toString();
    if (videoId != null && videoId.isNotEmpty) {
      final Future<String?> Function(String)? resolve = resolveVideoPath;
      if (resolve == null) throw const FormatException('asr: videoId not supported on this host');
      final String? path = await resolve(videoId);
      if (path == null) throw FormatException('asr: unknown videoId $videoId');
      return _ResolvedAudio(<String>[path], fromHostLibrary: true);
    }
    final String? named = ctx.params['input']?.toString();
    final List<String> names = named != null && named.isNotEmpty
        ? <String>[named]
        : ctx.inputNames;
    if (names.isEmpty) throw const FormatException('asr: no input uploaded');
    final List<String> paths = <String>[];
    for (final String name in names) {
      final File f = ctx.input(name);
      if (!await f.exists()) throw FormatException('asr: input "$name" not uploaded');
      paths.add(f.path);
    }
    return _ResolvedAudio(
      paths,
      fromHostLibrary: names.any(ctx.isHostInput),
    );
  }
}

class _ResolvedAudio {
  const _ResolvedAudio(this.paths, {required this.fromHostLibrary});

  final List<String> paths;

  /// 至少有一个路径是 host 库里的文件（不在本任务的 inputs 目录里）。
  final bool fromHostLibrary;
}

/// `cleanSpeech` / `mixedAudio`（大小写不敏感）→ 枚举；认不出返回 null。
asr.AsrAudioProfile? parseAsrAudioProfile(String value) {
  final String v = value.trim().toLowerCase();
  for (final asr.AsrAudioProfile profile in asr.AsrAudioProfile.values) {
    if (profile.name.toLowerCase() == v) return profile;
  }
  return null;
}

/// 一次转录该用哪种素材档位：显式参数优先；否则 host 库里的视频或视频扩展名
/// → [asr.AsrAudioProfile.mixedAudio]，其余（有声书音频）→
/// [asr.AsrAudioProfile.cleanSpeech]（保持旧任务的哈希与行为）。
asr.AsrAudioProfile asrAudioProfileForJob({
  String? explicit,
  bool fromLibraryVideo = false,
  required String path,
}) {
  if (explicit != null && explicit.isNotEmpty) {
    final asr.AsrAudioProfile? parsed = parseAsrAudioProfile(explicit);
    if (parsed != null) return parsed;
  }
  if (fromLibraryVideo ||
      kVideoExtensions.contains(p.extension(path).toLowerCase())) {
    return asr.AsrAudioProfile.mixedAudio;
  }
  return asr.AsrAudioProfile.cleanSpeech;
}
