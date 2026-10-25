// 视频库条目路径（`VideoBooks.videoPath`）的「文件在不在」判据——全仓唯一入口。
//
// 库里的路径不全是「一个真实存在的媒体文件」：
//
//   - 蓝光标题是真实的 `BDMV/PLAYLIST/*.mpls`，但媒体字节在 `STREAM/*.m2ts` 里；
//   - DVD 标题是虚拟路径 `<盘根>/VIDEO_TS/TITLE_nn.dvdtitle`（盘根可以是 `.iso`），
//     磁盘上根本没有这个文件（`dvd_title_path.dart`）；
//   - 网络流 / `.strm` 在本机没有媒体字节（`lacksLocalMediaFile`）。
//
// 于是「文件在不在」有三种互不相同的问法，各给一个入口，**不许再对库路径裸调
// `File(videoPath).exists*`**（守卫 `fushi/test/build/video_member_file_exists_guard_test.dart`）：
//
//   1. **这一条还在不在**（库条目 / 盘是否还在磁盘上，搬家、离线判据）——
//      [videoMemberExists] / [videoMemberExistsSync]。原盘成员换成它背后真实存在的那个
//      文件再判（`discMemberBackingFilePath`）：DVD → `VIDEO_TS.IFO` 或 `.iso`。
//   2. **本机有没有可直接读的媒体文件**（抽帧、哈希、上传、ASR、字幕抽取、弹幕指纹）
//      —— [hasLocalMediaFile] / [hasLocalMediaFileSync]。没有媒体字节的路径（网络流、
//      `.strm`、DVD title）一律 false，不去碰文件系统；DVD 的媒体要经原生 libdvdnav
//      按 title 读，不能把 IFO 或 VOB 当成这一条的媒体文件。
//   3. **这个路径本身是不是一个文件**（把它当文件处理：打进备份包、在它旁边放
//      sidecar 字幕）—— [videoPathFileExists] / [videoPathFileExistsSync]。本地
//      `.strm` 指针、蓝光 `.mpls` 是真文件，照常为真；DVD title 是虚拟路径，恒为假。

import 'dart:io';

import 'package:fushi_engine/media/video/disc/disc_format.dart'
    show discMemberBackingFilePath;
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart'
    show isDvdTitlePath;
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

/// [videoPath] 这个路径本身是不是磁盘上的一个文件（见文件头第 3 种问法）：DVD title
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

/// [videoPath] 在本机是否是一个可直接读字节的媒体文件（见文件头第 2 种问法）。
bool hasLocalMediaFileSync(String videoPath) {
  if (videoPath.isEmpty || lacksLocalMediaFile(videoPath)) return false;
  return File(videoPath).existsSync();
}

/// [hasLocalMediaFileSync] 的异步版。
Future<bool> hasLocalMediaFile(String videoPath) async {
  if (videoPath.isEmpty || lacksLocalMediaFile(videoPath)) return false;
  return File(videoPath).exists();
}
