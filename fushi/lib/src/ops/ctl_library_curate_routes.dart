import 'dart:async';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_media_link_assistant.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/library_curate/library_curator.dart';

import 'package:fushi/src/media/library_curate/library_curate_host.dart';
import 'package:fushi/src/media/library_curate/library_curate_link_ops.dart';
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_media_links_routes.dart'
    show parseMediaLinkEndpoint;
import 'package:fushi/src/ops/op_context.dart';

/// AI 库管家的控制通道路由（spec `docs/specs/2026-11-18-ai-library-curator-design.md`
/// §9）：CLI `library curate` / `curate-status` / `curate-runs` / `curate-undo` /
/// `curate-pending`（`packages/fushi_cli/lib/src/commands/library_commands.dart`），
/// AI 助手技能 `skill.curate_library`，设置页「立即整理」同一个编排器
/// （[libraryCuratorFor]，同一时刻只跑一趟）。
///
/// 另有两条 ④ 步的宿主操作（编排器经操作目录调它们，写操作照常记账、可撤销）：
/// `links/infer`（一批端点的关系推断）与 `links/music`（全库音乐关系批量推断）。
const String kLibraryCurateCtlRoot = '/api/admin/library/curate';

List<CtlRoute> buildLibraryCurateCtlRoutes(OpContext context) =>
    buildLibraryCurateCtlRoutesFor(
      curator: () => libraryCuratorFor(context),
      database: () => context.appModel.database,
      prefs: () => context.appModel.prefsRepo,
      aiModuleEnabled: () =>
          isAiModuleEnabled(context.appModel.moduleVisibility),
      isReadonly: () => context.appModel.isMigrationReadonly,
    );

/// 关系推断的外部依赖（测试注入离线桩；生产按「作品关联」指派现建）。
typedef LibraryCurateLinkDepsFactory =
    ({LibraryCurateLinkDeps deps, void Function() close}) Function(
      AiProviderConfig? provider,
      FushiDatabase db,
    );

/// 路由表本体：依赖按回调注入，测试不必起 [OpContext]。
List<CtlRoute> buildLibraryCurateCtlRoutesFor({
  required LibraryCurator Function() curator,
  required FushiDatabase Function() database,
  required PreferencesRepository Function() prefs,
  required bool Function() aiModuleEnabled,
  bool Function()? isReadonly,
  LibraryCurateLinkDepsFactory linkDeps = libraryCurateLinkDeps,
}) {
  void requireWritable() {
    if (isReadonly?.call() ?? false) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
    }
  }

  AiProviderConfig? linkProvider(bool wanted) =>
      wanted && aiModuleEnabled() ? resolveMediaLinkAiProvider(prefs()) : null;

  return <CtlRoute>[
    // 手动跑一趟（trigger = manual：中置信也生效、不设请求上限）。
    CtlRoute.post(kLibraryCurateCtlRoot, (CtlCall call) async {
      requireWritable();
      final PreferencesRepository p = prefs();
      final LibraryCurateAiAvailability ai = libraryCurateAiOf(
        p,
        aiModuleEnabled: aiModuleEnabled(),
      );
      final bool anyAi = ai.organize || ai.videoIdentify || ai.mediaLinks;
      // 「会发送什么」的同意与 AI 整理库共用一份（发出去的口径相同：标题、作者 /
      // 品牌、年份、卷 / 集数、视频文件夹末级名，spec §9）。一个 AI 都没指派时
      // 不发请求，也就不用同意。
      if (anyAi && !p.libraryOrganizeConsented) {
        if (call.optBool('yes') != true) {
          throw const CtlFailure.rejected(
            '会把标题、作者或品牌、年份、卷数 / 集数和视频文件夹名发给 AI 提供商'
            '（可能计费）；确认后加 --yes 再运行',
          );
        }
        await p.setLibraryOrganizeConsented(true);
      }
      final LibraryCurator c = curator();
      if (c.isRunning) {
        throw CtlFailure.conflict('已有一趟库管家在跑（#${c.current?.id ?? '?'}）');
      }
      final bool full = call.optBool('full') == true;
      if (call.optBool('wait') == false) {
        final Completer<LibraryCurateRun> started =
            Completer<LibraryCurateRun>();
        unawaited(
          c
              .run(
                trigger: LibraryCurateTrigger.manual,
                full: full,
                onStarted: started.complete,
              )
              .then<void>(
                (_) {},
                onError: (Object e) {
                  if (!started.isCompleted) started.completeError(e);
                },
              ),
        );
        final LibraryCurateRun run = await started.future;
        return <String, Object?>{'runId': run.id, 'status': 'running'};
      }
      final LibraryCurateRun run;
      try {
        run = await c.run(trigger: LibraryCurateTrigger.manual, full: full);
      } on LibraryCurateBusy catch (e) {
        throw CtlFailure.conflict('已有一趟库管家在跑（#${e.runId}）');
      }
      return libraryCurateRunJson(run);
    }),
    CtlRoute.get('$kLibraryCurateCtlRoot/estimate', (CtlCall call) async {
      final LibraryCurateEstimate e = await curator().estimate(
        full: call.optBool('full') == true,
      );
      return e.toJson();
    }),
    CtlRoute.get('$kLibraryCurateCtlRoot/status', (CtlCall call) async {
      final LibraryCurator c = curator();
      final LibraryCurateRun? current = c.current;
      final List<LibraryCurateRun> runs = await c.runs();
      return <String, Object?>{
        'running': c.isRunning,
        if (current != null) 'run': libraryCurateRunJson(current),
        if (c.currentStage != null) 'stage': c.currentStage!.wire,
        if (runs.isNotEmpty && runs.first.id != current?.id)
          'last': libraryCurateRunJson(runs.first),
        'auto': prefs().libraryCurateAuto,
      };
    }),
    CtlRoute.get('$kLibraryCurateCtlRoot/runs', (CtlCall call) async {
      final int limit = (call.optInt('limit') ?? 20).clamp(1, 200);
      return <String, Object?>{
        'runs': <Object?>[
          for (final LibraryCurateRun r in (await curator().runs()).take(limit))
            libraryCurateRunJson(r),
        ],
      };
    }),
    CtlRoute.post('$kLibraryCurateCtlRoot/runs/:id/undo', (CtlCall call) async {
      final int? id = int.tryParse(call.params['id'] ?? '');
      if (id == null || id <= 0) {
        throw const CtlFailure.badRequest('运行 id 必须是正整数');
      }
      requireWritable();
      try {
        return (await curator().undoRun(id)).toJson();
      } on LibraryCurateBusy {
        throw const CtlFailure.conflict('这一趟还在跑，跑完再撤销');
      }
    }),
    // 单条重试（待确认身份队列的「让 AI 重试」，BUG-5283）：对一个书 / 游戏刮削单元
    // 重跑刮削阶段。照常记一趟（手动、只含这一阶段），写入可整趟撤销；不推进水位。
    CtlRoute.post('$kLibraryCurateCtlRoot/scrape/retry', (CtlCall call) async {
      requireWritable();
      final LibraryCurateStage stage = switch (call.requireString('stage')) {
        'books' => LibraryCurateStage.scrapeBooks,
        'games' => LibraryCurateStage.scrapeGames,
        final String other => throw CtlFailure.badRequest(
          'stage 只能是 books / games：$other',
        ),
      };
      final String ref = call.requireString('ref');
      final PreferencesRepository p = prefs();
      final LibraryCurateAiAvailability ai = libraryCurateAiOf(
        p,
        aiModuleEnabled: aiModuleEnabled(),
      );
      if (ai.videoIdentify && !p.libraryOrganizeConsented) {
        if (call.optBool('yes') != true) {
          throw const CtlFailure.rejected(
            '会把标题、作者或品牌、年份、卷数发给 AI 提供商（可能计费）；'
            '确认后加 --yes 再运行',
          );
        }
        await p.setLibraryOrganizeConsented(true);
      }
      try {
        return libraryCurateRunJson(
          await curator().retryScrape(stage: stage, ref: ref),
        );
      } on LibraryCurateBusy catch (e) {
        throw CtlFailure.conflict('已有一趟库管家在跑（#${e.runId}）');
      }
    }),
    // 待确认：合集级建议（以用户身份接受 / 拒绝，见 library.organize.proposals）+
    // 最近几趟留下的待确认项（没认出来的视频作品、要用户确认才执行的操作）。
    CtlRoute.get('$kLibraryCurateCtlRoot/pending', (CtlCall call) async {
      final List<LibraryCurateRun> runs = await curator().runs();
      return <String, Object?>{
        'organizeProposals': <Object?>[
          for (final LibraryOrganizeProposalView v
              in await loadLibraryOrganizeProposals(database()))
            v.toJson(),
        ],
        'items': <Object?>[
          for (final LibraryCurateRun r in runs.take(5))
            if (r.undoneAt == null)
              for (final LibraryCuratePendingItem i in r.pendingItems)
                if (i.kind != 'organize_proposal')
                  <String, Object?>{'runId': r.id, ...i.toJson()},
        ],
      };
    }),
    // ④ 一批端点的关系推断（库管家内部步骤；撤销回执随结果返回）。
    CtlRoute.post('$kLibraryCurateCtlRoot/links/infer', (CtlCall call) async {
      requireWritable();
      final List<String> raw = call.stringList('items');
      if (raw.isEmpty) throw const CtlFailure.badRequest('items 缺失');
      if (raw.length > 50) {
        throw const CtlFailure.badRequest('一次最多 50 个条目');
      }
      final List<MediaLinkEndpoint> endpoints = <MediaLinkEndpoint>[
        for (final String e in raw) parseMediaLinkEndpoint(e),
      ];
      final ({LibraryCurateLinkDeps deps, void Function() close}) d = linkDeps(
        linkProvider(true),
        database(),
      );
      try {
        final LibraryCurateLinkResult r = await runLibraryCurateLinkInference(
          db: database(),
          endpoints: endpoints,
          trigger: libraryCurateLinkTrigger(call.optString('trigger')),
          deps: d.deps,
        );
        return r.toJson();
      } finally {
        d.close();
      }
    }),
    // ④ 全库音乐关系批量推断（声纹命中直接生效；标题 + 关键词经 AI 或写建议）。
    CtlRoute.post('$kLibraryCurateCtlRoot/links/music', (CtlCall call) async {
      requireWritable();
      final ({LibraryCurateLinkDeps deps, void Function() close}) d = linkDeps(
        linkProvider(call.optBool('useAi') != false),
        database(),
      );
      try {
        final LibraryCurateLinkResult r = await runLibraryCurateMusicInference(
          db: database(),
          trigger: libraryCurateLinkTrigger(call.optString('trigger')),
          judge: d.deps.judge,
        );
        return r.toJson();
      } finally {
        d.close();
      }
    }),
  ];
}

/// 一趟的线上形状（CLI / 设置页 / AI 助手共用）。
Map<String, Object?> libraryCurateRunJson(LibraryCurateRun run) => run.toJson();
