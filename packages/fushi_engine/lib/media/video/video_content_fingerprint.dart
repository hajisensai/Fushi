/// 视频内容指纹：来源扫描认「同名文件挪了位置」是不是同一个文件的直接证据（拍板台
/// design-nmv-video-move-fingerprint，表 `video_content_fingerprints`，schema v165）。
///
/// 指纹必须在文件**还在原处时**算好存下——搬家之后旧路径已经没有文件。所以有两个入口：
/// 来源扫描新建 / 改指一行时当场记（[recordVideoContentFingerprint]），以及
/// [backfillVideoContentFingerprints] 给存量行补算（升级后第一次、手动导入的行、
/// 文件原地换掉后重算）。
///
/// 两级指纹（拍板台 hbk-audit-004-video-move-full-hash）：
///
/// - `osh:`（采样）：不小于 128 KiB 的文件入库当场算 OpenSubtitles 文件哈希（大小 +
///   首尾各 64 KiB 的 64 位累加和，[computeOpenSubtitlesMovieHash]）——只读 128 KiB，
///   网络盘上几千个文件也读得起。但它**只能排除、不能认定**：同大小、首尾 64 KiB 相同
///   而中间不同的两个文件算出同一个值；
/// - `sha256:`（整文件）：不足 128 KiB 的小文件当场整份算；大文件由
///   [VideoContentFullHashUpgrader] 在后台把 `osh:` 逐个升级（[computeVideoContentFullHash]，
///   读盘与哈希都在原生库、后台 isolate，与制卡 / 互联回跳的 [VideoSourceFingerprint]
///   共用在途去重与缓存，已算过的不重读）。
///
/// 搬家判定（[matchVideoContent]）只有 `sha256:` 对上才算同一个文件；新文件的整文件
/// 哈希只在「旧行有 `sha256:` 且新文件字节数相等」时才算，算出来的结果随改指记回去，
/// 不再重读。
library;

import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart'
    show computeOpenSubtitlesMovieHash;
import 'package:fushi_engine/media/video/video_source_fingerprint.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// OpenSubtitles 哈希要求的最小文件大小（首尾各 64 KiB）。
const int _kOpenSubtitlesHashMinBytes = 128 * 1024;

/// 整文件 SHA-256 指纹的前缀。
const String _kFullHashPrefix = 'sha256:';

/// [fingerprint]（库里存的值）是不是整文件哈希（能认定同一个文件）。
bool isFullVideoContentHash(String fingerprint) =>
    fingerprint.startsWith(_kFullHashPrefix);

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

  /// 是不是整文件哈希（见 [isFullVideoContentHash]）。
  bool get isFullHash => isFullVideoContentHash(value);

  /// 与库里记下的 [row] 指纹相等（字节数与指纹都相等）。两边都是整文件哈希才说明是
  /// 同一份内容；`osh:` 相等只说明采样处相同，见 [matchVideoContent]。
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
      value = '$_kFullHashPrefix${sha256.convert(await file.readAsBytes())}';
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

/// 算 [path] 的整文件 SHA-256 指纹（`sha256:`）。读盘与哈希在原生库、后台 isolate 里做
/// （[VideoSourceFingerprint.instance]：与制卡 / 互联回跳共用在途去重、内存与落盘缓存，
/// 同一文件同一状态只读一遍）。不是普通文件、读不了、或者算的期间文件变了时为 null。
Future<VideoContentFingerprint?> computeVideoContentFullHash(
  String path,
) async {
  try {
    final File file = File(path);
    final FileStat before = await file.stat();
    if (before.type != FileSystemEntityType.file) return null;
    final String digest = await VideoSourceFingerprint.instance.fingerprint(
      path,
    );
    final FileStat after = await file.stat();
    if (after.type != FileSystemEntityType.file ||
        after.size != before.size ||
        after.modified != before.modified) {
      return null;
    }
    return VideoContentFingerprint(
      sizeBytes: before.size,
      modifiedAtMs: before.modified.millisecondsSinceEpoch,
      value: '$_kFullHashPrefix$digest',
    );
  } on FileSystemException {
    return null;
  }
}

/// [matchVideoContent] 的结论。
enum VideoContentMatch {
  /// 整文件哈希相等：同一个文件。
  same,

  /// 字节数或指纹不等：不是同一个文件。
  different,

  /// 旧行只有采样指纹（`osh:`，整文件哈希还没在后台算到），新文件采样相同：既不能
  /// 认定也不能排除。
  unconfirmed,

  /// 新文件读不了 / 算的期间在变：没有结论。
  unknown,
}

/// 新路径 [newPath] 上的文件与旧行记下的指纹 [known] 是不是同一份内容。
///
/// - [known] 是整文件哈希：先比字节数（stat，不读内容），相等才整文件哈希新文件
///   （[fullHashOf]）——同大小的候选才付整份读盘的代价；
/// - [known] 是采样指纹：只算新文件的采样指纹（[sampledOf]），不等即
///   [VideoContentMatch.different]，相等为 [VideoContentMatch.unconfirmed]。
///
/// [fullHashOf] / [sampledOf] 由调用方传入带缓存的版本，算过的结果可以原样记回库里。
Future<VideoContentMatch> matchVideoContent(
  VideoContentFingerprintRow known,
  String newPath, {
  Future<VideoContentFingerprint?> Function(String path) sampledOf =
      computeVideoContentFingerprint,
  Future<VideoContentFingerprint?> Function(String path) fullHashOf =
      computeVideoContentFullHash,
}) async {
  if (isFullVideoContentHash(known.fingerprint)) {
    final FileStat stat;
    try {
      stat = await File(newPath).stat();
    } on FileSystemException {
      return VideoContentMatch.unknown;
    }
    if (stat.type != FileSystemEntityType.file) {
      return VideoContentMatch.unknown;
    }
    if (stat.size != known.fileSizeBytes) return VideoContentMatch.different;
    final VideoContentFingerprint? now = await fullHashOf(newPath);
    if (now == null) return VideoContentMatch.unknown;
    return now.isFullHash && now.sameContentAs(known)
        ? VideoContentMatch.same
        : VideoContentMatch.different;
  }
  final VideoContentFingerprint? now = await sampledOf(newPath);
  if (now == null) return VideoContentMatch.unknown;
  if (!now.sameContentAs(known)) return VideoContentMatch.different;
  return VideoContentMatch.unconfirmed;
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

/// 把库里的采样指纹（`osh:`）逐个升级成整文件 SHA-256，返回写入的行数。
///
/// - 只处理还有视频行、能记指纹（[isVideoContentFingerprintCandidate]）的行；
/// - 盘根不在线的整根跳过（每个根只探一次），文件不在 / 读不了 / 算的期间在变的跳过，
///   下一轮再试；
/// - 一次只算一个文件，每个文件前后查 [isCancelled]（原生整文件哈希本身不可打断，最多
///   等当前这一个）；
/// - 文件原地换过（大小 / 修改时刻与旧指纹不同）照样算：记下的是它现在的内容。
///
/// [fullHashOf] 供测试替换。
Future<int> upgradeVideoContentFingerprintsToFullHash(
  FushiDatabase db, {
  Future<VideoContentFingerprint?> Function(String path) fullHashOf =
      computeVideoContentFullHash,
  bool Function()? isCancelled,
}) async {
  final Map<String, VideoContentFingerprintRow> existing = await db
      .allVideoContentFingerprints();
  final Set<String> pending = <String>{
    for (final VideoContentFingerprintRow row in existing.values)
      if (!isFullVideoContentHash(row.fingerprint)) row.bookUid,
  };
  if (pending.isEmpty) return 0;
  final List<VideoBookRow> rows = await (db.select(
    db.videoBooks,
  )..where(($VideoBooksTable t) => t.bookUid.isIn(pending))).get();
  final Map<String, bool> rootOnline = <String, bool>{};
  int written = 0;
  for (final VideoBookRow row in rows) {
    if (isCancelled?.call() ?? false) break;
    if (!isVideoContentFingerprintCandidate(row)) continue;
    final String root = p.rootPrefix(row.videoPath);
    final bool online = rootOnline[root] ??= await _directoryExists(root);
    if (!online) continue;
    final VideoContentFingerprint? full = await fullHashOf(row.videoPath);
    if (full == null || !full.isFullHash) continue;
    if (isCancelled?.call() ?? false) break;
    await recordVideoContentFingerprint(db, row.bookUid, full);
    written++;
  }
  return written;
}

/// 后台把采样指纹升级成整文件哈希的调度（[upgradeVideoContentFingerprintsToFullHash]），
/// 每个库一个（[of]）。
///
/// 代价：每个本地视频整份读一遍，之后只有新入库 / 原地换过的文件才再读。原生 SHA-256
/// 本机实测约 2 GB/s，瓶颈是盘：本地 SSD 上一部 27 GB 的原盘十几秒，机械盘 / 千兆网络盘
/// 约 100 MB/s（1 TB 约 3 小时）。所以不在扫描当场做（扫描只记 128 KiB 的采样指纹），
/// 扫描结束 / 视频书架打开后在后台一个文件一个文件地算，同一时刻只读一个文件。
/// [request] 在跑的期间再来只记一笔，跑完补一轮；出错记日志、不影响调用方。
class VideoContentFullHashUpgrader {
  VideoContentFullHashUpgrader(
    this._db, {
    Future<VideoContentFingerprint?> Function(String path) fullHashOf =
        computeVideoContentFullHash,
  }) : _fullHashOf = fullHashOf;

  static final Expando<VideoContentFullHashUpgrader> _byDb =
      Expando<VideoContentFullHashUpgrader>('VideoContentFullHashUpgrader');

  /// [db] 的那一个调度器（进程内每个库一个，扫描与书架共用）。
  static VideoContentFullHashUpgrader of(FushiDatabase db) =>
      _byDb[db] ??= VideoContentFullHashUpgrader(db);

  final FushiDatabase _db;
  final Future<VideoContentFingerprint?> Function(String path) _fullHashOf;

  Future<int>? _running;
  bool _again = false;
  bool _disposed = false;

  /// 当前这一轮（含跑的期间请求补的几轮）；没在跑时为 null。供测试等待。
  Future<int>? get running => _running;

  /// 请求跑一轮。在跑 → 跑完补一轮。
  void request() {
    if (_disposed) return;
    if (_running != null) {
      _again = true;
      return;
    }
    _running = _run();
  }

  Future<int> _run() async {
    int total = 0;
    try {
      do {
        _again = false;
        total += await upgradeVideoContentFingerprintsToFullHash(
          _db,
          fullHashOf: _fullHashOf,
          isCancelled: () => _disposed,
        );
      } while (_again && !_disposed);
    } on Object catch (error, stack) {
      engineLog.log('video.contentFullHashUpgrade', error, stack);
    } finally {
      _running = null;
    }
    return total;
  }

  /// 停止：之后不再开新的文件（当前在算的那一个照常在后台 isolate 算完）。
  void dispose() => _disposed = true;
}
