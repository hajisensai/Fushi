import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';

import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_video_player_support.dart'
    show ctlVideoJobJson;
import 'package:fushi/src/ops/op_context.dart';

/// 「生成日语字幕」的控制通道路由（CLI：`fushi_cli video subtitle-gen` /
/// `video subtitle-glossary`，见 `packages/fushi_cli/lib/src/commands/video_subtitle_commands.dart`）。
///
/// 与视频页面板、合集页整季走**同一个** [AppVideoSubtitleService]（同一张任务表、
/// 同一把「同时只跑一个」的门、同一个专名表存储）。提交即返回任务号，进度 / 取消
/// 用现有的 `video job <id> [--wait]` / `video job-cancel <id>`（任务登记在
/// [videoRemoteJobs]，种类 `subtitleGenerate`）。
List<CtlRoute> buildVideoSubtitleCtlRoutes(OpContext context) {
  AppModel appModel() => context.appModel;
  final CtlVideoSubtitleHandlers handlers = CtlVideoSubtitleHandlers(
    service: () => appVideoSubtitleService(appModel()),
    consented: () => appModel().prefsRepo.videoSubtitleAiConsented,
    acceptConsent: () => appModel().prefsRepo.setVideoSubtitleAiConsented(true),
    defaultSegmenter: () => appModel().prefsRepo.videoSubtitleSegmenter,
    defaultMossBackend: () => appModel().prefsRepo.videoSubtitleMossBackend,
    videoModuleEnabled: () =>
        appModel().moduleVisibility.isEnabled(ModuleId.video),
  );
  return <CtlRoute>[
    CtlRoute.post(kCtlVideoSubtitleGenPath, handlers.generate),
    CtlRoute.get(kCtlVideoSubtitleGlossaryPath, handlers.glossary),
    CtlRoute.put(kCtlVideoSubtitleGlossaryPath, handlers.setGlossary),
  ];
}

const String kCtlVideoSubtitleGenPath = '/api/admin/video/subtitle-gen';
const String kCtlVideoSubtitleGlossaryPath =
    '/api/admin/video/subtitle-glossary';

/// 路由处理器（依赖全部注入，测试不需要 AppModel）。
class CtlVideoSubtitleHandlers {
  CtlVideoSubtitleHandlers({
    required this.service,
    required this.consented,
    required this.acceptConsent,
    required this.defaultSegmenter,
    required this.defaultMossBackend,
    required this.videoModuleEnabled,
    this.asrSupported,
  });

  final AppVideoSubtitleService Function() service;
  final bool Function() consented;
  final Future<void> Function() acceptConsent;
  final VideoSubtitleSegmenterMode Function() defaultSegmenter;
  final MossBackendPreference Function() defaultMossBackend;
  final bool Function() videoModuleEnabled;

  /// 测试注入；null = 读本平台的 [isAsrSupported]。
  final bool Function()? asrSupported;

  void _requireVideoModule() {
    if (!videoModuleEnabled()) {
      throw const CtlFailure.rejected('「视频」模块已关闭（设置 › 功能模块）');
    }
  }

  /// `bookUid` 与 `collectionId` 恰好给一个。
  Future<AppVideoSubtitleTarget> _target(CtlCall call) async {
    final String? bookUid = call.optString('bookUid');
    final int? collectionId = call.optInt('collectionId');
    if ((bookUid == null) == (collectionId == null)) {
      throw const CtlFailure.badRequest('bookUid 与 collectionId 必须且只能给一个');
    }
    try {
      return bookUid != null
          ? await service().resolveBook(bookUid)
          : await service().resolveCollection(collectionId!);
    } on AppVideoSubtitleTargetNotFound catch (e) {
      throw CtlFailure.notFound('没有${e.what}（library ls / collection ls 查 id）');
    }
  }

  static T _parseEnum<T extends Enum>(
    List<T> values,
    String? raw,
    String name,
    T fallback,
  ) {
    if (raw == null) return fallback;
    for (final T v in values) {
      if (v.name == raw.toLowerCase()) return v;
    }
    throw CtlFailure.badRequest(
      '$name 取 ${values.map((T v) => v.name).join(' | ')}',
    );
  }

  /// `video subtitle-gen`：提交生成任务（缺省 AI 校对开；`proofread=false` 只做
  /// 识别 + 拆分 + 导出）。
  Future<Object?> generate(CtlCall call) async {
    _requireVideoModule();
    if (!(asrSupported?.call() ?? isAsrSupported)) {
      throw const CtlFailure.unsupported('本平台构建没有设备端语音转录');
    }
    final AppVideoSubtitleTarget target = await _target(call);
    final bool proofread = call.optBool('proofread') ?? true;
    final AppVideoSubtitleService svc = service();
    if (proofread) {
      if (svc.proofreadProvider == null) {
        throw const CtlFailure.rejected(
          '没有为「字幕校对」指派 AI 提供商：在 设置 › 模型 › LLM 指派（fushi_cli ai assign），'
          '或加 --no-ai 只做识别',
        );
      }
      if (!consented()) {
        if (call.optBool('consentAi') != true) {
          throw const CtlFailure.rejected(
            'AI 校对会把 ASR 识别出的日语文本与本作专名表发给所选提供商（不发音频与画面，'
            '按提供商计费）。同意请加 --consent-ai（只需一次），或加 --no-ai',
          );
        }
        await acceptConsent();
      }
    }
    final AppVideoSubtitleOptions options = AppVideoSubtitleOptions(
      proofread: proofread,
      segmenter: _parseEnum(
        VideoSubtitleSegmenterMode.values,
        call.optString('segmenter'),
        'segmenter',
        defaultSegmenter(),
      ),
      mossBackend: _parseEnum(
        MossBackendPreference.values,
        call.optString('mossBackend'),
        'mossBackend',
        defaultMossBackend(),
      ),
      regenerateGlossary: call.optBool('regenerateGlossary') ?? false,
    );
    final AppVideoSubtitleJob job;
    try {
      job = svc.start(target, options);
    } on AppVideoSubtitleStartRefused catch (refused) {
      throw switch (refused.problem) {
        AppVideoSubtitleStartProblem.busy => CtlFailure.conflict(
          '已有生成任务在跑：${refused.activeJob?.mirror.id} '
          '${refused.activeJob?.target.title}（video job <id> 看进度）',
        ),
        AppVideoSubtitleStartProblem.noProvider => const CtlFailure.rejected(
          '没有为「字幕校对」指派 AI 提供商',
        ),
        AppVideoSubtitleStartProblem.noLocalEpisodes => CtlFailure.rejected(
          '没有本机可处理的视频文件'
          '${target.unavailable.isEmpty ? '' : '：${target.unavailable.map((AppVideoSubtitleUnavailable u) => '${u.title}（${u.reason.name}）').join('、')}'}',
        ),
        AppVideoSubtitleStartProblem.nothingToRerun =>
          const CtlFailure.rejected('还没有任何一集跑过校对'),
      };
    }
    if (call.optBool('wait') == true) {
      await job.done;
      if (job.status != AppVideoSubtitleJobStatus.succeeded) {
        final VideoRemoteJob mirror = job.mirror;
        throw CtlFailure(
          job.status == AppVideoSubtitleJobStatus.cancelled ? 409 : 422,
          mirror.errorCode ?? job.status.name,
          '${mirror.id} ${mirror.error ?? job.status.name}',
        );
      }
    }
    return <String, Object?>{
      ...ctlVideoJobJson(job.mirror),
      'title': target.title,
      'episodes': target.episodes.length,
      if (target.missingScrapedData) 'scrapeHint': true,
    };
  }

  Map<String, Object?> _glossaryJson(
    AppVideoSubtitleTarget target,
    SubtitleGlossary? glossary,
  ) => <String, Object?>{
    'workKey': target.work.workKey,
    'title': target.title,
    'japaneseTitle': target.work.japaneseTitle,
    'hasScrapedData': target.work.hasScrapedData,
    'entries': <Map<String, Object?>>[
      for (final SubtitleGlossaryEntry e
          in glossary?.entries ?? const <SubtitleGlossaryEntry>[])
        e.toJson(),
    ],
    if (glossary?.generatedAt != null) 'generatedAt': glossary!.generatedAt,
    if (glossary?.userEditedAt != null) 'userEditedAt': glossary!.userEditedAt,
  };

  /// `video subtitle-glossary <bookUid|--collection id>`：读作品专名表。
  Future<Object?> glossary(CtlCall call) async {
    _requireVideoModule();
    final AppVideoSubtitleTarget target = await _target(call);
    return _glossaryJson(target, await service().loadGlossary(target.work));
  }

  /// `video subtitle-glossary … --set <json>`：整表替换（改过 / 新增的条目标
  /// `userEdited`，重新生成时保留）。
  Future<Object?> setGlossary(CtlCall call) async {
    _requireVideoModule();
    final AppVideoSubtitleTarget target = await _target(call);
    final Object? raw = call.body['entries'];
    if (raw is! List) {
      throw const CtlFailure.badRequest('entries 必须是条目数组');
    }
    final List<SubtitleGlossaryEntry> entries = <SubtitleGlossaryEntry>[];
    for (final Object? item in raw) {
      if (item is! Map) {
        throw const CtlFailure.badRequest('entries 的每一项必须是对象');
      }
      final SubtitleGlossaryEntry entry = SubtitleGlossaryEntry.fromJson(
        item.cast<String, Object?>(),
      );
      if (entry.ja.isEmpty) {
        throw const CtlFailure.badRequest('条目缺正式写法 ja');
      }
      entries.add(entry);
    }
    final Set<String> seen = <String>{};
    for (final SubtitleGlossaryEntry e in entries) {
      if (!seen.add(e.ja)) {
        throw CtlFailure.badRequest('正式写法重复：${e.ja}');
      }
    }
    final AppVideoSubtitleService svc = service();
    final SubtitleGlossary saved = await svc.saveGlossary(
      target.work,
      entries,
      previous: await svc.loadGlossary(target.work),
    );
    return _glossaryJson(target, saved);
  }
}
