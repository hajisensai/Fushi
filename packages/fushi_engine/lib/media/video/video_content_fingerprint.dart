/// 视频内容指纹：来源扫描认「同名文件挪了位置」是不是同一个文件的直接证据（拍板台
/// design-nmv-video-move-fingerprint，表 `video_content_fingerprints`，schema v165）。
///
/// 指纹必须在文件**还在原处时**算好存下——搬家之后旧路径已经没有文件。所以有两个入口：
/// 来源扫描新建 / 改指一行时当场记（[recordVideoContentFingerprint]），以及
/// [backfillVideoContentFingerprints] 给存量行补算（升级后第一次、手动导入的行、
/// 文件原地换掉后重算）。
///
/// 算法：不小于 128 KiB 的文件用 OpenSubtitles 文件哈希（大小 + 首尾各 64 KiB 的
/// 64 位累加和，[computeOpenSubtitlesMovieHash]）——只读 128 KiB，网络盘上几千个文件
/// 也读得起，且同一份片源在各处算出来一致；更小的文件整份 SHA-256。两种都带前缀，
/// 比较时再加上字节数（大小不等必不是同一个文件）。
library;

import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart'
    show computeOpenSubtitlesMovieHash;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// OpenSubtitles 哈希要求的最小文件大小（首尾各 64 KiB）。
const int _kOpenSubtitlesHashMinBytes = 128 * 1024;

/// 一个文件此刻的内容指纹。
@immutable
class VideoContentFingerprint {
  const VideoContentFingerprint({
    required this.sizeBytes,
    required this.modifiedAtMs,
    required this.value,
  });

  final int sizeBytes;
  final int modifiedAtMs;

  /// `osh:<16 位十六进制>` 或 `sha256:<64 位十六进制>`。
  final String value;

  /// 与库里记下的 [row] 是不是同一份内容（字节数与指纹都相等）。
  bool sameContentAs(VideoContentFingerprintRow row) =>
      row.fileSizeBytes == sizeBytes && row.fingerprint == value;

  VideoContentFingerprintsCompanion toCompanion(String bookUid, int nowMs) =>
      VideoContentFingerprintsCompanion.insert(
        bookUid: bookUid,
        fileSizeBytes: sizeBytes,
        fileModifiedAt: modifiedAtMs,
        fingerprint: value,
        computedAt: nowMs,
      );
}

/// 算 [path] 的内容指纹。不是普通文件、读不了、或者算的期间文件变了（还在下载 /
/// 被改写）时为 null——拿不准就不给证据。async：库根常在网络盘上（BUG-3756）。
Future<VideoContentFingerprint?> computeVideoContentFingerprint(
  String path,
) async {
  try {
    final File file = File(path);
    final FileStat before = await file.stat();
    if (before.type != FileSystemEntityType.file) return null;
    final String value;
    if (before.size >= _kOpenSubtitlesHashMinBytes) {
      final String? osh = await computeOpenSubtitlesMovieHash(path);
      if (osh == null) return null;
      value = 'osh:$osh';
    } else {
      value = 'sha256:${sha256.convert(await file.readAsBytes())}';
    }
    final FileStat after = await file.stat();
    if (after.type != FileSystemEntityType.file ||
        after.size != before.size ||
        after.modified != before.modified) {
      return null;
    }
    return VideoContentFingerprint(
      sizeBytes: before.size,
      modifiedAtMs: before.modified.millisecondsSinceEpoch,
      value: value,
    );
  } on FileSystemException {
    return null;
  }
}

/// 给 [bookUid] 记下 [fingerprint]（同键覆盖）。
Future<void> recordVideoContentFingerprint(
  FushiDatabase db,
  String bookUid,
  VideoContentFingerprint fingerprint,
) => db.upsertVideoContentFingerprint(
  fingerprint.toCompanion(bookUid, DateTime.now().millisecondsSinceEpoch),
);

/// [row] 是不是能记内容指纹的视频：本地普通文件（不是流媒体 / 播放列表 / URL）、
/// 绝对路径。
bool isVideoContentFingerprintCandidate(VideoBookRow row) {
  final String path = row.videoPath;
  if (row.playlistJson != null || row.streamSpecJson != null) return false;
  if (path.isEmpty || path.contains('://')) return false;
  return p.isAbsolute(path);
}

/// 给库里的视频行补算 / 重算内容指纹，返回写入的行数。
///
/// - 还没有指纹的行：文件在就算一次（升级后第一次、手动导入或别的入口进来的行）；
/// - 已有指纹的行只在 [recheckUids] 里才 stat 比对，大小或修改时刻变了（文件原地被
///   换掉）就重算。默认不复查：书架后台补算只管缺的，来源扫描只复查本轮扫到的文件，
///   不为全库每个文件每次都 stat 一遍网络盘。
/// - 盘根不在线（移动硬盘没插、网络盘没挂）的行整根跳过，每个根只探一次。
/// - 最后清掉已经没有对应视频行的指纹。
///
/// [known] 给了就复用（调用方刚取过整表），否则这里取一次。[fingerprintOf] 供测试替换。
Future<int> backfillVideoContentFingerprints(
  FushiDatabase db, {
  List<VideoBookRow>? rows,
  Map<String, VideoContentFingerprintRow>? known,
  Set<String> recheckUids = const <String>{},
  Future<VideoContentFingerprint?> Function(String path) fingerprintOf =
      computeVideoContentFingerprint,
  bool Function()? isCancelled,
}) async {
  final List<VideoBookRow> all = rows ?? await (db.select(db.videoBooks)).get();
  final Map<String, VideoContentFingerprintRow> existing =
      known ?? await db.allVideoContentFingerprints();
  final Map<String, bool> rootOnline = <String, bool>{};
  int written = 0;
  for (final VideoBookRow row in all) {
    if (isCancelled?.call() ?? false) break;
    if (!isVideoContentFingerprintCandidate(row)) continue;
    final VideoContentFingerprintRow? have = existing[row.bookUid];
    final bool recheck = recheckUids.contains(row.bookUid);
    if (have != null && !recheck) continue;
    final String path = row.videoPath;
    final String root = p.rootPrefix(path);
    final bool online = rootOnline[root] ??= await _directoryExists(root);
    if (!online) continue;
    final FileStat stat;
    try {
      stat = await File(path).stat();
    } on FileSystemException {
      continue;
    }
    if (stat.type != FileSystemEntityType.file) continue;
    if (have != null &&
        have.fileSizeBytes == stat.size &&
        have.fileModifiedAt == stat.modified.millisecondsSinceEpoch) {
      continue;
    }
    final VideoContentFingerprint? now = await fingerprintOf(path);
    if (now == null) continue;
    await recordVideoContentFingerprint(db, row.bookUid, now);
    written++;
  }
  await db.pruneOrphanVideoContentFingerprints();
  return written;
}

Future<bool> _directoryExists(String path) async {
  if (path.isEmpty) return false;
  try {
    return await Directory(path).exists();
  } on FileSystemException {
    return false;
  }
}
