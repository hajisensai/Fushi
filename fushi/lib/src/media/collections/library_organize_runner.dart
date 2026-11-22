import 'dart:async';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_facts.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_service.dart';
import 'package:fushi_engine/media/library_curate/library_curator.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/collections/collection_ai_order.dart'
    show scheduleAutomaticCollectionAiOrder;
import 'package:fushi/src/media/library_curate/library_curate_auto.dart'
    show
        appLibraryCurator,
        libraryCurateAiOf,
        libraryCurateAutoOwnsTriggers,
        scheduleAutomaticLibraryCurate;
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/library_organize_history_page.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiListItem;
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// AI 整理库的 app 侧装配（spec `docs/specs/2026-10-20-ai-library-organize-design.md`
/// §10 / §11）：手动入口（同意框 → 进度 → 结果）与导入后的自动整理。
///
/// 引擎（`LibraryOrganizeService`）只管「读事实 → 问 AI → 裁决 → 落盘 → 收敛」；
/// 这里只决定**什么时候、以谁的名义**跑它，以及给用户看什么。

/// 库页域的展示名。
String libraryOrganizeDomainLabel(CollectionShelfDomain domain) =>
    switch (domain) {
      CollectionShelfDomain.books => t.library_organize_domain_books,
      CollectionShelfDomain.manga => t.library_organize_domain_manga,
      CollectionShelfDomain.video => t.library_organize_domain_video,
      CollectionShelfDomain.games => t.library_organize_domain_games,
    };

LibraryOrganizeService _serviceFor({
  required FushiDatabase db,
  required AiSettingsSource settings,
  required String nameLanguage,
  AiChatClient Function()? clientFactory,
  Set<String> Function()? allowedRejectedKeys,
}) => LibraryOrganizeService(
  db: db,
  settings: settings,
  nameLanguage: nameLanguage,
  videoTagPrefix: t.library_organize_series_tag_prefix,
  clientFactory: clientFactory,
  allowedRejectedKeys: allowedRejectedKeys,
);

/// 「会发送什么」的一次性同意（照 `ocr_llm_default_consent.dart`）：点「开始」才记住；
/// Esc / 返回 / 点空白只是关掉，不算同意，下次再问。返回是否已同意。
Future<bool> ensureLibraryOrganizeConsent(
  BuildContext context,
  PreferencesRepository prefs,
) async {
  if (prefs.libraryOrganizeConsented) return true;
  final bool? accepted = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: const FushiDialogHeroIcon(
        icon: FushiIcons.aiAssistant,
        tone: FushiHeroTone.neutral,
      ),
      title: Text(t.library_organize_consent_title),
      content: Text(t.library_organize_consent_body),
      actions: <Widget>[
        FushiDialogAction(
          label: MaterialLocalizations.of(dialogContext).cancelButtonLabel,
          onPressed: () => Navigator.of(dialogContext).pop(false),
        ),
        FushiDialogAction(
          label: t.library_organize_consent_start,
          kind: FushiDialogActionKind.primary,
          onPressed: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
    ),
  );
  if (accepted != true) return false;
  await prefs.setLibraryOrganizeConsented(true);
  return true;
}

/// 手动「AI 整理」（库页顶栏 / 多选）。[onlyEntryKeys]（成员行键）给「整理所选」用。
/// [onChanged]：落了改动后通知页面刷新。
Future<void> runLibraryOrganizeInteractive({
  required BuildContext context,
  required AppModel appModel,
  required CollectionShelfDomain domain,
  Set<String>? onlyEntryKeys,
  VoidCallback? onChanged,
}) async {
  final PreferencesRepository prefs = appModel.prefsRepo;
  if (resolveLibraryOrganizeAiProvider(prefs) == null) {
    FushiToast.show(
      msg: t.library_organize_no_provider,
      severity: ToastSeverity.warning,
    );
    return;
  }
  if (!await ensureLibraryOrganizeConsent(context, prefs)) return;
  if (!context.mounted) return;
  bool cancelled = false;
  final FushiProgressDialogHandle handle = showFushiProgressDialog(
    context: context,
    title: t.library_organize_action,
    onCancel: () => cancelled = true,
    cancelLabel: t.library_organize_cancel,
  );
  LibraryOrganizeResult? result;
  try {
    result =
        await _serviceFor(
          db: appModel.database,
          settings: prefs,
          nameLanguage: appModel.appLocale.toLanguageTag(),
          allowedRejectedKeys: () => prefs.libraryOrganizeAllowedKeys,
        ).run(
          domain,
          trigger: OrganizeTrigger.manual,
          onlyEntryKeys: onlyEntryKeys,
          isCancelled: () => cancelled,
          onProgress: (int done, int total) {
            handle.progress.value = total == 0 ? null : done / total;
            handle.message.value = t.library_organize_progress(
              done: done + 1 > total ? total : done + 1,
              total: total,
            );
          },
        );
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('libraryOrganize.manual', error, stack);
  } finally {
    handle.close();
  }
  if (result == null) return;
  if (result.touchedCollectionIds.isNotEmpty) {
    scheduleAutomaticCollectionAiOrder(
      db: appModel.database,
      collectionIds: result.touchedCollectionIds,
    );
  }
  if (result.changes > 0) onChanged?.call();
  if (!context.mounted) return;
  await _showResult(context, appModel, result, onChanged);
}

Future<void> _showResult(
  BuildContext context,
  AppModel appModel,
  LibraryOrganizeResult result,
  VoidCallback? onChanged,
) async {
  final String message = switch (result.status) {
    LibraryOrganizeStatus.failed => t.library_organize_failed(
      reason: result.error ?? '',
    ),
    _ when result.changes == 0 => t.library_organize_nothing,
    _ => t.library_organize_done(n: result.changes),
  };
  if (result.changes == 0) {
    FushiToast.show(
      msg: message,
      severity: result.status == LibraryOrganizeStatus.failed
          ? ToastSeverity.error
          : ToastSeverity.neutral,
    );
    return;
  }
  final String? choice = await showAppDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: const FushiDialogHeroIcon(
        icon: FushiIcons.aiAssistant,
        tone: FushiHeroTone.neutral,
      ),
      title: Text(message),
      actions: <Widget>[
        FushiDialogAction(
          key: const ValueKey<String>('library_organize_result_undo'),
          label: t.library_organize_undo,
          onPressed: () => Navigator.of(dialogContext).pop('undo'),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('library_organize_result_view'),
          label: t.library_organize_view,
          onPressed: () => Navigator.of(dialogContext).pop('view'),
        ),
        FushiDialogAction(
          label: MaterialLocalizations.of(dialogContext).okButtonLabel,
          kind: FushiDialogActionKind.primary,
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
      ],
    ),
  );
  if (choice == 'undo') {
    await undoLibraryOrganizeRun(appModel.database, result.runId);
    onChanged?.call();
  } else if (choice == 'view' && context.mounted) {
    await openLibraryOrganizeHistoryPage(context, appModel);
    onChanged?.call();
  }
}

// ---------------------------------------------------------------------------
// 自动路径
// ---------------------------------------------------------------------------

/// 自动整理的装配（主进程 `AppModel.initialise()` 里装一次；弹窗 / 悬浮词典进程不装
/// = 自动路径什么都不做）。
class LibraryOrganizeAutoHost {
  const LibraryOrganizeAutoHost({
    required this.db,
    required this.prefs,
    required this.nameLanguage,
    this.clientFactory,
  });

  final FushiDatabase db;
  final PreferencesRepository prefs;
  final String Function() nameLanguage;

  /// 仅测试注入假 AI；生产为 null（[AiChatClient] 默认装配，走应用代理）。
  final AiChatClient Function()? clientFactory;
}

LibraryOrganizeAutoHost? _autoHost;

void installLibraryOrganizeAutomatic(LibraryOrganizeAutoHost? host) {
  _autoHost = host;
  for (final Timer timer in _debounce.values) {
    timer.cancel();
  }
  _debounce.clear();
}

/// 去抖：连续导入合成一次（spec §10.2）。
const Duration kLibraryOrganizeAutoDebounce = Duration(seconds: 30);

final Map<CollectionShelfDomain, Timer> _debounce =
    <CollectionShelfDomain, Timer>{};
final Set<CollectionShelfDomain> _autoInFlight = <CollectionShelfDomain>{};

/// 库页加载 / 来源扫描后调：开了「导入后自动整理」、同意过、有提供商时，去抖后对
/// [domain] 里**本机上次自动整理之后新入库**的条目跑一次。不阻塞调用方。
///
/// AI 库管家自动路径开着（`library_curate_auto`，默认开）时改由它接管：去抖后跑一
/// 趟库管家（第一阶段就是这个整理，四个域一起），旧的自动整理不再单独跑，两套自动
/// 任务不会对同一批新条目重复花钱。
void scheduleAutomaticLibraryOrganize(CollectionShelfDomain domain) {
  if (libraryCurateAutoOwnsTriggers()) {
    scheduleAutomaticLibraryCurate();
    return;
  }
  // 库管家关着时它只排 AI 助手自动复查（开着才排；流水线那一段按它自己的开关不跑）。
  scheduleAutomaticLibraryCurate();
  final LibraryOrganizeAutoHost? host = _autoHost;
  if (!_autoEnabled(host)) return;
  _debounce[domain]?.cancel();
  _debounce[domain] = Timer(
    kLibraryOrganizeAutoDebounce,
    () => unawaited(runAutomaticLibraryOrganize(domain)),
  );
}

bool _autoEnabled(LibraryOrganizeAutoHost? host) =>
    host != null &&
    !libraryCurateAutoOwnsTriggers() &&
    host.prefs.libraryOrganizeAuto &&
    host.prefs.libraryOrganizeConsented &&
    resolveLibraryOrganizeAiProvider(host.prefs) != null;

/// 跑一次自动整理（去抖到点后由 [scheduleAutomaticLibraryOrganize] 调；测试直接调）。
/// 门同上；没有新条目、同域已有一轮在跑时什么都不做。返回这次的结论（没跑为 null）。
@visibleForTesting
Future<LibraryOrganizeResult?> runAutomaticLibraryOrganize(
  CollectionShelfDomain domain,
) async {
  final LibraryOrganizeAutoHost? host = _autoHost;
  _debounce.remove(domain);
  if (!_autoEnabled(host) || !_autoInFlight.add(domain)) return null;
  try {
    final LibraryOrganizeService service = _serviceFor(
      db: host!.db,
      settings: host.prefs,
      nameLanguage: host.nameLanguage(),
      clientFactory: host.clientFactory,
      allowedRejectedKeys: () => host.prefs.libraryOrganizeAllowedKeys,
    );
    final int lastRun =
        await service.lastCompletedAutoRunStartedAt(domain) ?? 0;
    final int since = lastRun > host.prefs.libraryOrganizeAutoSince
        ? lastRun
        : host.prefs.libraryOrganizeAutoSince;
    final Set<String> fresh = await organizeEntryKeysAddedSince(
      host.db,
      domain,
      since,
    );
    if (fresh.isEmpty) return null;
    final LibraryOrganizeResult result = await service.run(
      domain,
      trigger: OrganizeTrigger.auto,
      onlyEntryKeys: fresh,
    );
    if (result.touchedCollectionIds.isNotEmpty) {
      scheduleAutomaticCollectionAiOrder(
        db: host.db,
        collectionIds: result.touchedCollectionIds,
      );
    }
    return result;
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('libraryOrganize.automatic', error, stack);
    return null;
  } finally {
    _autoInFlight.remove(domain);
  }
}

@visibleForTesting
bool get debugLibraryOrganizeAutoScheduled => _debounce.isNotEmpty;

// ---------------------------------------------------------------------------
// AI 库管家：设置 › AI 里的「立即整理整个库」
// ---------------------------------------------------------------------------

/// 阶段的展示名。
String libraryCurateStageLabel(LibraryCurateStage stage) => switch (stage) {
  LibraryCurateStage.organizeBooks => t.library_curate_stage_organize(
    domain: libraryOrganizeDomainLabel(CollectionShelfDomain.books),
  ),
  LibraryCurateStage.organizeManga => t.library_curate_stage_organize(
    domain: libraryOrganizeDomainLabel(CollectionShelfDomain.manga),
  ),
  LibraryCurateStage.organizeVideo => t.library_curate_stage_organize(
    domain: libraryOrganizeDomainLabel(CollectionShelfDomain.video),
  ),
  LibraryCurateStage.organizeGames => t.library_curate_stage_organize(
    domain: libraryOrganizeDomainLabel(CollectionShelfDomain.games),
  ),
  LibraryCurateStage.videoStructure => t.library_curate_stage_video_structure,
  LibraryCurateStage.scrape => t.library_curate_stage_scrape,
  LibraryCurateStage.scrapeBooks => t.library_curate_stage_scrape_books,
  LibraryCurateStage.scrapeGames => t.library_curate_stage_scrape_games,
  LibraryCurateStage.links => t.library_curate_stage_links,
  LibraryCurateStage.music => t.library_curate_stage_music,
  LibraryCurateStage.works => t.library_curate_stage_works,
};

String _curateStatusLabel(LibraryCurateStageStatus status) => switch (status) {
  LibraryCurateStageStatus.done => t.library_curate_status_done,
  LibraryCurateStageStatus.partial => t.library_curate_status_partial,
  LibraryCurateStageStatus.skipped => t.library_curate_status_skipped,
  LibraryCurateStageStatus.failed => t.library_curate_status_failed,
  LibraryCurateStageStatus.cancelled => t.library_curate_status_cancelled,
};

/// 手动跑一趟库管家（spec 2026-11-18 §9）：同意（与 AI 整理库共用，没指派任何 AI
/// 时不问）→ 费用预估确认 → 进度（可取消）→ 结果摘要（各阶段结论、整趟撤销、待
/// 确认入口跳整理记录页）。
Future<void> runLibraryCurateInteractive({
  required BuildContext context,
  required AppModel appModel,
}) async {
  final LibraryCurator? curator = appLibraryCurator();
  if (curator == null) {
    FushiToast.show(msg: t.library_curate_not_ready);
    return;
  }
  if (curator.isRunning) {
    FushiToast.show(msg: t.library_curate_busy);
    return;
  }
  final PreferencesRepository prefs = appModel.prefsRepo;
  final LibraryCurateAiAvailability ai = libraryCurateAiOf(
    prefs,
    aiModuleEnabled: isAiModuleEnabled(appModel.moduleVisibility),
  );
  if (ai.organize || ai.videoIdentify || ai.mediaLinks) {
    if (!await ensureLibraryOrganizeConsent(context, prefs)) return;
  }
  final LibraryCurateEstimate estimate;
  try {
    estimate = await curator.estimate();
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('libraryCurate.estimate', error, stack);
    return;
  }
  if (!context.mounted) return;
  final bool? go = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: const FushiDialogHeroIcon(
        icon: FushiIcons.aiAssistant,
        tone: FushiHeroTone.neutral,
      ),
      title: Text(t.library_curate_estimate_title),
      content: Text(
        t.library_curate_estimate_body(
          items: estimate.items,
          requests: estimate.requests,
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: MaterialLocalizations.of(dialogContext).cancelButtonLabel,
          onPressed: () => Navigator.of(dialogContext).pop(false),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('library_curate_start'),
          label: t.library_curate_start,
          kind: FushiDialogActionKind.primary,
          onPressed: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return;
  bool cancelled = false;
  final FushiProgressDialogHandle handle = showFushiProgressDialog(
    context: context,
    title: t.library_curate_run_action,
    onCancel: () => cancelled = true,
    cancelLabel: t.library_organize_cancel,
  );
  LibraryCurateRun? run;
  try {
    run = await curator.run(
      trigger: LibraryCurateTrigger.manual,
      isCancelled: () => cancelled,
      onProgress: (LibraryCurateStage stage, int index, int total) {
        handle.progress.value = total == 0 ? null : index / total;
        handle.message.value = libraryCurateStageLabel(stage);
      },
    );
  } on LibraryCurateBusy {
    FushiToast.show(msg: t.library_curate_busy);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('libraryCurate.manual', error, stack);
  } finally {
    handle.close();
  }
  if (run == null || !context.mounted) return;
  await _showCurateResult(context, appModel, curator, run);
}

Future<void> _showCurateResult(
  BuildContext context,
  AppModel appModel,
  LibraryCurator curator,
  LibraryCurateRun run,
) async {
  final String title = run.changes == 0 && run.pending == 0
      ? t.library_curate_result_nothing
      : t.library_curate_result_title(
          changes: run.changes,
          pending: run.pending,
        );
  final String? choice = await showAppDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: const FushiDialogHeroIcon(
        icon: FushiIcons.aiAssistant,
        tone: FushiHeroTone.neutral,
      ),
      title: Text(title),
      content: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final (int i, LibraryCurateStageResult s)
                in run.stages.indexed)
              FushiStaggeredEntrance(
                index: i,
                child: FushiListItem(
                  key: ValueKey<String>('library_curate_stage_${s.stage.wire}'),
                  padding: EdgeInsets.zero,
                  title: Text(libraryCurateStageLabel(s.stage)),
                  trailing: Text(
                    s.changes > 0 || s.pending > 0
                        ? '${_curateStatusLabel(s.status)} · '
                              '+${s.changes} / ${s.pending}'
                        : _curateStatusLabel(s.status),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        if (run.changes > 0)
          FushiDialogAction(
            key: const ValueKey<String>('library_curate_result_undo'),
            label: t.library_curate_undo_run,
            onPressed: () => Navigator.of(dialogContext).pop('undo'),
          ),
        if (run.pending > 0)
          FushiDialogAction(
            key: const ValueKey<String>('library_curate_result_pending'),
            label: t.library_curate_view_pending,
            onPressed: () => Navigator.of(dialogContext).pop('pending'),
          ),
        FushiDialogAction(
          label: MaterialLocalizations.of(dialogContext).okButtonLabel,
          kind: FushiDialogActionKind.primary,
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
      ],
    ),
  );
  if (choice == 'undo') {
    final LibraryCurateUndoResult r = await curator.undoRun(run.id);
    FushiToast.show(msg: t.library_curate_undone(n: r.undone));
  } else if (choice == 'pending' && context.mounted) {
    // 待确认的合集级建议与「挪走」记录都在整理记录页（那里有确认卡），不另做一份。
    await openLibraryOrganizeHistoryPage(context, appModel);
  }
}
