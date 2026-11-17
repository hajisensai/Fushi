import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_service.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/i18n/strings.g.dart';

/// AI 整理库的控制通道路由（spec `docs/specs/2026-10-20-ai-library-organize-design.md`
/// §10.1）：CLI `library organize` / `organize-history` / `organize-undo`
/// （`packages/fushi_cli/lib/src/commands/library_commands.dart`）。
///
/// 与库页「AI 整理」按钮同一个引擎入口（`LibraryOrganizeService.run`，手动触发）；
/// 撤销与整理记录页同一个 [undoLibraryOrganizeRun]。「会发送什么」的同意：没在界面里
/// 同意过时要求请求带 `yes: true`（CLI 的 `--yes`），带了就记为同意。
const String kLibraryOrganizeCtlRoot = '/api/admin/library/organize';

List<CtlRoute> buildLibraryOrganizeCtlRoutes(OpContext context) =>
    buildLibraryOrganizeCtlRoutesFor(
      database: () => context.appModel.database,
      prefs: () => context.appModel.prefsRepo,
      nameLanguage: () => context.appModel.appLocale.toLanguageTag(),
      isReadonly: () => context.appModel.isMigrationReadonly,
    );

/// 路由表本体：依赖按回调注入，测试不必起 [OpContext]。
List<CtlRoute> buildLibraryOrganizeCtlRoutesFor({
  required FushiDatabase Function() database,
  required PreferencesRepository Function() prefs,
  required String Function() nameLanguage,
  bool Function()? isReadonly,
  LibraryOrganizeService Function()? serviceOverride,
}) {
  return <CtlRoute>[
    CtlRoute.post(kLibraryOrganizeCtlRoot, (CtlCall call) async {
      final CollectionShelfDomain domain = _domain(
        call.requireString('domain'),
      );
      if (isReadonly?.call() ?? false) {
        throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
      }
      final PreferencesRepository p = prefs();
      // AI 库管家（spec 2026-11-18 §3）经这条路由跑 ①②：`rulesOnly` = 只跑不花钱
      // 的规则那一步（没指派提供商 / 碰到单趟请求上限），不发 AI 请求，也就不需要
      // 「会发送什么」的同意；`trigger=auto` = 自动路径门槛（只落高置信）；
      // `entryKeys` = 只看这些条目（增量水位之后的新条目）。
      final bool rulesOnly = call.optBool('rulesOnly') == true;
      final OrganizeTrigger trigger = call.optString('trigger') == 'auto'
          ? OrganizeTrigger.auto
          : OrganizeTrigger.manual;
      final List<String> entryKeys = call.stringList('entryKeys');
      if (!rulesOnly && resolveLibraryOrganizeAiProvider(p) == null) {
        throw const CtlFailure.rejected(
          '没有给「AI 整理库」指派提供商（或 AI 模块已关闭）：先在 设置 › 模型 › LLM 里指派',
        );
      }
      if (!rulesOnly && !p.libraryOrganizeConsented) {
        if (call.optBool('yes') != true) {
          throw const CtlFailure.rejected(
            '会把标题、作者或品牌、年份和视频文件夹名发给 AI 提供商（可能计费）；'
            '确认后加 --yes 再运行',
          );
        }
        await p.setLibraryOrganizeConsented(true);
      }
      final LibraryOrganizeService service =
          serviceOverride?.call() ??
          LibraryOrganizeService(
            db: database(),
            settings: p,
            nameLanguage: nameLanguage(),
            videoTagPrefix: t.library_organize_series_tag_prefix,
            allowedRejectedKeys: () => p.libraryOrganizeAllowedKeys,
          );
      final LibraryOrganizeResult r = await service.run(
        domain,
        trigger: trigger,
        onlyEntryKeys: call.body.containsKey('entryKeys')
            ? entryKeys.toSet()
            : null,
        rulesOnly: rulesOnly,
      );
      return <String, Object?>{
        'status': r.status.name,
        'runId': r.runId,
        'changes': r.changes,
        'proposals': r.proposals,
        'requests': r.requests,
        if (r.error != null) 'error': r.error,
      };
    }),
    CtlRoute.get('$kLibraryOrganizeCtlRoot/runs', (CtlCall call) async {
      final int limit = (call.optInt('limit') ?? 20).clamp(1, 200);
      return <String, Object?>{
        'runs': <Object?>[
          for (final ({
                LibraryOrganizeRunRow run,
                List<LibraryOrganizeChangeRow> changes,
              })
              h
              in await loadLibraryOrganizeHistory(database(), limit: limit))
            <String, Object?>{
              'id': h.run.id,
              'domain': h.run.domain,
              'trigger': h.run.trigger,
              'status': h.run.status,
              'startedAt': h.run.startedAt,
              'requests': h.run.requestCount,
              if (h.run.error != null) 'error': h.run.error,
              'changes': <Object?>[
                for (final LibraryOrganizeChangeRow c in h.changes)
                  <String, Object?>{
                    'id': c.id,
                    'kind': c.kind,
                    'collection': c.collectionName,
                    'source': c.source,
                    'confidence': c.confidence,
                    'undone': c.undoneAt != null,
                  },
              ],
            },
        ],
      };
    }),
    CtlRoute.post('$kLibraryOrganizeCtlRoot/runs/:id/undo', (
      CtlCall call,
    ) async {
      final int? id = int.tryParse(call.params['id'] ?? '');
      if (id == null || id <= 0) {
        throw const CtlFailure.badRequest('整理记录 id 必须是正整数');
      }
      if (isReadonly?.call() ?? false) {
        throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
      }
      return <String, Object?>{
        'undone': await undoLibraryOrganizeRun(database(), id),
      };
    }),
    // 待确认的合集级建议（AI 库管家设计稿 §8：用户合集的合并 / 改名）。
    CtlRoute.get('$kLibraryOrganizeCtlRoot/proposals', (CtlCall call) async {
      return <String, Object?>{
        'proposals': <Object?>[
          for (final LibraryOrganizeProposalView p
              in await loadLibraryOrganizeProposals(
                database(),
                pendingOnly: call.optBool('all') != true,
              ))
            p.toJson(),
        ],
      };
    }),
    CtlRoute.post(
      '$kLibraryOrganizeCtlRoot/proposals/:id/accept',
      (CtlCall call) => _resolveProposal(call, database, isReadonly, true),
    ),
    CtlRoute.post(
      '$kLibraryOrganizeCtlRoot/proposals/:id/reject',
      (CtlCall call) => _resolveProposal(call, database, isReadonly, false),
    ),
  ];
}

Future<Map<String, Object?>> _resolveProposal(
  CtlCall call,
  FushiDatabase Function() database,
  bool Function()? isReadonly,
  bool accept,
) async {
  final int? id = int.tryParse(call.params['id'] ?? '');
  if (id == null || id <= 0) {
    throw const CtlFailure.badRequest('建议 id 必须是正整数');
  }
  if (isReadonly?.call() ?? false) {
    throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
  }
  final OrganizeProposalState? state = await resolveLibraryOrganizeProposal(
    database(),
    id,
    accept: accept,
  );
  if (state == null) {
    throw const CtlFailure.notFound('没有这条待确认建议（或已处理过）');
  }
  return <String, Object?>{'id': id, 'state': state.name};
}

CollectionShelfDomain _domain(String raw) {
  for (final CollectionShelfDomain d in CollectionShelfDomain.values) {
    if (d.name == raw) return d;
  }
  throw CtlFailure.badRequest(
    'domain 只能是 ${CollectionShelfDomain.values.map((CollectionShelfDomain d) => d.name).join(' / ')}：$raw',
  );
}
