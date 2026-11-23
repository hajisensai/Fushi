/// 待确认身份在 app 里的装配：书 / 漫画与游戏的数据源、「让 AI 重试」、刷新信号。
///
/// 不 import `AppModel`（依赖全按参数注入）：书架 / 游戏库页在 import 大环里，
/// 这里若再读 AppModel 就会被拖进环（`test/build/import_cycle_guard_test.dart`）。
/// 编排器经叶子 `library_curate_auto.dart` 的 [appLibraryCurator] 取。
library;

import 'dart:async';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/identity/curator_pending_identity.dart';
import 'package:fushi_engine/media/identity/pending_identity.dart';
import 'package:fushi_engine/media/library_curate/library_curator.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/library_curate/library_curate_auto.dart';
import 'package:fushi/src/models/preferences_repository.dart';

/// 偏好里那份库管家本机状态（运行记录 / 水位 / seen）。编排器与待确认队列读同一份。
LibraryCurateStore libraryCurateStoreOf(PreferencesRepository prefs) =>
    JsonLibraryCurateStore(
      read: () async => prefs.libraryCurateState,
      write: prefs.setLibraryCurateState,
    );

/// 书 / 漫画（[CuratorPendingIdentityDomain.books]）或游戏的待确认数据源。
CuratorPendingIdentitySource curatorPendingIdentitySourceOf({
  required FushiDatabase db,
  required PreferencesRepository prefs,
  required CuratorPendingIdentityDomain domain,
}) => CuratorPendingIdentitySource(
  db: db,
  store: libraryCurateStoreOf(prefs),
  facts: DatabaseLibraryCurateFacts(db),
  domain: domain,
);

/// 「让 AI 重试」的结论（弹窗结论卡文案；null = 用户没同意发送，什么都没做）。
///
/// 没给「作品识别」指派提供商时不发任何请求，只引导去「设置 › AI」（与视频的
/// 「AI 识别」同一约定，BUG-2694）；发送前过库管家「会发送什么」的一次性同意
/// （[ensureConsent]）。写入经操作目录记账，这一趟在库管家运行记录里可整趟撤销。
Future<String?> retryPendingIdentityWithAi({
  required PendingIdentityEntry entry,
  required PreferencesRepository prefs,
  required bool aiModuleEnabled,
  required Future<bool> Function() ensureConsent,
  LibraryCurator? Function() curator = appLibraryCurator,
}) async {
  final LibraryCurateAiAvailability ai = libraryCurateAiOf(
    prefs,
    aiModuleEnabled: aiModuleEnabled,
  );
  if (!ai.videoIdentify) return t.ai_assist_no_provider;
  if (!await ensureConsent()) return null;
  final LibraryCurator? c = curator();
  if (c == null) return t.identity_pending_retry_failed;
  final LibraryCurateStage stage = entry.kind == PendingIdentityMediaKind.game
      ? LibraryCurateStage.scrapeGames
      : LibraryCurateStage.scrapeBooks;
  final LibraryCurateRun run;
  try {
    run = await c.retryScrape(stage: stage, ref: entry.key);
  } on LibraryCurateBusy {
    return t.identity_pending_retry_busy;
  }
  return pendingIdentityRetryOutcomeText(run);
}

/// 单条重试那一趟的结论文案：阶段没做完（失败 / 部分）→ 没跑完；留下待确认项 →
/// 仍没认出来；否则认出来了。
String pendingIdentityRetryOutcomeText(LibraryCurateRun run) {
  final bool incomplete = run.stages.any(
    (LibraryCurateStageResult s) => s.status != LibraryCurateStageStatus.done,
  );
  if (incomplete) return t.identity_pending_retry_failed;
  final bool stillPending = run.pendingItems.any(
    (LibraryCuratePendingItem p) =>
        p.kind == 'book_scrape_pending' || p.kind == 'game_scrape_pending',
  );
  return stillPending
      ? t.identity_pending_retry_still_pending
      : t.identity_pending_retry_identified;
}

/// 待确认提醒条的刷新信号：库管家每趟（含单条重试、撤销）结束 + 宿主自己 [ping]。
class PendingIdentityRefresh {
  PendingIdentityRefresh({
    LibraryCurator? Function() curator = appLibraryCurator,
  }) {
    _sub = curator()?.runFinished.listen((_) => ping());
  }

  final StreamController<void> _controller = StreamController<void>.broadcast();
  StreamSubscription<LibraryCurateRun>? _sub;

  Stream<void> get stream => _controller.stream;

  void ping() {
    if (!_controller.isClosed) _controller.add(null);
  }

  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_controller.close());
  }
}
