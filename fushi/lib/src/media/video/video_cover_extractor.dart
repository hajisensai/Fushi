/// 视频封面抽取器：视频书架封面的**初始落盘产线**（导入/扫描期）。
///
/// 审计 §1-A（目录归属）：这批封面逻辑原先住在
/// `utils/misc/desktop_audio_clipper.dart`（音频剪辑工具文件，与封面无关），
/// 现迁到 `media/video/`。**通用单帧抓取原语**（`buildFfmpegFrameArgs` /
/// `extractVideoFrameViaFfmpeg`）留在原文件——它同时服务制卡截图
/// （`immersion_mining_engine.dart`）与进度条缩略图预览
/// （`video_thumbnail_preview_controller.dart`），不是封面专属；本文件只
/// 消费它做「无内嵌封面时退回抽帧」。
///
/// 覆盖三条初始封面来源（输出统一为
/// `<documents>/video_covers/<sanitize(bookUid)>.jpg`，与手动/刮削封面同目录
/// 同命名，红线：目录名与文件名派生冻结不动）：
///   1. 容器内嵌封面（mkv `cover.*` 附件 / mp4 attached_pic 海报）；
///   2. ffmpeg 抽帧（默认 10s 避开黑场片头；播放列表遍历到首个可用集）；
///   3. 远端缩略图 URL 下载（流媒体书，如 YouTube hqdefault）。
///
/// 与 `MediaCoverService` 的分工：本文件的 **ffmpeg 两条路**（内嵌封面 / 抽帧）
/// 是导入期首写——写盘方是 ffmpeg 子进程、直接以目标路径为输出，Dart 侧无字节可
/// 交给收口，属于 `media_cover_write_guard_test.dart` 的记录在案豁免。**Dart 侧
/// 有字节的路（[downloadVideoCoverToPath]）不在豁免内**，一律走
/// `MediaCoverService.applyCoverBytes` 收口（原子落盘 + 双键驱逐）：它被番剧下载
/// 重放、流媒体换封面、导入弹窗重取三处**覆盖写**复用，按首写豁免裸写就是
/// BUG-1118。该豁免的边界由守卫**逐函数**钉死，不再是整文件放行（BUG-1394）。
library;

import 'dart:io';

import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/media_extensions.dart'
    show kPlaylistManifestExtensions;
import 'package:fushi/src/media/metadata/image_download.dart'
    show looksLikeImageBytes;
import 'package:fushi/src/media/video/ffmpeg_backend.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart'
    show extractVideoFrameViaFfmpeg;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/safe_file_name.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/utils/net/app_http.dart';

/// Builds the ffmpeg argument list to extract the **embedded cover art** of a
/// video container (e.g. an mkv with a `cover.jpg`/`cover.png` attachment, or an
/// mp4 with an `attached_pic` poster) into [outputPath]. Pure (no IO) so it is
/// unit-testable.
///
/// `-map 0:v:disp:attached_pic` selects **only** the video stream(s) whose
/// disposition is `attached_pic` — the cover art. Crucially there is **no**
/// trailing `?`: when the input has no cover art the map matches no stream and
/// ffmpeg exits non-zero **without writing any file**, so the caller can tell
/// "no embedded cover" apart from "extracted a cover" and fall back to a frame
/// grab. (A trailing `?` would make ffmpeg silently fall through to the main
/// video's first frame, defeating the prefer-embedded distinction.)
///
/// Matroska stores cover art as a file **attachment** (`filename=cover.*`,
/// `mimetype=image/*`); ffmpeg surfaces it as a video stream tagged
/// `(attached pic)` with the `attached_pic` disposition, which this selector
/// matches. `-vcodec copy` is intentionally **not** used: re-encoding to the
/// output extension (jpg) normalises png/webp/etc. covers to a uniform thumbnail
/// the shelf can display, same as the frame-grab path.
List<String> buildFfmpegEmbeddedCoverArgs({
  required String inputPath,
  required String outputPath,
}) {
  return <String>[
    '-y',
    '-i',
    inputPath,
    '-an',
    '-map',
    '0:v:disp:attached_pic',
    '-frames:v',
    '1',
    '-update',
    '1',
    outputPath,
  ];
}

/// Extracts the **embedded cover art** of the video [inputPath] into
/// [outputPath] via ffmpeg (see [buildFfmpegEmbeddedCoverArgs]). Returns
/// [outputPath] if a cover was written, else null — null specifically means
/// "this container has no embedded cover art" (the map matched no stream), so
/// the import flow falls back to [extractVideoFrameViaFfmpeg].
///
/// Mirrors [extractVideoFrameViaFfmpeg]: bounded timeout, drops partial output
/// on timeout, never throws for the caller (no ffmpeg on mobile / no cover both
/// yield null, not a crash). A non-zero ffmpeg exit (no matching cover stream)
/// is treated as "no cover", not fatal.
Future<String?> extractEmbeddedVideoCoverViaFfmpeg({
  required String inputPath,
  required String outputPath,
}) async {
  if (!File(inputPath).existsSync()) return null;
  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    final FfmpegRunResult result = await resolveFfmpegBackend().run(
      buildFfmpegEmbeddedCoverArgs(
        inputPath: inputPath,
        outputPath: outputPath,
      ),
      const Duration(seconds: 30),
    );
    final int? code = result.returnCode;
    if (code == null) {
      if (output.existsSync()) {
        try {
          output.deleteSync();
        } catch (_) {}
      }
      return null;
    }
    // No-cover containers exit non-zero ("Stream map matches no streams") and
    // write nothing; rely on the output file to discriminate.
    if (output.existsSync() && output.lengthSync() > 0) return outputPath;
    return null;
  } on ProcessException catch (e, stack) {
    ErrorLogService.instance
        .log('extractEmbeddedVideoCoverViaFfmpeg', e, stack);
    return null;
  } catch (e, stack) {
    ErrorLogService.instance
        .log('extractEmbeddedVideoCoverViaFfmpeg', e, stack);
    return null;
  }
}

/// 纯函数：[path] 是否是播放列表清单文件（`.m3u8`/`.m3u`，大小写不敏感）。
///
/// 清单是**文本列表**不是媒体流本体：本地清单喂 ffmpeg 抽帧必然
/// `Invalid data found when processing input`。判定只看扩展名（与导入/扫描分类
/// 同一判据，真相源 [kPlaylistManifestExtensions]），不做 IO。
bool isPlaylistManifestPath(String path) =>
    kPlaylistManifestExtensions.contains(p.extension(path).toLowerCase());

/// 纯函数：[videoPath] 是否是「本地可抽帧媒体文件」——封面**回填**队列的候选判据
/// （BUG-1564）。false 的三类各有正当去处，都不该进 ffmpeg 抽帧队列：
/// - 空路径：无源可抽；
/// - `http(s)://` 流 URL：回填不碰网络（流媒体封面走导入期缩略图下载 / host 元数据
///   产线；注意 ffmpeg 本身**能**吃远端流，导入期 `streamImportCoverStrategy` 仍走
///   [extractVideoCover]，本谓词只服务回填候选过滤，不是 ffmpeg 能力判定）；
/// - 本地播放列表清单（[isPlaylistManifestPath]）：文本清单不是媒体流本体，
///   抽帧永远失败——嵌套 m3u8 条目拆集成的行 `videoPath` 就是 `.m3u8` 自身。
bool isLocalFrameExtractableVideoSource(String videoPath) {
  final String path = videoPath.trim();
  if (path.isEmpty) return false;
  if (path.startsWith('http://') || path.startsWith('https://')) return false;
  if (isPlaylistManifestPath(path)) return false;
  return true;
}

/// 封面回填候选判据默认探测的头部字节数（[hasHollowMediaHeader]）。
const int kHollowMediaHeaderProbeBytes = 64 * 1024;

/// 纯函数：[head]（文件**头部**若干字节）是否说明「内容尚未落盘」——空，或全为 `0x00`。
///
/// BUG-1867：判据的正当性在于**每种被支持的容器头部都有魔数**——MPEG-TS 的 `0x47`
/// sync 字节（`.m2ts` 是 192 字节步长、前 4 字节 TP_extra_header）、MP4/MOV 的 `ftyp`、
/// Matroska 的 `1A 45 DF A3`、AVI/WAV 的 `RIFF`、FLV 的 `FLV`。合法媒体文件的头部
/// **不可能**全零，所以「全零 = 还不是媒体」没有误伤面。
bool isHollowMediaHeaderBytes(List<int> head) {
  if (head.isEmpty) return true;
  for (final int byte in head) {
    if (byte != 0) return false;
  }
  return true;
}

/// [path] 的头 [probeBytes] 字节是否「尚未落盘」（见 [isHollowMediaHeaderBytes]）。
///
/// BUG-1867 根因②：torrent **预分配但未下载完成**的文件在文件系统层与真视频完全
/// 一致——正确的扩展名、正确的字节数（甚至 8GB）、路径存在，`existsSync()` 与
/// [isLocalFrameExtractableVideoSource] 两道判据都放行，只有**内容**还是空洞。喂给
/// ffmpeg 的结果恒是 `Error opening input files: Invalid data found when processing
/// input`。
///
/// 这条判据买的**不是**时间：ffmpeg 在头部就 probe 失败，实测 0.02s/条（本机 12 条
/// 空洞 BDMV 合计 0.3s），一次 64KB 读只把它压到 1.3ms。买的是三件事——
/// ① 不为一个必然失败的抽帧去排 `VideoCoverMutationGate` 的队（同期的删除、手选封面、
/// 刮削要等在后面）；② 把「还没下完」与「这文件坏了」分成两个可诊断的原因，而不是
/// 混成同一个 `extract-failed`；③ 判定不依赖 ffmpeg 的具体行为（构建裁掉某个 demuxer
/// 或换版本都不影响这条判据的正确性）。
///
/// 读失败（权限 / 盘掉线 / 竞态删除）返回 `true`：读不出头部的文件此刻同样抽不出帧，
/// 与其让 ffmpeg 再失败一次，不如按「暂不可用」跳过——文件恢复后 mtime/size 变化会
/// 让 `CoverBackfillLedger` 自动放行重试。
bool hasHollowMediaHeader(String path,
    {int probeBytes = kHollowMediaHeaderProbeBytes}) {
  RandomAccessFile? handle;
  try {
    handle = File(path).openSync();
    final int length = handle.lengthSync();
    if (length <= 0) return true;
    final int wanted = length < probeBytes ? length : probeBytes;
    return isHollowMediaHeaderBytes(handle.readSync(wanted));
  } catch (_) {
    return true;
  } finally {
    try {
      handle?.closeSync();
    } catch (_) {}
  }
}

/// 由 [bookUid] 生成视频封面文件名（无目录），把路径分隔符与 `:` 等非法字符
/// 归一成 `_`，避免 `video/playlist/...` 这类带 `/` `:` 的 bookUid 当文件名非法
/// （尤其 Windows）。纯函数，便于单测。
///
/// TODO-817 M1c 曾从 `video_import_dialog.dart`（UI 层）下沉到
/// `desktop_audio_clipper.dart`；审计 §1-A 再迁到本文件（封面命名的自然归宿）。
/// `video_import_dialog.dart` 仍 re-export 本符号，既有调用点零改动。
String videoCoverFileName(String bookUid) {
  final String safe = safeWindowsFileName(bookUid);
  return '$safe.jpg';
}

/// TODO-1281：把**远端封面 URL**（YouTube 缩略图 `youtubeThumbnailUrl` 等）下载到
/// [outputPath]（调用方用 [videoCoverFileName] + [AppPaths.videoCoversDirectory] 拼出
/// 与 [extractVideoCover] 同目录同命名，书架显示逻辑复用），成功返回 [outputPath]，否则
/// 返回 null（下载失败 / 非 2xx / 空体 / 非图片 / 非法 URL）——**best-effort**，绝不抛：
/// 导入仍成功，书架显示占位。流媒体书 videoPath 是 URL、ffmpeg 抽帧不适用，故封面走
/// 缩略图 URL 下载。
///
/// **落盘走统一收口 [MediaCoverService.applyCoverBytes]**（原子 `.tmp`+rename、失败
/// 不动旧封面、成功后双键驱逐解码缓存），响应体先过 [looksLikeImageBytes] 魔数/
/// Content-Type 校验。本函数虽然住在「导入期首写产线」文件里，实际是被**三个覆盖写
/// 场景**复用的通用下载器（番剧下载重放 `reuseExistingPaths` 覆盖同名文件、流媒体
/// 换封面、导入弹窗重取缩略图）；旧实现的裸 `writeAsBytes` 继承了首写豁免却跑在覆盖
/// 路径上，同路径重下后 UI 命中旧解码缓存 = 显示旧图，正是 BUG-1118 的形状。
///
/// [httpClient] 仅供测试注入（默认自建、用完关闭）；把「下载 IO」与「目录解析」分离，让
/// 本函数无需 path_provider 即可单测（调用方负责解析 [outputPath]）。
Future<String?> downloadVideoCoverToPath({
  required String coverUrl,
  required String outputPath,
  http.Client? httpClient,
}) {
  final VideoScrapeOperationLease? lease =
      VideoScrapeOperationGate.tryEnterOperation();
  if (lease == null) return Future<String?>.value();
  return _downloadVideoCoverToPathUnlocked(
    coverUrl: coverUrl,
    outputPath: outputPath,
    httpClient: httpClient,
  ).whenComplete(lease.release);
}

Future<String?> _downloadVideoCoverToPathUnlocked({
  required String coverUrl,
  required String outputPath,
  required http.Client? httpClient,
}) async {
  final Uri? uri = Uri.tryParse(coverUrl);
  if (uri == null || !uri.hasScheme) return null;
  final http.Client client = httpClient ?? createAppHttpIoClient();
  try {
    final http.Response res = await client.get(uri);
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    if (res.bodyBytes.isEmpty) return null;
    // 非图片（错误页 HTML / 占位文本）不落盘：零字节封面与「一张 404 页面」在书架
    // 上同样是坏图，但后者还会顶掉本来能抽出来的帧。
    if (!looksLikeImageBytes(res.bodyBytes, res.headers['content-type'])) {
      return null;
    }
    await File(outputPath).parent.create(recursive: true);
    await MediaCoverService.applyCoverBytes(
      bytes: res.bodyBytes,
      destPath: outputPath,
    );
    return outputPath;
  } catch (_) {
    return null;
  } finally {
    if (httpClient == null) client.close();
  }
}

/// 提取 [videoPath] 的书架封面存进 app 文档目录的
/// `video_covers/<sanitized bookUid>.jpg`（持久路径，非 temp），返回封面绝对
/// 路径；ffmpeg 缺失（移动端）/失败时返回 null（导入仍成功，书架显示占位）。
///
/// 优先级：**① 视频自带封面**（mkv 的 `cover.*` 附件 / mp4 的 attached_pic 海报，
/// 见 [extractEmbeddedVideoCoverViaFfmpeg]）；自带封面通常是制作方/刮削器精挑的
/// 海报，比随机帧更具代表性。**② 无自带封面再退回抽帧**（[atSeconds] 处一帧，
/// 默认 10s 避开黑场片头）。两路输出同一 outputPath，书架显示逻辑不变。
Future<String?> extractVideoCover({
  required String videoPath,
  required String bookUid,
  double atSeconds = 10.0,
  // BUG-891：远端自签主机的 TLS 证书 SHA-256 钉扎指纹（透传给抽帧 ffmpeg），非远端/公网源为 null。
  String? tlsPinSha256,
  // BUG-1867：best-effort 后台产线（书架封面回填）把抽帧失败降级成诊断日志，见
  // [extractVideoFrameViaFfmpeg]。用户主动触发的导入/换封面路径保持默认 false。
  bool diagnosticOnly = false,
}) {
  final VideoScrapeOperationLease? lease =
      VideoScrapeOperationGate.tryEnterOperation();
  if (lease == null) return Future<String?>.value();
  return _extractVideoCoverUnlocked(
    videoPath: videoPath,
    bookUid: bookUid,
    atSeconds: atSeconds,
    tlsPinSha256: tlsPinSha256,
    diagnosticOnly: diagnosticOnly,
  ).whenComplete(lease.release);
}

Future<String?> _extractVideoCoverUnlocked({
  required String videoPath,
  required String bookUid,
  required double atSeconds,
  required String? tlsPinSha256,
  required bool diagnosticOnly,
}) async {
  // BUG-1564：**本地**播放列表清单（.m3u8/.m3u）是文本列表不是媒体流，两条 ffmpeg
  // 路（内嵌封面 / 抽帧）对它都必然失败（`Invalid data found`）——在抽取器层直接
  // 拒收，所有调用方（回填 / 拆集导入遍历嵌套清单条目 / 外部打开 / host 服务）一并
  // 免疫，不再各自烧一次 ffmpeg 子进程。远端 `http(s)://…m3u8` 是 HLS 流、ffmpeg
  // 能直接抽（流媒体导入的 ffmpegFrame 策略依赖这条路），不在拒收之列。
  final bool isRemoteInput =
      videoPath.startsWith('http://') || videoPath.startsWith('https://');
  if (!isRemoteInput && isPlaylistManifestPath(videoPath)) return null;
  // BUG-1867：**本地**文件的内容尚未落盘（头部全零 —— torrent 预分配的空洞文件）时，
  // 两条 ffmpeg 路对它同样必然失败（`Invalid data found`）。与上面的清单拒收同层收口：
  // 所有调用方（回填 / 导入 / 拆集 / host 服务）一并免疫，给出确定性的 null 而不是靠
  // ffmpeg 的行为兜底。远端输入不做本判据（读不到本地字节，且 ffmpeg 能直接吃流）。
  if (!isRemoteInput && hasHollowMediaHeader(videoPath)) return null;
  // TODO-1236：经 AppPaths 解析封面目录（跟随桌面自定义数据根 →
  // `<dataRoot>/documents/video_covers`；默认根仍是平台 Documents），与 TODO-1226
  // 迁移白名单 `video_covers` 一致，避免自定义数据根下新封面落回平台 Documents。
  final Directory coverDir = await AppPaths.videoCoversDirectory();
  final String outputPath = p.join(coverDir.path, videoCoverFileName(bookUid));
  // ① 优先视频自带封面（attached_pic）。
  final String? embedded = await extractEmbeddedVideoCoverViaFfmpeg(
    inputPath: videoPath,
    outputPath: outputPath,
  );
  if (embedded != null) return embedded;
  // ② 无自带封面：退回抽帧。
  return extractVideoFrameViaFfmpeg(
    inputPath: videoPath,
    outputPath: outputPath,
    atSeconds: atSeconds,
    tlsPinSha256: tlsPinSha256,
    diagnosticOnly: diagnosticOnly,
  );
}

/// 视频封面抽取器签名（[extractVideoCover] 的形状）。仅供 [extractPlaylistCover]
/// 注入测试替身，生产路径默认走 [extractVideoCover]。
typedef VideoCoverExtractor = Future<String?> Function({
  required String videoPath,
  required String bookUid,
  double atSeconds,
});

/// 播放列表封面：依次尝试 [episodePaths] 里的各集，返回**首个成功**抽到封面的绝对
/// 路径；全部失败（首集缺失 / 远端占位 / 无可抽帧）返回 null。
///
/// TODO-1237 ①「m3u8 播放列表导入少封面」根因：旧路径只对 `entries.first.path` 调一次
/// [extractVideoCover]，首集一旦不可用（文件缺失、OP/预告短片、远端 URL 占位、m3u8
/// 相对路径没解析到真文件）就整张播放列表卡在书架占位图；而单视频天然只有一个候选、
/// 有 ffmpeg 就有封面。这里遍历到**首个可用集**拿到有代表性的封面，与单视频对齐。单集
/// 播放列表退化为一次 [extractVideoCover] 调用，行为不变。
///
/// [maxAttempts] 限制最多尝试的集数（默认 5），避免整列都不可用（尤其远端每集 ffmpeg
/// 30s 超时）时把导入拖成分钟级。空路径跳过且不计入尝试次数。[extractor] 仅供测试注入。
Future<String?> extractPlaylistCover({
  required List<String> episodePaths,
  required String bookUid,
  double atSeconds = 10.0,
  int maxAttempts = 5,
  @visibleForTesting VideoCoverExtractor? extractor,
}) async {
  final VideoCoverExtractor extract = extractor ?? extractVideoCover;
  int attempts = 0;
  for (final String path in episodePaths) {
    if (path.isEmpty) continue;
    if (attempts >= maxAttempts) break;
    attempts++;
    final String? cover =
        await extract(videoPath: path, bookUid: bookUid, atSeconds: atSeconds);
    if (cover != null) return cover;
  }
  return null;
}
