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

import 'package:fushi_engine/media/video/bluray/bluray_source.dart'
    show blurayDiscRootForPlaylistPath, isBlurayPlaylistPath;
import 'package:fushi_engine/media/video/dvd/dvd_angle.dart'
    show dvdTitleAnglePath, parseDvdTitleAnglePath;
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart' show isDvdTitlePath;
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart'
    show dvdDiscRootForTitlePath, dvdTitleNumberForPath, dvdTitlePath;
import 'package:fushi_engine/media/video/m3u8_playlist.dart' show PlaylistEntry;
import 'package:fushi_engine/sync/ttu_filename.dart' show sanitizeTtuFilename;
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

/// 纯函数：视频行第 [episodeIndex] 集的文件路径（host 按集反查文件的唯一判据：播放
/// 端点、按集字幕、字幕任务共用）。下标从 0 起，与 `?episode=` 同口径：
/// - 负数 → null；
/// - 第 0 集，或这一行没有播放列表 → [videoPath]（空串 → null）；
/// - 其余取 [playlistEntryPaths] 的第 [episodeIndex] 项，越界 / 空路径 → null。
///
/// 路径只来自这一行自己的库数据，不接受外部传入的路径。
String? videoBookEpisodePath({
  required String videoPath,
  String? playlistJson,
  required int episodeIndex,
}) {
  if (episodeIndex < 0) return null;
  if (episodeIndex == 0) return videoPath.isEmpty ? null : videoPath;
  final List<String> entries = playlistEntryPaths(playlistJson);
  if (episodeIndex >= entries.length) return null;
  final String path = entries[episodeIndex];
  return path.isEmpty ? null : path;
}

/// 纯函数：与视频行成员路径 [videoPath] 同一张原盘上的另一条 title（[discTitle]，
/// 相对盘根、`/` 分隔）的成员路径。host 按（盘, title）定位远端原盘会话里的 title
/// （菜单里的特典等库里没有行的、多角度 title 的某个角度、DVD title）的唯一判据：远端
/// 原盘会话的字幕任务 `discTitle` 与 `clipaudio?discTitle=` 共用。
///
/// - 蓝光行：恰好三段 `BDMV/PLAYLIST/<名>.mpls`（大小写不敏感），名字里不许有路径
///   分隔符、`..`；
/// - DVD 行（[videoPath] 是 `VIDEO_TS/TITLE_nn.dvdtitle`）：恰好两段
///   `VIDEO_TS/TITLE_nn.dvdtitle`（或角度成员路径 `VIDEO_TS/TITLE_nn.aK.dvdtitle`），
///   title 号 1～99，按 [dvdTitlePath] 在这一行的盘根上重拼、保留角度（规整写法，读媒体
///   经 `DvdFfmpegBackend` 按 title / 角度读）；
/// - [videoPath] 不是原盘成员（没有盘根）、两边格式不同 → null。
///
/// 路径只由这一行自己的盘根拼出，[discTitle] 走不出这张盘。
String? videoBookDiscTitlePath({
  required String videoPath,
  required String discTitle,
}) {
  if (isDvdTitlePath(videoPath)) {
    return _dvdDiscTitlePath(videoPath: videoPath, discTitle: discTitle);
  }
  if (!isBlurayPlaylistPath(videoPath)) return null;
  final String? root = blurayDiscRootForPlaylistPath(videoPath);
  if (root == null) return null;
  final List<String> parts = discTitle.split('/');
  if (parts.length != 3 ||
      parts[0].toUpperCase() != 'BDMV' ||
      parts[1].toUpperCase() != 'PLAYLIST') {
    return null;
  }
  final String name = parts[2];
  if (name.isEmpty ||
      name.contains(r'\') ||
      name.contains(':') ||
      name.startsWith('.') ||
      p.extension(name).toLowerCase() != '.mpls') {
    return null;
  }
  final String path = p.join(root, parts[0], parts[1], name);
  final String? back = blurayDiscRootForPlaylistPath(path);
  return back != null && p.equals(back, root) ? path : null;
}

/// [videoBookDiscTitlePath] 的 DVD 分支。
String? _dvdDiscTitlePath({
  required String videoPath,
  required String discTitle,
}) {
  final String? root = dvdDiscRootForTitlePath(videoPath);
  if (root == null) return null;
  final List<String> parts = discTitle.split('/');
  if (parts.length != 2 || parts[0].toUpperCase() != 'VIDEO_TS') return null;
  final String name = parts[1];
  if (name.contains(r'\') || name.contains(':')) return null;
  final int? number = dvdTitleNumberForPath(name);
  if (number == null) return null;
  // 多角度 title 的角度成员路径（`TITLE_03.a2.dvdtitle`，`dvd_angle.dart`）保留角度：
  // host 按会话里正在播的角度读。
  final int angle = parseDvdTitleAnglePath(name)?.angleIndex ?? 0;
  return dvdTitleAnglePath(dvdTitlePath(root, number), angle);
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
    // DVD 标题同理，而且它的成员路径是虚拟的（`VIDEO_TS/TITLE_nn.dvdtitle`），
    // 盘上没有这个文件可删；一张盘的各 title 共用 VTS 的 VOB。
    if (isDvdTitlePath(raw)) continue;
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

/// 纯函数：[path] 是否落在某个选择器导入副本目录 [copyDirs] 之内（BUG-2863，
/// 见 `EnginePaths.pickerImportCopyDirectories`）。落在里面的视频是 app 拷出来的
/// 副本而非用户原件，删库条目时不论「同时删除本地文件」勾没勾都要回收。
///
/// 比对走 [platformPathKey] 归一后的 `p.isWithin`：只认严格位于目录**之内**的
/// 路径，目录本身与同名前缀的兄弟目录（`tmp2/`）都不算。
bool isPickerImportCopyPath(String path, Iterable<String> copyDirs) {
  if (!isLocalVideoFilePath(path)) return false;
  final String key = platformPathKey(path.trim());
  for (final String dir in copyDirs) {
    if (dir.trim().isEmpty) continue;
    if (p.isWithin(platformPathKey(dir.trim()), key)) return true;
  }
  return false;
}

/// 删除 [candidates] 中真实存在、且不在 [stillReferenced]（[platformPathKey] 归一
/// 的路径集）里的文件；逐条结果原样回传，失败不吞。
///
/// 只删 `File`（含符号链接），目录一律跳过——`videoPath` 不该是目录，真遇到也绝不
/// 递归删。单个失败（Windows 句柄占用等）不翻转其它文件的结果。
///
/// [onCandidateDone] 每处理完一个候选回调一次（入参是已处理的候选数，含被护栏挡下
/// 的），给删除进度用。
Future<LocalFileDeleteReport> deleteLocalVideoFiles({
  required Iterable<String> candidates,
  required Set<String> stillReferenced,
  void Function(int done)? onCandidateDone,
}) async {
  final List<String> all = candidates.toList(growable: false);
  final List<String> deletable = <String>[
    for (final String path in all)
      if (!stillReferenced.contains(platformPathKey(path))) path,
  ];
  final int skipped = all.length - deletable.length;
  if (skipped > 0) onCandidateDone?.call(skipped);
  return deleteLocalFiles(
    deletable,
    onPathDone: onCandidateDone == null
        ? null
        : (int done) => onCandidateDone(skipped + done),
  );
}

/// 纯函数：从同目录文件名清单 [dirFileNames] 里挑出**跟着 [videoFileName] 一起走**
/// 的 sidecar 外挂字幕文件名（原样返回，便于调用方拼回目录）。
///
/// 归属判据就是播放器列字幕的那一条 [listSidecarSubtitles]（`<stem>[.lang].srt|ass|
/// ssa|vtt`，大小写不敏感，「最长主干认领」）：`ep01.mkv` 与 `ep01.5.mkv` 并存时，
/// `ep01.5.srt` 按前缀匹配会同时命中两边（对 `ep01` 而言后缀 `.5.srt` 里的 `5` 正好
/// 长得像语言标记），它归 stem 更长的 `ep01.5.mkv`——播放 `ep01.mkv` 不会选它，删
/// `ep01.mkv` 也绝不顺手带走还在用的那一集的字幕。
///
/// 反过来，`ep01.5.mkv` 若也在同一批删除里，它自己的候选照样包含 `ep01.5.srt`，
/// 两者并集仍然完整——护栏只挡「实体还在的邻居」，不挡「一起赴死的同伴」。
List<String> sidecarSubtitlesForDeletedVideo({
  required String videoFileName,
  required List<String> dirFileNames,
}) {
  final String stem = p.basenameWithoutExtension(videoFileName);
  if (stem.isEmpty) return const <String>[];
  return listSidecarSubtitles(stem, dirFileNames);
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
///
/// [onVideoDone] 每看完一个视频回调一次（入参是已看完的视频数），给删除进度用。
Future<List<String>> localVideoSidecarSubtitleCandidates(
  Iterable<String> videoPaths, {
  void Function(int done)? onVideoDone,
}) async {
  final Map<String, List<String>> dirFilesByKey = <String, List<String>>{};
  final Set<String> seen = <String>{};
  final List<String> out = <String>[];
  int done = 0;
  for (final String videoPath in videoPaths) {
    final String dir = p.dirname(videoPath);
    final List<String> dirFileNames = dirFilesByKey[platformPathKey(dir)] ??=
        await _listFileNames(dir);
    if (dirFileNames.isNotEmpty) {
      for (final String name in sidecarSubtitlesForDeletedVideo(
        videoFileName: p.basename(videoPath),
        dirFileNames: dirFileNames,
      )) {
        final String full = p.normalize(p.join(dir, name));
        if (seen.add(platformPathKey(full))) out.add(full);
      }
    }
    onVideoDone?.call(++done);
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
Set<String> referencedLocalSubtitlePaths(Iterable<VideoBookRow> rows) =>
    <String>{
      for (final VideoBookRow row in rows)
        for (final String? source in <String?>[
          row.subtitleSource,
          row.secondarySubtitleSource,
        ])
          if (source != null && isLocalVideoFilePath(source))
            platformPathKey(source.trim()),
    };

/// 把选择器交回的视频路径变成**可长期落库**的路径（反馈 HfXM-ECaE8）。
///
/// [isRealPath] = true（桌面 / 安卓 SAF 解析到原始位置 / 拖入）原样返回，不复制。
/// false = 平台临时副本（iOS import 模式的 `NSTemporaryDirectory()`、安卓 app
/// cache）：系统清 tmp、词典 / 外部阅读器导入调 `FilePicker.clearTemporaryFiles()`
/// 都会把它删掉。这里把它**挪**进
/// `<copiesRoot>/<sanitize(bookUid)>/<原文件名>` 再返回新路径：先 rename（同卷零
/// 额外空间），跨卷失败才退回 copy + 删源。保留原文件名，标题 / sidecar 派生不变。
///
/// 目标目录按 bookUid 归属 app 自有；同名旧文件（重新选择文件、或同 uid 删后重导
/// 的残留）先删再落。复制成功但删源失败时撤掉新副本再抛，不留两份。
Future<String> adoptPickedVideoCopy({
  required String pickedPath,
  required bool isRealPath,
  required String bookUid,
  required Directory copiesRoot,
}) async {
  if (isRealPath) return pickedPath;
  final Directory dir = Directory(
    p.join(copiesRoot.path, sanitizeTtuFilename(bookUid)),
  );
  await dir.create(recursive: true);
  final String target = p.join(dir.path, p.basename(pickedPath));
  if (platformPathKey(target) == platformPathKey(pickedPath)) return target;
  final File existing = File(target);
  if (await existing.exists()) await existing.delete();
  final File source = File(pickedPath);
  try {
    await source.rename(target);
    return target;
  } on FileSystemException {
    // rename 跨文件系统 / 跨卷会失败（EXDEV）：走 copy + 删源。源文件本身不在
    // 时 copy 照样抛，真实失败不会被这里吞掉。
  }
  final File copied = await source.copy(target);
  try {
    await source.delete();
  } on FileSystemException {
    await copied.delete();
    rethrow;
  }
  return target;
}
