/// AI 库管家的 app 侧组装（spec `docs/specs/2026-11-18-ai-library-curator-design.md`
/// §3）：用进程内操作目录 + AI 工具箱组一个编排器，进程里只有一个（控制通道路由、
/// 设置页按钮、自动路径共用，同一时刻只跑一趟）。
///
/// 本文件依赖操作上下文（经它依赖 `AppModel`），所以**只许大环外的文件 import**
/// （`main.dart`、控制通道路由、设置页入口）；大环里的 `AppModel` / 库整理 runner
/// 只 import 叶子 `library_curate_auto.dart`，编排器经
/// [registerLibraryCuratorProvider] 注入（`test/build/import_cycle_guard_test.dart`）。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_cli/fushi_cli.dart' show OpInvoker;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_media_identity_assistant.dart';
import 'package:fushi_engine/ai/ai_video_identity_assistant.dart';
import 'package:fushi_engine/media/library_curate/library_curator.dart';
import 'package:fushi_engine/media/video/metadata/video_collection_relation_sync.dart'
    show productionAniDbXmlDirectory;
import 'package:fushi_engine/media/video/metadata/video_series_relation_refresh.dart';

import 'package:fushi/src/ai/agent/ai_agent_toolbox.dart';
import 'package:fushi/src/media/library_curate/library_curate_auto.dart';
import 'package:fushi/src/media/video/acquisition/app_video_acquisition_assembly.dart'
    show videoDiscoveryScrapeConfig;
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/app_op_context.dart';
import 'package:fushi/src/ops/op_context.dart';

export 'package:fushi/src/media/library_curate/library_curate_auto.dart';

/// 偏好里的那份本机状态。
LibraryCurateStore libraryCurateStoreOf(PreferencesRepository prefs) =>
    JsonLibraryCurateStore(
      read: () async => prefs.libraryCurateState,
      write: prefs.setLibraryCurateState,
    );

/// 用 [invoker]（进程内操作目录）组一个编排器。
LibraryCurator buildAppLibraryCurator({
  required FushiDatabase db,
  required PreferencesRepository prefs,
  required OpInvoker invoker,
  required bool Function() aiModuleEnabled,
  required String Function() uiLocaleTag,
}) {
  final PreferencesAiVideoIdentityAdvisor advisor =
      PreferencesAiVideoIdentityAdvisor(prefs);
  final PreferencesAiMediaIdentityAdvisor mediaAdvisor =
      PreferencesAiMediaIdentityAdvisor(prefs);
  return LibraryCurator(
    db: db,
    toolbox: AiAgentToolbox(invoker: invoker, database: db),
    store: libraryCurateStoreOf(prefs),
    facts: DatabaseLibraryCurateFacts(
      db,
      allowedKeys: () => prefs.libraryOrganizeAllowedKeys,
    ),
    ai: () => libraryCurateAiOf(prefs, aiModuleEnabled: aiModuleEnabled()),
    videoDecider: () => advisor.capabilityKey == null ? null : advisor.decide,
    mediaDecider: () => mediaAdvisor.isAssigned ? mediaAdvisor.decide : null,
    // 先按合集去重联网补齐旧 TMDB 电影快照缺的合集成员表（已补过的 0 请求），
    // 再跑不联网的存量补填；每趟库管家都把缺的系列关系补上。
    seriesRelationBackfill: () async => (await refreshVideoSeriesRelations(
      db,
      config: videoDiscoveryScrapeConfig(prefs, uiLocaleTag: uiLocaleTag()),
      aniDbXmlDirectory: productionAniDbXmlDirectory,
    )).backfill,
  );
}

LibraryCurator? _shared;
OpContext? _sharedFor;

/// [context] 的进程级编排器（[context] 换了——根组件重建——才重建）。
LibraryCurator libraryCuratorFor(OpContext context) {
  final LibraryCurator? cached = _shared;
  if (cached != null && identical(_sharedFor, context)) return cached;
  _sharedFor = context;
  return _shared = buildAppLibraryCurator(
    db: context.appModel.database,
    prefs: context.appModel.prefsRepo,
    invoker: buildAppInProcessOpInvoker(context),
    aiModuleEnabled: () => isAiModuleEnabled(context.appModel.moduleVisibility),
    uiLocaleTag: () => context.appModel.appLocale.toLanguageTag(),
  );
}

/// 根组件登记操作上下文后调（`main.dart`）：让自动路径与设置页拿得到编排器。
void registerAppLibraryCurator() => registerLibraryCuratorProvider(() {
  final OpContext? context = appOpContext;
  return context == null ? null : libraryCuratorFor(context);
});

/// 测试替换进程级编排器（null = 恢复默认）。
@visibleForTesting
void debugSetAppLibraryCurator(LibraryCurator? curator, OpContext? context) {
  _shared = curator;
  _sharedFor = context;
}
