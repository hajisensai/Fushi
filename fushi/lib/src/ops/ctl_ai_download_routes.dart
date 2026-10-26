import 'package:flutter/widgets.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/sync/assistant/host_assistant.dart';

import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart';
import 'package:fushi/src/media/acquisition/media_acquisition_backends.dart';
import 'package:fushi/src/media/downloads/download_start_result.dart';
import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show fushiBooksProvider, srtBooksProvider;
import 'package:fushi/src/media/video/acquisition/app_video_acquisition_assembly.dart'
    show createVideoAcquisitionAssistantHost;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/ai_media_acquisition_page.dart'
    show mediaAcquisitionBackendsFor;
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart'
    show OnlineSourcesDomain, visibleOnlineSourcesDomains;
import 'package:fushi/src/ops/ctl_ai_download_session.dart';
import 'package:fushi/src/ops/ctl_online_routes.dart'
    show startCtlNovelDownloadTask;
import 'package:fushi/src/ops/ctl_online_support.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/utils.dart' show createAppHttpClient;

/// 「AI 下载」会话路由（CLI 侧命令见 `packages/fushi_cli/lib/src/commands/ai_download_commands.dart`）。
///
/// 会话种类与门控都与 app 入口同一判据：
///
/// - `video`：首页「AI 下视频」的组合根 [createVideoAcquisitionAssistantHost]（互联
///   host 代办手机请求用的也是它）——能力门（合规 / 浏览模块 / AI 模块 / 提供商 /
///   下载就绪）由它自己判，开不了回稳定短码；
/// - `novel` / `manga` / `game`：发现页「AI 下载」按钮的门（偏好就绪 + 下载 / 外部
///   发现两项合规 + AI 模块）+ 提供商指派，后端用页面同一个
///   [mediaAcquisitionBackendsFor]，在线来源是否参与同「来源」页签的门。
///
/// [open] 只给测试注入假会话；生产按上面的门与组合根开会话。
List<CtlRoute> buildAiDownloadCtlRoutes(
  OpContext context, {
  @visibleForTesting CtlAiDownloadOpener? open,
}) {
  final _AiDownloadCtl ctl = _AiDownloadCtl(context, open);
  return <CtlRoute>[
    CtlRoute.get('/api/admin/ai-download/sessions', ctl.list),
    CtlRoute.post('/api/admin/ai-download/sessions', ctl.start),
    CtlRoute.get('/api/admin/ai-download/sessions/:id', ctl.status),
    CtlRoute.delete('/api/admin/ai-download/sessions/:id', ctl.close),
    CtlRoute.post('/api/admin/ai-download/sessions/:id/say', ctl.say),
    CtlRoute.post('/api/admin/ai-download/sessions/:id/choose', ctl.choose),
    CtlRoute.post('/api/admin/ai-download/sessions/:id/confirm', ctl.confirm),
    CtlRoute.post('/api/admin/ai-download/sessions/:id/cancel', ctl.cancel),
    CtlRoute.post('/api/admin/ai-download/sessions/:id/restart', ctl.restart),
    CtlRoute.post(
      '/api/admin/ai-download/sessions/:id/franchise',
      ctl.toggleFranchise,
    ),
  ];
}

class _AiDownloadCtl {
  _AiDownloadCtl(this.context, CtlAiDownloadOpener? open) {
    sessions = CtlAiDownloadSessions(open ?? _open);
  }

  final OpContext context;
  late final CtlAiDownloadSessions sessions;

  AppModel get appModel => context.appModel;

  // ── 开会话 ──────────────────────────────────────────────────────────────

  Future<HostAssistantSession> _open(CtlAiDownloadFeature feature) {
    final AiMediaAcquisitionDomain? domain = feature.mediaDomain;
    if (domain == null) {
      return createVideoAcquisitionAssistantHost(
        appModel,
      ).open(kHostAssistantFeatureVideoAcquire, locale: '');
    }
    return Future<HostAssistantSession>.value(_openMedia(domain));
  }

  /// 发现页「AI 下载」按钮同一组门（`discoveryAiAcquireAction`）+ 提供商指派
  /// （`openAiMediaAcquisition` 在未指派时引导去设置，这里回 422 说明去哪配）。
  HostAssistantSession _openMedia(AiMediaAcquisitionDomain domain) {
    if (!appModel.isPreferencesReady ||
        !StoreRestrictedCapability.downloads.isAvailable ||
        !StoreRestrictedCapability.externalDiscovery.isAvailable ||
        !isAiModuleEnabled(appModel.moduleVisibility)) {
      throw const HostAssistantUnavailable('disabled');
    }
    if (resolveMediaAcquireAiProvider(appModel.prefsRepo) == null) {
      throw const HostAssistantUnavailable('no_provider');
    }
    final OnlineSourcesDomain? onlineDomain = switch (domain) {
      AiMediaAcquisitionDomain.novel => OnlineSourcesDomain.novel,
      AiMediaAcquisitionDomain.manga => OnlineSourcesDomain.manga,
      AiMediaAcquisitionDomain.game => null,
    };
    return CtlMediaAcquisitionSession(
      domain: domain,
      ai: createPreferencesAiMediaAcquisitionAi(appModel.prefsRepo),
      backends: mediaAcquisitionBackendsFor(
        appModel: appModel,
        domain: domain,
        includeOnlineSources:
            onlineDomain != null &&
            visibleOnlineSourcesDomains(
              appModel.moduleVisibility,
            ).contains(onlineDomain),
      ),
      acquire: _acquire,
      cancelTask: (String taskId) {
        try {
          CtlOnlineTaskRegistry.instance.cancel(taskId);
        } on CtlFailure {
          // 任务已结束 / 已被淘汰：没有可取消的东西。
        }
      },
    );
  }

  /// 确认一条候选：小说插件候选走 CLI 的可查进度 / 可取消整本下载（与
  /// `source dl --kind novel` 同一处，不弹 app 内对话框）；其余候选调页面同一个
  /// `backend.acquire`（发现源 → 下载中心自动入库；Mihon → 加入书架 + 未锁章节入队），
  /// 它可能弹 app 内确认，所以先把主窗口带到前台。
  Future<CtlMediaAcquireOutcome> _acquire(
    MediaAcquisitionCandidate candidate,
  ) async {
    final Object payload = candidate.payload;
    if (payload is LnReaderAcquisitionHit) {
      final LnReaderNovel novel;
      await appModel.lnReaderManager.load(payload.plugin);
      novel = await appModel.lnReaderManager.runtime.novel(
        payload.plugin.id,
        payload.item.path,
      );
      if (novel.chapters.isEmpty) {
        return const CtlMediaAcquireOutcome(started: false, message: '作品没有章节');
      }
      final CtlOnlineTask task = startCtlNovelDownloadTask(
        download: LnReaderBookDownload(
          manager: appModel.lnReaderManager,
          database: appModel.database,
          httpClientFactory: createAppHttpClient,
        ),
        plugin: payload.plugin,
        novel: novel,
        chapters: novel.chapters,
        onShelfChanged: () {
          context.ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
          context.ref.invalidate(srtBooksProvider);
        },
      );
      return CtlMediaAcquireOutcome(
        started: true,
        taskId: task.id,
        message:
            '整本 ${novel.chapters.length} 章（fushi_cli source task ${task.id}）',
      );
    }
    await context.focusMainWindow();
    final BuildContext? buildContext = context.navigator?.context;
    if (buildContext == null || !buildContext.mounted) {
      return const CtlMediaAcquireOutcome(started: false, message: '主窗口尚未就绪');
    }
    final DownloadStartResult result = await candidate.backend.acquire(
      buildContext,
      candidate,
    );
    return CtlMediaAcquireOutcome(
      started: result.started,
      message: result.started ? result.summary : result.failureReason,
    );
  }

  // ── 路由 ────────────────────────────────────────────────────────────────

  Future<Object?> list(CtlCall call) async => <String, Object?>{
    'sessions': await sessions.list(),
  };

  Future<Object?> start(CtlCall call) async {
    final CtlAiDownloadFeature feature = CtlAiDownloadFeature.parse(
      call.requireString('domain'),
    );
    final String text = call.requireString('text');
    final Map<String, Object?> envelope = await sessions.start(feature, text);
    return _maybeWait(call, envelope);
  }

  /// `wait`（秒）> 0 时等会话不忙再回（搜作品 / 搜资源要几秒到几十秒）。
  Future<Map<String, Object?>> _maybeWait(
    CtlCall call,
    Map<String, Object?> envelope,
  ) async {
    final int wait = call.optInt('wait') ?? 0;
    if (wait <= 0) return envelope;
    return sessions.read('${envelope['id']}', wait: Duration(seconds: wait));
  }

  Future<Object?> status(CtlCall call) async {
    final int wait = call.optInt('wait') ?? 0;
    return sessions.read(
      call.params['id']!,
      wait: Duration(seconds: wait < 0 ? 0 : wait),
    );
  }

  Future<Object?> close(CtlCall call) async {
    final String id = call.params['id']!;
    if (!await sessions.close(id)) {
      throw CtlFailure.notFound('没有这个会话：$id');
    }
    return null;
  }

  Future<Object?> say(CtlCall call) async => _maybeWait(
    call,
    await sessions.act(call.params['id']!, <String, Object?>{
      'type': 'text',
      'text': call.requireString('text'),
    }),
  );

  /// 消歧：视频按当前问题的选项作答；AI 下载按序号 / id 选定候选。
  Future<Object?> choose(CtlCall call) async {
    final String id = call.params['id']!;
    final List<String> answers = call.stringList('answers');
    if (answers.isEmpty) throw const CtlFailure.badRequest('answers 缺失');
    final CtlAiDownloadSessionInfo info = sessions.info(id);
    final Map<String, Object?> action;
    if (info.feature == CtlAiDownloadFeature.video) {
      if (answers.length != 1) {
        throw const CtlFailure.badRequest('视频会话一次回答一个问题');
      }
      final Map<String, Object?> current = await sessions.read(id);
      try {
        action = resolveCtlVideoChoice(
          (current['view'] as Map<Object?, Object?>?)
                  ?.cast<String, Object?>() ??
              const <String, Object?>{},
          answers.single,
          remember: call.optBool('remember'),
        );
      } on StateError catch (error) {
        throw CtlFailure.conflict(error.message);
      } on ArgumentError catch (error) {
        throw CtlFailure.badRequest('${error.message}');
      }
    } else {
      action = <String, Object?>{'type': 'choose', 'optionIds': answers};
    }
    return _maybeWait(call, await sessions.act(id, action));
  }

  Future<Object?> confirm(CtlCall call) async => _maybeWait(
    call,
    await sessions.act(call.params['id']!, const <String, Object?>{
      'type': 'confirm',
    }),
  );

  Future<Object?> cancel(CtlCall call) async => sessions.act(
    call.params['id']!,
    const <String, Object?>{'type': 'cancel'},
  );

  Future<Object?> restart(CtlCall call) async => sessions.act(
    call.params['id']!,
    const <String, Object?>{'type': 'restart'},
  );

  /// 视频「整个系列」清单里勾 / 取消一部（1 起序号）。
  Future<Object?> toggleFranchise(CtlCall call) async {
    final String id = call.params['id']!;
    if (sessions.info(id).feature != CtlAiDownloadFeature.video) {
      throw const CtlFailure.badRequest('只有视频会话有系列清单');
    }
    final int? index = call.optInt('index');
    if (index == null || index < 1) {
      throw const CtlFailure.badRequest('index 从 1 开始');
    }
    return sessions.act(id, <String, Object?>{
      'type': 'toggleFranchise',
      'index': index - 1,
    });
  }
}
