// 视频库条目路径（`VideoBooks.videoPath`）的「文件在不在」判据——全仓唯一入口。
//
// 库里的路径不全是「一个真实存在的媒体文件」：
//
//   - 蓝光标题是真实的 `BDMV/PLAYLIST/*.mpls`，但媒体字节在 `STREAM/*.m2ts` 里；
//     按集展开的分集是虚拟路径 `PLAYLIST/00001.p03.mpls`（`bluray_episode.dart`），
//     背后真实存在的是 `00001.mpls`——第 1、2 种问法里它与真实标题同口径，第 3、4 种
//     问法为假；
//   - DVD 标题是虚拟路径 `<盘根>/VIDEO_TS/TITLE_nn.dvdtitle`（盘根可以是 `.iso`），
//     磁盘上根本没有这个文件（`dvd_title_path.dart`）；
//   - 网络流 / `.strm` 在本机没有媒体字节（`lacksLocalMediaFile`）。
//
// 于是「文件在不在」有四种互不相同的问法，各给一个入口，**不许再对库路径裸调
// `File(videoPath).exists*`**（守卫 `fushi/test/build/video_member_file_exists_guard_test.dart`）：
//
//   1. **这一条还在不在**（库条目 / 盘是否还在磁盘上，搬家、离线判据）——
//      [videoMemberExists] / [videoMemberExistsSync]。原盘成员换成它背后真实存在的那个
//      文件再判（`discMemberBackingFilePath`）：DVD → `VIDEO_TS.IFO` 或 `.iso`。
//   2. **本机能不能经 ffmpeg / 原生解码器读到这条的媒体**（抽帧、抽字体、内嵌轨证据、
//      ASR 解码——都走 `ffmpeg_backend`：蓝光整卷与分集由 `prepareBlurayFfmpegArgs`
//      换成盘上的 m2ts，DVD title 由 `DvdFfmpegBackend` 改写成统一 FFmpeg 的
//      `dvdvideo` demuxer 按 title 读，CSS 由随包 libdvdcss 解）—— [hasLocalMediaFile] /
//      [hasLocalMediaFileSync]。没有本机媒体字节的路径（网络流、`.strm`）一律 false；DVD
//      title 按盘（`VIDEO_TS.IFO` / `.iso`）在不在判。**判真之后不许对这个路径直接
//      `File(...).length/open/read`**：蓝光分集与 DVD title 是虚拟路径，整卷 `.mpls`
//      只是几百字节的索引。
//   3. **这个路径本身就是装着全部媒体字节的单文件**（按字节读：互联 / 云上传、
//      弹幕文件指纹、按文件长度定身份）—— [hasLocalSingleMediaFile] /
//      [hasLocalSingleMediaFileSync]。原盘成员（蓝光整卷 / 分集、DVD title）一律
//      false，其余同第 2 种。为真则 `File(path)` 可直接读字节。
//   4. **这个路径本身是不是一个文件**（把它当文件处理：打进备份包、在它旁边放
//      sidecar 字幕）—— [videoPathFileExists] / [videoPathFileExistsSync]。本地
//      `.strm` 指针、蓝光 `.mpls` 是真文件，照常为真；DVD title 与蓝光分集 / 角度成员是虚拟路径，
//      为假。

import 'dart:io';

import 'package:fushi_engine/media/video/bluray/bluray_angle.dart'
    show blurayMemberBackingPlaylistPath;
import 'package:fushi_engine/media/video/bluray/bluray_source.dart'
    show isBlurayPlaylistPath;
import 'package:fushi_engine/media/video/disc/disc_format.dart'
    show discMemberBackingFilePath;
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart'
    show isDvdTitlePath;
import 'package:fushi_engine/media/video/media_path_probe.dart';

export 'package:fushi_engine/media/video/media_path_probe.dart'
    show MediaPathPresence, kMediaPathProbeTimeout;
import 'package:fushi_engine/media/video/strm_file.dart'
    show lacksLocalMediaFile;

/// 库条目 [videoPath] 背后应当存在于磁盘上的那个文件（原盘成员换成盘上的真实文件，
/// 其余原样）。
String videoMemberPresencePath(String videoPath) =>
    discMemberBackingFilePath(videoPath);

/// 库条目 [videoPath] 是否还在磁盘上（见文件头第 1 种问法）。
bool videoMemberExistsSync(String videoPath) {
  if (videoPath.isEmpty) return false;
  return File(videoMemberPresencePath(videoPath)).existsSync();
}

/// [videoMemberExistsSync] 的异步版。
Future<bool> videoMemberExists(String videoPath) async {
  if (videoPath.isEmpty) return false;
  return File(videoMemberPresencePath(videoPath)).exists();
}

/// [videoMemberExists] 的有界三态版（BUG-5605）：UI isolate 上的播放 / 缩略图 / 制卡路径
/// 用它。库条目常在网络盘上，卷卡住时答 [MediaPathPresence.unavailable]，调用方按「暂不
/// 可用」处理，不当成文件丢失（见 `media_path_probe.dart`）。
Future<MediaPathPresence> probeVideoMember(
  String videoPath, {
  Duration timeout = kMediaPathProbeTimeout,
}) {
  if (videoPath.isEmpty) {
    return Future<MediaPathPresence>.value(MediaPathPresence.missing);
  }
  return probeMediaPath(videoMemberPresencePath(videoPath), timeout: timeout);
}

/// [hasLocalMediaFile] 的有界三态版（BUG-5605）。没有本机媒体字节的路径（网络流、
/// `.strm`）恒 [MediaPathPresence.missing]，不碰文件系统。
Future<MediaPathPresence> probeLocalMediaFile(
  String videoPath, {
  Duration timeout = kMediaPathProbeTimeout,
}) {
  final String? backing = _mediaBackingPath(videoPath);
  if (backing == null) {
    return Future<MediaPathPresence>.value(MediaPathPresence.missing);
  }
  return probeMediaPath(backing, timeout: timeout);
}

/// [videoPath] 这个路径本身是不是磁盘上的一个文件（见文件头第 4 种问法）：DVD title
/// 是虚拟路径，恒 false 且不碰文件系统；其余（含本地 `.strm` 指针、蓝光 `.mpls`）
/// 按磁盘判。
bool videoPathFileExistsSync(String videoPath) {
  if (videoPath.isEmpty || isDvdTitlePath(videoPath)) return false;
  return File(videoPath).existsSync();
}

/// [videoPathFileExistsSync] 的异步版。
Future<bool> videoPathFileExists(String videoPath) async {
  if (videoPath.isEmpty || isDvdTitlePath(videoPath)) return false;
  return File(videoPath).exists();
}

/// 本机能否经 ffmpeg / 原生解码器读到 [videoPath] 的媒体（见文件头第 2 种问法）。
/// 原盘成员换成它背后真实存在的文件判（[_mediaBackingPath]）。判真不代表
/// `File(videoPath)` 可读字节，要按字节读用 [hasLocalSingleMediaFileSync]。
bool hasLocalMediaFileSync(String videoPath) {
  final String? backing = _mediaBackingPath(videoPath);
  return backing != null && File(backing).existsSync();
}

/// [hasLocalMediaFileSync] 的异步版。
Future<bool> hasLocalMediaFile(String videoPath) async {
  final String? backing = _mediaBackingPath(videoPath);
  return backing != null && await File(backing).exists();
}

/// 第 2 种问法要判存在的那个真实文件：DVD title（虚拟路径，`DvdFfmpegBackend` 按 title
/// 读）→ 盘的 `VIDEO_TS.IFO` / `.iso`（[discMemberBackingFilePath]，形状不对的 title
/// 路径换不出盘根，原样返回、判不存在）；蓝光分集 / 角度成员 → 它背后的 `.mpls`；没有
/// 本机媒体字节的（网络流、`.strm`）→ null。
String? _mediaBackingPath(String videoPath) {
  if (videoPath.isEmpty) return null;
  if (isDvdTitlePath(videoPath)) return discMemberBackingFilePath(videoPath);
  if (lacksLocalMediaFile(videoPath)) return null;
  return blurayMemberBackingPlaylistPath(videoPath);
}

/// 只看路径就能断定 [videoPath] 本身不是装着媒体字节的单文件：网络流、`.strm`、
/// 原盘成员（蓝光 `.mpls` 整卷 / 分集、DVD title）。纯函数，不碰文件系统——给只做
/// 粗筛、不想 stat 的地方用（如上传候选枚举），真要读字节前仍过
/// [hasLocalSingleMediaFile]。
bool videoPathLacksSingleMediaFile(String videoPath) =>
    videoPath.isEmpty ||
    lacksLocalMediaFile(videoPath) ||
    isBlurayPlaylistPath(videoPath) ||
    isDvdTitlePath(videoPath);

/// [videoPath] 本身是不是本机上装着全部媒体字节的单文件（见文件头第 3 种问法）：
/// 为真则 `File(videoPath)` 可以直接 `length` / `open` / `read`。原盘成员、网络流、
/// `.strm` 恒 false，不碰文件系统。
bool hasLocalSingleMediaFileSync(String videoPath) {
  if (videoPathLacksSingleMediaFile(videoPath)) return false;
  return File(videoPath).existsSync();
}

/// [hasLocalSingleMediaFileSync] 的异步版。
Future<bool> hasLocalSingleMediaFile(String videoPath) async {
  if (videoPathLacksSingleMediaFile(videoPath)) return false;
  return File(videoPath).exists();
}
