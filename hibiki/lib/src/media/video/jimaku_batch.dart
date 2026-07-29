import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/video/jimaku_client.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';

/// 合集批量字幕下载里的一集输入：稳定身份 + 定位信息 + 合集内序位。
///
/// [isStream] 区分持久化路径：本地视频落 DB（subtitleSource 列 + cue），远端/流媒体落
/// prefs（`<bookUid>#ep`，见 PreferencesRepository.remoteSubtitleSources）——两者的
/// 持久化由调用方（对话框）按 [isStream] 分派，本模块只负责下载落盘。
class JimakuBatchTarget {
  const JimakuBatchTarget({
    required this.bookUid,
    required this.title,
    required this.videoPath,
    required this.sortIndex,
    required this.isStream,
  });

  /// 视频稳定身份（本地 = VideoBooks.bookUid，远端 = RemoteVideoInfo.id）。
  final String bookUid;

  /// 显示标题（用于解析集号 + UI 展示）。
  final String title;

  /// 视频路径（本地绝对路径 / http(s) 流 URL）；也用于解析集号。
  final String videoPath;

  /// 合集内序位（MediaCollectionItems.sortIndex，0-based）。解析不出真实集号时的兜底。
  final int sortIndex;

  /// 是否流媒体（videoPath 为 http/https）。决定持久化落 DB 还是 prefs。
  final bool isStream;
}

/// 一集在批量下载里的状态。
enum JimakuBatchStatus {
  /// 排队中，尚未处理。
  pending,

  /// 正在下载。
  downloading,

  /// 已下载并（由调用方）持久化。
  done,

  /// 该集在 Jimaku 无匹配字幕文件。
  noMatch,

  /// 下载/落盘失败。
  failed,
}

/// 一集的批量结果（可变：随处理推进更新 [status] 等）。
class JimakuBatchItem {
  JimakuBatchItem({required this.target, required this.episode});

  final JimakuBatchTarget target;

  /// 用于 Jimaku 匹配的集号（[resolveBatchEpisode]）。
  final int episode;

  JimakuBatchStatus status = JimakuBatchStatus.pending;

  /// 下载落盘的字幕文件绝对路径（成功时非空）。
  String? subtitlePath;

  /// 选中字幕识别出的语言代码（`ja`/`zh`/...；认不出为 null）。
  String? language;

  /// 失败/无匹配时的简短原因（UI 副标题）。
  String? message;
}

/// 解析该集用于 Jimaku 匹配的真实集号：优先从视频路径文件名 / 标题解析
/// （`第N話` / `E01` / `SxxEyy` / `- 12` 等），认不出退回 `sortIndex + 1`
/// （合集内序位转 1-based）。纯函数，便于单测。
///
/// 用真实集号而非 sortIndex：sortIndex 可被用户拖拽重排、或合集含缺集/特典而与真实
/// 集号错位（见仓库地图对 MediaCollectionItems.sortIndex 的说明），直接拿它当集号会
/// 错配 Jimaku 文件。
int resolveBatchEpisode(JimakuBatchTarget target) {
  final int? fromPath =
      parseVideoFilename(p.basename(target.videoPath)).episode;
  if (fromPath != null) return fromPath;
  final int? fromTitle = parseVideoFilename(target.title).episode;
  if (fromTitle != null) return fromTitle;
  return target.sortIndex + 1;
}

/// 从某集的候选文件里挑最佳字幕。纯函数，便于单测。
///
/// Jimaku 的 `episode` 服务端过滤是**文件名启发式**，可能回整季打包 / 邻集文件，故：
/// 1. 先只留精确命中 [episode] 集号的文本字幕；一个都没有再退回全体文本字幕（尽力而为，
///    避免因启发式漏判而整集拿不到字幕）；
/// 2. 池内按语言权重（[jimakuLanguageRank]，优先 [preferredLanguage]）→ 文件名排序，取首。
///
/// 无任何文本字幕候选返回 null（该集记 noMatch）。
JimakuFile? pickBestSubtitleFile(
  List<JimakuFile> files, {
  required int episode,
  String? preferredLanguage,
}) {
  final List<JimakuFile> text =
      files.where((JimakuFile f) => f.isTextSubtitle).toList();
  if (text.isEmpty) return null;
  final List<JimakuFile> matching =
      text.where((JimakuFile f) => f.episode == episode).toList();
  final List<JimakuFile> pool = matching.isNotEmpty ? matching : text;
  pool.sort((JimakuFile a, JimakuFile b) {
    final int la = jimakuLanguageRank(detectSubtitleLanguage(a.name),
        preferred: preferredLanguage);
    final int lb = jimakuLanguageRank(detectSubtitleLanguage(b.name),
        preferred: preferredLanguage);
    if (la != lb) return la.compareTo(lb);
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return pool.first;
}

/// 批量下载落盘的文件名：以稳定 bookUid（清洗成合法文件名段）为前缀，避免多集拿到同名
/// 文件（整季打包字幕对不同集同名）时互相覆盖。纯函数，便于单测。
String batchSubtitleFileName(String bookUid, String fileName) {
  final String safe = bookUid.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return '${safe}__$fileName';
}

/// 每集处理完（下载落盘后，含 noMatch/failed）的回调；调用方据此持久化 + 刷新 UI。
typedef JimakuBatchItemCallback = Future<void> Function(JimakuBatchItem item);

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

  for (final JimakuBatchTarget target in targets) {
    final JimakuBatchItem item = JimakuBatchItem(
      target: target,
      episode: resolveBatchEpisode(target),
    );
    item.status = JimakuBatchStatus.downloading;
    if (onItemStart != null) await onItemStart(item);
    try {
      final List<JimakuFile> files = <JimakuFile>[];
      for (final int id in ids) {
        files.addAll(
          await client.listFiles(
            id,
            episode: item.episode,
            throwOnError: true,
          ),
        );
      }
      final JimakuFile? best = pickBestSubtitleFile(
        files,
        episode: item.episode,
        preferredLanguage: preferredLanguage,
      );
      if (best == null) {
        item.status = JimakuBatchStatus.noMatch;
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
