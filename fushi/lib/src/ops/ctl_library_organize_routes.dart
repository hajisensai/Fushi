import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_service.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/utils.dart';

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
      if (resolveLibraryOrganizeAiProvider(p) == null) {
        throw const CtlFailure.rejected(
          '没有给「AI 整理库」指派提供商（或 AI 模块已关闭）：先在 设置 › 模型 › LLM 里指派',
        );
      }
      if (!p.libraryOrganizeConsented) {
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
          );
      final LibraryOrganizeResult r = await service.run(
        domain,
        trigger: OrganizeTrigger.manual,
      );
      return <String, Object?>{
        'status': r.status.name,
        'runId': r.runId,
        'changes': r.changes,
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
  ];
}

CollectionShelfDomain _domain(String raw) {
  for (final CollectionShelfDomain d in CollectionShelfDomain.values) {
    if (d.name == raw) return d;
  }
  throw CtlFailure.badRequest(
    'domain 只能是 ${CollectionShelfDomain.values.map((CollectionShelfDomain d) => d.name).join(' / ')}：$raw',
  );
}
