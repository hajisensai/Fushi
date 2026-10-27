/// 发现作品详情页「获取途径」面板的查询层：媒体库 / 在线源 / BT 搜索 / 媒体服务器
/// 四个渠道各自并发查询、各自一份状态（加载中 / 未配置 / 无结果 / 有结果 / 失败），
/// 一个渠道慢或失败不拖累其余。
///
/// 本文件不依赖任何 widget 树：渠道后端由装配层注入（生产见
/// `video_work_acquisition_backends.dart`，测试给假后端），面板只渲染
/// [VideoWorkAcquisitionController] 的快照。合规门（iOS 不带在线源宿主 / 下载中心）
/// 由装配层决定**是否传入**该渠道的后端：没传的渠道整组不出现。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';

/// 获取渠道（面板分组顺序即枚举顺序）。
enum VideoAcquisitionChannel { library, onlineSource, torrent, mediaServer }

/// 一个渠道此刻的状态。
enum VideoAcquisitionChannelStatus {
  /// 正在查。
  loading,

  /// 渠道没配置（没有启用的在线源 / BT 搜索站 / 媒体服务器）：面板给引导而不是空白。
  unconfigured,

  /// 配置了、查过了，没有命中。
  empty,

  /// 有命中。
  ready,

  /// 整个渠道失败（可重试）。部分来源失败但仍有来源成功时不算失败，见
  /// [VideoAcquisitionChannelState.failedSourceCount]。
  failed,
}

/// 打开一条命中 / 一个渠道入口的动作。需要 [BuildContext] 才能 push 路由，但
/// 控制器本身从不调用它——只原样转交给面板。
typedef VideoAcquisitionOpen = Future<void> Function(BuildContext context);

/// 渠道里的一条命中。
@immutable
class VideoAcquisitionHit {
  const VideoAcquisitionHit({
    required this.id,
    required this.title,
    this.subtitle,
    this.meta = const <String>[],
    this.open,
  });

  /// 渠道内唯一（用作 widget key）。
  final String id;
  final String title;

  /// 命中来自哪里（在线源名 / 服务器名 / BT 站名）。
  final String? subtitle;
  final List<String> meta;

  /// null = 这条命中只作预览、不能单独打开（BT 资源要进完整资源搜索页才能选
  /// 落地位置并提交下载，见渠道入口 [VideoAcquisitionLookup.entry]）。
  final VideoAcquisitionOpen? open;
}

/// 一个渠道后端的一次查询结果。
@immutable
class VideoAcquisitionLookup {
  /// 渠道没配置。[configure] 是引导按钮的动作（null = 只给一句引导文案）。
  const VideoAcquisitionLookup.unconfigured({this.configure})
    : configured = false,
      hits = const <VideoAcquisitionHit>[],
      totalCount = 0,
      failedSourceCount = 0,
      entry = null;

  /// 查过了。[hits] 可为空（= 无结果）；[totalCount] 是渠道里的命中总数（面板只
  /// 展示前几条时用它写「共 N 条」），缺省等于 `hits.length`。[failedSourceCount]
  /// 是本次失败的来源数（部分失败仍算查过）。[entry] 是渠道的完整入口（BT 渠道 =
  /// 进现有资源搜索页）。
  const VideoAcquisitionLookup.hits(
    this.hits, {
    int? totalCount,
    this.failedSourceCount = 0,
    this.entry,
  }) : configured = true,
       totalCount = totalCount ?? -1,
       configure = null;

  final bool configured;
  final List<VideoAcquisitionHit> hits;
  final int totalCount;
  final int failedSourceCount;
  final VideoAcquisitionOpen? configure;
  final VideoAcquisitionOpen? entry;

  int get effectiveTotalCount => totalCount < 0 ? hits.length : totalCount;
}

/// 渠道查询失败（包一层来源抛出的原始错误，来源可能抛任意对象）。
class VideoAcquisitionChannelFailure implements Exception {
  const VideoAcquisitionChannelFailure(this.cause);

  final Object cause;

  @override
  String toString() => 'VideoAcquisitionChannelFailure: $cause';
}

/// 一个获取渠道的后端。整个渠道失败时**抛出**（控制器收成 [failed]）；只有部分
/// 来源失败时返回 [VideoAcquisitionLookup.hits] 并带上 failedSourceCount。
abstract interface class VideoAcquisitionChannelBackend {
  VideoAcquisitionChannel get channel;

  Future<VideoAcquisitionLookup> lookup(VideoMediaReference reference);
}

/// 一个渠道的不可变快照。
@immutable
class VideoAcquisitionChannelState {
  const VideoAcquisitionChannelState({
    required this.status,
    this.hits = const <VideoAcquisitionHit>[],
    this.totalCount = 0,
    this.failedSourceCount = 0,
    this.error,
    this.configure,
    this.entry,
  });

  static const VideoAcquisitionChannelState loading =
      VideoAcquisitionChannelState(
        status: VideoAcquisitionChannelStatus.loading,
      );

  final VideoAcquisitionChannelStatus status;
  final List<VideoAcquisitionHit> hits;
  final int totalCount;
  final int failedSourceCount;
  final Object? error;
  final VideoAcquisitionOpen? configure;
  final VideoAcquisitionOpen? entry;
}

/// 把作品的标题 / 原名 / 别名按搜索口径（[normalizeMediaSearchText]）去重，取前
/// [max] 个作为按标题搜索的查询词。按名称搜的渠道（在线源 / 媒体服务器）依次试这些
/// 词，第一个有命中的为准。
List<String> videoAcquisitionSearchTitles(
  VideoMediaReference reference, {
  int max = 3,
}) {
  final Set<String> seen = <String>{};
  final List<String> titles = <String>[];
  for (final String? raw in <String?>[
    reference.title,
    reference.originalTitle,
    ...reference.aliases,
  ]) {
    final String value = raw?.trim() ?? '';
    if (value.isEmpty) continue;
    final String key = normalizeMediaSearchText(value);
    if (key.isEmpty || !seen.add(key)) continue;
    titles.add(value);
    if (titles.length >= max) break;
  }
  return titles;
}

/// 四渠道并发查询的控制器。
class VideoWorkAcquisitionController extends ChangeNotifier {
  VideoWorkAcquisitionController({
    required this.reference,
    required Iterable<VideoAcquisitionChannelBackend> backends,
  }) : _backends = <VideoAcquisitionChannel, VideoAcquisitionChannelBackend>{
         for (final VideoAcquisitionChannelBackend backend in backends)
           backend.channel: backend,
       };

  final VideoMediaReference reference;
  final Map<VideoAcquisitionChannel, VideoAcquisitionChannelBackend> _backends;
  final Map<VideoAcquisitionChannel, VideoAcquisitionChannelState> _states =
      <VideoAcquisitionChannel, VideoAcquisitionChannelState>{};

  /// 每个渠道每发起一次查询 +1：重试后旧查询晚回来时比对丢弃。
  final Map<VideoAcquisitionChannel, int> _generations =
      <VideoAcquisitionChannel, int>{};
  bool _disposed = false;

  /// 出现在面板上的渠道（按 [VideoAcquisitionChannel] 顺序；没传后端的不在内）。
  List<VideoAcquisitionChannel> get channels => <VideoAcquisitionChannel>[
    for (final VideoAcquisitionChannel channel
        in VideoAcquisitionChannel.values)
      if (_backends.containsKey(channel)) channel,
  ];

  VideoAcquisitionChannelState stateOf(VideoAcquisitionChannel channel) =>
      _states[channel] ?? VideoAcquisitionChannelState.loading;

  /// 所有渠道同时发查询（互不等待）。返回值在全部渠道结束时完成，测试用。
  Future<void> loadAll() => Future.wait<void>(<Future<void>>[
    for (final VideoAcquisitionChannel channel in channels) load(channel),
  ]);

  /// 查（或重查）一个渠道。
  Future<void> load(VideoAcquisitionChannel channel) async {
    final VideoAcquisitionChannelBackend? backend = _backends[channel];
    if (backend == null || _disposed) return;
    final int generation = (_generations[channel] ?? 0) + 1;
    _generations[channel] = generation;
    _set(channel, VideoAcquisitionChannelState.loading);
    VideoAcquisitionChannelState next;
    try {
      final VideoAcquisitionLookup lookup = await backend.lookup(reference);
      next = _stateFor(lookup);
    } on Object catch (error) {
      next = VideoAcquisitionChannelState(
        status: VideoAcquisitionChannelStatus.failed,
        error: error,
      );
    }
    if (_disposed || _generations[channel] != generation) return;
    _set(channel, next);
  }

  static VideoAcquisitionChannelState _stateFor(VideoAcquisitionLookup lookup) {
    if (!lookup.configured) {
      return VideoAcquisitionChannelState(
        status: VideoAcquisitionChannelStatus.unconfigured,
        configure: lookup.configure,
      );
    }
    return VideoAcquisitionChannelState(
      status: lookup.hits.isEmpty
          ? VideoAcquisitionChannelStatus.empty
          : VideoAcquisitionChannelStatus.ready,
      hits: List<VideoAcquisitionHit>.unmodifiable(lookup.hits),
      totalCount: lookup.effectiveTotalCount,
      failedSourceCount: lookup.failedSourceCount,
      entry: lookup.entry,
    );
  }

  void _set(VideoAcquisitionChannel channel, VideoAcquisitionChannelState s) {
    _states[channel] = s;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
