import 'dart:io';

import 'package:fushi_engine/media/video/dandanplay_file_key.dart'
    show DandanplayFileKey;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataWork;
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_library_source.dart';

/// **任何**远端视频来源都具备的能力：列清单 + 按 id 把整片下载到本地。
///
/// 互联 host 的 live 库与云盘的 `__videos__/` 目录都能做到这两件事，所以库页的
/// 「列清单 → 混排占位卡 → 点击下载入库」这条主干可以只依赖本接口，不必知道背后
/// 是哪一种源。
///
/// **为什么要分成两级**（TODO-2119）——此前只有 [RemoteVideoClient] 一个接口，而
/// 云盘没有 live host、给不出流播 URL / 外挂字幕 / 跨端断点，于是
/// `CloudRemoteVideoClient` 干脆**不实现**任何接口，逼得视频页同时持有两个互斥的
/// nullable 字段，每条下载 / 封面 / 字幕路径都要 `if (cloud != null) ... else ...`，
/// 还要在页面里手写一个 manifest→DTO 的适配函数（给 `RemoteVideoInfo` 加字段时
/// 漏改那里，云侧该字段就永远是空的）。
///
/// 反过来让云端 `implements RemoteVideoClient` 再把 4 个方法写成抛异常也不对：那只是
/// 把「能力靠 `is` 判断」换成「调了会抛」，编译器照样拦不住。按能力分级之后，
/// `source is RemoteVideoClient` 是**类型系统认可**的能力判据——拿不到 live 能力的
/// 地方根本调不出流播/字幕/断点方法。
abstract class RemoteVideoSource implements RemoteLibrarySource {
  /// 列出该源可见的远端视频。云盘源在这里就把目录清单适配成 [RemoteVideoInfo]，
  /// 消费方（库页）不再需要知道 manifest 长什么样。
  Future<List<RemoteVideoInfo>> listRemoteVideos();

  /// 把 [id] 对应的视频整片下载到 [dest]。
  ///
  /// 续传口径按源写实：互联走 host live 下载引擎（Range + `.part` + `If-Range`
  /// 验证器，中断可续、host 文件换了就从头下）；云盘是整文件重下，失败清残片、
  /// 无断点续传。
  ///
  /// [onBytes] 报字节级进度 `(已收, 总量)`；续传时 `已收` 从断点偏移起算，总量
  /// 未知为 null。能廉价拿到字节数的源才报。
  ///
  /// [cancelSignal] 完成即请求取消：支持取消的源中止传输并抛
  /// [RemoteDownloadCancelled]（互联保留 `.part` 供下次续传）；不支持的源忽略。
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  });
}

/// [RemoteVideoSource.downloadRemoteVideo] 被 `cancelSignal` 取消。
///
/// 与失败区分开：调用方据此不报错、不清断点（互联源的 `.part` 仍在，下次同一
/// 目标路径的下载从断点续上）。
class RemoteDownloadCancelled implements Exception {
  const RemoteDownloadCancelled([this.message = 'remote download cancelled']);

  final String message;

  @override
  String toString() => 'RemoteDownloadCancelled: $message';
}

/// 具备实时流播 / 外挂字幕 / 跨端断点的远端视频源——只有互联 host 的 live 库有这些
/// 端点（云盘目录只是一堆静态资产，没有服务端能回答这些请求）。
abstract class RemoteVideoClient extends RemoteVideoSource {
  /// 向 host 换取可直接播放的视频 stream URL。[episodeIndex]>0（TODO-885）请求远端
  /// 播放列表的某一集。
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  });

  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  });

  /// 读 host 端记录的视频 [id] 播放断点（TODO-653 跨设备同步）。
  /// 返回 (位置毫秒, 更新时间毫秒)；无记录或不支持时返回 (0, 0)。
  /// [episodeIndex]>0（TODO-885）按集读断点。
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  });

  /// 向 host 上报视频 [id] 的本端播放断点（TODO-653）。host 端「取较新时间戳」决定
  /// 是否覆盖。[updatedAtMs] 为本端写入时刻（epoch 毫秒）。[episodeIndex]>0 按集上报。
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  });
}

/// 「流请求要带 HTTP 头」的可选能力（防盗链 Referer / User-Agent / Cookie 等）。
///
/// 播放页在 load 时把它下发到 libmpv `http-header-fields`（同时给 HLS 画质探测与
/// 同站字幕下载用）。此前只有粘贴 URL 流（`UrlStreamVideoClient`）有这个需求，
/// 播放页写死了 `is UrlStreamVideoClient`；视频源扩展（Aniyomi）解析出的流几乎
/// 全部要带站点 Referer，按能力判而不是按具体类判，两者共用同一条下发路径。
///
/// 值以**当前已解析的流**为准：扩展的每一集、甚至每条画质候选的头都可能不同，
/// 实现应在 [RemoteVideoClient.remoteVideoStreamUrls] 返回时把该集的头记下来，
/// 播放页紧接着的 load 读到的就是这一份。
abstract interface class RemoteVideoStreamHeaders {
  Map<String, String> get httpHeaderFields;
}

/// 「host 能回传图形字幕整轨」的可选能力（互联 host：它有原文件）。
///
/// 图形字幕（PGS / VobSub / DVB）由 libmpv 自绘，播放页要每句的起止才能制卡锚句；
/// host 在本机把那一条字幕轨原样抽出来（几百 KB）回传，client 不为字幕把整片再读一遍。
/// 媒体服务器 / URL 流没有这种端点，不实现本能力（它们的整轨抽取走流地址）。
abstract interface class RemoteVideoGraphicSubtitleTrackFetch {
  /// 把视频 [id] 第 [embeddedStreamIndex] 条字幕轨（host 的
  /// [RemoteVideoEmbeddedSubtitleTrack.streamIndex]）的整轨载荷下载到 [dest]。host 不支持
  /// （老 host 404 / 没接入抽取 501 / 编码不支持 415）或抽取失败时抛错。
  Future<void> getRemoteVideoGraphicSubtitleTrack(
    String id,
    File dest, {
    required int embeddedStreamIndex,
    int episodeIndex = 0,
  });

  /// 同一条轨的轨头（JSON：编码 + 载荷里没有的 extradata，如 VobSub 调色板 / DVB
  /// 页号）下载到 [dest]。这条轨没有轨头（PGS）或 host 不支持时抛错——调用方据此
  /// 只靠载荷本身解（PGS 段流自带全部信息）。
  Future<void> getRemoteVideoGraphicSubtitleTrackHeader(
    String id,
    File dest, {
    required int embeddedStreamIndex,
    int episodeIndex = 0,
  });
}

/// 「知道某一集的集号」的可选能力（BUG-2626）。
///
/// [RemoteVideoInfo] 只有 `title` 与合集内的 `sortIndex`：前者是分集标题（在线视频源
/// 扩展给的常是 `Episode 1`），后者是**播放序**，含特别篇/OVA 或不从第 1 集开始的季度
/// 时与集号并不相等。而字幕检索要的是集号本身。
///
/// 只有真正持有集号的来源才实现（在线视频源扩展的 `MihonEpisode.number`）；拿不到
/// 集号的来源不实现，调用方回落到按文件名/标题解析，行为与本能力引入前一致。
abstract interface class RemoteVideoEpisodeNumber {
  /// 远端视频 [id] 的集号；不知道则 null（调用方据此回落，不要返回 0 或序号冒充）。
  int? remoteVideoEpisodeNumber(String id);
}

/// 远端视频所属作品的**身份**（字幕检索用，BUG-3199）。
class RemoteVideoTitleIdentity {
  const RemoteVideoTitleIdentity({
    this.originalTitle,
    this.title,
    this.externalIds = const <String, String>{},
    this.isMovie = false,
  });

  /// 作品原名（日文原名等）。
  final String? originalTitle;

  /// 服务器上的作品显示名（常是用户语言的译名）。
  final String? title;

  /// `provider → id`，provider 名小写（`anilist` / `tmdb` / `imdb` / `anidb` …），
  /// 与 `video_metadata_provider_identities.provider` 同口径。
  final Map<String, String> externalIds;

  final bool isMovie;
}

/// 「知道远端视频是哪部作品」的可选能力（BUG-3199）：媒体服务器的条目自带
/// `OriginalTitle` 与 `ProviderIds`，而界面上的标题是服务器的显示名（中文用户的库里
/// 就是中文译名），拿它去日语字幕站搜必然空手。字幕检索先按 ID / 原名搜，没有时
/// 才回落显示名。
abstract interface class RemoteVideoTitleIdentityFetch {
  /// 远端视频 [id] 所属作品的身份；拿不到返回 null（调用方回落显示名）。
  Future<RemoteVideoTitleIdentity?> remoteVideoTitleIdentity(String id);
}

/// 「远端合集就是一部作品」的标记能力（BUG-2626 审查补）。
///
/// 字幕检索预填番名时，只有合集语义 = 作品的来源才能拿合集名当番名：在线视频源
/// 扩展的合集是 `anime.title`、媒体服务器的合集是 `seriesName`。互联 host 的
/// `RemoteCollectionMembership.collectionName` 是 host 库里的 `MediaCollectionRow.name`
/// ——用户自建的「待看」「2024 春番」也在其中，拿它当番名搜必然空手；host 那边
/// `VideoBook.title` 本身就是番名，仍走标题路径。不实现本标记 = 合集名不参与选词。
abstract interface class RemoteVideoCollectionIsWork {}

/// 「播放真正结束」的可选能力。
///
/// 只有 Jellyfin/Emby 这类有会话生命周期端点的来源需要它；周期断点上报仍由
/// [RemoteVideoClient.putRemoteVideoPosition] 负责。单独拆成可选接口，避免 URL 流和
/// 互联 host 被迫实现并不存在的停止协议。
abstract interface class RemoteVideoPlaybackStop {
  /// 上报远端视频 [id] 已停止，位置单位为毫秒。
  Future<void> stopRemoteVideoPlayback(String id, int positionMs);
}

/// 「手动标记已看 / 未看」的可选能力（Jellyfin / Emby 的 PlayedItems 端点）。
///
/// 互联 host 与云盘的「看完」状态归对端自己，没有这个协议，所以单独拆成可选接口，
/// 与 [RemoteVideoPlaybackStop] 同范式：页面 `source is RemoteVideoPlayedMark`
/// 才出对应菜单项。
abstract interface class RemoteVideoPlayedMark {
  /// 把远端视频 [id] 标成已看（[played] = true）或未看。
  Future<void> setRemoteVideoPlayed(String id, {required bool played});
}

/// 「播放会话生命周期」的可选能力——[RemoteVideoPlaybackStop] 的超集。
///
/// Jellyfin / Emby 的会话协议是三段式：`/Sessions/Playing`（开始）→
/// `/Sessions/Playing/Progress`（心跳，含暂停 / 继续事件）→ `/Sessions/Playing/Stopped`。
/// 此前本仓只发后两段：服务器从没见过 Start，仪表盘「正在播放」看不到本客户端、
/// 暂停对服务器不可见（心跳恒 `IsPaused=false`）、服务端也无法把 Progress / Stopped
/// 关联到某一次播放。周期心跳仍走 [RemoteVideoClient.putRemoteVideoPosition]；
/// 暂停 / 继续走 [setRemoteVideoPlaybackPaused]（即时，不受心跳节流）。
abstract interface class RemoteVideoPlaybackSession
    implements RemoteVideoPlaybackStop {
  /// 本次播放真正起播时调（流已打开）。位置单位毫秒。
  Future<void> startRemoteVideoPlayback(String id, int positionMs);

  /// 暂停 / 继续即时上报。
  Future<void> setRemoteVideoPlaybackPaused(
    String id,
    int positionMs, {
    required bool paused,
  });
}

/// [RemoteVideoPlaybackSession] 实现共用的「按条目的本地暂停意图」。
///
/// 周期心跳（[RemoteVideoClient.putRemoteVideoPosition]）不知道播放器此刻是否暂停，
/// 而播放页的断点落库是异步的：后台先暂停、延迟落库后才发的那条心跳若恒报「播放中」，
/// 服务器会把刚暂停的条目重新标成播放中（BUG：Jellyfin #2107 / Plex 同根）。心跳的
/// 播放态因此以这里记的意图为准。
///
/// 契约（各实现必须同样遵守，否则时序窗口重新打开）：
/// - [record] 在暂停 / 继续请求发出**之前**同步调用：请求在途或失败都不改变本地意图，
///   后一条心跳负责把失败的暂停补上。
/// - [reset] 在起播的第一个 await **之前**调用：新一次播放从「播放中」开始。
/// - 停止**不**清除意图：路由销毁时可能在停止上报之后再落一次断点，那不是继续播放。
/// - 意图属于条目：别的条目不受影响。
final class RemotePlaybackPauseIntent {
  final Set<String> _pausedIds = <String>{};

  /// 记录 [id] 的暂停 / 继续意图。
  void record(String id, {required bool paused}) {
    if (paused) {
      _pausedIds.add(id);
    } else {
      _pausedIds.remove(id);
    }
  }

  /// 新一次播放起播：清除 [id] 的暂停意图。
  void reset(String id) => _pausedIds.remove(id);

  /// 心跳读：[id] 最近一次本地意图是否为暂停。
  bool isPaused(String id) => _pausedIds.contains(id);
}

/// 媒体服务器串流画质档（成熟客户端的「画质」菜单：自动 / 1080p 20 Mbps / …）。
///
/// 选档 = 向服务器声明码率上限 + 宽度上限：原文件码率不超上限就仍直播放，超了由
/// 服务器转码到该档。null 上限 = 自动（服务器允许时直播放原文件）。
class MediaServerQualityPreset {
  const MediaServerQualityPreset({
    required this.label,
    required this.maxBitrate,
    required this.maxWidth,
  });

  /// 菜单文案（`1080p · 20 Mbps` 形式，纯数字与单位，不进 i18n）。
  final String label;

  /// 码率上限（bps）。
  final int maxBitrate;

  /// 宽度上限（像素），转码时按它缩。
  final int maxWidth;
}

/// 「串流画质档」的可选能力：只有 Jellyfin / Emby 这类能按 DeviceProfile 协商
/// 直播放 / 转码的来源有它。改档后调用方需重新取流（[RemoteVideoClient.remoteVideoStreamUrls]）。
abstract interface class RemoteVideoQualityLimit {
  List<MediaServerQualityPreset> get qualityPresets;

  /// 当前档在 [qualityPresets] 里的下标；-1 = 自动。
  int get qualityPresetIndex;
  set qualityPresetIndex(int index);
}

/// 同一集的一条可播候选（视频源扩展的「线路 / 画质」：一集常给多家 hoster × 多档
/// 画质，扩展自己排好序）。
class RemoteVideoStreamVariant {
  const RemoteVideoStreamVariant({required this.label});

  /// 菜单文案：扩展给的画质 / 线路名（`1080p` / `Vidstream · 720p`），不进 i18n。
  final String label;
}

/// 「同一集多条可播候选」的可选能力（视频源扩展）。
///
/// 起播**不问用户**：默认那条由实现自己定（扩展标的 `preferred` / 排序第一条），
/// 播放页的画质菜单再列出 [streamVariants] 让用户换线路。改选后调用方须重新取流
/// （[RemoteVideoClient.remoteVideoStreamUrls]），实现要把选择记到下一次取流；列表
/// 以**当前已取流的那一集**为准，换集后随之更新。
abstract interface class RemoteVideoStreamVariants {
  List<RemoteVideoStreamVariant> get streamVariants;

  /// 正在播的那条在 [streamVariants] 里的下标；尚未取流为 -1。
  int get streamVariantIndex;
  set streamVariantIndex(int index);
}

/// 「清单里省掉的重字段按需补齐」的**可选**能力（BUG-1891）。
///
/// 起因是 Jellyfin/Emby：清单请求带 `Fields=MediaSources` 会让服务器为**每一条**
/// 条目展开媒体源（Emby 侧还含外挂字幕的磁盘探测），几十万条目的服务器上一进视频
/// 页就是几十上百个重查询连发。把重字段从「列表阶段人人有份」改成「单条目用到时
/// 才取」之后，清单卡的 `sizeBytes` / `subtitleFileName` 会是空的，需要一个统一的
/// 补齐入口。
///
/// 与 [RemoteVideoPlaybackSync] 同款理由不并进 [RemoteVideoClient]：互联 host 与
/// 云盘的清单本来就是全量下发的，没有「重字段」这回事，硬扩面只会逼十几个测试 fake
/// 补一个恒等实现。消费点用 `client is RemoteVideoDetailFetch` 做类型系统认可的
/// 能力判据。
abstract interface class RemoteVideoDetailFetch {
  /// 用单条目详情补齐 [listInfo]（同 id）。失败时由调用方 best-effort 退回
  /// [listInfo] —— 补字段是锦上添花，不该把下载/信息弹窗整条路径拖死。
  Future<RemoteVideoInfo> remoteVideoDetail(RemoteVideoInfo listInfo);
}

/// 「远端文件的弹幕匹配指纹」的**可选**能力（BUG-3614）。
///
/// 弹幕（弹弹play）按文件名 + 前 16 MiB md5 + 字节数匹配；远端流播时本机没有
/// 文件、算不出指纹，播放页的弹幕于是整条短路——下载到本机后才有弹幕。只有持有
/// 文件的互联 host 能算（媒体服务器 / 云盘 / 在线源没有这个端点），故单列能力，
/// 播放页用 `client is RemoteVideoDanmakuKeyFetch` 判据。
abstract interface class RemoteVideoDanmakuKeyFetch {
  /// 远端视频 [id] 第 [episodeIndex] 集的弹弹play 指纹；host 不支持 / 视频没有
  /// 本地文件返回 null（调用方当作没有弹幕来源，与改动前相同）。
  Future<DandanplayFileKey?> remoteVideoDanmakuKey(
    String id, {
    int episodeIndex = 0,
  });
}

/// 「远端单条视频自己的刮削资料」的**可选**能力（BUG-3613）。
///
/// 合集作品的资料随同步落进本机库（合集行本机有），但独立电影 / 单集作品挂在
/// host 的视频行上，本机没有那一行（`video_metadata_works.book_uid` 外键指向
/// `video_books`），同步只能跳过——远端单条视频因此在库页点开就直接播放，看不到
/// 资料页。资料页改为按需向 host 取这一部的资料。
abstract interface class RemoteVideoWorkMetadataFetch {
  /// 远端视频 [id] 自己拥有的作品资料；host 没刮过 / 不支持返回 null。
  Future<VideoMetadataWork?> remoteVideoWorkMetadata(String id);
}

/// 「播放偏好跨设备同步」的**可选**能力（BUG-1620 调轴起步，播放偏好同步泛化批
/// 扩展为统一带戳字段模型）——只有互联 host 有 `/playback` 端点；URL 直链 /
/// YouTube（[RemoteVideoClient] 的另一个实现 `UrlStreamVideoClient`）没有 host
/// 可上报。
///
/// 不并进 [RemoteVideoClient] 的理由与上面的两级拆分一致：该接口有十余个测试 fake
/// 用 `implements` 全量实现，扩面强制全部补桩；播放页用 `client is
/// RemoteVideoPlaybackSync` 做类型系统认可的能力判据，拿不到能力的源根本调不出上报。
abstract interface class RemoteVideoPlaybackSync {
  /// 读 host 端视频 [id] 的播放偏好带戳状态。host 无记录 / 旧 host 无端点（404）
  /// 返回全默认状态。
  Future<VideoPlaybackSyncState> remoteVideoPlayback(String id);

  /// 向 host 上报视频 [id] 的播放偏好带戳字段（可只带一个字段——调整哪个报哪个）。
  /// host 端逐字段「严格较新时间戳者胜」合并。旧 host 无端点时抛（404 经
  /// checkStatus），调用方 best-effort 捕获——本地 prefs 已持久化，不阻塞播放。
  Future<void> putRemoteVideoPlayback(String id, VideoPlaybackSyncState state);
}
