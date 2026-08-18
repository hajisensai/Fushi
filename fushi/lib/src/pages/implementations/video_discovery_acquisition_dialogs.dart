import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/media_extensions.dart';
import 'package:fushi/src/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        MediaSourceRow,
        VideoDownloadJobLifecycle,
        VideoDownloadJobRow,
        VideoDownloadJobStage;
import 'package:path/path.dart' as p;

typedef VideoDiscoveryDownloadSubmit = Future<void> Function(
  VideoDiscoveryDownloadSelection selection,
);

typedef VideoDiscoverySubscriptionSubmit = Future<void> Function(
  VideoDiscoverySubscriptionSelection selection,
);

typedef VideoDiscoveryPathPicker = Future<String?> Function(
  BuildContext context,
);

typedef VideoDiscoverySubtitleInstalled = Future<void> Function(
  SubtitleInstallTarget target,
  String selectedPath,
  String installedPath,
);

typedef VideoDiscoverySubtitleAttach = Future<void> Function(
  VideoDownloadJobRow job,
  VideoSubtitleCandidate candidate,
);

@immutable
class VideoDiscoveryDownloadSelection {
  const VideoDiscoveryDownloadSelection({
    required this.media,
    required this.resource,
    required this.source,
    required this.subtitlePolicy,
  });

  final VideoMediaReference media;
  final VideoResourceCandidate resource;
  final MediaSourceRow source;
  final VideoDownloadSubtitlePolicy subtitlePolicy;
}

@immutable
class StrictVideoSubscriptionFilter {
  const StrictVideoSubscriptionFilter({
    required this.json,
    required this.releaseGroup,
    required this.resolution,
    required this.summaryParts,
  });

  final String json;
  final String? releaseGroup;
  final String? resolution;
  final List<String> summaryParts;
}

@immutable
class VideoDiscoverySubscriptionSelection {
  const VideoDiscoverySubscriptionSelection({
    required this.download,
    required this.filter,
    this.startAfterEpisode,
  });

  final VideoDiscoveryDownloadSelection download;
  final StrictVideoSubscriptionFilter filter;
  final int? startAfterEpisode;
}

enum SubtitleInstallTarget { activeTask, existingVideo, directory }

/// 独立字幕搜索只允许强身份一致、且尚未越过 subtitle 阶段的持久任务作为附加目标。
/// 标题/年份不参与兜底，避免同名作品误挂字幕。
bool isAttachableVideoDownloadJob(
  VideoDownloadJobRow job,
  VideoMediaReference reference,
) {
  if (job.lifecycle != VideoDownloadJobLifecycle.active &&
      job.lifecycle != VideoDownloadJobLifecycle.needsAttention) {
    return false;
  }
  if (!const <String>{
    VideoDownloadJobStage.enqueue,
    VideoDownloadJobStage.download,
    VideoDownloadJobStage.organize,
    VideoDownloadJobStage.subtitle,
  }.contains(job.stage)) {
    return false;
  }
  final String provider = job.metadataProvider?.trim().toLowerCase() ?? '';
  final String externalId = job.externalId?.trim().toLowerCase() ?? '';
  if (provider.isEmpty || externalId.isEmpty) return false;
  if (provider == reference.providerId.trim().toLowerCase() &&
      externalId == reference.mediaId.trim().toLowerCase()) {
    return true;
  }
  return switch (provider) {
    'tmdb' => externalId == reference.tmdbId?.toString(),
    'anilist' => externalId == reference.anilistId?.toString(),
    'bangumi' => externalId == reference.bangumiId?.toString(),
    'imdb' => externalId == reference.imdbId?.trim().toLowerCase(),
    'tvdb' => externalId == reference.tvdbId?.toString(),
    _ => reference.externalIds.entries.any(
        (MapEntry<String, String> entry) =>
            entry.key.trim().toLowerCase() == provider &&
            entry.value.trim().toLowerCase() == externalId,
      ),
  };
}

/// 从用户选中的 release 提取严格订阅规则。返回 null 表示该 release 没有足够的
/// 版本证据，UI 必须拒绝创建订阅，不能退化成宽松标题订阅。
StrictVideoSubscriptionFilter? deriveStrictVideoSubscriptionFilter(
  VideoResourceCandidate candidate,
) {
  final String provider = candidate.providerId.trim().toLowerCase();
  final String? releaseGroup = _nonEmpty(candidate.releaseGroup);
  final String? resolution = _nonEmpty(candidate.resolution) ??
      _firstMatch(candidate.title, RegExp(r'\b(?:2160|1080|720|576|480)p\b'));
  final Map<String, Object> filter = <String, Object>{'strict': true};
  final List<String> summary = <String>[];

  if (releaseGroup != null) {
    filter['releaseGroup'] = releaseGroup;
    summary.add(releaseGroup);
  }
  if (resolution != null) {
    filter['resolution'] = resolution;
    summary.add(resolution);
  }
  if (candidate.category?.trim().isNotEmpty == true) {
    filter['category'] = candidate.category!.trim();
  }

  if (provider == 'nyaa') {
    if (releaseGroup == null || resolution == null) return null;
    // Nyaa 的 trusted 是来源给出的结构化证据；true/false 都按所选 release 精确锁定。
    filter['trusted'] = candidate.trusted;
    summary.add(candidate.trusted ? 'trusted' : 'untrusted');
  } else if (provider == 'torznab') {
    final String? source = _firstMatch(
      candidate.title,
      RegExp(
        r'\b(?:BluRay|WEB[ ._-]?DL|WEB[ ._-]?Rip|HDTV|DVD)\b',
        caseSensitive: false,
      ),
    );
    final String? codec = _firstMatch(
      candidate.title,
      RegExp(
        r'\b(?:AV1|HEVC|H[ ._-]?265|x265|AVC|H[ ._-]?264|x264)\b',
        caseSensitive: false,
      ),
    );
    final String? language = _firstMatch(
      candidate.title,
      RegExp(
        r'\b(?:Dual[ ._-]?Audio|MULTi|Chinese|CHS|CHT|JPN|Japanese|ENG|English)\b',
        caseSensitive: false,
      ),
    );
    if (source != null) {
      filter['source'] = source;
      summary.add(source);
    }
    if (codec != null) {
      filter['codec'] = codec;
      summary.add(codec);
    }
    // 只有标题明确给出语言/音轨证据时才锁定；UI 不推测或声称未选语言。
    if (language != null) {
      filter['language'] = language;
      summary.add(language);
    }
    if (releaseGroup == null &&
        resolution == null &&
        source == null &&
        codec == null &&
        language == null) {
      return null;
    }
  } else {
    return null;
  }

  return StrictVideoSubscriptionFilter(
    json: jsonEncode(filter),
    releaseGroup: releaseGroup,
    resolution: resolution,
    summaryParts: List<String>.unmodifiable(summary),
  );
}

/// 订阅候选列表里的一行：一条**可订阅的规则**，而不是一个发布。
@immutable
class VideoSubscriptionCandidateGroup {
  const VideoSubscriptionCandidateGroup({
    required this.representative,
    required this.filter,
    required this.memberCount,
    required this.episodeNumbers,
    required this.latestPublishedAt,
  });

  /// 用来推出订阅规则、也用来喂下游下载选择的那一条。同组任意一条推出的
  /// filter 都相同（分组键就是它），选谁都不影响订阅本身。
  final VideoResourceCandidate representative;

  /// `null` 表示这一条没有足够的版本证据、根本不能建订阅（UI 照旧显示它并在
  /// 提交时拒绝，不静默吞掉）。
  final StrictVideoSubscriptionFilter? filter;

  /// 这条规则在当前搜索结果里命中了几个发布。
  final int memberCount;

  /// 命中发布里能解析出的集数（升序、去重）；解析不出的不计入。
  final List<int> episodeNumbers;

  final DateTime? latestPublishedAt;
}

/// 把搜索结果按**订阅生效单位**聚合。
///
/// ## 为什么分组键是 `filter.json` 而不是「字幕组 × 分辨率」
///
/// 用户报障：订阅页搜一部番，列表里是同一个字幕组同一分辨率的十几集，一集一
/// 行，「重复的数据太多了」。根子在于**列表的行单位与订阅的生效单位不一致**：
/// 订阅追踪的是「Erai-raws · 1080p」这条规则，而列表按发布逐条列。
///
/// 于是分组键直接取 [deriveStrictVideoSubscriptionFilter] 的产物 `json`——它
/// 就是「这两个发布订起来是不是同一条」的**定义本身**。自己另写一个
/// 「releaseGroup + resolution」的键看着等价，但 nyaa 还锁 `trusted`、torznab
/// 还锁 source/codec/language，键一旦漏掉其中一维，两条本该分开的规则会被合成
/// 一行，用户订到的和看到的就不是一回事。用定义当键，这种漂移不可能发生。
///
/// 推不出 filter 的条目（版本证据不足）**不聚合**：它们各占一行，保持原样显示，
/// 提交时由既有校验拒绝。把它们并成一坨只会让「为什么订不了」更难看懂。
List<VideoSubscriptionCandidateGroup> groupVideoSubscriptionCandidates(
  List<VideoResourceCandidate> candidates,
) {
  final Map<String, List<VideoResourceCandidate>> byFilter =
      <String, List<VideoResourceCandidate>>{};
  final Map<String, StrictVideoSubscriptionFilter> filters =
      <String, StrictVideoSubscriptionFilter>{};
  final List<VideoSubscriptionCandidateGroup> ungroupable =
      <VideoSubscriptionCandidateGroup>[];
  // 保持来源顺序：Map 的插入序即首次出现序，用户看到的排序不会因聚合而抖动。
  final List<String> order = <String>[];

  for (final VideoResourceCandidate candidate in candidates) {
    final StrictVideoSubscriptionFilter? filter =
        deriveStrictVideoSubscriptionFilter(candidate);
    if (filter == null) {
      ungroupable.add(
        VideoSubscriptionCandidateGroup(
          representative: candidate,
          filter: null,
          memberCount: 1,
          episodeNumbers: const <int>[],
          latestPublishedAt: candidate.publishedAt,
        ),
      );
      continue;
    }
    if (!byFilter.containsKey(filter.json)) {
      byFilter[filter.json] = <VideoResourceCandidate>[];
      filters[filter.json] = filter;
      order.add(filter.json);
    }
    byFilter[filter.json]!.add(candidate);
  }

  final List<VideoSubscriptionCandidateGroup> grouped =
      <VideoSubscriptionCandidateGroup>[];
  for (final String key in order) {
    final List<VideoResourceCandidate> members = byFilter[key]!;
    // 代表条：做种最多的那条（最可能拉得动）；并列时取最新发布，再并列取标题
    // 字典序——**全序**，同一份搜索结果每次渲染都得到同一行，不会跳。
    final List<VideoResourceCandidate> sorted =
        List<VideoResourceCandidate>.of(members)
          ..sort((VideoResourceCandidate a, VideoResourceCandidate b) {
            final int bySeeders = b.seeders.compareTo(a.seeders);
            if (bySeeders != 0) return bySeeders;
            final DateTime? pa = a.publishedAt;
            final DateTime? pb = b.publishedAt;
            if (pa != null && pb != null) {
              final int byDate = pb.compareTo(pa);
              if (byDate != 0) return byDate;
            } else if (pa != pb) {
              return pa == null ? 1 : -1;
            }
            return a.title.compareTo(b.title);
          });
    final Set<int> episodes = <int>{};
    DateTime? latest;
    for (final VideoResourceCandidate member in members) {
      final int? episode = episodeNumberFromReleaseTitle(member.title);
      if (episode != null) episodes.add(episode);
      final DateTime? published = member.publishedAt;
      if (published != null && (latest == null || published.isAfter(latest))) {
        latest = published;
      }
    }
    grouped.add(
      VideoSubscriptionCandidateGroup(
        representative: sorted.first,
        filter: filters[key],
        memberCount: members.length,
        episodeNumbers: (episodes.toList()..sort()),
        latestPublishedAt: latest,
      ),
    );
  }

  // 可订阅的排前面：它们才是这个页面要用户挑的东西。
  return <VideoSubscriptionCandidateGroup>[...grouped, ...ungroupable];
}

int? episodeNumberFromReleaseTitle(String title) {
  final RegExpMatch? seasonEpisode = RegExp(
    r'\bS\d{1,3}[ ._-]*E(\d{1,4})(?:v\d+)?\b',
    caseSensitive: false,
  ).firstMatch(title);
  if (seasonEpisode != null) return int.tryParse(seasonEpisode.group(1)!);
  final RegExpMatch? anime = RegExp(
    r'(?:^|\s)-\s*(\d{1,4})(?:v\d+)?(?=\s*(?:\[|\(|$))',
    caseSensitive: false,
  ).firstMatch(title);
  return anime == null ? null : int.tryParse(anime.group(1)!);
}

String videoDiscoverySubscriptionId(VideoMediaReference reference) {
  final String digest = sha256
      .convert(utf8.encode(reference.canonicalIdentityKey))
      .toString()
      .substring(0, 24);
  return 'video-discovery-$digest';
}

/// 下载“资源”页没有现成发现卡片时，要求用户显式提供可确认的元数据身份。
/// 不生成 `manual` 假身份，保证后续精确刮削不会因为缺 provider binding 而停住。
VideoMediaReference? buildManualVideoMediaReference({
  required String providerId,
  required String mediaId,
  required String title,
  required String yearText,
  required VideoDiscoveryCategory category,
  required VideoMetadataMediaKind mediaKind,
}) {
  final String provider = providerId.trim().toLowerCase();
  final String id = mediaId.trim();
  final String normalizedTitle = title.trim();
  final int? numericId = int.tryParse(id);
  final int? year = int.tryParse(yearText.trim());
  if (!const <String>{'tmdb', 'anilist', 'bangumi'}.contains(provider) ||
      numericId == null ||
      numericId <= 0 ||
      normalizedTitle.isEmpty ||
      year == null ||
      year < 1800 ||
      year > 9999 ||
      (category == VideoDiscoveryCategory.movie &&
          mediaKind != VideoMetadataMediaKind.movie) ||
      (category == VideoDiscoveryCategory.tv &&
          mediaKind != VideoMetadataMediaKind.tv)) {
    return null;
  }
  return VideoMediaReference(
    providerId: provider,
    mediaId: id,
    mediaKind: mediaKind,
    discoveryCategory: category,
    title: normalizedTitle,
    year: year,
    tmdbId: provider == 'tmdb' ? numericId : null,
    anilistId: provider == 'anilist' ? numericId : null,
    bangumiId: provider == 'bangumi' ? numericId : null,
    externalIds: <String, String>{provider: id},
  );
}

/// 把下载的字幕保存为 sidecar。已有不同内容时自动选择新文件名，绝不覆盖。
Future<String> installDiscoverySubtitle({
  required VideoSubtitleDownload download,
  required SubtitleInstallTarget target,
  required String selectedPath,
}) async {
  if (target == SubtitleInstallTarget.activeTask) {
    throw ArgumentError.value(target, 'target', 'active tasks attach metadata');
  }
  final Directory directory;
  final String stem;
  if (target == SubtitleInstallTarget.existingVideo) {
    final File video = File(selectedPath);
    if (!await video.exists()) {
      throw FileSystemException('selected video is unavailable', selectedPath);
    }
    directory = video.parent;
    stem = p.basenameWithoutExtension(video.path);
  } else {
    directory = Directory(selectedPath);
    if (!await directory.exists()) {
      throw FileSystemException(
          'selected directory is unavailable', selectedPath);
    }
    stem = p.basenameWithoutExtension(download.fileName);
  }

  String extension = p.extension(download.fileName).toLowerCase();
  if (!const <String>{'.ass', '.ssa', '.srt', '.vtt'}.contains(extension)) {
    extension = '.srt';
  }
  final String safeStem = safeWindowsFileName(stem).trim().isEmpty
      ? 'subtitle'
      : safeWindowsFileName(stem).trim();
  final String language = safeWindowsFileName(download.language).trim();
  final String baseName =
      target == SubtitleInstallTarget.existingVideo && language.isNotEmpty
          ? '$safeStem.$language'
          : safeStem;

  for (int suffix = 0; suffix < 1000; suffix++) {
    final String leaf = '$baseName${suffix == 0 ? '' : '.$suffix'}$extension';
    final File destination = File(p.join(directory.path, leaf));
    if (await destination.exists()) {
      final Digest existing = await sha256.bind(destination.openRead()).first;
      if (existing == sha256.convert(download.bytes)) return destination.path;
      continue;
    }
    final File temporary = File(
      p.join(
        directory.path,
        '.$leaf.fushi-${Random.secure().nextInt(0x7fffffff).toRadixString(16)}.tmp',
      ),
    );
    await temporary.create(exclusive: true);
    try {
      final RandomAccessFile handle =
          await temporary.open(mode: FileMode.write);
      try {
        await handle.writeFrom(download.bytes);
        await handle.flush();
      } finally {
        await handle.close();
      }
      // 再检查一次，缩小并发写入窗口；目标若已出现就换 suffix，不覆盖它。
      if (await destination.exists()) continue;
      await temporary.rename(destination.path);
      return destination.path;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
  throw FileSystemException(
      'no conflict-free subtitle file name', selectedPath);
}

class VideoDiscoveryResourceSearchDialog extends StatelessWidget {
  const VideoDiscoveryResourceSearchDialog({
    required this.item,
    required this.registry,
    required this.sources,
    required this.onSubmit,
    this.defaultSourceId,
    super.key,
  });

  final VideoDiscoveryItem item;
  final VideoResourceRegistry registry;
  final List<MediaSourceRow> sources;
  final int? defaultSourceId;
  final VideoDiscoveryDownloadSubmit onSubmit;

  @override
  Widget build(BuildContext context) => FushiDialogFrame(
        maxWidth: 760,
        maxHeightFactor: 0.88,
        scrollable: false,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: VideoResourceSearchSurface(
          initialItem: item,
          registry: registry,
          sources: sources,
          defaultSourceId: defaultSourceId,
          onSubmit: onSubmit,
          onClose: () => Navigator.pop(context),
        ),
      );
}

/// 详情页的资源搜索使用独立路由，避免在小对话框内压缩发布信息。
class VideoDiscoveryResourceSearchPage extends StatelessWidget {
  const VideoDiscoveryResourceSearchPage({
    required this.item,
    required this.registry,
    required this.sources,
    required this.onSubmit,
    this.defaultSourceId,
    super.key,
  });

  final VideoDiscoveryItem item;
  final VideoResourceRegistry registry;
  final List<MediaSourceRow> sources;
  final int? defaultSourceId;
  final VideoDiscoveryDownloadSubmit onSubmit;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(t.video_discovery_resource_search)),
        body: SafeArea(
          child: VideoResourceSearchSurface(
            initialItem: item,
            registry: registry,
            sources: sources,
            defaultSourceId: defaultSourceId,
            onSubmit: onSubmit,
            onClose: () => Navigator.of(context).pop(),
            pageMode: true,
          ),
        ),
      );
}

/// 发现详情的订阅创建使用独立路由，与资源搜索共享同一块全尺寸 surface。
class VideoDiscoverySubscriptionPage extends StatelessWidget {
  const VideoDiscoverySubscriptionPage({
    required this.item,
    required this.registry,
    required this.sources,
    required this.onSubmit,
    this.defaultSourceId,
    super.key,
  });

  final VideoDiscoveryItem item;
  final VideoResourceRegistry registry;
  final List<MediaSourceRow> sources;
  final int? defaultSourceId;
  final VideoDiscoverySubscriptionSubmit onSubmit;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(t.video_discovery_subscribe)),
        body: SafeArea(
          child: VideoResourceSearchSurface(
            initialItem: item,
            registry: registry,
            sources: sources,
            defaultSourceId: defaultSourceId,
            onSubscriptionSubmit: onSubmit,
            onClose: () => Navigator.of(context).pop(),
            pageMode: true,
          ),
        ),
      );
}

/// 发现详情对话框与下载模块“资源”tab 共用的资源搜索 surface。
class VideoResourceSearchSurface extends StatefulWidget {
  const VideoResourceSearchSurface({
    required this.registry,
    required this.sources,
    this.initialItem,
    this.defaultSourceId,
    this.onSubmit,
    this.onSubscriptionSubmit,
    this.onClose,
    this.pageMode = false,
    super.key,
  }) : assert((onSubmit == null) != (onSubscriptionSubmit == null));

  final VideoDiscoveryItem? initialItem;
  final VideoResourceRegistry registry;
  final List<MediaSourceRow> sources;
  final int? defaultSourceId;
  final VideoDiscoveryDownloadSubmit? onSubmit;
  final VideoDiscoverySubscriptionSubmit? onSubscriptionSubmit;
  final VoidCallback? onClose;
  final bool pageMode;

  bool get subscription => onSubscriptionSubmit != null;

  @override
  State<VideoResourceSearchSurface> createState() =>
      _VideoResourceSearchSurfaceState();
}

class _VideoResourceSearchSurfaceState
    extends State<VideoResourceSearchSurface> {
  final TextEditingController _queryController = TextEditingController();
  final TextEditingController _manualIdController = TextEditingController();
  final TextEditingController _manualYearController = TextEditingController();
  final TextEditingController _startAfterController = TextEditingController();
  VideoDiscoveryCategory _manualCategory = VideoDiscoveryCategory.anime;
  VideoMetadataMediaKind _manualMediaKind = VideoMetadataMediaKind.tv;
  String _manualProvider = 'anilist';
  ProviderBatchResult<VideoResourceCandidate>? _result;
  VideoResourceCandidate? _selected;
  int? _sourceId;
  VideoDownloadSubtitlePolicy _subtitlePolicy =
      VideoDownloadSubtitlePolicy.bestEffort;
  bool _loading = false;
  bool _submitting = false;
  bool _strictConfirmed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final VideoMediaReference? reference = widget.initialItem?.reference;
    final List<String> preferredQueries = reference == null
        ? const <String>[]
        : preferredNyaaSearchQueries(
            VideoResourceSearchRequest(media: reference),
          );
    _queryController.text = preferredQueries.firstOrNull ??
        widget.initialItem?.reference.title ??
        '';
    _sourceId = widget.sources.any(
      (MediaSourceRow source) => source.id == widget.defaultSourceId,
    )
        ? widget.defaultSourceId
        : widget.sources.firstOrNull?.id;
    if (widget.initialItem != null) unawaited(_search());
  }

  @override
  void dispose() {
    _queryController.dispose();
    _manualIdController.dispose();
    _manualYearController.dispose();
    _startAfterController.dispose();
    super.dispose();
  }

  VideoMediaReference? get _media {
    final VideoDiscoveryItem? item = widget.initialItem;
    if (item != null) return item.reference;
    return buildManualVideoMediaReference(
      providerId: _manualProvider,
      mediaId: _manualIdController.text,
      title: _queryController.text,
      yearText: _manualYearController.text,
      category: _manualCategory,
      mediaKind: _manualMediaKind,
    );
  }

  bool get _manualIdentityReady => _media != null;

  /// 手动身份未满足时搜索按钮必须禁用（设计如此，不造 `manual` 假身份），
  /// 但禁用原因要在 tooltip 里说清，而不是继续显示「搜索」误导用户。
  String get _manualSearchTooltip => _manualIdentityReady
      ? t.dialog_search
      : t.video_discovery_manual_identity_hint;

  void _invalidateManualSearch() {
    setState(() {
      _result = null;
      _selected = null;
      _strictConfirmed = false;
    });
  }

  Future<void> _search() async {
    final VideoMediaReference? media = _media;
    if (media == null || _loading) return;
    final int generation = ++_generation;
    setState(() {
      _loading = true;
      _selected = null;
      _strictConfirmed = false;
    });
    final ProviderBatchResult<VideoResourceCandidate> result =
        await widget.registry.search(
      VideoResourceSearchRequest(media: media, query: _queryController.text),
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _result = result;
      _loading = false;
    });
  }

  void _select(VideoResourceCandidate candidate) {
    setState(() {
      _selected = candidate;
      _strictConfirmed = false;
      final int? episode = episodeNumberFromReleaseTitle(candidate.title);
      _startAfterController.text = episode?.toString() ?? '';
    });
  }

  MediaSourceRow? get _source {
    for (final MediaSourceRow source in widget.sources) {
      if (source.id == _sourceId) return source;
    }
    return null;
  }

  Future<void> _submit() async {
    final VideoMediaReference? media = _media;
    final VideoResourceCandidate? resource = _selected;
    final MediaSourceRow? source = _source;
    if (media == null || resource == null || source == null || _submitting) {
      return;
    }
    final VideoDiscoveryDownloadSelection download =
        VideoDiscoveryDownloadSelection(
      media: media,
      resource: resource,
      source: source,
      subtitlePolicy: _subtitlePolicy,
    );
    setState(() => _submitting = true);
    try {
      if (widget.subscription) {
        final StrictVideoSubscriptionFilter? filter =
            deriveStrictVideoSubscriptionFilter(resource);
        if (filter == null || !_strictConfirmed) return;
        final int? startAfter = media.mediaKind == VideoMetadataMediaKind.movie
            ? null
            : int.tryParse(_startAfterController.text.trim());
        await widget.onSubscriptionSubmit!(
          VideoDiscoverySubscriptionSelection(
            download: download,
            filter: filter,
            startAfterEpisode: startAfter,
          ),
        );
      } else {
        await widget.onSubmit!(download);
      }
      if (mounted) widget.onClose?.call();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool manual = widget.initialItem == null;
    final VideoResourceCandidate? selected = _selected;
    final StrictVideoSubscriptionFilter? filter =
        selected == null ? null : deriveStrictVideoSubscriptionFilter(selected);
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.card + 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (!widget.pageMode) ...<Widget>[
            Text(
              widget.subscription
                  ? t.video_discovery_subscribe
                  : t.video_discovery_resource_search,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SizedBox(height: tokens.spacing.card),
          ],
          if (!manual && widget.pageMode) ...<Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('video-resource-query'),
                    controller: _queryController,
                    decoration: InputDecoration(
                      hintText: t.video_discovery_search_hint,
                      prefixIcon: const Icon(Icons.search_rounded),
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => unawaited(_search()),
                  ),
                ),
                SizedBox(width: tokens.spacing.gap),
                IconButton.filledTonal(
                  tooltip: t.dialog_search,
                  onPressed: _loading ? null : () => unawaited(_search()),
                  icon: const Icon(Icons.search_rounded),
                ),
              ],
            ),
            if (widget.initialItem!.reference.discoveryCategory ==
                VideoDiscoveryCategory.anime) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Wrap(
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: preferredNyaaSearchQueries(
                  VideoResourceSearchRequest(
                    media: widget.initialItem!.reference,
                  ),
                )
                    .map(
                      (String query) => ActionChip(
                        label: Text(query),
                        onPressed: _loading
                            ? null
                            : () {
                                _queryController.text = query;
                                unawaited(_search());
                              },
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
            SizedBox(height: tokens.spacing.card),
          ],
          if (manual) ...<Widget>[
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Widget search = TextField(
                  key: const ValueKey<String>('video-resource-query'),
                  controller: _queryController,
                  decoration: InputDecoration(
                    hintText: t.video_discovery_search_hint,
                    prefixIcon: const Icon(Icons.search_rounded),
                  ),
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => _invalidateManualSearch(),
                  onSubmitted: (_) => unawaited(_search()),
                );
                final Widget category =
                    DropdownButtonFormField<VideoDiscoveryCategory>(
                  key: const ValueKey<String>('video-resource-category'),
                  initialValue: _manualCategory,
                  items: <DropdownMenuItem<VideoDiscoveryCategory>>[
                    DropdownMenuItem<VideoDiscoveryCategory>(
                      value: VideoDiscoveryCategory.anime,
                      child: Text(t.media_tracking_anime),
                    ),
                    DropdownMenuItem<VideoDiscoveryCategory>(
                      value: VideoDiscoveryCategory.movie,
                      child: Text(t.collection_relation_movie),
                    ),
                    DropdownMenuItem<VideoDiscoveryCategory>(
                      value: VideoDiscoveryCategory.tv,
                      child: Text(t.series),
                    ),
                  ],
                  onChanged: (VideoDiscoveryCategory? value) {
                    if (value == null) return;
                    setState(() {
                      _manualCategory = value;
                      if (value == VideoDiscoveryCategory.movie) {
                        _manualMediaKind = VideoMetadataMediaKind.movie;
                      } else if (value == VideoDiscoveryCategory.tv) {
                        _manualMediaKind = VideoMetadataMediaKind.tv;
                      }
                      _manualProvider = value == VideoDiscoveryCategory.anime
                          ? 'anilist'
                          : 'tmdb';
                      _result = null;
                      _selected = null;
                    });
                  },
                );
                if (constraints.maxWidth < 520) {
                  return Column(
                    children: <Widget>[
                      search,
                      SizedBox(height: tokens.spacing.gap),
                      Row(
                        children: <Widget>[
                          Expanded(child: category),
                          SizedBox(width: tokens.spacing.gap),
                          IconButton.filledTonal(
                            tooltip: _manualSearchTooltip,
                            onPressed: _loading || !_manualIdentityReady
                                ? null
                                : () => unawaited(_search()),
                            icon: const Icon(Icons.search_rounded),
                          ),
                        ],
                      ),
                    ],
                  );
                }
                return Row(
                  children: <Widget>[
                    Expanded(child: search),
                    SizedBox(width: tokens.spacing.gap),
                    SizedBox(width: 160, child: category),
                    SizedBox(width: tokens.spacing.gap),
                    IconButton.filledTonal(
                      tooltip: _manualSearchTooltip,
                      onPressed: _loading || !_manualIdentityReady
                          ? null
                          : () => unawaited(_search()),
                      icon: const Icon(Icons.search_rounded),
                    ),
                  ],
                );
              },
            ),
            if (_manualCategory == VideoDiscoveryCategory.anime) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              DropdownButtonFormField<VideoMetadataMediaKind>(
                key: const ValueKey<String>('video-resource-anime-kind'),
                initialValue: _manualMediaKind,
                decoration: InputDecoration(labelText: t.media_tracking_kind),
                items: <DropdownMenuItem<VideoMetadataMediaKind>>[
                  DropdownMenuItem<VideoMetadataMediaKind>(
                    value: VideoMetadataMediaKind.tv,
                    child: Text(t.series),
                  ),
                  DropdownMenuItem<VideoMetadataMediaKind>(
                    value: VideoMetadataMediaKind.movie,
                    child: Text(t.collection_relation_movie),
                  ),
                ],
                onChanged: (VideoMetadataMediaKind? value) {
                  if (value == null) return;
                  setState(() {
                    _manualMediaKind = value;
                    _result = null;
                    _selected = null;
                    _strictConfirmed = false;
                  });
                },
              ),
            ],
            SizedBox(height: tokens.spacing.gap),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Widget provider = DropdownButtonFormField<String>(
                  key: const ValueKey<String>('video-resource-provider'),
                  initialValue: _manualProvider,
                  decoration: InputDecoration(
                    labelText: t.video_source_scrape_provider,
                  ),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(
                      value: 'tmdb',
                      child: Text('TMDB'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'anilist',
                      child: Text('AniList'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'bangumi',
                      child: Text('Bangumi'),
                    ),
                  ],
                  onChanged: (String? value) {
                    if (value == null) return;
                    setState(() {
                      _manualProvider = value;
                      _result = null;
                      _selected = null;
                    });
                  },
                );
                final Widget externalId = TextField(
                  key: const ValueKey<String>('video-resource-external-id'),
                  controller: _manualIdController,
                  decoration: InputDecoration(
                    labelText: t.video_work_external_ids,
                  ),
                  onChanged: (_) => _invalidateManualSearch(),
                );
                final Widget year = TextField(
                  key: const ValueKey<String>('video-resource-year'),
                  controller: _manualYearController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t.video_filter_year,
                  ),
                  onChanged: (_) => _invalidateManualSearch(),
                );
                if (constraints.maxWidth < 520) {
                  return Column(
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(child: provider),
                          SizedBox(width: tokens.spacing.gap),
                          SizedBox(width: 112, child: year),
                        ],
                      ),
                      SizedBox(height: tokens.spacing.gap),
                      externalId,
                    ],
                  );
                }
                return Row(
                  children: <Widget>[
                    SizedBox(width: 160, child: provider),
                    SizedBox(width: tokens.spacing.gap),
                    Expanded(child: externalId),
                    SizedBox(width: tokens.spacing.gap),
                    SizedBox(width: 112, child: year),
                  ],
                );
              },
            ),
            if (!_manualIdentityReady) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                t.video_discovery_manual_identity_hint,
                key: const ValueKey<String>('video-resource-identity-hint'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
            SizedBox(height: tokens.spacing.gap),
          ],
          if (_result?.isPartial == true)
            _ProviderWarning(message: t.video_discovery_provider_warning),
          Expanded(child: _buildResults()),
          SizedBox(height: tokens.spacing.gap),
          _buildOptions(filter),
          SizedBox(height: tokens.spacing.card),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              if (widget.onClose != null && !widget.pageMode)
                TextButton(
                  onPressed: _submitting ? null : widget.onClose,
                  child: Text(t.dialog_cancel),
                ),
              SizedBox(width: tokens.spacing.gap),
              FilledButton.icon(
                key: ValueKey<String>(
                  widget.subscription
                      ? 'video-subscription-submit'
                      : 'video-resource-submit',
                ),
                onPressed:
                    _canSubmit(filter) ? () => unawaited(_submit()) : null,
                icon: _submitting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(widget.subscription
                        ? Icons.favorite_border_rounded
                        : Icons.download_rounded),
                label: Text(
                  widget.subscription
                      ? t.video_discovery_subscribe
                      : t.dialog_done,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _canSubmit(StrictVideoSubscriptionFilter? filter) =>
      !_loading &&
      !_submitting &&
      _selected != null &&
      _source != null &&
      (!widget.subscription || (filter != null && _strictConfirmed));

  Widget _buildResults() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final ProviderBatchResult<VideoResourceCandidate>? result = _result;
    if (result == null) {
      return Center(child: Text(t.anime_download_search_start_hint));
    }
    if (result.isTotalFailure) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(t.video_discovery_load_failed),
            TextButton(
                onPressed: () => unawaited(_search()), child: Text(t.retry)),
          ],
        ),
      );
    }
    if (result.hasNoActiveProvider) {
      return _NoProviderEmptyState(
        key: const ValueKey<String>('video-resource-no-provider'),
        icon: Icons.travel_explore_outlined,
        title: t.video_resource_no_provider_title,
        hint: t.video_resource_no_provider_hint,
      );
    }
    if (result.items.isEmpty) {
      return Center(child: Text(t.video_discovery_empty));
    }
    // 订阅模式下行单位 = 订阅生效单位（见 groupVideoSubscriptionCandidates 的
    // 文档）；下载模式仍是一集一行，用户要挑的就是具体那一个发布。
    final List<VideoSubscriptionCandidateGroup>? groups = widget.subscription
        ? groupVideoSubscriptionCandidates(result.items)
        : null;
    return ListView.builder(
      key: const ValueKey<String>('video-resource-results'),
      itemCount: groups?.length ?? result.items.length,
      itemBuilder: (BuildContext context, int index) {
        final VideoSubscriptionCandidateGroup? group = groups?[index];
        final VideoResourceCandidate candidate =
            group?.representative ?? result.items[index];
        final List<String> metadata = <String>[
          candidate.providerId,
          candidate.providerInstanceId,
          if (candidate.category?.trim().isNotEmpty == true)
            candidate.category!,
          if (candidate.resolution?.trim().isNotEmpty == true)
            candidate.resolution!,
          if (candidate.releaseGroup?.trim().isNotEmpty == true)
            candidate.releaseGroup!,
          if (candidate.sizeBytes case final int bytes)
            FushiByteFormat.bytes(bytes),
          '${candidate.seeders}↑  ${candidate.leechers}↓  ${candidate.completed}✓',
          if (candidate.publishedAt case final DateTime published)
            _compactDate(published),
        ];
        // 聚合行：把「这条规则覆盖了多少个发布 / 哪些集」说清楚，否则用户看到
        // 一行会以为只订到一集。
        if (group != null && group.memberCount > 1) {
          metadata.add(
            t.video_subscription_group_release_count(count: group.memberCount),
          );
          final List<int> episodes = group.episodeNumbers;
          if (episodes.isNotEmpty) {
            metadata.add(episodes.length == 1
                ? 'EP${episodes.first}'
                : 'EP${episodes.first}-${episodes.last}');
          }
        }
        return FushiListItem(
          key: ValueKey<String>('video-resource-${candidate.identityKey}'),
          title: Text(candidate.title),
          subtitle: Text(metadata.join(' · ')),
          titleMaxLines: 2,
          subtitleMaxLines: 2,
          density: widget.pageMode
              ? FushiListDensity.standard
              : FushiListDensity.compact,
          selected: identical(_selected, candidate),
          leading: Icon(candidate.trusted
              ? Icons.verified_rounded
              : Icons.cloud_download_outlined),
          onTap: () => _select(candidate),
        );
      },
    );
  }

  Widget _buildOptions(StrictVideoSubscriptionFilter? filter) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<int>(
                key: const ValueKey<String>('video-resource-source'),
                initialValue: _sourceId,
                isExpanded: true,
                decoration: InputDecoration(
                  // 只给标签时这个下拉读起来像「搜哪个源」，用户据此以为选不了
                  // 视频来源；它其实是下载落地的本地目录（BUG-1713）。
                  labelText: t.video_download_target_source_title,
                  helperText: t.video_download_target_source_hint,
                  helperMaxLines: 2,
                ),
                items: widget.sources
                    .map(
                      (MediaSourceRow source) => DropdownMenuItem<int>(
                        value: source.id,
                        child: Text(
                          source.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _submitting
                    ? null
                    : (int? value) => setState(() => _sourceId = value),
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            Expanded(
              child: DropdownButtonFormField<VideoDownloadSubtitlePolicy>(
                key: const ValueKey<String>('video-resource-subtitle-policy'),
                initialValue: _subtitlePolicy,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: t.anime_download_include_subs,
                ),
                items: <DropdownMenuItem<VideoDownloadSubtitlePolicy>>[
                  DropdownMenuItem<VideoDownloadSubtitlePolicy>(
                    value: VideoDownloadSubtitlePolicy.none,
                    child: Text(
                      t.anime_download_no_subs,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem<VideoDownloadSubtitlePolicy>(
                    value: VideoDownloadSubtitlePolicy.bestEffort,
                    child: Text(
                      t.anime_download_include_subs,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem<VideoDownloadSubtitlePolicy>(
                    value: VideoDownloadSubtitlePolicy.required,
                    child: Text(
                      t.anime_download_require_subs,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                onChanged: _submitting
                    ? null
                    : (VideoDownloadSubtitlePolicy? value) {
                        if (value != null) {
                          setState(() => _subtitlePolicy = value);
                        }
                      },
              ),
            ),
          ],
        ),
        if (widget.subscription && _selected != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          if (filter == null)
            _ProviderWarning(
              message: t.download_subscription_unavailable_hint,
              error: true,
            )
          else
            AdaptiveSettingsSwitchRow(
              key: const ValueKey<String>('video-subscription-strict-confirm'),
              title: t.download_subscription_choice_hint(
                group: filter.releaseGroup ?? filter.summaryParts.first,
                resolution: filter.resolution ?? filter.summaryParts.last,
              ),
              value: _strictConfirmed,
              onChanged: _submitting
                  ? null
                  : (bool value) => setState(() => _strictConfirmed = value),
            ),
          if (_media?.mediaKind != VideoMetadataMediaKind.movie) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            TextField(
              key: const ValueKey<String>('video-subscription-start-after'),
              controller: _startAfterController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: t.video_jimaku_episode,
                helperText: t.download_subscription_start_episode(
                  episode: _startAfterController.text.trim().isEmpty
                      ? '1'
                      : _startAfterController.text.trim(),
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class VideoDiscoverySubtitleSearchPage extends StatelessWidget {
  const VideoDiscoverySubtitleSearchPage({
    required this.item,
    required this.registry,
    required this.pickVideo,
    required this.pickDirectory,
    this.attachableJobs = const <VideoDownloadJobRow>[],
    this.onAttach,
    this.onInstalled,
    super.key,
  });

  final VideoDiscoveryItem item;
  final VideoSubtitleRegistry registry;
  final VideoDiscoveryPathPicker pickVideo;
  final VideoDiscoveryPathPicker pickDirectory;
  final List<VideoDownloadJobRow> attachableJobs;
  final VideoDiscoverySubtitleAttach? onAttach;
  final VideoDiscoverySubtitleInstalled? onInstalled;

  @override
  Widget build(BuildContext context) => VideoDiscoverySubtitleSearchDialog(
        item: item,
        registry: registry,
        pickVideo: pickVideo,
        pickDirectory: pickDirectory,
        attachableJobs: attachableJobs,
        onAttach: onAttach,
        onInstalled: onInstalled,
        pageMode: true,
      );
}

class VideoDiscoverySubtitleSearchDialog extends StatefulWidget {
  const VideoDiscoverySubtitleSearchDialog({
    required this.item,
    required this.registry,
    required this.pickVideo,
    required this.pickDirectory,
    this.attachableJobs = const <VideoDownloadJobRow>[],
    this.onAttach,
    this.onInstalled,
    this.pageMode = false,
    super.key,
  });

  final VideoDiscoveryItem item;
  final VideoSubtitleRegistry registry;
  final VideoDiscoveryPathPicker pickVideo;
  final VideoDiscoveryPathPicker pickDirectory;
  final List<VideoDownloadJobRow> attachableJobs;
  final VideoDiscoverySubtitleAttach? onAttach;
  final VideoDiscoverySubtitleInstalled? onInstalled;
  final bool pageMode;

  @override
  State<VideoDiscoverySubtitleSearchDialog> createState() =>
      _VideoDiscoverySubtitleSearchDialogState();
}

class _VideoDiscoverySubtitleSearchDialogState
    extends State<VideoDiscoverySubtitleSearchDialog> {
  SubtitleInstallTarget _target = SubtitleInstallTarget.existingVideo;
  String? _selectedPath;
  String? _selectedJobId;
  ProviderBatchResult<VideoSubtitleCandidate>? _result;
  VideoSubtitleCandidate? _selected;
  bool _loading = false;
  bool _installing = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  Future<void> _search() async {
    final int generation = ++_generation;
    setState(() => _loading = true);
    LocalVideoFingerprint? fingerprint;
    final String? selectedPath = _selectedPath;
    if (_target == SubtitleInstallTarget.existingVideo &&
        selectedPath != null) {
      final File file = File(selectedPath);
      if (await file.exists()) {
        fingerprint = LocalVideoFingerprint(
          fileSize: await file.length(),
          openSubtitlesMovieHash:
              await computeOpenSubtitlesMovieHash(selectedPath),
          fileName: p.basename(selectedPath),
        );
      }
    }
    final ProviderBatchResult<VideoSubtitleCandidate> result =
        await widget.registry.search(
      VideoSubtitleSearchRequest(
        media: widget.item.reference,
        query: widget.item.reference.title,
        alternateTitles: <String>[
          if (widget.item.reference.originalTitle?.trim().isNotEmpty == true)
            widget.item.reference.originalTitle!,
          ...widget.item.reference.aliases,
        ],
        fingerprint: fingerprint,
      ),
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      _result = result;
      _selected = null;
    });
  }

  Future<void> _pickTarget() async {
    if (_target == SubtitleInstallTarget.activeTask) return;
    final String? path = _target == SubtitleInstallTarget.existingVideo
        ? await widget.pickVideo(context)
        : await widget.pickDirectory(context);
    if (path == null || !mounted) return;
    setState(() => _selectedPath = path);
    unawaited(_search());
  }

  Future<void> _install() async {
    final VideoSubtitleCandidate? candidate = _selected;
    if (candidate == null || !_hasSelectedTarget || _installing) return;
    setState(() => _installing = true);
    try {
      if (_target == SubtitleInstallTarget.activeTask) {
        final VideoDownloadJobRow? job = widget.attachableJobs
            .where((VideoDownloadJobRow row) => row.jobId == _selectedJobId)
            .firstOrNull;
        final VideoDiscoverySubtitleAttach? attach = widget.onAttach;
        if (job == null || attach == null) return;
        await attach(job, candidate);
        if (mounted) Navigator.pop(context, job.jobId);
        return;
      }
      final String selectedPath = _selectedPath!;
      final VideoSubtitleDownload download =
          await widget.registry.download(candidate);
      final String installed = await installDiscoverySubtitle(
        download: download,
        target: _target,
        selectedPath: selectedPath,
      );
      await widget.onInstalled?.call(_target, selectedPath, installed);
      if (mounted) Navigator.pop(context, installed);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  bool get _hasSelectedTarget => _target == SubtitleInstallTarget.activeTask
      ? _selectedJobId != null
      : _selectedPath != null;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget content = Padding(
      padding: EdgeInsets.all(tokens.spacing.card + 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (!widget.pageMode) ...<Widget>[
            Text(
              t.video_discovery_subtitle_search,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SizedBox(height: tokens.spacing.card),
          ],
          DropdownButtonFormField<SubtitleInstallTarget>(
            key: const ValueKey<String>('video-subtitle-target'),
            initialValue: _target,
            items: <DropdownMenuItem<SubtitleInstallTarget>>[
              if (widget.attachableJobs.isNotEmpty && widget.onAttach != null)
                DropdownMenuItem<SubtitleInstallTarget>(
                  value: SubtitleInstallTarget.activeTask,
                  child: Text(t.download_tasks_tab),
                ),
              DropdownMenuItem<SubtitleInstallTarget>(
                value: SubtitleInstallTarget.existingVideo,
                child: Text(t.anime_download_kind_video),
              ),
              DropdownMenuItem<SubtitleInstallTarget>(
                value: SubtitleInstallTarget.directory,
                child: Text(t.download_save_root_title),
              ),
            ],
            onChanged: _installing
                ? null
                : (SubtitleInstallTarget? value) {
                    if (value == null) return;
                    setState(() {
                      _target = value;
                      _selectedPath = null;
                      _selectedJobId = value == SubtitleInstallTarget.activeTask
                          ? widget.attachableJobs.firstOrNull?.jobId
                          : null;
                    });
                  },
          ),
          SizedBox(height: tokens.spacing.gap),
          if (_target == SubtitleInstallTarget.activeTask)
            DropdownButtonFormField<String>(
              key: const ValueKey<String>('video-subtitle-active-task'),
              initialValue: _selectedJobId,
              decoration: InputDecoration(labelText: t.download_tasks_tab),
              items: widget.attachableJobs
                  .map(
                    (VideoDownloadJobRow job) => DropdownMenuItem<String>(
                      value: job.jobId,
                      child: Text(
                        '${job.title} · ${job.stage}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: _installing
                  ? null
                  : (String? value) => setState(() => _selectedJobId = value),
            )
          else
            OutlinedButton.icon(
              key: const ValueKey<String>('video-subtitle-pick-target'),
              onPressed: _installing ? null : () => unawaited(_pickTarget()),
              icon: const Icon(Icons.folder_open_outlined),
              label: Text(
                _selectedPath == null
                    ? t.dialog_select
                    : p.basename(_selectedPath!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          SizedBox(height: tokens.spacing.gap),
          if (_result?.isPartial == true)
            _ProviderWarning(message: t.video_discovery_provider_warning),
          Expanded(child: _buildSubtitleResults()),
          SizedBox(height: tokens.spacing.gap),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              if (!widget.pageMode) ...<Widget>[
                TextButton(
                  onPressed: _installing ? null : () => Navigator.pop(context),
                  child: Text(t.dialog_cancel),
                ),
                SizedBox(width: tokens.spacing.gap),
              ],
              FilledButton.icon(
                key: const ValueKey<String>('video-subtitle-install'),
                onPressed:
                    _selected == null || !_hasSelectedTarget || _installing
                        ? null
                        : () => unawaited(_install()),
                icon: _installing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.subtitles_outlined),
                label: Text(t.dialog_save),
              ),
            ],
          ),
        ],
      ),
    );
    if (widget.pageMode) {
      return Scaffold(
        appBar: AppBar(title: Text(t.video_discovery_subtitle_search)),
        body: SafeArea(child: content),
      );
    }
    return FushiDialogFrame(
      maxWidth: 720,
      maxHeightFactor: 0.88,
      scrollable: false,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: content,
    );
  }

  Widget _buildSubtitleResults() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final ProviderBatchResult<VideoSubtitleCandidate>? result = _result;
    if (result == null || result.isTotalFailure) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(t.video_discovery_load_failed),
            TextButton(
                onPressed: () => unawaited(_search()), child: Text(t.retry)),
          ],
        ),
      );
    }
    if (result.hasNoActiveProvider) {
      return _NoProviderEmptyState(
        key: const ValueKey<String>('video-subtitle-no-provider'),
        icon: Icons.subtitles_off_outlined,
        title: t.video_subtitle_no_provider_title,
        hint: t.video_subtitle_no_provider_hint,
      );
    }
    if (result.items.isEmpty) {
      return Center(child: Text(t.video_discovery_empty));
    }
    return ListView.builder(
      key: const ValueKey<String>('video-subtitle-results'),
      itemCount: result.items.length,
      itemBuilder: (BuildContext context, int index) {
        final VideoSubtitleCandidate candidate = result.items[index];
        final List<String> metadata = <String>[
          candidate.providerId,
          candidate.language,
          if (candidate.releaseName?.trim().isNotEmpty == true)
            candidate.releaseName!,
          if (candidate.season case final int season) 'S$season',
          if (candidate.episode case final int episode) 'E$episode',
          if (candidate.fileSize case final int bytes)
            FushiByteFormat.bytes(bytes),
          if (candidate.downloadCount > 0) '${candidate.downloadCount}✓',
          if (candidate.fps case final double fps)
            '${fps.toStringAsFixed(3)} fps',
          if (candidate.hearingImpaired) 'HI',
        ];
        return FushiListItem(
          key: ValueKey<String>('video-subtitle-${candidate.identityKey}'),
          title: Text(candidate.fileName),
          subtitle: Text(metadata.join(' · ')),
          titleMaxLines: 2,
          subtitleMaxLines: 2,
          density: widget.pageMode
              ? FushiListDensity.standard
              : FushiListDensity.compact,
          selected: identical(_selected, candidate),
          leading: const Icon(Icons.subtitles_outlined),
          onTap: () => setState(() => _selected = candidate),
        );
      },
    );
  }
}

class _ProviderWarning extends StatelessWidget {
  const _ProviderWarning({required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: Row(
        children: <Widget>[
          Icon(
            error ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
            color: error ? colors.error : colors.tertiary,
          ),
          SizedBox(width: tokens.spacing.gap),
          Expanded(child: Text(message, style: tokens.type.metadata)),
        ],
      ),
    );
  }
}

/// 「一个来源都没参与」的空态：说清是配置缺失、去哪儿配，而不是让用户以为
/// 换个搜索词就能搜到（BUG-1713）。
class _NoProviderEmptyState extends StatelessWidget {
  const _NoProviderEmptyState({
    required this.icon,
    required this.title,
    required this.hint,
    super.key,
  });

  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.card),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            SizedBox(height: tokens.spacing.gap),
            Text(title, style: theme.textTheme.titleSmall),
            SizedBox(height: tokens.spacing.gap / 2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                hint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _compactDate(DateTime value) {
  final DateTime local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

String? _nonEmpty(String? value) {
  final String normalized = value?.trim() ?? '';
  return normalized.isEmpty ? null : normalized;
}

String? _firstMatch(String input, RegExp expression) =>
    expression.firstMatch(input)?.group(0)?.trim();

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

Set<String> get videoDiscoveryPickerExtensions =>
    kVideoExtensions.map((String value) => value.substring(1)).toSet();
