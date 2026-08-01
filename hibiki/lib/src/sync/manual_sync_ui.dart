import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/sync/sync_activity.dart';
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_conflict_prompter.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/sync/sync_message_dialog.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_progress.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/utils.dart';

/// 手动同步完成后的 SnackBar 摘要（消费 [SyncRunReport]）。纯函数，便于单测边界：
/// 全 0 → "无新增"；多类型 → ` · ` 拼接；有失败 → 追加失败计数后缀。
@visibleForTesting
String summarizeSyncReport(SyncRunReport r) {
  final List<String> parts = <String>[
    if (r.booksImported > 0) t.sync_now_books_in(count: r.booksImported),
    if (r.dictionariesImported > 0)
      t.sync_now_dicts_in(count: r.dictionariesImported),
    if (r.dictionariesExported > 0)
      t.sync_now_dicts_out(count: r.dictionariesExported),
    if (r.audiobooksImported > 0)
      t.sync_now_audio_in(count: r.audiobooksImported),
    if (r.audiobooksExported > 0)
      t.sync_now_audio_out(count: r.audiobooksExported),
    if (r.localAudioImported > 0)
      t.sync_now_local_audio_in(count: r.localAudioImported),
    if (r.localAudioExported > 0)
      t.sync_now_local_audio_out(count: r.localAudioExported),
  ];
  final String head = parts.isEmpty ? t.sync_now_no_changes : parts.join(' · ');
  final String done = t.sync_now_done(detail: head);
  if (r.errors.isEmpty) return done;
  final String failed =
      '$done${t.sync_now_failed_suffix(count: r.errors.length)}';
  // BUG-1324：鉴权类失败不能和网络抖动一样只计进「N 项失败」——那句话里
  // 没有任何可操作信息。「凭据不被接受」要说去重新登录；「服务端拒绝」要把
  // 服务端给的原因原样摆出来，并说明这不是登录问题（否则用户会去反复重配
  // 一个根本没问题的 token，BUG-1311 的原始症状）。只拿第一条：报告已去重，
  // 同一轮里同因的几百条只会剩一条。
  if (r.authFailures.isEmpty) return failed;
  final SyncAuthFailure auth = r.authFailures.first;
  return '$failed · '
      '${friendlySyncAuthFailure(auth.kind, auth.serverReason)}';
}

/// 鉴权失败后是否应当登出。这是一个**判断**，不是一个副作用，故抽成纯函数：
/// 登出会毁掉用户的会话，它的判据必须能被直接钉住（BUG-1323）。
///
/// - [SyncAuthFailureKind.credentials]（401 / 未配置 / OAuth 失效）：会话真的完了，
///   必须登出，否则账号行不退回「未登录」，用户无从重新登录（TODO-836）。
/// - [SyncAuthFailureKind.forbidden]（403）：凭据已被接受，只是服务端拒了这一次
///   请求。登出就是用一条服务端策略抢先毁掉一个好端端的会话。
/// - [SyncAuthFailureKind.browserTimeout]（BUG-1348）：浏览器的授权回调压根没回到
///   app，跟凭据毫无关系。登出只会把用户手上可能仍然有效的会话一起毁掉。
///
/// **逐值 switch，而不是 `!error.isForbidden`**：后者是「非 A 即 B」，
/// [SyncAuthFailureKind] 一加新值就被默默归进「该登出」那一边，而编译器一声不吭
/// （`browserTimeout` 加进来时就正是如此）。switch 表达式对枚举强制穷尽 —— 新增值
/// 不显式给出登出决定就编译不过。
bool shouldSignOutOnAuthError(SyncAuthError error) => switch (error.kind) {
      SyncAuthFailureKind.credentials => true,
      SyncAuthFailureKind.forbidden => false,
      SyncAuthFailureKind.browserTimeout => false,
    };

/// 本地化的同步阶段名（进度行用）。
String syncPhaseLabel(SyncPhase phase) {
  switch (phase) {
    case SyncPhase.books:
      return t.sync_progress_books;
    case SyncPhase.readingData:
      return t.sync_progress_reading;
    case SyncPhase.dictionaries:
      return t.sync_progress_dictionaries;
    case SyncPhase.localAudio:
      return t.sync_progress_local_audio;
    case SyncPhase.audiobooks:
      return t.sync_progress_audiobooks;
    case SyncPhase.videos:
      return t.sync_progress_videos;
  }
}

/// "阶段 (k/N) 标题" —— 阶段没有条目总数时省略计数。
String syncProgressLine(SyncProgress p) {
  final String phase = syncPhaseLabel(p.phase);
  if (p.itemTotal <= 0) return phase;
  final String head = '$phase (${p.itemIndex + 1}/${p.itemTotal})';
  final String? title = p.title;
  return (title == null || title.isEmpty) ? head : '$head $title';
}

/// 没有阶段 tick 可显示时的兜底行 —— 说清这轮同步**是谁**。
///
/// 全量 sweep 在第一个阶段 tick 之前有一整段准备期（等锁 / 读开关 / 走网络鉴权），
/// 合集与单本两条路径则全程没有阶段结构。以前这三种情况一律显示空白，进度条成了
/// 一条无法解读的线。
String syncActivityLine(SyncActivity a) {
  switch (a.kind) {
    case SyncActivityKind.fullSweep:
      return t.sync_progress_preparing;
    case SyncActivityKind.collections:
      return t.sync_progress_collections;
    case SyncActivityKind.singleBook:
      final String? title = a.title;
      return (title == null || title.isEmpty)
          ? t.sync_progress_book
          : t.sync_progress_book_titled(title: title);
  }
}

/// 上一轮同步的结局行（设置页「立即同步」在空闲时显示）。
///
/// 关键的是 [SyncOutcomeReason.noChannels]：一条通道都没通过认证意味着**什么也
/// 没同步**，而在补上这行之前它与正常跑完在界面上完全同形。
String syncOutcomeLine(SyncRunOutcome o) {
  switch (o.reason) {
    case SyncOutcomeReason.completed:
      return t.sync_last_completed(count: o.channelsRun);
    case SyncOutcomeReason.noChannels:
      return t.sync_last_no_channels;
    case SyncOutcomeReason.nothingToSync:
      return t.sync_last_nothing;
    case SyncOutcomeReason.autoDisabled:
      return t.sync_last_auto_disabled;
    case SyncOutcomeReason.cooledDown:
      return t.sync_last_cooled_down;
    case SyncOutcomeReason.failed:
      return t.sync_last_failed;
  }
}

/// 手动同步在 UI 层的**单一入口**：跑 [runManualFullSync]，再统一处理三种 outcome
/// 的提示、逐通道冲突解决、鉴权失效登出。
///
/// 设置页的「立即同步」行和各媒体页的下拉刷新共用这一条路径 —— 否则「跑同步 +
/// 反馈」那套（冲突必须按**各自通道的后端**呈现、[SyncAuthError] 必须登出以让登录
/// 按钮回来）会被复制成 N 份，任何一份漏掉一步就是静默写错端或卡在无效会话。
///
/// [announceNotConfigured] / [announceBusy] / [announceCompleted] 控制三种结果是否
/// 弹 SnackBar。下拉刷新把前两者关掉：绝大多数用户没配云同步，每次下拉都弹「同步
/// 不可用」纯属噪音；已有同步在跑时用户下拉，结果与他期望的一致（数据照样会更
/// 新），不需要打断。冲突提示和错误提示**永远**给 —— 那是不能吞的东西。
///
/// 返回实际发生的 outcome，调用方可据此决定后续（下拉刷新据此不重复刷列表）。
/// 全程不抛：错误都转成用户可读的 SnackBar。
Future<ManualSyncOutcome> runManualSyncWithFeedback({
  required BuildContext context,
  required AppModel appModel,
  bool announceNotConfigured = true,
  bool announceBusy = true,
  bool announceCompleted = true,
}) async {
  // 重入 / 已在飞 guard：设置页整行是焦点目标（Activate 也会触发），且后台/开机
  // 自动同步可能已经持有 sweep 锁。两种情况下第二次触发都是 no-op —— 全局
  // [syncInProgress] 已经在驱动进度条（BUG-101），这里没别的事可做。
  if (syncInProgress.value) {
    if (announceBusy) showSyncMessage(context, t.sync_now_busy);
    return ManualSyncOutcome.busy;
  }
  try {
    final ManualSyncResult result = await runManualFullSync(
      db: appModel.database,
      dictionaryResourceRoot: appModel.dictionaryResourceDirectory,
      audioDatabaseRoot: Directory('${appModel.appDirectory.path}/audiobooks'),
      tempDir: appModel.temporaryDirectory,
      localAudioEntries: appModel.localAudioDbs,
      onLocalAudioImported: appModel.importSyncedLocalAudioDb,
      onPostRun: appModel.refreshAfterSyncRun,
    );
    if (!context.mounted) return result.outcome;
    switch (result.outcome) {
      case ManualSyncOutcome.notConfigured:
        if (announceNotConfigured) {
          showSyncMessage(context, t.sync_compare_unavailable);
        }
      case ManualSyncOutcome.busy:
        if (announceBusy) showSyncMessage(context, t.sync_now_busy);
      case ManualSyncOutcome.completed:
        final SyncRunReport report = result.report!;
        if (announceCompleted) {
          showSyncMessage(context, summarizeSyncReport(report));
        }
        // 手动同步是用户的显式动作：立刻解冲突，不受 in-book/snooze 约束
        // （ConflictSource.manual）。option B 双通道：逐通道用**各自的**后端呈现
        // 该通道的冲突 —— 合并报告的冲突可能来自互联通道，用云后端去 apply 会
        // 写错端。
        for (final ManualSyncChannelReport channel in result.channelReports) {
          if (channel.report.conflicts.isEmpty) continue;
          if (!context.mounted) return result.outcome;
          await appModel.syncConflictPrompter.present(
            navigatorKey: appModel.navigatorKey,
            db: appModel.database,
            backend: channel.backend,
            conflicts: channel.report.conflicts,
            source: ConflictSource.manual,
            inBook: appModel.isMediaOpen,
          );
        }
    }
    return result.outcome;
  } on SyncAuthError catch (e) {
    // TODO-836: insufficient_scope（或任何**凭据类**鉴权错误）—— 存下来的会话
    // 已经不可用了。先登出，让账号行退回「未登录」（登录按钮重新出现），再提示
    // 重新登录。登出序列与 account.part.dart 里的手动登出路径一致。
    //
    // BUG-1323：403 是例外。凭据**已经被接受**，是服务端按策略拒绝了这一次
    // 请求（如 host 对明文会话拒发 service config）。把它当凭据失效去 signOut，
    // 等于用一条服务端策略毁掉用户一个好端端的会话，还要他去重配一个没问题的
    // token——正是 BUG-1311 里用户抱怨的那个循环。提示照常给，只是不动会话。
    if (shouldSignOutOnAuthError(e)) {
      final SyncRepository repo = SyncRepository(appModel.database);
      try {
        final SyncBackend backend =
            resolveSyncBackend(await repo.getBackendType());
        await backend.signOut(repo: repo);
        backend.clearCache();
        await repo.clearFolderCache();
      } catch (_) {
        // 尽力登出；绝不因此盖掉原本要给用户的重新登录提示。
      }
    }
    if (context.mounted) showSyncMessage(context, friendlySyncError(e));
    return ManualSyncOutcome.notConfigured;
  } catch (e) {
    if (context.mounted) {
      showSyncMessage(
          context, t.sync_error(message: friendlySyncErrorDetail(e)));
    }
    return ManualSyncOutcome.notConfigured;
  }
  // 没有本地收尾：进度条由全局 [syncInProgress] / [syncProgress] 驱动，各同步入口
  // 在自己的 finally 里复位。
}
