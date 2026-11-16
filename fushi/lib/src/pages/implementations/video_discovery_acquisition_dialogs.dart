import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/pages/implementations/download_notice.dart';
import 'package:fushi/src/pages/implementations/bt_site_settings_route.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/subscription_release_scope.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/download/video_discovery_selection.dart';
import 'package:fushi_engine/media/video/download/video_resource_version_groups.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:fushi/src/utils/components/header_scroll_split.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveSegmentedButton;
import 'package:fushi_core/fushi_core.dart'
    show
        MediaSourceRow,
        VideoDownloadJobLifecycle,
        VideoDownloadJobRow,
        VideoDownloadJobStage;
import 'package:path/path.dart' as p;

import 'package:fushi/src/pages/implementations/video_resource_version_group_list.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/interconnect_subscription_client.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart'
    show LibraryFilterChip;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show shellRedesignActive;
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show
        fushiMastheadCompact,
        fushiMastheadPageColor,
        fushiMastheadProgressOf,
        kFushiMastheadTrackedOffset;
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show fushiExpressiveMotionEnabled;
import 'package:fushi/src/utils/system_transparency.dart'
    show SystemTransparency;
import 'package:fushi/src/utils/fushi_icons.dart';

export 'package:fushi_engine/media/video/download/video_discovery_selection.dart';

// 集数解析下沉后的源兼容出口（订阅聚合与既有测试从本文件 import 它）。
export 'package:fushi_engine/media/video/download/video_resource_version_groups.dart'
    show episodeNumberFromReleaseTitle;

typedef VideoDiscoveryDownloadSubmit =
    Future<void> Function(VideoDiscoveryDownloadSelection selection);

typedef VideoDiscoverySubscriptionSubmit =
    Future<void> Function(VideoDiscoverySubscriptionSelection selection);

/// 失败态里「去配置下载后端」的端口。返回 true = 用户真配完了，调用方可以重试原动作。
///
/// 为什么是端口而不是在 surface 里直接调 `promptDownloadBackendSetup`：这块 surface 是
/// 纯展示层，落地动作一律由宿主用回调注入（`onSubmit` / `onSubscriptionSubmit`），它
/// 手上没有 `AppModel`；为了弹一个配置框把整棵子树改成 riverpod consumer 会连带要求
/// 祖先有 `ProviderScope`，而既有 widget 测试正是不带 `ProviderScope` 直接 pump 它的。
///
/// 允许为 null：宿主没接线时 SnackBar 只报事实、**不给一个按下去什么都不发生的按钮**
/// （与 `settings_schema_lookup.dart` 里「平台不支持就给 null」同一姿态）。
/// 资源搜索前补齐作品别名（BUG-2794）：发现卡片只带原名时，从详情拿罗马字 /
/// 英文名。宿主注入（页面自己拿不到发现服务）；失败应返回原条目、不抛。
typedef VideoDiscoveryItemAliasResolver =
    Future<VideoDiscoveryItem> Function(VideoDiscoveryItem item);

typedef VideoDownloadBackendSetupPrompt =
    Future<bool> Function(BuildContext context);

typedef VideoDiscoveryPathPicker =
    Future<String?> Function(BuildContext context);

typedef VideoDiscoverySubtitleInstalled =
    Future<void> Function(
      SubtitleInstallTarget target,
      String selectedPath,
      String installedPath,
    );

typedef VideoDiscoverySubtitleAttach =
    Future<void> Function(
      VideoDownloadJobRow job,
      VideoSubtitleCandidate candidate,
    );

/// 订阅交给已配对 host 跑（host 自己搜、自己下到自己的库）。没有本地落地源
/// （`MediaSourceRow`）这一维——落点是 host 的下载目录。
class VideoDiscoveryRemoteSubscriptionSelection {
  const VideoDiscoveryRemoteSubscriptionSelection({
    required this.target,
    required this.media,
    required this.resource,
    required this.filter,
    required this.subtitlePolicy,
    this.startAfterEpisode,
    this.batchRelease = false,
  });

  final HostSubscriptionTarget target;
  final VideoMediaReference media;
  final VideoResourceCandidate resource;
  final StrictVideoSubscriptionFilter filter;
  final VideoDownloadSubtitlePolicy subtitlePolicy;
  final int? startAfterEpisode;

  /// 同 [VideoDiscoverySubscriptionSelection.batchRelease]：host 侧订阅同样要按
  /// 一次性建，否则远端也只是多一条永不命中的追更订阅。
  final bool batchRelease;
}

typedef VideoDiscoveryRemoteSubscriptionSubmit =
    Future<void> Function(VideoDiscoveryRemoteSubscriptionSelection selection);

/// 下载交给已配对 host（设计 §3.3）：host 只收磁链、下到自己的库；没有本地落地
/// 源这一维，字幕由 host 按自己的规则补（wire 不带字幕策略）。
class VideoDiscoveryRemoteDownloadSelection {
  const VideoDiscoveryRemoteDownloadSelection({
    required this.target,
    required this.media,
    required this.resource,
  });

  final HostDownloadTarget target;
  final VideoMediaReference media;
  final VideoResourceCandidate resource;
}

typedef VideoDiscoveryRemoteDownloadSubmit =
    Future<void> Function(VideoDiscoveryRemoteDownloadSelection selection);

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
    'anidb' => externalId == reference.anidbId?.toString(),
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

/// 下载“资源”页没有现成发现卡片时，要求用户显式提供可确认的元数据身份。
/// 不生成 `manual` 假身份；AniDB 可成为后续刮削的规范身份，TMDB/AniList 只作为
/// 发现与下载阶段的可追踪交叉引用，导入后仍须经过 AniDB 身份门控。
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
  if (!const <String>{'anidb', 'tmdb', 'anilist'}.contains(provider) ||
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
    anidbId: provider == 'anidb' ? numericId : null,
    tmdbId: provider == 'tmdb' ? numericId : null,
    anilistId: provider == 'anilist' ? numericId : null,
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
        'selected directory is unavailable',
        selectedPath,
      );
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
      final RandomAccessFile handle = await temporary.open(
        mode: FileMode.write,
      );
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
    'no conflict-free subtitle file name',
    selectedPath,
  );
}

class VideoDiscoveryResourceSearchDialog extends StatelessWidget {
  const VideoDiscoveryResourceSearchDialog({
    required this.item,
    required this.registry,
    required this.sources,
    required this.onSubmit,
    this.defaultSourceId,
    this.onConfigureBackend,
    this.resolveAliases,
    super.key,
  });

  final VideoDiscoveryItem item;
  final VideoResourceRegistry registry;
  final List<MediaSourceRow> sources;
  final int? defaultSourceId;
  final VideoDiscoveryDownloadSubmit onSubmit;
  final VideoDownloadBackendSetupPrompt? onConfigureBackend;
  final VideoDiscoveryItemAliasResolver? resolveAliases;

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
      onConfigureBackend: onConfigureBackend,
      resolveAliases: resolveAliases,
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
    this.onConfigureBackend,
    this.remoteTargets = const <HostDownloadTarget>[],
    this.defaultRemoteTargetUrl,
    this.onRemoteSubmit,
    this.resolveAliases,
    super.key,
  });

  /// 见 [VideoDiscoveryItemAliasResolver]。
  final VideoDiscoveryItemAliasResolver? resolveAliases;

  final VideoDiscoveryItem item;
  final VideoResourceRegistry registry;
  final List<MediaSourceRow> sources;
  final int? defaultSourceId;
  final VideoDiscoveryDownloadSubmit onSubmit;
  final VideoDownloadBackendSetupPrompt? onConfigureBackend;

  /// 宣告代下载能力的已配对 host；非空时多出「下载到」下拉（见 surface）。
  final List<HostDownloadTarget> remoteTargets;

  /// 「下载执行设备」偏好（host 地址）：在 [remoteTargets] 里时作为默认选中。
  final String? defaultRemoteTargetUrl;
  final VideoDiscoveryRemoteDownloadSubmit? onRemoteSubmit;

  @override
  Widget build(BuildContext context) => VideoResourceSearchSurface(
    initialItem: item,
    registry: registry,
    sources: sources,
    defaultSourceId: defaultSourceId,
    onSubmit: onSubmit,
    remoteDownloadTargets: remoteTargets,
    defaultRemoteDownloadUrl: defaultRemoteTargetUrl,
    onRemoteDownloadSubmit: onRemoteSubmit,
    onConfigureBackend: onConfigureBackend,
    resolveAliases: resolveAliases,
    onClose: () => Navigator.of(context).pop(),
    pageMode: true,
    pageTitle: t.video_discovery_resource_search,
  );
}

/// 字幕搜索独立页的页面外壳（资源搜索 / 订阅页的外壳由 surface 自己搭，见
/// [VideoResourceSearchSurface.pageTitle]：宽屏查询条要钉进页头下一行）：
/// 重设计外壳下是二级页页头大字（[FushiPageScaffold.masthead] → `FushiMastheadScaffold`：返回键 + 页名
/// 大字，与其它已改版二级页同一形态），取代旧的「返回胶囊 + 标题胶囊」顶栏；
/// 墨水屏照旧走 [FushiPageHeader]。
///
/// 页名随结果滚动收缩，与其它二级页一致：手机竖屏上要把屏幕尽量让给结果
/// （反馈 XFsZIWYbr8：头部固定时结果只剩一条窄缝可滚）。正文铺到页头底下，
/// surface 在 `pageMode` 下自己消费顶部 padding（见 [HeaderScrollSplit.topInset]）：
/// 窄屏查询头部随结果滚到页头底下（垫页头底板），宽屏头部固定在页头下沿。
class _VideoResourceSearchPageShell extends StatelessWidget {
  const _VideoResourceSearchPageShell({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      FushiPageScaffold(title: title, masthead: true, body: child);
}

/// 发现详情的订阅创建使用独立路由，与资源搜索共享同一块全尺寸 surface。
class VideoDiscoverySubscriptionPage extends StatelessWidget {
  const VideoDiscoverySubscriptionPage({
    required this.item,
    required this.registry,
    required this.sources,
    required this.onSubmit,
    this.defaultSourceId,
    this.onConfigureBackend,
    this.remoteTargets = const <HostSubscriptionTarget>[],
    this.onRemoteSubmit,
    this.resolveAliases,
    super.key,
  });

  /// 见 [VideoDiscoveryItemAliasResolver]。
  final VideoDiscoveryItemAliasResolver? resolveAliases;

  final VideoDiscoveryItem item;
  final VideoResourceRegistry registry;
  final List<MediaSourceRow> sources;
  final int? defaultSourceId;
  final VideoDiscoverySubscriptionSubmit onSubmit;
  final VideoDownloadBackendSetupPrompt? onConfigureBackend;
  final List<HostSubscriptionTarget> remoteTargets;
  final VideoDiscoveryRemoteSubscriptionSubmit? onRemoteSubmit;

  @override
  Widget build(BuildContext context) => VideoResourceSearchSurface(
    initialItem: item,
    registry: registry,
    sources: sources,
    defaultSourceId: defaultSourceId,
    onSubscriptionSubmit: onSubmit,
    remoteTargets: remoteTargets,
    onRemoteSubscriptionSubmit: onRemoteSubmit,
    onConfigureBackend: onConfigureBackend,
    resolveAliases: resolveAliases,
    onClose: () => Navigator.of(context).pop(),
    pageMode: true,
    pageTitle: t.video_discovery_subscribe,
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
    this.remoteTargets = const <HostSubscriptionTarget>[],
    this.onRemoteSubscriptionSubmit,
    this.remoteDownloadTargets = const <HostDownloadTarget>[],
    this.defaultRemoteDownloadUrl,
    this.onRemoteDownloadSubmit,
    this.onConfigureBackend,
    this.resolveAliases,
    this.onClose,
    this.pageMode = false,
    this.pageTitle,
    super.key,
  }) : assert((onSubmit == null) != (onSubscriptionSubmit == null));

  /// 见 [VideoDiscoveryItemAliasResolver]：[initialItem] 没有拉丁标题时，首次
  /// 搜索前先补齐别名，而不是赌那一次发现搜索里 MAL / AniList 碰巧成功。
  final VideoDiscoveryItemAliasResolver? resolveAliases;

  final VideoDiscoveryItem? initialItem;
  final VideoResourceRegistry registry;
  final List<MediaSourceRow> sources;
  final int? defaultSourceId;
  final VideoDiscoveryDownloadSubmit? onSubmit;
  final VideoDiscoverySubscriptionSubmit? onSubscriptionSubmit;

  /// 宣告支持内容订阅的已配对 host（只在订阅模式有意义）。非空时多出「运行位置」
  /// 下拉：本机 / 某台 host；没有本地落地源时默认落到第一台 host。
  final List<HostSubscriptionTarget> remoteTargets;
  final VideoDiscoveryRemoteSubscriptionSubmit? onRemoteSubscriptionSubmit;

  /// 宣告代下载能力的已配对 host（只在下载模式有意义，设计 §3.3）。非空时多出
  /// 「下载到」下拉：本机 / 某台 host；[defaultRemoteDownloadUrl]（「下载执行设备」
  /// 偏好）命中其中一台时默认选它，否则没有本地落地源时默认落到第一台。
  final List<HostDownloadTarget> remoteDownloadTargets;
  final String? defaultRemoteDownloadUrl;
  final VideoDiscoveryRemoteDownloadSubmit? onRemoteDownloadSubmit;

  /// 见 [VideoDownloadBackendSetupPrompt]：提交失败在「后端没配好 / 后端运行时缺失」
  /// 时的可执行出口。null = 宿主没接线，失败态只报事实不给按钮。
  final VideoDownloadBackendSetupPrompt? onConfigureBackend;
  final VoidCallback? onClose;
  final bool pageMode;

  /// 非 null（且 [pageMode]）= surface 自己挂独立页的页面外壳（
  /// [FushiPageScaffold.masthead]，页名 = 本值）：宽屏重设计外壳下查询 / 筛选条
  /// 要钉进页头大字的下一行（[FushiPageScaffold.mastheadBottom]），而它的状态
  /// 在 surface 里，所以外壳由 surface 来搭。null = 宿主自己给外壳。
  final String? pageTitle;

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

  /// 钉住查询条形态（见 [_pinsQueryHeader]）下结果滚动区的竖向偏移：只给钉住条
  /// 下沿的渐隐边算进度，与页头底板同一条映射（[fushiMastheadProgressOf]）。
  final ValueNotifier<double> _pinnedScrollOffset = ValueNotifier<double>(0);

  /// 订阅起始集号的默认值。新版（`organizationPolicy == 'library'`）订阅把
  /// `startAfterEpisode` 按「从该集开始」解释（见
  /// `video_download_subscription_service.dart` 的 `inclusiveStart`），所以默认
  /// 第 1 集与「留空 = 不限」落到同一个窗口；显式填出来用户才看得见起点。
  static const String _defaultStartEpisode = '1';

  final TextEditingController _startAfterController = TextEditingController(
    text: _defaultStartEpisode,
  );
  VideoDiscoveryCategory _manualCategory = VideoDiscoveryCategory.anime;
  VideoMetadataMediaKind _manualMediaKind = VideoMetadataMediaKind.tv;
  String _manualProvider = 'anidb';
  VideoResourceSearchResult? _result;

  /// 已选中的候选，按点选顺序（入队顺序就按这个走，与用户看到的顺序一致）。
  ///
  /// 只有**下载模式**才可能多于一条：订阅是「一条规则跟一个 release 模板」，
  /// 多选在那里没有意义，所以订阅模式下选新的直接替换旧的（见 [_select]）。
  /// 用一个集合而不是「单值 + 集合」两份状态，是为了不再有两处要同步。
  final List<VideoResourceCandidate> _selectedCandidates =
      <VideoResourceCandidate>[];

  VideoResourceCandidate? get _selected =>
      _selectedCandidates.isEmpty ? null : _selectedCandidates.last;

  bool _isSelected(VideoResourceCandidate candidate) => _selectedCandidates.any(
    (VideoResourceCandidate c) => c.identityKey == candidate.identityKey,
  );

  Set<String> get _selectedIdentityKeys => <String>{
    for (final VideoResourceCandidate c in _selectedCandidates) c.identityKey,
  };
  int? _sourceId;
  VideoDownloadSubtitlePolicy _subtitlePolicy =
      VideoDownloadSubtitlePolicy.bestEffort;
  bool _loading = false;
  bool _submitting = false;

  /// 「加入订阅」开关（追踪当前 release 的字幕组 + 分辨率）。默认打开：进这个
  /// 面板本来就是为了订阅，再要求用户手工确认一次只是多一步（提交按钮此前一直
  /// 因为它是 false 而禁用）。用户显式关掉后不再被换候选/重新搜索拉回来。
  bool _strictConfirmed = true;
  int _generation = 0;

  /// 订阅运行位置：null = 本机。
  HostSubscriptionTarget? _remoteTarget;

  /// 下载落点：null = 本机（下载模式专用，与 [_remoteTarget] 互斥于模式）。
  HostDownloadTarget? _remoteDownloadTarget;
  bool get _remote => _remoteTarget != null || _remoteDownloadTarget != null;

  /// 当前作品条目：起初是 [VideoResourceSearchSurface.initialItem]，补齐别名后
  /// 换成补齐版（提交时的身份快照也随之带上别名）。
  VideoDiscoveryItem? _item;

  /// 搜索框的默认词（首选检索词）。用户没改过搜索框时，补齐别名后跟着换。
  static String _defaultQueryFor(VideoDiscoveryItem? item) {
    final VideoMediaReference? reference = item?.reference;
    if (reference == null) return '';
    return preferredNyaaSearchQueries(
          VideoResourceSearchRequest(media: reference),
        ).firstOrNull ??
        reference.title;
  }

  @override
  void initState() {
    super.initState();
    _item = widget.initialItem;
    final VideoMediaReference? reference = _item?.reference;
    if (reference != null) _manualCategory = reference.discoveryCategory;
    _queryController.text = _defaultQueryFor(_item);
    _sourceId =
        widget.sources.any(
          (MediaSourceRow source) => source.id == widget.defaultSourceId,
        )
        ? widget.defaultSourceId
        : widget.sources.firstOrNull?.id;
    if (widget.subscription &&
        widget.sources.isEmpty &&
        widget.remoteTargets.isNotEmpty) {
      _remoteTarget = widget.remoteTargets.first;
    }
    if (!widget.subscription && widget.remoteDownloadTargets.isNotEmpty) {
      _remoteDownloadTarget =
          widget.remoteDownloadTargets.firstWhereOrNull(
            // 按「是不是那台 host」认，而不是 URL 字面：选路可能经另一条地址到达。
            (HostDownloadTarget t) => t.isPeer(widget.defaultRemoteDownloadUrl),
          ) ??
          (widget.sources.isEmpty ? widget.remoteDownloadTargets.first : null);
    }
    if (_item != null) unawaited(_resolveAliasesThenSearch());
  }

  /// 首次搜索：条目缺拉丁标题且宿主给了补齐端口时先补齐，再搜。
  Future<void> _resolveAliasesThenSearch() async {
    final VideoDiscoveryItem? item = _item;
    final VideoDiscoveryItemAliasResolver? resolve = widget.resolveAliases;
    if (item != null && resolve != null && !item.reference.hasLatinTitle) {
      final int generation = ++_generation;
      setState(() => _loading = true);
      final String before = _queryController.text;
      VideoDiscoveryItem resolved = item;
      try {
        resolved = await resolve(item);
      } on Object catch (error, stack) {
        // 补齐是加法：失败就按原条目搜，不能挡住搜索本身。
        ErrorLogService.instance.log(
          'VideoResourceSearchSurface.resolveAliases',
          error,
          stack,
        );
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _item = resolved;
        _loading = false;
        if (_queryController.text == before &&
            before == _defaultQueryFor(item)) {
          _queryController.text = _defaultQueryFor(resolved);
        }
      });
    }
    await _search();
  }

  @override
  void dispose() {
    _queryController.dispose();
    _manualIdController.dispose();
    _manualYearController.dispose();
    _startAfterController.dispose();
    _pinnedScrollOffset.dispose();
    super.dispose();
  }

  VideoMediaReference? get _media {
    final VideoDiscoveryItem? item = _item;
    if (item != null) {
      return item.reference.withDiscoveryCategory(_manualCategory);
    }
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
      ++_generation;
      _loading = false;
      _result = null;
      _selectedCandidates.clear();
    });
  }

  void _changeCategory(VideoDiscoveryCategory? value) {
    if (value == null || value == _manualCategory || _submitting) return;
    setState(() {
      _manualCategory = value;
      if (_item == null) {
        if (value == VideoDiscoveryCategory.movie) {
          _manualMediaKind = VideoMetadataMediaKind.movie;
        } else if (value == VideoDiscoveryCategory.tv) {
          _manualMediaKind = VideoMetadataMediaKind.tv;
        }
        _manualProvider = value == VideoDiscoveryCategory.anime
            ? 'anidb'
            : 'tmdb';
      }
    });
    _invalidateManualSearch();
    if (_item != null) unawaited(_search());
  }

  static String _identityProviderLabel(String id) => switch (id) {
    'anidb' => 'AniDB',
    'tmdb' => 'TMDB',
    'anilist' => 'AniList',
    _ => id,
  };

  Widget _buildCategorySelector() =>
      _ResourceMenuSelect<VideoDiscoveryCategory>(
        key: const ValueKey<String>('video-resource-category'),
        title: t.media_tracking_kind,
        // 页面模式里它和作品拼写 chip 同排：不带图标时「系列」读起来像又一枚
        // 拼写快捷搜索，筛选图标标明这一枚是分类筛选。
        icon: FushiIcons.filter,
        value: _manualCategory,
        options: const <VideoDiscoveryCategory>[
          VideoDiscoveryCategory.anime,
          VideoDiscoveryCategory.movie,
          VideoDiscoveryCategory.tv,
        ],
        labelOf: (VideoDiscoveryCategory category) => switch (category) {
          VideoDiscoveryCategory.anime => t.media_tracking_anime,
          VideoDiscoveryCategory.movie => t.collection_relation_movie,
          _ => t.series,
        },
        onSelected: _submitting ? null : _changeCategory,
      );

  Future<void> _search() async {
    final VideoMediaReference? media = _media;
    if (media == null || _loading) return;
    final int generation = ++_generation;
    setState(() {
      _loading = true;
      _selectedCandidates.clear();
    });
    final VideoResourceSearchResult result = await widget.registry.search(
      VideoResourceSearchRequest(media: media, query: _queryController.text),
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _result = result;
      _loading = false;
    });
  }

  /// 下载模式：true = 平铺全部条目（旧视图）；false（默认）= 版本卡视图。
  bool _flatResourceView = false;

  /// 把 [members] 整组设成选中 / 未选中（合辑整包选）。保持既有点选顺序，
  /// 已选的不重复入列。
  void _setGroupSelected(List<VideoResourceCandidate> members, bool selected) {
    final Set<String> keys = <String>{
      for (final VideoResourceCandidate m in members) m.identityKey,
    };
    setState(() {
      if (selected) {
        for (final VideoResourceCandidate m in members) {
          if (!_isSelected(m)) _selectedCandidates.add(m);
        }
      } else {
        _selectedCandidates.removeWhere(
          (VideoResourceCandidate c) => keys.contains(c.identityKey),
        );
      }
    });
  }

  void _select(VideoResourceCandidate candidate) {
    setState(() {
      if (widget.subscription) {
        // 订阅只跟一条模板：选新的直接替换，不累积。
        _selectedCandidates
          ..clear()
          ..add(candidate);
      } else if (!_selectedCandidates.remove(
        _selectedCandidates.firstWhereOrNull(
          (VideoResourceCandidate c) => c.identityKey == candidate.identityKey,
        ),
      )) {
        _selectedCandidates.add(candidate);
      }
      // 起始集号只对订阅有意义，且要跟着「当前这一条」走；下载模式多选时用最后
      // 点的那条填，反正提交时不读它。
      final VideoResourceCandidate? current = _selected;
      final int? episode = current == null
          ? null
          : episodeNumberFromReleaseTitle(current.title);
      _startAfterController.text = episode?.toString() ?? _defaultStartEpisode;
    });
  }

  /// 当前选中的候选是不是整包。判据与订阅检查端同源（引擎
  /// [subscriptionReleaseIsBatch]），避免两端各判一次又判得不一样——那正是
  /// BUG-2619 里「UI 按单集建、服务端按整包丢」的成因。
  ///
  /// 订阅模式下列表的一行是**一条规则**而不是一个发布，所以要问的是这条规则
  /// 覆盖的发布里还有没有单集：有就照旧追更，全是整包才建一次性订阅。
  bool get _selectedIsBatch {
    final VideoResourceCandidate? candidate = _selected;
    if (candidate == null) return false;
    if (widget.subscription) {
      final ProviderBatchResult<VideoResourceCandidate>? result = _result;
      if (result != null) {
        for (final VideoSubscriptionCandidateGroup group
            in groupVideoSubscriptionCandidates(result.items)) {
          if (group.representative.identityKey == candidate.identityKey) {
            return group.batchOnly;
          }
        }
      }
    }
    return subscriptionReleaseIsBatch(candidate.title);
  }

  MediaSourceRow? get _source {
    for (final MediaSourceRow source in widget.sources) {
      if (source.id == _sourceId) return source;
    }
    return null;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    // 资源搜索的候选全是 BT / 磁力（本机下、交给 host 下、建订阅都一样）。
    if (!await confirmP2pDownloadNotice(context) || !mounted) return;
    if (_remoteTarget != null) return _submitRemote();
    if (_remoteDownloadTarget != null) return _submitRemoteDownload();
    final VideoMediaReference? media = _media;
    final MediaSourceRow? source = _source;
    // 目标集在任何 await 之前定死：提交期间搜索结果会被刷新重建，跨 await 重读
    // 会让「按钮上写的 N」与实际入队条数对不上。
    final List<VideoResourceCandidate> resources =
        List<VideoResourceCandidate>.of(_selectedCandidates);
    if (media == null || resources.isEmpty || source == null || _submitting) {
      return;
    }
    VideoDiscoveryDownloadSelection downloadFor(
      VideoResourceCandidate resource,
    ) => VideoDiscoveryDownloadSelection(
      media: media,
      resource: resource,
      source: source,
      subtitlePolicy: _subtitlePolicy,
    );
    setState(() => _submitting = true);
    try {
      if (widget.subscription) {
        final VideoResourceCandidate resource = resources.first;
        final StrictVideoSubscriptionFilter? filter =
            deriveStrictVideoSubscriptionFilter(resource);
        if (filter == null || !_strictConfirmed) return;
        // 整包没有「从第几集起追」这一维，起始集号不能带出去：留着它只会让一条
        // 一次性订阅显示一个毫无意义的起点（BUG-2619）。
        final bool batch = _selectedIsBatch;
        final int? startAfter =
            batch || media.mediaKind == VideoMetadataMediaKind.movie
            ? null
            : int.tryParse(_startAfterController.text.trim());
        await widget.onSubscriptionSubmit!(
          VideoDiscoverySubscriptionSelection(
            download: downloadFor(resource),
            filter: filter,
            startAfterEpisode: startAfter,
            batchRelease: batch,
          ),
        );
      } else {
        // 串行：入队最终落到同一张 video_download_jobs 表，并发只会把一批提交
        // 变成一批竞态。首条失败直接抛给下面的 catch（后端不可用 / 没配好这类
        // 前置问题对整批都成立，逐条重复报 N 次没有意义）；后续条目的失败聚合成
        // 一句，不让一条挂掉把其余的也废掉。已有任务管着同一颗种子是管线的领域
        // 结果（[VideoDownloadAlreadyQueued]，BUG-4270）：单独计「已在队列」，
        // 不算失败、也不让首条重复把整批判成失败。
        int queued = 0;
        int alreadyQueued = 0;
        int failed = 0;
        for (int i = 0; i < resources.length; i++) {
          try {
            await widget.onSubmit!(downloadFor(resources[i]));
            queued++;
          } on VideoDownloadAlreadyQueued {
            alreadyQueued++;
          } on Object catch (error, stackTrace) {
            if (queued == 0 && alreadyQueued == 0) rethrow;
            failed++;
            debugPrint(
              '[fushi-discovery] batch enqueue failed: $error\n$stackTrace',
            );
          }
        }
        if (mounted && (failed > 0 || alreadyQueued > 0)) {
          _showSubmitFailure(
            <String>[
              if (alreadyQueued > 0)
                t.download_batch_already_queued(n: alreadyQueued),
              if (failed > 0) t.download_batch_failed(n: failed),
            ].join(' · '),
            null,
          );
        }
      }
      if (mounted) widget.onClose?.call();
    } on VideoDownloadBackendUnavailable catch (error) {
      // 选中的后端 runtime 不可用（内置引擎的原生库缺失）。用户能自己做的事只有一件：
      // 换一个后端 / 重配下载后端——所以按钮直落配置引导，而不是让他对着一句
      // 「运行时缺失」干瞪眼。
      _showSubmitFailure(error.message, _backendSetupAction());
    } on ArgumentError {
      // 后端身份拼不出来（qBittorrent 地址空/非法、安装 id 空）。缺的就是那几个字段。
      _showSubmitFailure(
        t.download_backend_not_configured,
        _backendSetupAction(),
      );
    } on VideoDownloadPipelineActionRequired catch (error) {
      // 原因是运行期的（后端不可达、加种失败、路径映射缺失……），没有一个固定的
      // 设置页可跳；唯一确定有意义的动作是「按用户修好外部条件后再来一次」。
      _showSubmitFailure(
        error.message,
        SnackBarAction(label: t.retry, onPressed: () => unawaited(_submit())),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 订阅交给 host：不经本地后端，失败原因来自 host（provider 不在 / 没配后端 /
  /// 网络），按 host 的结构化 reason 给文案。
  Future<void> _submitRemote() async {
    final HostSubscriptionTarget? target = _remoteTarget;
    final VideoMediaReference? media = _media;
    final VideoResourceCandidate? resource = _selected;
    final VideoDiscoveryRemoteSubscriptionSubmit? submit =
        widget.onRemoteSubscriptionSubmit;
    if (target == null ||
        media == null ||
        resource == null ||
        submit == null ||
        _submitting) {
      return;
    }
    final StrictVideoSubscriptionFilter? filter =
        deriveStrictVideoSubscriptionFilter(resource);
    if (filter == null || !_strictConfirmed) return;
    final String providerId = persistedVideoResourceProviderId(resource);
    if (!target.supportsResourceProvider(providerId)) {
      _showSubmitFailure(
        t.subscription_remote_provider_unavailable(provider: providerId),
        null,
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      final bool batch = _selectedIsBatch;
      await submit(
        VideoDiscoveryRemoteSubscriptionSelection(
          target: target,
          media: media,
          resource: resource,
          filter: filter,
          subtitlePolicy: _subtitlePolicy,
          startAfterEpisode:
              batch || media.mediaKind == VideoMetadataMediaKind.movie
              ? null
              : int.tryParse(_startAfterController.text.trim()),
          batchRelease: batch,
        ),
      );
      if (mounted) widget.onClose?.call();
    } on HostSubscriptionException catch (error) {
      final String message = switch (error.reason) {
        'provider_unavailable' => t.subscription_remote_provider_unavailable(
          provider: providerId,
        ),
        'unsupported' => t.subscription_remote_unsupported,
        _ => error.detail ?? error.code,
      };
      _showSubmitFailure(
        message,
        SnackBarAction(label: t.retry, onPressed: () => unawaited(_submit())),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 下载交给 host：目标集在 await 前定死、逐条串行、首条失败直接报、后续聚合
  /// ——与本地批量提交同一套纪律。失败原因来自 host（连不上 / 后端没配 / 只收
  /// 磁链），按客户端结构化 code 给文案。
  Future<void> _submitRemoteDownload() async {
    final HostDownloadTarget? target = _remoteDownloadTarget;
    final VideoMediaReference? media = _media;
    final VideoDiscoveryRemoteDownloadSubmit? submit =
        widget.onRemoteDownloadSubmit;
    final List<VideoResourceCandidate> resources =
        List<VideoResourceCandidate>.of(_selectedCandidates);
    if (target == null ||
        media == null ||
        submit == null ||
        resources.isEmpty ||
        _submitting) {
      return;
    }
    setState(() => _submitting = true);
    try {
      int failed = 0;
      for (int i = 0; i < resources.length; i++) {
        try {
          await submit(
            VideoDiscoveryRemoteDownloadSelection(
              target: target,
              media: media,
              resource: resources[i],
            ),
          );
        } on Object catch (error, stackTrace) {
          if (i == 0) rethrow;
          failed++;
          debugPrint(
            '[fushi-discovery] remote batch enqueue failed: $error\n$stackTrace',
          );
        }
      }
      if (failed > 0 && mounted) {
        _showSubmitFailure(t.download_batch_failed(n: failed), null);
      }
      if (mounted) widget.onClose?.call();
    } on HostDownloadException catch (error) {
      final String message = switch (error.code) {
        'magnet_only' => t.download_execution_remote_magnet_only,
        _ => error.detail ?? error.code,
      };
      _showSubmitFailure(
        message,
        SnackBarAction(label: t.retry, onPressed: () => unawaited(_submit())),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 提交失败的统一播报口：**一句事实 + 一个能直接解决它的动作**。
  ///
  /// 旧实现三条 catch 各写一遍裸 `SnackBar(content:)`，用户看到「下载后端未配置」
  /// 却没有任何可按的东西，只能自己去猜该翻哪个页面。停留时间也一并拉长——4 秒的
  /// 默认时长里根本来不及看完一句报错再决定按不按那个按钮。
  void _showSubmitFailure(String message, SnackBarAction? action) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      FushiSnackBar(
        content: Text(message),
        duration: const Duration(seconds: 10),
        action: action,
      ),
    );
  }

  /// 「去配置下载后端」动作；宿主没接线时返回 null（不渲染按不动的按钮）。
  SnackBarAction? _backendSetupAction() {
    final VideoDownloadBackendSetupPrompt? configure =
        widget.onConfigureBackend;
    if (configure == null) return null;
    return SnackBarAction(
      label: t.download_backend_setup_start,
      onPressed: () => unawaited(_configureBackendAndRetry(configure)),
    );
  }

  /// 配完后**自动重试原提交**：用户点这个按钮的意图是「把这次下载办成」，让他配完
  /// 再手动找一遍刚才那条 release 并重按一次提交，等于把修好的一半又扔回给他。
  /// 返回 false（用户取消/没配完）或 surface 已卸载时不重试，绝不空转。
  Future<void> _configureBackendAndRetry(
    VideoDownloadBackendSetupPrompt configure,
  ) async {
    if (!mounted) return;
    final bool configured = await configure(context);
    if (!configured || !mounted) return;
    await _submit();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool manual = _item == null;
    final VideoResourceCandidate? selected = _selected;
    final StrictVideoSubscriptionFilter? filter = selected == null
        ? null
        : deriveStrictVideoSubscriptionFilter(selected);
    final double inset = tokens.spacing.card + 4;
    final bool pinQuery = _pinsQueryHeader(context);
    // [bodyContext]：正文所在的 context。surface 自己搭页面外壳时，页头下沿
    // （MediaQuery 顶部 padding）只在外壳的 body 里量得到，不能拿外层 context。
    Widget content(BuildContext bodyContext) => Padding(
      // 独立页正文铺到页头底下：顶部留白改由滚动区自己让（页头下沿 + inset），
      // 窄屏滚动内容才能滚进页头底下，而不是在页头下沿被硬切。
      padding: widget.pageMode
          ? EdgeInsets.fromLTRB(inset, 0, inset, inset)
          : EdgeInsets.all(inset),
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
          // 窄屏头部随结果同滚、宽屏头部固定（见 HeaderScrollSplit）；底部的
          // 落地目录 / 字幕策略 / 提交两种布局都固定在滚动区外。
          Expanded(
            // 每次拿到新一批结果（新搜索 / 切分类 / 切平铺视图）重开一次错峰
            // 进场；滚动带出的卡片直接出现，不拖影。
            child: FushiEntranceScope(
              replayKey: Object.hash(_result, _flatResourceView),
              child: pinQuery
                  ? _buildPinnedResultScroll(
                      tokens,
                      MediaQuery.paddingOf(bodyContext).top,
                    )
                  : HeaderScrollSplit(
                      scrollKey: const ValueKey<String>(
                        'video-resource-scroll',
                      ),
                      topInset: widget.pageMode
                          ? MediaQuery.paddingOf(bodyContext).top + inset
                          : 0,
                      header: _buildQueryHeader(tokens, manual),
                      resultSlivers: _buildResultSlivers(),
                    ),
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          _buildOptions(filter),
          SizedBox(height: tokens.spacing.card),
          _buildSubmitRow(filter),
        ],
      ),
    );
    final String? pageTitle = widget.pageTitle;
    if (!widget.pageMode || pageTitle == null) return content(context);
    return FushiPageScaffold(
      title: pageTitle,
      masthead: true,
      // 宽屏：查询 / 筛选条是页头大字的下一行——与页名同属一块吸顶面，滚动后
      // 一起垫页头底板（90% 页面底色 + 模糊），页名在它上面连续收缩；结果从这块
      // 面底下滑过。页头这一行左右边距是 spacing.page，补齐到正文的 inset，
      // 搜索框与结果列表左右对齐。
      mastheadBottom: pinQuery
          ? _PinnedQueryEdge(
              offset: _pinnedScrollOffset,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: max(0, inset - tokens.spacing.page),
                ),
                child: _buildQueryHeader(tokens, manual, pinned: true),
              ),
            )
          : null,
      body: SafeArea(top: false, child: Builder(builder: content)),
    );
  }

  /// 查询 / 筛选条是否钉进页头（[VideoResourceSearchSurface.pageTitle] 外壳、
  /// 重设计外壳、宽屏）。窄屏照旧随结果滚走（反馈 XFsZIWYbr8：手机竖屏把屏幕让给
  /// 结果）；墨水屏页头不是页头大字形态，没有可钉的下一行，照旧放在正文里。
  bool _pinsQueryHeader(BuildContext context) =>
      widget.pageMode &&
      widget.pageTitle != null &&
      shellRedesignActive(context) &&
      !HeaderScrollSplit.isPhoneLayout(context);

  /// 钉住查询条形态下的结果滚动区：铺到页头底下（顶部让出页头下沿），逐源回执、
  /// 来源标签 / 视图切换与结果同属一个滚动视图，一起从页头底板下面滑过——不再
  /// 有固定头部下沿那道把半截行硬切掉的边，标签行也不会在滚动中突然跳没。
  /// [bodyTop] = 页头下沿（正文 MediaQuery 的顶部 padding）。
  Widget _buildPinnedResultScroll(FushiDesignTokens tokens, double bodyTop) {
    final List<VideoResourceSourceReport>? reports = _loading
        ? null
        : _result?.sources;
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical) {
          _pinnedScrollOffset.value = notification.metrics.extentBefore;
        }
        return false;
      },
      child: CustomScrollView(
        key: const ValueKey<String>('video-resource-scroll'),
        slivers: <Widget>[
          SliverPadding(
            padding: EdgeInsets.only(top: bodyTop + tokens.spacing.gap),
          ),
          if (reports != null && reports.isNotEmpty)
            SliverToBoxAdapter(
              child: VideoResourceSourceStatusList(reports: reports),
            ),
          ..._buildResultSlivers(),
        ],
      ),
    );
  }

  /// 查询 / 筛选头部：手动模式的检索字段，或作品模式的搜索框 + 分类 + 拼写
  /// chip，外加逐源回执。放在结果滚动视图的首个 sliver 里随结果一起滚走；
  /// [pinned] = 钉进页头大字下一行（见 [_pinsQueryHeader]）：不带逐源回执
  /// （它随结果滚动）与末尾留白（页头这一行自带下边距）。
  Widget _buildQueryHeader(
    FushiDesignTokens tokens,
    bool manual, {
    bool pinned = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!manual && !widget.pageMode) ...<Widget>[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: _buildCategorySelector(),
          ),
          SizedBox(height: tokens.spacing.gap),
        ],
        if (!manual && widget.pageMode) ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: FushiSearchBar(
                  fieldKey: const ValueKey<String>('video-resource-query'),
                  controller: _queryController,
                  hintText: t.video_discovery_search_hint,
                  onSubmitted: (_) => unawaited(_search()),
                ),
              ),
              SizedBox(width: tokens.spacing.gap),
              FushiIconButtonControl.filledTonal(
                tooltip: t.dialog_search,
                onPressed: _loading ? null : () => unawaited(_search()),
                icon: const FushiIcon(Icons.search_rounded),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap),
          // 分类 chip 打头、作品拼写 chip 跟在同一行：一行筛选条，不再是一整条
          // MD2 下拉字段 + 下面再一行拼写。
          // 单行横滑而不是多行 Wrap：四五个拼写换成两三行会把本来就紧的结果区
          // 再压掉一截。桌面默认 dragDevices 不含鼠标：不包
          // HorizontalDragScrollable 时鼠标拖不出右侧被截掉的拼写。
          HorizontalDragScrollable(
            child: SingleChildScrollView(
              key: const ValueKey<String>('video-resource-alias-chips'),
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  _buildCategorySelector(),
                  SizedBox(width: tokens.spacing.gap),
                  if (_manualCategory == VideoDiscoveryCategory.anime)
                    // 与 Nyaa 实际补查的作品拼写同一份（BUG-2818）：元数据排第一的
                    // 罗马字不一定是发布组的写法，其余拼写也得点得到。
                    ...nyaaSearchQueries(
                      VideoResourceSearchRequest(media: _media),
                    ).map(
                      (String query) => Padding(
                        padding: EdgeInsetsDirectional.only(
                          end: tokens.spacing.gap,
                        ),
                        child: FushiActionChipControl(
                          label: Text(query),
                          onPressed: _loading
                              ? null
                              : () {
                                  _queryController.text = query;
                                  unawaited(_search());
                                },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!pinned) SizedBox(height: tokens.spacing.card),
        ],
        if (manual) ...<Widget>[
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Widget search = FushiSearchBar(
                fieldKey: const ValueKey<String>('video-resource-query'),
                controller: _queryController,
                hintText: t.video_discovery_search_hint,
                onQueryChanged: (_) => _invalidateManualSearch(),
                onSubmitted: (_) => unawaited(_search()),
              );
              final Widget category = Align(
                alignment: AlignmentDirectional.centerStart,
                child: _buildCategorySelector(),
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
                        FushiIconButtonControl.filledTonal(
                          tooltip: _manualSearchTooltip,
                          onPressed: _loading || !_manualIdentityReady
                              ? null
                              : () => unawaited(_search()),
                          icon: const FushiIcon(Icons.search_rounded),
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
                  FushiIconButtonControl.filledTonal(
                    tooltip: _manualSearchTooltip,
                    onPressed: _loading || !_manualIdentityReady
                        ? null
                        : () => unawaited(_search()),
                    icon: const FushiIcon(Icons.search_rounded),
                  ),
                ],
              );
            },
          ),
          if (_manualCategory == VideoDiscoveryCategory.anime) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: _ResourceMenuSelect<VideoMetadataMediaKind>(
                key: const ValueKey<String>('video-resource-anime-kind'),
                title: t.media_tracking_kind,
                value: _manualMediaKind,
                options: const <VideoMetadataMediaKind>[
                  VideoMetadataMediaKind.tv,
                  VideoMetadataMediaKind.movie,
                ],
                labelOf: (VideoMetadataMediaKind kind) =>
                    kind == VideoMetadataMediaKind.movie
                    ? t.collection_relation_movie
                    : t.series,
                onSelected: (VideoMetadataMediaKind value) {
                  setState(() {
                    _manualMediaKind = value;
                    _result = null;
                    _selectedCandidates.clear();
                  });
                },
              ),
            ),
          ],
          SizedBox(height: tokens.spacing.gap),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // 与同排的外部 ID / 年份是同一个输入框组件（见 [_ResourceMenuField]），
              // 两套设计系统下高度 / 密度 / 内边距 / 基线天然一致；值受控，切分类
              // 时程序改写的识别源立刻显示出来。
              final Widget provider = _ResourceMenuField<String>(
                key: const ValueKey<String>('video-resource-provider'),
                title: t.video_resource_identity_provider,
                value: _manualProvider,
                options: const <String>['anidb', 'tmdb', 'anilist'],
                labelOf: _identityProviderLabel,
                onSelected: _submitting
                    ? null
                    : (String value) {
                        setState(() {
                          _manualProvider = value;
                          _result = null;
                          _selectedCandidates.clear();
                        });
                      },
              );
              final Widget externalId = FushiTextFieldControl(
                key: const ValueKey<String>('video-resource-external-id'),
                controller: _manualIdController,
                decoration: InputDecoration(
                  labelText: t.video_work_external_ids,
                ),
                onChanged: (_) => _invalidateManualSearch(),
              );
              final Widget year = FushiTextFieldControl(
                key: const ValueKey<String>('video-resource-year'),
                controller: _manualYearController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t.video_filter_year),
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
          if (!pinned) SizedBox(height: tokens.spacing.gap),
        ],
        // 逐源回执（BUG-2794）：旧的「部分来源暂不可用」横幅不说是哪家，
        // 成功但 0 条的源更是完全隐形。钉住形态下它排在结果滚动区里。
        if (!pinned && !_loading && (_result?.sources.isNotEmpty ?? false))
          VideoResourceSourceStatusList(reports: _result!.sources),
      ],
    );
  }

  Widget _buildSubmitRow(StrictVideoSubscriptionFilter? filter) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        if (widget.onClose != null && !widget.pageMode)
          FushiTextButton(
            onPressed: _submitting ? null : widget.onClose,
            child: Text(t.dialog_cancel),
          ),
        SizedBox(width: tokens.spacing.gap),
        FushiFilledButton.icon(
          key: ValueKey<String>(
            widget.subscription
                ? 'video-subscription-submit'
                : 'video-resource-submit',
          ),
          onPressed: _canSubmit(filter) ? () => unawaited(_submit()) : null,
          icon: _submitting
              ? const SizedBox.square(
                  dimension: 16,
                  child: FushiCircularProgressIndicator(strokeWidth: 2),
                )
              : FushiIcon(
                  widget.subscription
                      ? Icons.favorite_border_rounded
                      : Icons.download_rounded,
                ),
          label: Text(
            widget.subscription
                ? t.video_discovery_subscribe
                : _selectedCandidates.length > 1
                // 选了多条时按钮上直接写清楚这一下会入队几条，
                // 免得用户以为只下最后点的那一条。
                ? t.batch_selected_count(n: _selectedCandidates.length)
                : t.dialog_done,
          ),
        ),
      ],
    );
  }

  bool _canSubmit(StrictVideoSubscriptionFilter? filter) =>
      !_loading &&
      !_submitting &&
      _selectedCandidates.isNotEmpty &&
      // 远端下载目标不需要本地 source：任务整条交给对端执行。
      (_source != null || _remote) &&
      (!widget.subscription || (filter != null && _strictConfirmed));

  /// 结果区的 sliver 序列（接在查询头部之后，同一个滚动视图）。有候选时顶部一条
  /// 统一的「BT / 磁力 · P2P」+「外部来源」标签：这里的候选全部来自第三方资源
  /// 索引站、全部走 BT，逐行重复同一对标签只是噪音（10-09 拍板：只在顶部放一条）。
  ///
  /// 空态 / 加载 / 失败用 [SliverFillRemaining]：头部没滚走时撑满剩余视口居中，
  /// 窗口太矮放不下时按自身高度排、随整页滚动，不会溢出裁掉「重试」。
  List<Widget> _buildResultSlivers() {
    Widget fill(Widget child) =>
        SliverFillRemaining(hasScrollBody: false, child: child);
    if (_loading) return <Widget>[fill(const FushiLoadingView())];
    final ProviderBatchResult<VideoResourceCandidate>? result = _result;
    if (result == null) {
      return <Widget>[
        fill(Center(child: Text(t.anime_download_search_start_hint))),
      ];
    }
    if (result.isTotalFailure) {
      return <Widget>[
        fill(
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(t.video_discovery_load_failed),
                FushiTextButton(
                  onPressed: () => unawaited(_search()),
                  child: Text(t.retry),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (result.hasNoActiveProvider) {
      return <Widget>[
        fill(
          _NoProviderEmptyState(
            key: const ValueKey<String>('video-resource-no-provider'),
            icon: Icons.travel_explore_outlined,
            title: t.video_resource_no_provider_title,
            hint: t.bt_site_empty_hint,
            selfScrolling: false,
            // 没有任何 BT 来源：直接去添加 BT 站，回来后重搜一次。
            action: FushiFilledButton.tonal(
              key: const ValueKey<String>('video-resource-open-bt-sites'),
              onPressed: () async {
                await pushBtSiteSettingsPage(context);
                if (mounted) unawaited(_search());
              },
              child: Text(t.bt_site_open_settings_action),
            ),
          ),
        ),
      ];
    }
    if (result.items.isEmpty) {
      return <Widget>[fill(Center(child: Text(t.video_discovery_empty)))];
    }
    const Widget sourceTagChips = DownloadSourceTags(
      key: ValueKey<String>('video-resource-source-tags'),
      method: DownloadTransferMethod.torrent,
    );
    const Widget sourceTags = SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.only(bottom: 6),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: sourceTagChips,
        ),
      ),
    );
    // 订阅模式下行单位 = 订阅生效单位（见 groupVideoSubscriptionCandidates 的
    // 文档）；下载模式默认「发布组 › 清晰度」版本卡（B2，参照
    // RSS-Subtitle-Manager）——挑组一次、组内挑集，几十条发布不再平铺；
    // 「版本卡 / 全部条目」分段随时切回平铺视图。
    final List<VideoSubscriptionCandidateGroup>? groups = widget.subscription
        ? groupVideoSubscriptionCandidates(result.items)
        : null;
    if (groups != null) {
      return <Widget>[sourceTags, _buildFlatResults(result, groups)];
    }
    // 来源标签与「版本卡 / 全部条目」分段同一行（左标签、右视图切换）。两种
    // 视图互斥、恒有一个生效，是单选分段而不是一枚开关 chip。
    final Widget tagsAndToggle = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        // 放得下就一行（左标签、右分段），手机竖屏放不下时分段折到下一行。
        child: OverflowBar(
          alignment: MainAxisAlignment.spaceBetween,
          spacing: FushiDesignTokens.of(context).spacing.gap,
          overflowSpacing: 6,
          children: <Widget>[
            sourceTagChips,
            KeyedSubtree(
              key: const ValueKey<String>('video-resource-flat-toggle'),
              child: adaptiveSegmentedButton<bool>(
                context: context,
                segments: <ButtonSegment<bool>>[
                  ButtonSegment<bool>(
                    value: false,
                    label: Text(t.resource_version_view_groups),
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    label: Text(t.resource_version_view_flat),
                  ),
                ],
                selected: <bool>{_flatResourceView},
                onSelectionChanged: (Set<bool> value) =>
                    setState(() => _flatResourceView = value.first),
              ),
            ),
          ],
        ),
      ),
    );
    return <Widget>[
      tagsAndToggle,
      if (_flatResourceView)
        _buildFlatResults(result, groups)
      else
        VideoResourceVersionGroupList(
          groups: buildVideoResourceVersionGroups(result.items),
          selectedIdentityKeys: _selectedIdentityKeys,
          multiSelect: !widget.subscription,
          onSelect: _select,
          onSetGroupSelected: _setGroupSelected,
          compact: !widget.pageMode,
          sliver: true,
        ),
    ];
  }

  /// 平铺列表（订阅模式恒用；下载模式经「全部条目」分段可切回）。返回 sliver。
  Widget _buildFlatResults(
    ProviderBatchResult<VideoResourceCandidate> result,
    List<VideoSubscriptionCandidateGroup>? groups,
  ) {
    return SliverList.builder(
      key: const ValueKey<String>('video-resource-results'),
      itemCount: groups?.length ?? result.items.length,
      itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int index) {
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
            metadata.add(
              episodes.length == 1
                  ? 'EP${episodes.first}'
                  : 'EP${episodes.first}-${episodes.last}',
            );
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
          selected: _isSelected(candidate),
          // 下载模式给勾选框（可多选整季分集）；订阅模式仍是单选，摆勾选框会
          // 让人以为能订阅一批。
          leading: widget.subscription
              ? FushiIcon(
                  candidate.trusted
                      ? Icons.verified_rounded
                      : Icons.cloud_download_outlined,
                )
              : FushiCheckbox(
                  value: _isSelected(candidate),
                  onChanged: (_) => _select(candidate),
                ),
          onTap: () => _select(candidate),
        );
      }),
    );
  }

  Widget _buildOptions(StrictVideoSubscriptionFilter? filter) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool showRunLocation =
        widget.subscription && widget.remoteTargets.isNotEmpty;
    final bool showDownloadLocation =
        !widget.subscription && widget.remoteDownloadTargets.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 落地选项一行 M3E 菜单 chip（取代三条 MD2 下拉字段）：图标标出这一项管
        // 什么，维度名进 tooltip / 语义；窄屏自动折行。chip 同高，不会再有
        // helperText 把并排两框挤歪（BUG-1765）的问题。
        Wrap(
          key: const ValueKey<String>('video-resource-options'),
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (showDownloadLocation)
              _ResourceMenuSelect<HostDownloadTarget?>(
                key: const ValueKey<String>('video-download-run-location'),
                title: t.download_target_label,
                icon: FushiIcons.devices,
                value: _remoteDownloadTarget,
                options: <HostDownloadTarget?>[
                  if (widget.sources.isNotEmpty) null,
                  ...widget.remoteDownloadTargets,
                ],
                labelOf: (HostDownloadTarget? target) => target == null
                    ? t.download_target_local
                    : t.download_target_remote(device: target.label),
                onSelected: _submitting
                    ? null
                    : (HostDownloadTarget? value) =>
                          setState(() => _remoteDownloadTarget = value),
              ),
            if (showRunLocation)
              _ResourceMenuSelect<HostSubscriptionTarget?>(
                key: const ValueKey<String>('video-subscription-run-location'),
                title: t.subscription_run_location,
                icon: FushiIcons.devices,
                value: _remoteTarget,
                options: <HostSubscriptionTarget?>[
                  if (widget.sources.isNotEmpty) null,
                  ...widget.remoteTargets,
                ],
                labelOf: (HostSubscriptionTarget? target) => target == null
                    ? t.subscription_run_local
                    : t.subscription_run_remote(device: target.label),
                onSelected: _submitting
                    ? null
                    : (HostSubscriptionTarget? value) =>
                          setState(() => _remoteTarget = value),
              ),
            // 交给 host 跑时落点是 host 的下载目录，本地来源不参与。
            if (!_remote)
              _ResourceMenuSelect<int?>(
                key: const ValueKey<String>('video-resource-source'),
                // 只给值时这个选择读起来像「搜哪个源」，用户据此以为选不了视频
                // 来源；它其实是下载落地的本地目录（BUG-1713）：文件夹图标 +
                // tooltip 写明维度与说明。
                title: t.video_download_target_source_title,
                tooltip: <String>[
                  t.video_download_target_source_title,
                  t.video_download_target_source_hint,
                ].join('\n'),
                icon: FushiIcons.folder,
                value: _sourceId,
                options: <int?>[
                  for (final MediaSourceRow source in widget.sources) source.id,
                ],
                labelOf: (int? id) =>
                    widget.sources
                        .firstWhereOrNull((MediaSourceRow s) => s.id == id)
                        ?.label ??
                    t.video_download_target_source_title,
                onSelected: _submitting
                    ? null
                    : (int? value) => setState(() => _sourceId = value),
              ),
            _ResourceMenuSelect<VideoDownloadSubtitlePolicy>(
              key: const ValueKey<String>('video-resource-subtitle-policy'),
              title: t.anime_download_include_subs,
              icon: FushiIcons.subtitles,
              value: _subtitlePolicy,
              options: VideoDownloadSubtitlePolicy.values,
              labelOf: (VideoDownloadSubtitlePolicy policy) => switch (policy) {
                VideoDownloadSubtitlePolicy.none => t.anime_download_no_subs,
                VideoDownloadSubtitlePolicy.bestEffort =>
                  t.anime_download_include_subs,
                VideoDownloadSubtitlePolicy.required =>
                  t.anime_download_require_subs,
              },
              onSelected: _submitting
                  ? null
                  : (VideoDownloadSubtitlePolicy value) =>
                        setState(() => _subtitlePolicy = value),
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
              // 整包与追更是两种订阅，确认行必须说清将要建的是哪一种：用户选了
              // 一个全集包却看到「新的单集会入队」，建出来的订阅永远不会命中，
              // 而界面只会说「还没有跟踪到任何发布」（BUG-2619）。
              title: _selectedIsBatch
                  ? t.download_subscription_choice_hint_batch(
                      group: filter.releaseGroup ?? filter.summaryParts.first,
                      resolution: filter.resolution ?? filter.summaryParts.last,
                    )
                  : t.download_subscription_choice_hint(
                      group: filter.releaseGroup ?? filter.summaryParts.first,
                      resolution: filter.resolution ?? filter.summaryParts.last,
                    ),
              value: _strictConfirmed,
              onChanged: _submitting
                  ? null
                  : (bool value) => setState(() => _strictConfirmed = value),
            ),
          // 起始集号只对「追更」有意义：整包一次下完，没有起点可言。
          if (_media?.mediaKind != VideoMetadataMediaKind.movie &&
              !_selectedIsBatch) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            FushiTextFieldControl(
              key: const ValueKey<String>('video-subscription-start-after'),
              controller: _startAfterController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: t.video_jimaku_episode,
                helperText: t.download_subscription_start_episode(
                  episode: _startAfterController.text.trim().isEmpty
                      ? _defaultStartEpisode
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
          openSubtitlesMovieHash: await computeOpenSubtitlesMovieHash(
            selectedPath,
          ),
          fileName: p.basename(selectedPath),
        );
      }
    }
    final ProviderBatchResult<VideoSubtitleCandidate> result = await widget
        .registry
        .search(
          VideoSubtitleSearchRequest(
            media: widget.item.reference,
            query: widget.item.reference.title,
            alternateTitles: <String>[
              if (widget.item.reference.originalTitle?.trim().isNotEmpty ==
                  true)
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
      final VideoSubtitleDownload download = await widget.registry.download(
        candidate,
      );
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

  /// 可选的落点：有可附加的下载任务（且宿主接了附加回调）时多一档「任务」。
  List<SubtitleInstallTarget> get _targetOptions => <SubtitleInstallTarget>[
    if (widget.attachableJobs.isNotEmpty && widget.onAttach != null)
      SubtitleInstallTarget.activeTask,
    SubtitleInstallTarget.existingVideo,
    SubtitleInstallTarget.directory,
  ];

  static String _targetLabel(SubtitleInstallTarget target) => switch (target) {
    SubtitleInstallTarget.activeTask => t.download_tasks_tab,
    SubtitleInstallTarget.existingVideo => t.anime_download_kind_video,
    SubtitleInstallTarget.directory => t.download_save_root_title,
  };

  String _jobLabel(String? jobId) {
    final VideoDownloadJobRow? job = widget.attachableJobs.firstWhereOrNull(
      (VideoDownloadJobRow row) => row.jobId == jobId,
    );
    return job == null ? t.download_tasks_tab : '${job.title} · ${job.stage}';
  }

  void _changeTarget(SubtitleInstallTarget value) {
    if (value == _target) return;
    setState(() {
      _target = value;
      _selectedPath = null;
      _selectedJobId = value == SubtitleInstallTarget.activeTask
          ? widget.attachableJobs.firstOrNull?.jobId
          : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = tokens.spacing.card + 4;
    // Builder：独立页的页头让位来自页面外壳下发的 MediaQuery，要在外壳之内读。
    final Widget content = Builder(
      builder: (BuildContext context) => Padding(
        // 独立页正文铺到页头底下：顶部留白由滚动区自己让（同资源搜索页）。
        padding: widget.pageMode
            ? EdgeInsets.fromLTRB(inset, 0, inset, inset)
            : EdgeInsets.all(inset),
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
            // 窄屏落点选择随结果同滚、宽屏固定（见 HeaderScrollSplit）；底部的
            // 保存行固定在滚动区外。
            Expanded(
              // 每拿到一批新结果重开一次错峰进场。
              child: FushiEntranceScope(
                replayKey: _result,
                child: HeaderScrollSplit(
                  scrollKey: const ValueKey<String>('video-subtitle-scroll'),
                  topInset: widget.pageMode
                      ? MediaQuery.paddingOf(context).top + inset
                      : 0,
                  header: _buildTargetHeader(tokens),
                  resultSlivers: _buildSubtitleResultSlivers(),
                ),
              ),
            ),
            SizedBox(height: tokens.spacing.gap),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                if (!widget.pageMode) ...<Widget>[
                  FushiTextButton(
                    onPressed: _installing
                        ? null
                        : () => Navigator.pop(context),
                    child: Text(t.dialog_cancel),
                  ),
                  SizedBox(width: tokens.spacing.gap),
                ],
                FushiFilledButton.icon(
                  key: const ValueKey<String>('video-subtitle-install'),
                  onPressed:
                      _selected == null || !_hasSelectedTarget || _installing
                      ? null
                      : () => unawaited(_install()),
                  icon: _installing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: FushiCircularProgressIndicator(strokeWidth: 2),
                        )
                      : const FushiIcon(Icons.subtitles_outlined),
                  label: Text(t.dialog_save),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (widget.pageMode) {
      // 与资源搜索 / 订阅页同一外壳：二级页页头大字，随结果滚动收缩。
      return _VideoResourceSearchPageShell(
        title: t.video_discovery_subtitle_search,
        child: SafeArea(top: false, child: content),
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

  /// 落点选择：一行 M3E 菜单 chip（取代两条 MD2 下拉字段，与资源搜索页的落地
  /// 选项同一形态）——图标标出这一项管什么，维度名进 tooltip / 语义；选视频 /
  /// 目录的落点后面跟「选择」按钮。窄屏自动折行。
  Widget _buildTargetHeader(FushiDesignTokens tokens) {
    final bool activeTask = _target == SubtitleInstallTarget.activeTask;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          key: const ValueKey<String>('video-subtitle-target-row'),
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            _ResourceMenuSelect<SubtitleInstallTarget>(
              key: const ValueKey<String>('video-subtitle-target'),
              title: t.video_subtitle_install_target,
              icon: FushiIcons.folder,
              value: _target,
              options: _targetOptions,
              labelOf: _targetLabel,
              onSelected: _installing ? null : _changeTarget,
            ),
            if (activeTask)
              _ResourceMenuSelect<String?>(
                key: const ValueKey<String>('video-subtitle-active-task'),
                title: t.download_tasks_tab,
                icon: FushiIcons.downloading,
                value: _selectedJobId,
                options: <String?>[
                  for (final VideoDownloadJobRow job in widget.attachableJobs)
                    job.jobId,
                ],
                labelOf: _jobLabel,
                onSelected: _installing
                    ? null
                    : (String? value) => setState(() => _selectedJobId = value),
              )
            else
              FushiOutlinedButton.icon(
                key: const ValueKey<String>('video-subtitle-pick-target'),
                onPressed: _installing ? null : () => unawaited(_pickTarget()),
                icon: const FushiIcon(Icons.folder_open_outlined),
                label: Text(
                  _selectedPath == null
                      ? t.dialog_select
                      : p.basename(_selectedPath!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        SizedBox(height: tokens.spacing.gap),
        if (_result?.isPartial == true) ...<Widget>[
          _ProviderWarning(message: t.video_discovery_provider_warning),
          SizedBox(height: tokens.spacing.gap),
        ],
      ],
    );
  }

  /// 结果区的 sliver（排在 [HeaderScrollSplit] 的结果滚动视图里）。空态 / 加载 /
  /// 失败撑满剩余视口居中（[SliverFillRemaining]），窗口太矮时随整页滚动。
  List<Widget> _buildSubtitleResultSlivers() {
    Widget fill(Widget child) =>
        SliverFillRemaining(hasScrollBody: false, child: child);
    if (_loading) return <Widget>[fill(const FushiLoadingView())];
    final ProviderBatchResult<VideoSubtitleCandidate>? result = _result;
    if (result == null || result.isTotalFailure) {
      return <Widget>[
        fill(
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(t.video_discovery_load_failed),
                FushiTextButton(
                  onPressed: () => unawaited(_search()),
                  child: Text(t.retry),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (result.hasNoActiveProvider) {
      return <Widget>[
        fill(
          _NoProviderEmptyState(
            key: const ValueKey<String>('video-subtitle-no-provider'),
            icon: Icons.subtitles_off_outlined,
            title: t.video_subtitle_no_provider_title,
            hint: t.video_subtitle_no_provider_hint,
            selfScrolling: false,
          ),
        ),
      ];
    }
    if (result.items.isEmpty) {
      return <Widget>[fill(Center(child: Text(t.video_discovery_empty)))];
    }
    return <Widget>[
      SliverList.builder(
        key: const ValueKey<String>('video-subtitle-results'),
        itemCount: result.items.length,
        itemBuilder: fushiStaggeredItemBuilder((
          BuildContext context,
          int index,
        ) {
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
            leading: const FushiIcon(Icons.subtitles_outlined),
            onTap: () => setState(() => _selected = candidate),
          );
        }),
      ),
    ];
  }
}

/// 资源源的用户可见名：回执自带名字（用户 BT 站的名字 / 主机名，由注册表从
/// provider 填入）就用它；否则 Torznab 叫 Torznab，其余按 id。
String videoResourceSourceDisplayName(
  String providerId, {
  String? displayName,
}) {
  final String name = displayName?.trim() ?? '';
  if (name.isNotEmpty) return name;
  return providerId == 'torznab' ? 'Torznab' : providerId;
}

/// 失败性质的短说明（不带 URL / 响应体，[ExternalProviderFailure] 本身已脱敏）。
String videoResourceFailureReason(ExternalProviderFailure failure) {
  final String reason = switch (failure.kind) {
    ExternalProviderFailureKind.timeout => t.video_resource_failure_timeout,
    ExternalProviderFailureKind.network => t.video_resource_failure_network,
    ExternalProviderFailureKind.rateLimited ||
    ExternalProviderFailureKind.quotaExceeded =>
      t.video_resource_failure_rate_limited,
    _ => t.video_resource_failure_other,
  };
  final int? status = failure.statusCode;
  return status == null ? reason : '$reason · HTTP $status';
}

/// 一个资源源这次搜索的一行状态：「Nyaa：75 条（Frieren 75 · 葬送のフリーレン 0）」
/// / 「Nyaa：失败（超时）」/「apibay：未参与」。成功但 0 条同样成行（BUG-2794）。
String videoResourceSourceStatusText(VideoResourceSourceReport report) {
  final String name = videoResourceSourceDisplayName(
    report.providerId,
    displayName: report.displayName,
  );
  if (report.failed) {
    return t.video_resource_source_failed(
      name: name,
      reason: videoResourceFailureReason(report.failures.first),
    );
  }
  if (report.skipped) return t.video_resource_source_skipped(name: name);
  final String queries = report.queries
      .map(
        (VideoResourceQueryReport query) => query.failure == null
            ? '${query.query} ${query.itemCount}'
            : t.video_resource_query_failed(query: query.query),
      )
      .join(' · ');
  return t.video_resource_source_result(
    name: name,
    n: report.itemCount,
    queries: queries,
  );
}

/// 资源搜索结果上方的逐源状态列表。
class VideoResourceSourceStatusList extends StatelessWidget {
  const VideoResourceSourceStatusList({required this.reports, super.key});

  final List<VideoResourceSourceReport> reports;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 每个来源一枚设计系统状态标签（MD3 色调容器 / Apple 空心胶囊），不再是
    // 「裸图标 + 小字」的一列：成功 / 跳过中性、失败错误色。
    return Padding(
      key: const ValueKey<String>('video-resource-source-status'),
      padding: EdgeInsets.only(bottom: tokens.spacing.gap / 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: <Widget>[
          for (final VideoResourceSourceReport report in reports)
            FushiTag(
              key: ValueKey<String>(
                'video-resource-source-status-${report.providerId}',
              ),
              text: videoResourceSourceStatusText(report),
              icon: report.failed
                  ? FushiIcons.error
                  : report.skipped
                  ? FushiIcons.block
                  : FushiIcons.success,
              iconSize: 14,
              tone: report.failed ? FushiTagTone.error : FushiTagTone.neutral,
              dense: true,
            ),
        ],
      ),
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
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: FushiInlineNotice(
        severity: error
            ? FushiNoticeSeverity.error
            : FushiNoticeSeverity.warning,
        message: message,
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
    this.selfScrolling = true,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String hint;

  /// 空态下方的动作（如「前往 BT 站设置」）。
  final Widget? action;

  /// false = 已在外层滚动视图里（资源搜索的 [SliverFillRemaining]）：只居中，
  /// 不再自带滚动，也不用 LayoutBuilder（sliver 要按固有高度量它）。
  final bool selfScrolling;

  @override
  Widget build(BuildContext context) {
    // 空态走共享占位（M3E 色块图标 / Apple ContentUnavailableView 观感）。
    // 两处调用都在结果区的 `Expanded` 里，高度由窗口与上方查询 / 筛选行瓜分；
    // 窄窗口下 72px 色块 + 标题 + 说明放不下时必须能滚，不能溢出裁字。放得下
    // 时撑满结果区居中，观感不变。
    final Widget placeholder = FushiPlaceholderMessage(
      icon: icon,
      message: title,
      detail: hint,
      action: action,
    );
    if (!selfScrolling) return Center(child: placeholder);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: placeholder),
          ),
        );
      },
    );
  }
}

String _compactDate(DateTime value) {
  final DateTime local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

Set<String> get videoDiscoveryPickerExtensions =>
    kVideoExtensions.map((String value) => value.substring(1)).toSet();

/// 资源搜索页的单选菜单：M3E 筛选 chip（与库页筛选同一枚 [LibraryFilterChip]）
/// + 共享弹出菜单（[FushiPopupMenuButton] / [FushiPopupMenuItem]，选中项常驻
/// 圆角高亮）；Apple 设计下 chip 与菜单由同一组件换成玻璃弹出按钮。取代旧的
/// MD2 形态 `DropdownButtonFormField` 填充字段。
///
/// chip 只写当前值；这一项管什么由前置 [icon] 与 tooltip / 语义里的 [title]
/// 说明。`null` 也可以是一个合法选项（「本机」），菜单值统一包一层
/// [_MenuChoice]：[PopupMenuButton] 把 null 结果当成「取消」。
/// [onSelected] 为 null = 禁用（提交中）。
class _ResourceMenuSelect<T> extends StatelessWidget {
  const _ResourceMenuSelect({
    required this.title,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onSelected,
    this.icon,
    this.tooltip,
    super.key,
  });

  final String title;
  final T value;
  final List<T> options;
  final String Function(T value) labelOf;
  final ValueChanged<T>? onSelected;
  final IconData? icon;

  /// null = [title]。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<T>? select = onSelected;
    final bool enabled = select != null;
    final IconData? leading = icon;
    final Widget menu = FushiPopupMenuButton<_MenuChoice<T>>(
      tooltip: tooltip ?? title,
      enabled: enabled,
      initialValue: _MenuChoice<T>(value),
      onSelected: (_MenuChoice<T> choice) => select?.call(choice.value),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<_MenuChoice<T>>>[
        for (final T option in options)
          FushiPopupMenuItem<_MenuChoice<T>>(
            label: labelOf(option),
            value: _MenuChoice<T>(option),
            selected: option == value,
          ),
      ],
      child: LibraryFilterChip(label: labelOf(value), active: false),
    );
    return Semantics(
      label: title,
      container: true,
      child: AnimatedOpacity(
        // 禁用态：M3 禁用不透明度 0.38，形状不变，读得出当前值、一眼知道点不动。
        opacity: enabled ? 1 : 0.38,
        duration: fushiMotionDuration(context, FushiMotion.short),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (leading != null) ...<Widget>[
              FushiIcon(
                leading,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
            ],
            menu,
          ],
        ),
      ),
    );
  }
}

/// 表单行里的菜单选择字段：外观就是 [FushiTextFieldControl]（只读、带维度
/// 标题与下拉箭头），点按 / 回车弹出与 [_ResourceMenuSelect] 同一套菜单。
///
/// 为什么不是 `FushiDropdownButtonFormField`：它和文本框是两套组件，Apple
/// 形态下标题字号与字段高度都不同（同排文本框底边、基线对不齐）；它又是
/// `initialValue` 型，Apple 形态的 `FormField` 不跟随新的初始值，程序改值后
/// 显示停在旧值。这里显示文本每次构建都由 [value] 推出（受控）。
class _ResourceMenuField<T> extends StatefulWidget {
  const _ResourceMenuField({
    required this.title,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onSelected,
    super.key,
  });

  final String title;
  final T value;
  final List<T> options;
  final String Function(T value) labelOf;

  /// null = 禁用（提交中）。
  final ValueChanged<T>? onSelected;

  @override
  State<_ResourceMenuField<T>> createState() => _ResourceMenuFieldState<T>();
}

class _ResourceMenuFieldState<T> extends State<_ResourceMenuField<T>> {
  late final TextEditingController _display = TextEditingController(
    text: widget.labelOf(widget.value),
  );

  @override
  void didUpdateWidget(covariant _ResourceMenuField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String label = widget.labelOf(widget.value);
    if (_display.text != label) _display.text = label;
  }

  @override
  void dispose() {
    _display.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ValueChanged<T>? select = widget.onSelected;
    final bool enabled = select != null;
    return Semantics(
      label: widget.title,
      value: widget.labelOf(widget.value),
      container: true,
      child: FushiPopupMenuButton<_MenuChoice<T>>(
        tooltip: widget.title,
        enabled: enabled,
        // 状态层与填充式字段同一圆角（fushiMd3FieldDecoration 的 12）。
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        initialValue: _MenuChoice<T>(widget.value),
        onSelected: (_MenuChoice<T> choice) => select?.call(choice.value),
        itemBuilder: (BuildContext context) => <PopupMenuEntry<_MenuChoice<T>>>[
          for (final T option in widget.options)
            FushiPopupMenuItem<_MenuChoice<T>>(
              label: widget.labelOf(option),
              value: _MenuChoice<T>(option),
              selected: option == widget.value,
            ),
        ],
        // 字段只负责画：焦点 / 点按都归外层菜单按钮（聚焦后回车即弹菜单）。
        child: ExcludeSemantics(
          child: IgnorePointer(
            child: FushiTextFieldControl(
              controller: _display,
              readOnly: true,
              canRequestFocus: false,
              enabled: enabled,
              enableInteractiveSelection: false,
              decoration: InputDecoration(
                // 单行：Apple 形态的字段标题排在框上方、默认会折行，长标题
                // （「Resource identity source」）折成多行就把整格撑高、与同排
                // 文本框错位；全称在 tooltip / 语义里。
                label: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // 下拉箭头不参与字段高度（heightFactor 0，绘制仍以行中线居中）：
                // Apple 形态的输入行按文字行高排，桌面字号下 20dp 的箭头比文字行
                // 高，会把这一格撑高 2dp、与同排文本框顶边错开；MD3 的尾部图标
                // 槽本来就有 48dp 最小高度，不受影响。
                suffixIcon: const Align(
                  heightFactor: 0,
                  child: FushiIcon(Icons.arrow_drop_down_rounded),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [_ResourceMenuSelect] 的菜单值盒子（让 null 也能被选中）。
@immutable
class _MenuChoice<T> {
  const _MenuChoice(this.value);

  final T value;

  @override
  bool operator ==(Object other) =>
      other is _MenuChoice<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// 钉进页头大字下一行的查询 / 筛选条，外加它下沿一道柔和的渐隐边。
///
/// 页头底板（[FushiPageScaffold.masthead] 的 90% 页面底色 + 模糊）在页头下沿是
/// 一道硬边：结果行从底下滑过时，紧贴下沿的那半截字直接撞上一条直线。这里在
/// 底板下沿外再垫一段从底板同色渐到透明的薄雾，结果行先淡出再没入底板。透明度
/// 跟底板同一条进度（同一滚动偏移 → [fushiMastheadProgressOf]，减弱动态 / 墨水
/// 屏下同样只取两档），静止在顶部时不画；不吃指针。
class _PinnedQueryEdge extends StatelessWidget {
  const _PinnedQueryEdge({required this.offset, required this.child});

  /// 结果滚动区的竖向偏移。
  final ValueNotifier<double> offset;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 页头这一行左右各留 spacing.page、下面留 spacing.gap（见
    // FushiMastheadHeader）：渐隐边要铺满整宽、接在底板下沿之外。
    final double side = tokens.spacing.page;
    final double below = tokens.spacing.gap;
    final double extent = tokens.spacing.gap * 2;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        child,
        Positioned(
          left: -side,
          right: -side,
          bottom: -(below + extent),
          height: extent,
          child: IgnorePointer(
            child: ValueListenableBuilder<bool>(
              valueListenable: SystemTransparency.reduceTransparency,
              builder: (BuildContext context, bool reduce, Widget? _) =>
                  ValueListenableBuilder<double>(
                    valueListenable: offset,
                    builder: (BuildContext context, double value, Widget? _) {
                      final double progress = fushiMastheadProgressOf(
                        compact: fushiMastheadCompact(context),
                        motionEnabled: fushiExpressiveMotionEnabled(context),
                        offset: value.clamp(0.0, kFushiMastheadTrackedOffset),
                      );
                      if (progress <= 0) return const SizedBox.shrink();
                      // 与底板同一填充透明度：能模糊时 90%，减弱透明度 / 高对比
                      // 时实色。
                      final bool blur =
                          !reduce &&
                          !(MediaQuery.maybeHighContrastOf(context) ?? false);
                      final Color page = fushiMastheadPageColor(context);
                      return DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: <Color>[
                              page.withValues(
                                alpha: (blur ? 0.9 : 1) * progress,
                              ),
                              page.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
            ),
          ),
        ),
      ],
    );
  }
}
