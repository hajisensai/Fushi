/// 视频条目的「本机原始文件」判据与删除（删除确认框「同时删除本地文件」的落地）。
///
/// 纯函数部分零 IO，供弹窗决定要不要摆勾选框；[deleteLocalVideoFiles] 是唯一动
/// 磁盘的入口，只删**文件**、绝不递归删目录，且仍被其它库行引用的路径一律保留。
///
/// 「本机原始文件」= 视频本体（`videoPath` + 播放列表各集）**加上跟着它走的
/// sidecar 外挂字幕**（[localVideoSidecarSubtitleCandidates]，BUG-2565）。字幕
/// 之所以要按磁盘实况扫而不能只看 DB：`subtitleSource` 只记当前选中那一条，同一
/// 集旁边往往还躺着别的语言/格式版本，只删选中那条等于留一地孤儿。
///
/// 路径同一性一律走 [platformPathKey]（绝对化 + Windows 折大小写），**不用**
/// `normalizeVideoPath`：后者不绝对化也不折大小写，Windows 上 `D:\a\b.mkv` 与
/// `d:\a\b.mkv` 会被判成两个文件，「仍被引用」的护栏就会漏命中、把用户还在用的
/// 文件删掉。`normalizeVideoPath` 的语义已固化进 `externalVideoBookUid` 派生的
/// uid，不能改，也不该被借来当删除判据。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart'
    show LocalFileDeleteReport, VideoBookRow, deleteLocalFiles, platformPathKey;
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/media_extensions.dart' show kVideoExtensions;
import 'package:fushi_engine/media/video/bluray/bluray_source.dart'
    show isBlurayPlaylistPath;
import 'package:fushi_engine/media/video/m3u8_playlist.dart' show PlaylistEntry;
import 'package:fushi_engine/media/video/video_sidecar.dart'
    show listSidecarSubtitles;

/// 删除本机原件的前后挂钩，由上层（`video_library_delete.dart`）接线。
///
/// 分成前后两步不是为了对称，而是顺序本身就是正确性的一部分：**先让引用方放手，
/// 再销毁实体**。还在做种的文件必须先在下载后端标 skip，文件才可以消失；反过来
/// 做，中间任何一次种子校验都会撞上「文件缺失」把整个种子停掉，别的集跟着断。
class LocalVideoFileDeleteHooks {
  const LocalVideoFileDeleteHooks({this.beforeDelete, this.afterDelete});

  /// 磁盘删除**之前**，入参是护栏过滤后真正要删的候选路径。
  final Future<void> Function(List<String> candidates)? beforeDelete;

  /// 磁盘删除**之后**，入参是逐条删除结果（含失败）。
  final Future<void> Function(LocalFileDeleteReport report)? afterDelete;
}

/// 纯函数：[path] 是不是一条可以拿去 `File(path).delete()` 的本机**绝对**路径。
///
/// 两条判据：
/// - 不能是带 scheme 的 URI：远端互联直传、WebDAV、Jellyfin 的 `videoPath` 都是
///   `http(s)://…`，磁盘上没有文件可删。scheme 长度 ≤1 视为盘符（`D:\…` 解析出
///   的 scheme 是 `d`），不算 URI；
/// - 必须绝对：`File('relative/ep01.mkv').delete()` 按**进程当前工作目录**解析，
///   删掉哪个文件取决于 app 启动时的 cwd。删除路径上不接受这种不确定性。
bool isLocalVideoFilePath(String path) {
  final String trimmed = path.trim();
  if (trimmed.isEmpty) return false;
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri != null && uri.scheme.length > 1) return false;
  return p.isAbsolute(trimmed);
}

/// 纯函数：从 `playlistJson`（`[{title,path}]`）解出各集路径；空 / 坏 JSON → 空表。
List<String> playlistEntryPaths(String? playlistJson) {
  if (playlistJson == null || playlistJson.isEmpty) return const <String>[];
  try {
    final dynamic decoded = jsonDecode(playlistJson);
    if (decoded is! List) return const <String>[];
    return <String>[
      for (final dynamic item in decoded)
        if (item is Map<String, dynamic>) PlaylistEntry.fromJson(item).path,
    ];
  } catch (_) {
    return const <String>[];
  }
}

/// 纯函数：这一行视频在本机拥有的原始文件候选（`videoPath` + 播放列表各集），只
/// 保留形如本地绝对路径的。空表 = 没有任何本地文件可删（远端流 / 相对 / 空路径）。
List<String> localVideoFileCandidates({
  required String videoPath,
  String? playlistJson,
}) {
  final Set<String> seen = <String>{};
  final List<String> out = <String>[];
  for (final String raw in <String>[
    videoPath,
    ...playlistEntryPaths(playlistJson),
  ]) {
    if (!isLocalVideoFilePath(raw)) continue;
    // 蓝光标题的 `videoPath` 是盘里的 `BDMV/PLAYLIST/*.mpls`。它是真实文件，但不是
    // 「这一条的原始文件」——它是盘结构的一部分，删掉它等于把盘拆坏（码流还在
    // `STREAM/` 下，盘却再也说不出该怎么播）。一张盘上多条标题还共用同一批码流，
    // 「删这条的文件」在 BD 上根本没有对应物，所以一条候选都不给：删除确认框据此
    // 连「同时删除本地文件」的勾选框都不会摆出来。
    if (isBlurayPlaylistPath(raw)) continue;
    if (seen.add(platformPathKey(raw))) out.add(raw.trim());
  }
  return out;
}

/// 纯函数：这一行有没有本机可删的原始文件——删除确认框据此决定摆不摆
/// 「同时删除本地文件」勾选框。
bool videoBookHasLocalFiles(VideoBookRow row) => localVideoFileCandidates(
      videoPath: row.videoPath,
      playlistJson: row.playlistJson,
    ).isNotEmpty;

/// 纯函数：[rows] 引用的全部本地文件路径（按 [platformPathKey] 归一），用作删除
/// 护栏——出现在这个集合里的文件仍被库里某一行引用，绝不删。
Set<String> referencedLocalVideoPaths(Iterable<VideoBookRow> rows) => <String>{
      for (final VideoBookRow row in rows)
        for (final String path in localVideoFileCandidates(
          videoPath: row.videoPath,
          playlistJson: row.playlistJson,
        ))
          platformPathKey(path),
    };

/// 删除 [candidates] 中真实存在、且不在 [stillReferenced]（[platformPathKey] 归一
/// 的路径集）里的文件；逐条结果原样回传，失败不吞。
///
/// 只删 `File`（含符号链接），目录一律跳过——`videoPath` 不该是目录，真遇到也绝不
/// 递归删。单个失败（Windows 句柄占用等）不翻转其它文件的结果。
Future<LocalFileDeleteReport> deleteLocalVideoFiles({
  required Iterable<String> candidates,
  required Set<String> stillReferenced,
}) =>
    deleteLocalFiles(<String>[
      for (final String path in candidates)
        if (!stillReferenced.contains(platformPathKey(path))) path,
    ]);

/// 纯函数：从同目录文件名清单 [dirFileNames] 里挑出**跟着 [videoFileName] 一起走**
/// 的 sidecar 外挂字幕文件名（原样返回，便于调用方拼回目录）。
///
/// 归属判据复用 [listSidecarSubtitles]（`<stem>[.lang].srt|ass|ssa|vtt`，大小写
/// 不敏感），再减去「同目录另一个 stem 更长的**视频文件**也认领的那些」：
/// `ep01.mkv` 与 `ep01.5.mkv` 并存时，`ep01.5.srt` 按前缀匹配会同时命中两边
/// （对 `ep01` 而言后缀 `.5.srt` 里的 `5` 正好长得像语言标记），而它显然属于
/// `ep01.5.mkv`。删 `ep01.mkv` 绝不能顺手带走还在用的那一集的字幕。
///
/// 反过来，`ep01.5.mkv` 若也在同一批删除里，它自己的候选照样包含 `ep01.5.srt`，
/// 两者并集仍然完整——护栏只挡「实体还在的邻居」，不挡「一起赴死的同伴」。
List<String> sidecarSubtitlesForDeletedVideo({
  required String videoFileName,
  required List<String> dirFileNames,
}) {
  final String stem = p.basenameWithoutExtension(videoFileName);
  if (stem.isEmpty) return const <String>[];
  final List<String> mine = listSidecarSubtitles(stem, dirFileNames);
  if (mine.isEmpty) return const <String>[];
  final String stemLower = stem.toLowerCase();
  final Set<String> claimedByNeighbours = <String>{};
  for (final String name in dirFileNames) {
    if (!kVideoExtensions.contains(p.extension(name).toLowerCase())) continue;
    final String otherStem = p.basenameWithoutExtension(name);
    // 只有「更长且以本 stem 开头」的邻居才可能抢走本 stem 的候选；其余视频的
    // sidecar 本就匹配不到这里来。
    if (otherStem.length <= stem.length) continue;
    if (!otherStem.toLowerCase().startsWith(stemLower)) continue;
    for (final String claimed in listSidecarSubtitles(otherStem, dirFileNames)) {
      claimedByNeighbours.add(claimed.toLowerCase());
    }
  }
  return <String>[
    for (final String name in mine)
      if (!claimedByNeighbours.contains(name.toLowerCase())) name,
  ];
}

/// [videoPaths]（**已过护栏、确定要删**的本机视频文件）各自同目录的 sidecar 外挂
/// 字幕绝对路径，去重后按输入顺序返回。每个目录只列一次。
///
/// 为什么字幕不能像 `videoPath` 那样从 DB 推导：`VideoBooks.subtitleSource` 只记
/// **当前选中**那一条（还可能是 `embedded:<n>` / `off:` / app 目录里的导入副本），
/// 而用户目录里同一集往往躺着好几条（`.ja.srt` + `.zh.ass` + 无语言标记的）。
/// 删了视频只删「当前选中那条」等于把其余的留成孤儿——所以这里按磁盘实况取。
///
/// app 自有目录里的字幕副本不归这里管：它们在删行后由
/// `VideoStorage.deleteBookAssets` 无条件回收，与本勾选框无关。
Future<List<String>> localVideoSidecarSubtitleCandidates(
  Iterable<String> videoPaths,
) async {
  final Map<String, List<String>> dirFilesByKey = <String, List<String>>{};
  final Set<String> seen = <String>{};
  final List<String> out = <String>[];
  for (final String videoPath in videoPaths) {
    final String dir = p.dirname(videoPath);
    final List<String> dirFileNames =
        dirFilesByKey[platformPathKey(dir)] ??= await _listFileNames(dir);
    if (dirFileNames.isEmpty) continue;
    for (final String name in sidecarSubtitlesForDeletedVideo(
      videoFileName: p.basename(videoPath),
      dirFileNames: dirFileNames,
    )) {
      final String full = p.normalize(p.join(dir, name));
      if (seen.add(platformPathKey(full))) out.add(full);
    }
  }
  return out;
}

/// 列出 [dir] 下的文件名（不跟随符号链接）；目录不存在 / 读不动一律空表——收集
/// 候选失败只该少删文件，不该让「视频行已删」这个既成事实翻车。
Future<List<String>> _listFileNames(String dir) async {
  final Directory directory = Directory(dir);
  try {
    if (!await directory.exists()) return const <String>[];
    return <String>[
      await for (final FileSystemEntity entity in directory.list(
        followLinks: false,
      ))
        if (entity is File) p.basename(entity.path),
    ];
  } on FileSystemException {
    return const <String>[];
  }
}

/// 纯函数：[rows] 引用的、形如本机绝对路径的字幕文件（主 + 副字幕源，按
/// [platformPathKey] 归一）。
///
/// 与 [referencedLocalVideoPaths] 并用作删除护栏：幸存行手动挂着的外挂字幕，哪怕
/// 正好躺在被删视频旁边、名字也对得上，也绝不能删。`embedded:<n>` / `off:` 两种
/// 非路径编码由 [isLocalVideoFilePath] 天然滤掉。
Set<String> referencedLocalSubtitlePaths(Iterable<VideoBookRow> rows) => <String>{
      for (final VideoBookRow row in rows)
        for (final String? source in <String?>[
          row.subtitleSource,
          row.secondarySubtitleSource,
        ])
          if (source != null && isLocalVideoFilePath(source))
            platformPathKey(source.trim()),
    };
