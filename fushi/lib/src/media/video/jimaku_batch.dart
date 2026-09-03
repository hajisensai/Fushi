import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/jimaku_matching.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_batch.dart';

export 'package:fushi/src/media/video/subtitle/subtitle_batch.dart'
    show
        SubtitleBatchTarget,
        SubtitleBatchStatus,
        SubtitleBatchItem,
        SubtitleBatchItemCallback,
        batchSubtitleFileName,
        resolveSubtitleBatchEpisode,
        runSubtitleBatch;

/// Jimaku 直连版批量编排（`JimakuClient` + `JimakuFile`）。
///
/// 来源无关的编排与数据类型已搬到 `subtitle/subtitle_batch.dart`（`runSubtitleBatch`
/// 经 registry 下载，Jimaku / OpenSubtitles / AJATT 一视同仁）；本文件的类型只是它们
/// 的别名，[runJimakuBatch] 仍保留给尚未迁到 registry 的老番剧订阅路径。判据仍只有
/// 一个（`chooseSubtitleForEpisode`，BUG-1695）。
typedef JimakuBatchTarget = SubtitleBatchTarget;
typedef JimakuBatchStatus = SubtitleBatchStatus;
typedef JimakuBatchItem = SubtitleBatchItem;
typedef JimakuBatchItemCallback = SubtitleBatchItemCallback;

/// 见 [resolveSubtitleBatchEpisode]。
int resolveBatchEpisode(JimakuBatchTarget target) =>
    resolveSubtitleBatchEpisode(target);

/// 从某集的候选文件里挑最佳字幕。纯函数，便于单测。
///
/// **判据不在这里**——委托给全仓唯一的 [chooseJimakuFileForEpisode]（BUG-1695）。
/// 本函数只剩「把文件列表建成索引」这一步存在的理由，保留是为了不改既有调用点形状。
///
/// [soleTarget] 见 [chooseJimakuFileForEpisode]：只有本次匹配确实只有一个待配视频
/// 时，未编号字幕（剧场版 / 整季单文件）才允许被采用。
///
/// 旧实现在「集号一个都没命中」时会退回**全体文本字幕取第一个**。那不是尽力而为，
/// 是把「错季 / 绝对集号编号 / 条目选错」这三种冲突静默变成一个错答案：整季 12 集
/// 会拿到同一个文件，状态还显示 done。冲突现在明确记 noMatch。
JimakuFile? pickBestSubtitleFile(
  List<JimakuFile> files, {
  required int episode,
  required bool soleTarget,
  String? preferredLanguage,
}) =>
    chooseJimakuFileForEpisode(
      JimakuEpisodeIndex.fromFiles(files, preferredLanguage: preferredLanguage),
      episode: episode,
      soleTarget: soleTarget,
    ).file;

/// 批量下载只能在所选来源的预检查已经成功完成且确有可解析字幕时开放。
///
/// loading / failed / 合法空库存都必须保持禁用，避免用户在还没看完预览或已经明确
/// 失败时启动一条语义不同的下载请求链。
bool canDownloadJimakuInventory({
  required int? selectedEntryId,
  required Map<int, JimakuFileInventory> inventories,
  required Set<int> loadingEntryIds,
  required Set<int> failedEntryIds,
}) {
  final int? entryId = selectedEntryId;
  if (entryId == null ||
      loadingEntryIds.contains(entryId) ||
      failedEntryIds.contains(entryId)) {
    return false;
  }
  final JimakuFileInventory? inventory = inventories[entryId];
  return inventory != null && inventory.files.isNotEmpty;
}

/// 编排合集批量字幕下载：对 [targets] 逐集在 [entryIds]（合集绑定的 Jimaku 条目）里按
/// 集号列文件 → 挑最佳 → 下载 → 落 [saveDirectory]。每集处理前后各回调一次
/// （[onItemStart] / [onItemDone]），持久化由 [onItemDone] 里调用方按 target.isStream 分派。
///
/// 尽力而为：单集失败/无匹配不中断整批（记该集状态后继续），网络异常吞进该集 failed。
/// [client] 由调用方创建并负责关闭（便于测试注入 mock）。返回全部集的结果。
Future<List<JimakuBatchItem>> runJimakuBatch({
  required JimakuClient client,
  required List<int> entryIds,
  required List<JimakuBatchTarget> targets,
  required String saveDirectory,
  String? preferredLanguage,
  JimakuBatchItemCallback? onItemStart,
  JimakuBatchItemCallback? onItemDone,
}) async {
  final List<int> ids = entryIds.toSet().toList(growable: false);
  final List<JimakuBatchItem> results = <JimakuBatchItem>[];
  final Directory dir = Directory(saveDirectory);
  final bool soleTarget = targets.length == 1;

  // 条目文件**整批只列一次**（不带 episode query），而不是每集每条目各列一次。
  //
  // 两个理由，第二个才是重点（BUG-1695）：
  // ① 请求数从 targets×entries 降到 entries；
  // ② 带 `episode=` 时服务端按**文件名启发式**先过滤一道，客户端拿到的就只是它的
  //    猜测——「字幕侧到底有哪些集号」这个事实被遮住了，于是没法区分「这一集没有
  //    字幕」和「整个条目就是按绝对集号编号的」。要判集号冲突，必须看到全集合。
  final List<JimakuFile> allFiles = <JimakuFile>[];
  JimakuEpisodeIndex? sharedIndex;
  String? listError;
  try {
    for (final int id in ids) {
      allFiles.addAll(await client.listFiles(id, throwOnError: true));
    }
    sharedIndex = JimakuEpisodeIndex.fromFiles(
      allFiles,
      preferredLanguage: preferredLanguage,
    );
  } catch (e) {
    // 列文件失败是整批共因，不能伪装成每集各自的 noMatch（fail-open 会让用户以为
    // 「这个条目没字幕」）。逐集记 failed，保持「单集失败不中断」的既有语义。
    listError = '$e';
  }

  for (final JimakuBatchTarget target in targets) {
    final JimakuBatchItem item = JimakuBatchItem(
      target: target,
      episode: resolveBatchEpisode(target),
    );
    item.status = JimakuBatchStatus.downloading;
    if (onItemStart != null) await onItemStart(item);
    if (listError != null) {
      item.status = JimakuBatchStatus.failed;
      item.message = listError;
      if (onItemDone != null) await onItemDone(item);
      results.add(item);
      continue;
    }
    try {
      final JimakuEpisodeMatch match = chooseJimakuFileForEpisode(
        sharedIndex!,
        episode: item.episode,
        soleTarget: soleTarget,
      );
      final JimakuFile? best = match.file;
      if (best == null) {
        item.status = JimakuBatchStatus.noMatch;
        // 「为什么没配上」对用户是三件不同的事（改条目 / 等字幕 / 无能为力），
        // 别全压成一句「无匹配」。
        item.message = match.failureReason;
      } else {
        final Uint8List? bytes = await client.downloadFile(best.url);
        if (bytes == null) {
          item.status = JimakuBatchStatus.failed;
          item.message = 'download';
        } else {
          if (!dir.existsSync()) dir.createSync(recursive: true);
          final String dest = p.join(
            dir.path,
            batchSubtitleFileName(target.bookUid, best.name),
          );
          await File(dest).writeAsBytes(bytes);
          item.subtitlePath = dest;
          item.language = detectSubtitleLanguage(best.name);
          item.status = JimakuBatchStatus.done;
        }
      }
    } catch (e) {
      item.status = JimakuBatchStatus.failed;
      item.message = '$e';
    }
    if (onItemDone != null) await onItemDone(item);
    results.add(item);
  }
  return results;
}
