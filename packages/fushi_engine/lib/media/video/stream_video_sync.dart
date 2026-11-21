import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart'
    show downloadVideoCoverToPath, videoCoverFileName;
import 'package:fushi_engine/media/video/youtube_source_resolver.dart'
    show youtubeThumbnailUrl, youtubeVideoIdOrNull;
import 'package:path/path.dart' as p;

/// 互联「流媒体书」元数据同步（拍板台 Z2OhxAjKVv：Mac 与 Android 的 YouTube
/// 观看进度不同步）。
///
/// 进度 / 播放偏好的 live sweep 只对「两端都有的 uid」生效，而「粘贴 URL 导入」/
/// 网页视频站落的流媒体书没有本地字节，从不随视频文件上传到 host，于是两端各看
/// 各的，只有偶然各自导入过同一条时才对得上。这里补的是**行本身**（标题 + URL +
/// 重开规格），不传任何视频字节：行两端都有之后，既有的进度 / 播放偏好 / 看完
/// 标记 sweep 原样接管。
///
/// 范围只取 [isSyncableStreamVideo]：`video/stream/` 身份族（[streamVideoBookUid]
/// 派生，YouTube 规范化成 `video/stream/yt:<id>`，任意设备同一条视频同一个 uid）
/// 且 videoPath 是 http(s) 地址。在线视频源 / 媒体服务器 / 来源库条目依赖本机的
/// 扩展、服务器登录或来源配置，对端拿到也放不了，不在此列。
const String kStreamVideoUidPrefix = 'video/stream/';

/// 清单条目里流媒体书字段的 wire 键（[RemoteStreamVideoEntry]）。
const String kRemoteStreamVideoWireKey = 'stream';

/// 能力位：host 能收 `PUT /api/library/videos/<id>/streamentry`。
const String kLiveLibraryStreamVideosCapability = 'streamVideos';

/// 注册端点的路径后缀。
const String kStreamVideoEntryPathSuffix = 'streamentry';

/// 这条视频行是否走流媒体书元数据同步（见库注释）。
bool isSyncableStreamVideo({
  required String bookUid,
  required String videoPath,
}) {
  if (!bookUid.startsWith(kStreamVideoUidPrefix)) return false;
  if (bookUid.length == kStreamVideoUidPrefix.length) return false;
  final Uri? uri = Uri.tryParse(videoPath.trim());
  if (uri == null || uri.host.isEmpty) return false;
  final String scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

/// 规格 JSON 的上限（字符）：只装外挂字幕 URL + 防盗链 header，正常远小于此。
const int kStreamVideoSpecMaxChars = 16 * 1024;

/// host 视频清单里流媒体书携带的重开信息（`RemoteVideoInfo.stream`）。
///
/// 只有 [isSyncableStreamVideo] 的行才带；client 据此在本机落一本同 uid 的流媒体书。
class RemoteStreamVideoEntry {
  const RemoteStreamVideoEntry({
    required this.url,
    this.streamSpecJson,
    this.addedAt,
  });

  /// `VideoBooks.videoPath`（原始 URL）。
  final String url;

  /// `VideoBooks.streamSpecJson`（外挂字幕 URL / 防盗链 header；null = 无）。
  final String? streamSpecJson;

  /// host 开始拥有这一行的时刻（host 时钟，`VideoBooks.localAddedAt`，缺失回落
  /// `importedAt`）。client 的拉取基线只和同一 host 的这个值比，不跨时钟。
  final int? addedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    if (streamSpecJson != null) 'spec': streamSpecJson,
    if (addedAt != null) 'addedAt': addedAt,
  };

  /// 形状不对返回 null（旧 / 坏数据不让整份清单解析失败）。
  static RemoteStreamVideoEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? url = raw['url'];
    if (url is! String || url.trim().isEmpty) return null;
    final Object? spec = raw['spec'];
    final Object? addedAt = raw['addedAt'];
    return RemoteStreamVideoEntry(
      url: url.trim(),
      streamSpecJson:
          spec is String &&
              spec.isNotEmpty &&
              spec.length <= kStreamVideoSpecMaxChars
          ? spec
          : null,
      addedAt: addedAt is num ? addedAt.toInt() : null,
    );
  }
}

/// client 向 host 注册一本流媒体书的请求体（`PUT .../streamentry`）。
class StreamVideoRegistration {
  const StreamVideoRegistration({
    required this.title,
    required this.url,
    this.streamSpecJson,
    this.importedAt,
  });

  final String title;
  final String url;
  final String? streamSpecJson;

  /// 推送方的入库时刻（展示排序用；host 的拥有时刻另记，见 [RemoteStreamVideoEntry.addedAt]）。
  final int? importedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'url': url,
    if (streamSpecJson != null) 'spec': streamSpecJson,
    if (importedAt != null) 'importedAt': importedAt,
  };

  /// 解析并校验请求体；不合法抛 [FormatException]（端点回 400）。
  factory StreamVideoRegistration.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('stream video registration: not an object');
    }
    final Object? title = raw['title'];
    final Object? url = raw['url'];
    final Object? spec = raw['spec'];
    final Object? importedAt = raw['importedAt'];
    if (url is! String || url.trim().isEmpty) {
      throw const FormatException('stream video registration: missing url');
    }
    if (spec != null &&
        (spec is! String || spec.length > kStreamVideoSpecMaxChars)) {
      throw const FormatException('stream video registration: bad spec');
    }
    return StreamVideoRegistration(
      title: title is String ? title.trim() : '',
      url: url.trim(),
      streamSpecJson: spec is String && spec.isNotEmpty ? spec : null,
      importedAt: importedAt is num ? importedAt.toInt() : null,
    );
  }
}

/// client 推一本流媒体书给 host 的结果。
enum StreamVideoPushResult {
  /// host 新建了这一行。
  created,

  /// host 已有同 uid 的行，没改动。
  existed,

  /// host 的删除墓碑否决了这次推送（「从所有设备删除」之前就在本机的那份）。
  vetoed,
}

/// 一本同步来的流媒体书的建行内容（host 收注册 / client 收清单共用）。
///
/// 标题为空时退回 uid；`importedAt` 缺失取 [nowMs]。`localAddedAt` 不填，由
/// `upsertVideoBook` 记成本机此刻（本机开始拥有的时刻，删除墓碑仲裁依据它）。
VideoBooksCompanion streamVideoRowCompanion({
  required String bookUid,
  required String title,
  required String url,
  required String? streamSpecJson,
  required int? importedAt,
  required int nowMs,
}) => VideoBooksCompanion(
  bookUid: Value<String>(bookUid),
  title: Value<String>(title.isEmpty ? bookUid : title),
  videoPath: Value<String>(url),
  streamSpecJson: Value<String?>(streamSpecJson),
  importedAt: Value<int?>(importedAt ?? nowMs),
);

/// 给同步来的 YouTube 流媒体书补一张缩略图封面（尽力而为，失败返回 null）。
///
/// 只认 YouTube：缩略图地址由 videoId 直接派生，不必抓页面；其它直链 / HLS 没有
/// 现成的图可取，留占位（与导入对话框对网页站的处置一致）。已有封面不动。目的地
/// 派生后交给 [downloadVideoCoverToPath] 收口落盘，本文件自己不写字节。
Future<String?> backfillStreamVideoThumbnailCover(
  FushiDatabase db, {
  required String bookUid,
  required String url,
  required Directory coversDir,
}) async {
  final String? videoId = youtubeVideoIdOrNull(url);
  if (videoId == null || videoId.isEmpty) return null;
  final VideoBookRow? row = await db.getVideoBookByBookUid(bookUid);
  if (row == null) return null;
  if (row.coverPath != null && row.coverPath!.isNotEmpty) return null;
  final String? cover = await downloadVideoCoverToPath(
    coverUrl: youtubeThumbnailUrl(videoId),
    outputPath: p.join(coversDir.path, videoCoverFileName(bookUid)),
  );
  if (cover == null) return null;
  await db.updateVideoBookCover(bookUid, cover);
  return cover;
}
