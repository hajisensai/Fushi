/// 各域的后台检查动作（v101；扩展域含后台自动更新）。番剧不在此列——它走自己
/// 的相位学习节奏，见 `update_check_scheduler.dart` 的库注释。
///
/// 每个 probe 都是「拉一次真相 → 交给既有的投递路径」，**自己不判重、不发通知**：
/// 那两件事是 `UpdateFeedService` 的，重复实现一份就会有两套判据。
library;

import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:fushi_core/fushi_core.dart'
    show EpubBookRow, FushiDatabase, MangaExtensionRow, UpdateFeedEntryRow;

import 'package:fushi/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_updates.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart'
    show MihonBulkInstallReport;
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';

/// 书架里的在线漫画条目（本地导入的 mokuro 漫画没有 `sourceMetadata`，天然被
/// [OnlineMangaLibraryEntry.tryParse] 排除）。
List<({EpubBookRow book, OnlineMangaLibraryEntry entry})>
onlineMangaLibraryRows(Iterable<EpubBookRow> books) {
  final List<({EpubBookRow book, OnlineMangaLibraryEntry entry})> out =
      <({EpubBookRow book, OnlineMangaLibraryEntry entry})>[];
  for (final EpubBookRow book in books) {
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      book.sourceMetadata,
    );
    if (entry != null) out.add((book: book, entry: entry));
  }
  return out;
}

/// 订阅自动下载的入队口：`entry.autoDownload` 为真的条目刷新出新章时调用，
/// [chapters] 按章序（旧 → 新）。生产是 `MangaDownloadService.enqueueChapters`；
/// 测试注入记录器。
typedef OnlineMangaAutoDownload =
    Future<void> Function(
      OnlineMangaLibraryEntry entry,
      List<OnlineMangaChapter> chapters,
    );

/// 在线漫画库检查：逐条联网刷新，新章提醒由
/// `OnlineMangaLibraryService.refresh` 自己投递（那里是唯一的提醒 diff 点）。
///
/// 订阅（设计稿 2026-09-12 §5）：`autoDownload` 为真的条目，这次刷新新出现的章
/// （[newlyAppearedChapters] 同一判据——首次拉取、身份漂移都不算）交给
/// [autoDownload] 入队。**不另起 Timer**：追更就挂在这条 6 小时探针上。
///
/// **串行**而不是并发：几十条书架条目并发打同一个源站等于自制一次小型压测，
/// 而这是后台任务，快几秒对用户没有任何意义。
///
/// 单条失败（源挂了、Cloudflare 拦截、章节列表返回空）只跳过这一条：一条书架
/// 条目的源出问题，不该让后面几十条都查不成。
Future<int> runOnlineMangaUpdateProbe({
  required FushiDatabase database,
  required OnlineMangaLibraryService Function(OnlineMangaRuntimeKind)
  serviceFor,
  OnlineMangaAutoDownload? autoDownload,
  void Function(Object error, String bookKey)? onError,
}) async {
  final List<EpubBookRow> books = await database.getAllEpubBooks();
  int refreshed = 0;
  for (final ({EpubBookRow book, OnlineMangaLibraryEntry entry}) row
      in onlineMangaLibraryRows(books)) {
    try {
      final OnlineMangaLibraryEntry updated = await serviceFor(
        row.entry.runtime,
      ).refreshFromSource(bookKey: row.book.bookKey, entry: row.entry);
      refreshed++;
      if (autoDownload != null && row.entry.autoDownload) {
        final List<OnlineMangaChapter> fresh = newlyAppearedChapters(
          previous: row.entry.chapters,
          current: updated.chapters,
        );
        if (fresh.isNotEmpty) {
          // 源按新→旧返回；入队按章序（旧章先下）。
          await autoDownload(updated, fresh.reversed.toList(growable: false));
        }
      }
    } on Object catch (error) {
      onError?.call(error, row.book.bookKey);
    }
  }
  return refreshed;
}

/// 「后台自动更新扩展」开关（bool，默认 false；漫画与视频扩展共用）。
const String kMihonExtensionAutoUpdatePref = 'mihon_extension_auto_update';

/// 后台自动更新扩展需要的两样东西（自动更新开关关着时整个对象为 null）。
///
/// 全是注入：装不装、什么时候算空闲，都是 `AppModel` 才知道的事；探针只负责
/// 「查到可更新 → 该装的装 → 结果投递成更新中心条目」这条流水线。
class MihonExtensionAutoUpdater {
  const MihonExtensionAutoUpdater({
    required this.isIdle,
    required this.install,
  });

  /// 此刻能不能装。装完要让运行时失效（桌面 = 重启 sidecar），正在用在线源
  /// 读 / 播 / 下载时装会把用户手上的会话打断，所以不空闲就整批推迟。
  final bool Function() isIdle;

  /// 升级安装这一批（生产 = `MihonManager.installMany(upgrade: true,
  /// trustSigner: false)`）。[isCancelled] 在装的过程中变真时停止后续条目。
  final Future<MihonBulkInstallReport> Function(
    List<MihonAvailableExtension> targets,
    bool Function() isCancelled,
  )
  install;
}

/// 自动更新失败里「重试也没用、必须用户亲自处理」的错误码：签名相关（换了签名
/// 只能由用户看着指纹确认，后台绝不顺手接受）以及包本身不合格。
///
/// 这些失败落库后，**同一版本**不再每次启动重下 APK 重撞同一道门；网络错误等
/// 其余失败照常在下一轮重试。
const Set<String> kExtensionAutoUpdateManualCodes = <String>{
  'SIGNATURE_CHANGED',
  'SIGNER_NOT_TRUSTED',
  'SIGNATURE_MISMATCH',
  'METADATA_MISMATCH',
  'DOWNGRADE_REJECTED',
  'UNSUPPORTED_LIB',
  'WRONG_MEDIA_KIND',
};

/// 扩展检查（漫画 / 视频两个生态共用，[kind] 选域）：拉一次仓库索引，把「已装
/// 且仓库里更高版本」的投递出去。
///
/// [refreshStores] 由调用方给（`MihonManager.refreshStores`），因为拉索引这件事
/// 的 etag/304、错误分类、并发保护全在 manager 里，这里再实现一遍只会有两套。
///
/// [autoUpdate] 非空（用户开了「后台自动更新扩展」）且此刻空闲时，先把可更新的
/// 装上，再按结局投递：
/// - 装上了 → 一条 `installed` 结果条目（「有新版」那条若投递过，标已读）；
/// - 失败了 → 一条 `failed` 结果条目，原因进 detailJson，由用户回扩展页处理；
///   **不弹任何对话框**——这是后台任务，用户没在看。
/// - 推迟 / 被并发流程占着 / 此前已因需人工处理的原因失败过 → 照旧投递「有新版」。
///
/// 返回可更新的扩展数。
Future<int> runMihonExtensionUpdateProbe({
  required UpdateFeedService feed,
  required UpdateFeedKind kind,
  required Future<void> Function() refreshStores,
  required List<MihonAvailableExtension> Function() available,
  required List<MangaExtensionRow> Function() installed,
  MihonExtensionAutoUpdater? autoUpdate,
}) async {
  assert(
    kind == UpdateFeedKind.mangaExtension ||
        kind == UpdateFeedKind.animeExtension,
    'runMihonExtensionUpdateProbe 只投扩展域',
  );
  await refreshStores();
  final List<MihonExtensionUpdate> updates = mihonExtensionUpdates(
    available: available(),
    installed: installed(),
  );
  if (updates.isEmpty) return 0;

  String availableEntryId(MihonExtensionUpdate update) => updateFeedEntryId(
    kind,
    mangaExtensionTargetKey(
      packageName: update.packageName,
      versionCode: update.versionCode,
    ),
  );
  String outcomeTargetKey(
    MihonExtensionUpdate update,
    ExtensionAutoUpdateOutcome outcome,
  ) => extensionAutoUpdateTargetKey(
    packageName: update.packageName,
    versionCode: update.versionCode,
    outcome: outcome,
  );

  MihonBulkInstallReport? report;
  if (autoUpdate != null && autoUpdate.isIdle()) {
    final List<MihonAvailableExtension> targets = <MihonAvailableExtension>[];
    for (final MihonExtensionUpdate update in updates) {
      if (await _needsManualHandling(
        feed,
        updateFeedEntryId(
          kind,
          outcomeTargetKey(update, ExtensionAutoUpdateOutcome.failed),
        ),
      )) {
        continue;
      }
      targets.add(update.available);
    }
    if (targets.isNotEmpty) {
      report = await autoUpdate.install(targets, () => !autoUpdate.isIdle());
    }
  }

  final List<UpdateFeedDraft> drafts = <UpdateFeedDraft>[];
  final List<String> superseded = <String>[];
  for (final MihonExtensionUpdate update in updates) {
    final Map<String, Object?> detail = <String, Object?>{
      'packageName': update.packageName,
      'versionCode': update.versionCode,
      'storeUrl': update.available.storeUrl,
    };
    final String targetKey;
    if (report != null && report.installed.contains(update.packageName)) {
      targetKey = outcomeTargetKey(
        update,
        ExtensionAutoUpdateOutcome.installed,
      );
      detail['autoUpdate'] = ExtensionAutoUpdateOutcome.installed.name;
      superseded
        ..add(availableEntryId(update))
        ..add(
          updateFeedEntryId(
            kind,
            outcomeTargetKey(update, ExtensionAutoUpdateOutcome.failed),
          ),
        );
    } else if (report?.failed[update.packageName] case final String reason) {
      final String? code = report!.failureCodes[update.packageName];
      targetKey = outcomeTargetKey(update, ExtensionAutoUpdateOutcome.failed);
      detail['autoUpdate'] = ExtensionAutoUpdateOutcome.failed.name;
      detail['reason'] = reason;
      if (code != null) detail['reasonCode'] = code;
      detail['manual'] =
          code != null && kExtensionAutoUpdateManualCodes.contains(code);
      superseded.add(availableEntryId(update));
    } else {
      targetKey = mangaExtensionTargetKey(
        packageName: update.packageName,
        versionCode: update.versionCode,
      );
    }
    drafts.add(
      UpdateFeedDraft(
        kind: kind,
        targetKey: targetKey,
        title: update.available.name,
        subtitle: update.available.versionName,
        detailJson: jsonEncode(detail),
      ),
    );
  }
  await feed.publishBatch(kind, drafts);
  // 结果条目取代了「有新版」那条（以及上一轮失败的那条）：留着未读等于让用户
  // 去处理一件已经办完的事。
  if (superseded.isNotEmpty) await feed.markSeen(superseded);
  return updates.length;
}

/// 这个版本此前是不是已经以「需人工处理」的原因自动更新失败过。
Future<bool> _needsManualHandling(
  UpdateFeedService feed,
  String entryId,
) async {
  final UpdateFeedEntryRow? row = await feed.entry(entryId);
  if (row == null) return false;
  final String? raw = row.detailJson;
  if (raw == null) return false;
  try {
    final Object? decoded = jsonDecode(raw);
    return decoded is Map && decoded['manual'] == true;
  } on FormatException {
    return false;
  }
}

/// app 新版本检查：由调用方给「有没有新版、版本号是多少」的判据
/// （`UpdateChecker` 那套发布通道 / 渠道过滤逻辑不该在这里复刻一份）。
///
/// [releaseUrl] 进 detailJson，更新页点条目时直接落到发布页。
Future<bool> publishAppReleaseUpdate({
  required UpdateFeedService feed,
  required String version,
  String? releaseNotes,
  String? releaseUrl,
}) async {
  final UpdateFeedPublishResult result = await feed.publish(
    UpdateFeedDraft(
      kind: UpdateFeedKind.appRelease,
      targetKey: appReleaseTargetKey(version),
      title: version,
      subtitle: releaseNotes == null || releaseNotes.trim().isEmpty
          ? null
          : releaseNotes.trim().split('\n').first,
      detailJson: jsonEncode(<String, Object?>{
        'version': version,
        if (releaseUrl != null) 'releaseUrl': releaseUrl,
      }),
    ),
  );
  return result.hasNew;
}
