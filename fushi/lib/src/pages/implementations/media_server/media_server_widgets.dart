import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/utils/cover_image.dart'
    show kLocalCoverDecodePixelWidth;
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show
        FushiFloatingChromeController,
        FushiFloatingChromeInset,
        FushiFloatingChromeInsetPadding,
        FushiFloatingChromeOverlay,
        FushiFloatingChromeScope;
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 横滚行里一张竖卡的宽度（2:3 海报）。与视频首页横滚行同量级。
const double kMediaServerRowCardWidth = 150;

/// 媒体库卡（16:9）的基准宽度：首页库网格的最大列宽按它推，库卡单测也按它给槽。
const double kMediaServerLibraryCardWidth = 220;

/// 媒体库卡外层卡与封面之间的内缩：20（卡）- 8 = 12（封面），同心圆角。
const double kMediaServerLibraryCardInset = 8;

/// 服务器条目封面（缩放到 [kLocalCoverDecodePixelWidth] 以内解码）。fetcher 就是
/// 浏览器本身（[MediaServerBrowser] implements `RemoteCoverFetcher`）；无图返回 null，
/// 页面画占位图，**不**拿一个必 404 的地址去请求。
ImageProvider? mediaServerCoverImage(
  MediaServerBrowser browser,
  MediaServerItem item, {
  MediaServerImageKind kind = MediaServerImageKind.primary,
}) {
  final String? url = browser.coverUrl(item, kind: kind);
  if (url == null || url.isEmpty) return null;
  return ResizeImage(
    RemoteCoverImage(url, browser, cacheKey: '${item.id}:${kind.name}'),
    width: kLocalCoverDecodePixelWidth,
    allowUpscaling: false,
  );
}

/// 详情页 hero 用的大图（横版背景 / 标题 logo）：请求宽度与解码宽度都比网格卡大
/// ——背景要铺满 1600+ 逻辑像素宽的 hero，720 像素放大后一片糊；logo 在 hero 里
/// 最大 460×110 逻辑像素 × dpr。缓存键带上请求宽度，与网格卡的 720 版本互不串。
/// 其它 [kind] 退回 [mediaServerCoverImage] 的常规尺寸。无图返回 null。
ImageProvider? mediaServerHeroImage(
  MediaServerBrowser browser,
  MediaServerItem item, {
  required MediaServerImageKind kind,
}) {
  final (int requestWidth, int decodeWidth) = switch (kind) {
    MediaServerImageKind.backdrop => (1920, 2560),
    MediaServerImageKind.logo => (800, 800),
    MediaServerImageKind.primary || MediaServerImageKind.thumb => (
      kMediaServerCoverMaxWidth,
      kLocalCoverDecodePixelWidth,
    ),
  };
  final String? url = browser.coverUrl(
    item,
    kind: kind,
    maxWidth: requestWidth,
  );
  if (url == null || url.isEmpty) return null;
  return ResizeImage(
    RemoteCoverImage(
      url,
      browser,
      cacheKey: '${item.id}:${kind.name}:$requestWidth',
    ),
    width: decodeWidth,
    allowUpscaling: false,
  );
}

ImageProvider? mediaServerLibraryCoverImage(
  MediaServerBrowser browser,
  MediaServerLibrary library,
) {
  final String? url = browser.libraryCoverUrl(library);
  if (url == null || url.isEmpty) return null;
  return ResizeImage(
    RemoteCoverImage(url, browser, cacheKey: 'library:${library.id}'),
    width: kLocalCoverDecodePixelWidth,
    allowUpscaling: false,
  );
}

/// `1:32:05` / `24:10` 形态的时长；null / 0 返回空串。
String formatMediaServerDuration(int? durationMs) {
  if (durationMs == null || durationMs <= 0) return '';
  final Duration d = Duration(milliseconds: durationMs);
  final int hours = d.inHours;
  final int minutes = d.inMinutes.remainder(60);
  final int seconds = d.inSeconds.remainder(60);
  final String mm = minutes.toString().padLeft(2, '0');
  final String ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$minutes:$ss';
}

/// 服务器端观看进度（0..1）；无断点 / 无时长返回 null。
double? mediaServerProgress(MediaServerItem item) {
  final int? duration = item.durationMs;
  if (item.positionMs <= 0 || duration == null || duration <= 0) return null;
  return (item.positionMs / duration).clamp(0.0, 1.0);
}

/// 卡片 / 列表行的第二行元数据：年份 · 类型 / 季集号 · 时长。
String mediaServerItemMetadata(MediaServerItem item) {
  final List<String> parts = <String>[];
  switch (item.type) {
    case MediaServerItemType.movie:
      if (item.productionYear != null) parts.add('${item.productionYear}');
      parts.add(t.collection_relation_movie);
    case MediaServerItemType.series:
      if (item.productionYear != null) parts.add('${item.productionYear}');
      parts.add(t.series);
    case MediaServerItemType.season:
      if (item.seasonNumber != null) {
        parts.add(t.collection_group_season(n: item.seasonNumber!));
      }
    case MediaServerItemType.episode:
      final String code = item.episodeCode;
      if (code.isNotEmpty) parts.add(code);
      final String duration = formatMediaServerDuration(item.durationMs);
      if (duration.isNotEmpty) parts.add(duration);
    case MediaServerItemType.folder:
      parts.add(t.media_server_item_folder);
      if (item.childCount != null) parts.add('${item.childCount}');
  }
  return parts.join(' · ');
}

/// 封面卡标题块的上下内边距（[_MediaServerCardCaption]）。
const double _kCaptionTop = 8;
const double _kCaptionBottom = 4;

/// 卡片文字块高度（一行名称 + 一行元数据 + 上下 padding）。行高 = 封面高 + 它。
/// 名称行按封面卡标题样式（[shelfCardTitleStyle]）量，与卡内实际字阶同源。
double mediaServerCardTextBlock(BuildContext context) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final double titleLine = textLineHeight(
    context,
    shelfCardTitleStyle(context),
  );
  final double metaLine = textLineHeight(context, tokens.type.metadata);
  return titleLine +
      metaLine +
      _kCaptionTop +
      _kCaptionBottom +
      kTextBlockSlack;
}

/// 横滚行竖卡的整卡高度。
double mediaServerRowCardHeight(BuildContext context) =>
    kMediaServerRowCardWidth * 3 / 2 + mediaServerCardTextBlock(context);

/// 悬停抬升（[FushiHoverLift]）放大后上下各多出的高度：横滚行的列表视口按它
/// 上下留白，抬升的卡与加深的投影不被行的裁切边吃掉。
double mediaServerLiftHeadroom(double cardHeight) =>
    cardHeight * (kFushiHoverLiftScale - 1) / 2 + 4;

/// 服务器的类型（只为图标 / 类型名区分；契约本身不分类型）。Plex 的 serverId
/// 以 `plex:` 起头；Jellyfin 实现一套双吃 Jellyfin / Emby / 飞牛，统归一类。
enum MediaServerFamily { jellyfin, plex }

MediaServerFamily mediaServerFamilyOf(String serverId) =>
    serverId.startsWith('plex:')
    ? MediaServerFamily.plex
    : MediaServerFamily.jellyfin;

/// 类型图标：Jellyfin 系是「服务器机柜」，Plex 是「播放圆钮」（品牌中性的单色
/// 图标，不画品牌色块）。
IconData mediaServerFamilyIcon(MediaServerFamily family) => switch (family) {
  MediaServerFamily.jellyfin => FushiIcons.server,
  MediaServerFamily.plex => FushiIcons.playCircle,
};

/// 类型名（产品名不翻译）。
String mediaServerFamilyLabel(MediaServerFamily family) => switch (family) {
  MediaServerFamily.jellyfin => 'Jellyfin · Emby',
  MediaServerFamily.plex => 'Plex',
};

/// 服务器首页页头上的连接状态。
enum MediaServerConnectionStatus { connecting, online, offline }

/// 服务器名前的连接状态点：连接中灰、在线绿、失败红（MD3 harmonize 的状态色 /
/// Apple 系统绿红；墨水屏退成前景色实心 / 空心圈，靠形状区分）。悬停 / 长按
/// 给文字说明。
class MediaServerStatusDot extends StatelessWidget {
  const MediaServerStatusDot({required this.status, super.key});

  final MediaServerConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final Color color = switch (status) {
      MediaServerConnectionStatus.online => fushiStatusColor(
        context,
        FushiStatusTone.success,
      ),
      MediaServerConnectionStatus.offline => fushiStatusColor(
        context,
        FushiStatusTone.error,
      ),
      MediaServerConnectionStatus.connecting =>
        isGlassDesign(context)
            ? appleColorsOf(context).tertiaryLabel
            : tokens.surfaces.onVariant,
    };
    final String label = switch (status) {
      MediaServerConnectionStatus.online => t.sync_client_connected,
      MediaServerConnectionStatus.offline => t.media_server_items_load_failed,
      MediaServerConnectionStatus.connecting =>
        t.game_endpoint_phase_connecting,
    };
    final bool hollow = eink && status != MediaServerConnectionStatus.online;
    // 颜色过渡走 effects 弹簧（不过冲）；在线时点略放大，连接中 → 在线有一下
    // 「亮起」的落位感（尺寸走 spatial 弹簧）。墨水屏 / 减弱动态效果下瞬切。
    final FushiMotionScheme motion = context.fushiMotion;
    final double size = status == MediaServerConnectionStatus.online ? 10 : 8;
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: SizedBox.square(
          dimension: 10,
          child: Center(
            child: AnimatedContainer(
              key: const ValueKey<String>('media-server-status-dot'),
              duration: motion.spatialFast.duration,
              curve: motion.spatialFast.curve,
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hollow ? null : color,
                border: hollow ? Border.all(color: color, width: 1.5) : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 封面卡下方的两行文字：名称（封面卡标题样式）+ 元数据。左对齐、单行省略；
/// 高度与 [mediaServerCardTextBlock] 同口径。
class _MediaServerCardCaption extends StatelessWidget {
  const _MediaServerCardCaption({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, _kCaptionTop, 2, _kCaptionBottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: shelfCardTitleStyle(context),
          ),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.metadata,
          ),
        ],
      ),
    );
  }
}

/// 一张服务器条目卡：「封面即卡片」（与书架 / 视频库同一套 [ShelfCoverFrame]：
/// MD3 12 圆角、悬停柔和投影；Apple 10 圆角 + 0.5px 内描边 + 柔和投影）+ 名称 +
/// 元数据。角标：剧的未看集数（右上）、已看勾（右上）、服务器端断点进度胶囊
/// （封面底边）。悬停抬升 / 按压下沉来自 [FushiHoverLift] 与卡片自带的按压缩放。
class MediaServerItemCard extends StatelessWidget {
  const MediaServerItemCard({
    required this.browser,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.onInfo,
    this.focusId,
    super.key,
  });

  final MediaServerBrowser browser;
  final MediaServerItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 封面左上角「详情」角标的回调。2026-10 体验优化：电影短按直接播放、
  /// 详情只能长按 / 右键进，触屏用户发现不了；给电影 / 剧一个可见入口。
  /// 只对 movie / series 生效，其余类型不画角标。
  final VoidCallback? onInfo;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? image = mediaServerCoverImage(browser, item);
    final double? progress = mediaServerProgress(item);
    final int unplayed = item.unplayedChildCount ?? 0;
    final Widget cover = Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (image == null)
          ShelfCoverPlaceholder(icon: _placeholderIcon(item.type))
        else
          PortraitCoverImage(
            image: image,
            errorBuilder: (_) =>
                const ShelfCoverPlaceholder(icon: FushiIcons.brokenImage),
          ),
        if (item.isContainer && unplayed > 0)
          Positioned(top: 6, right: 6, child: CoverBadge(label: '$unplayed')),
        if (onInfo != null && _hasDetail(item.type))
          Positioned(
            top: 0,
            left: 0,
            child: MediaServerInfoCorner(onPressed: onInfo!),
          ),
        if (item.isPlayable && item.played)
          const Positioned(
            top: 6,
            right: 6,
            child: CoverBadge(icon: FushiIcons.check),
          ),
        if (progress != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: CoverProgressStrip(value: progress),
          ),
      ],
    );
    final String title =
        item.type == MediaServerItemType.episode &&
            (item.seriesName?.isNotEmpty ?? false)
        ? item.seriesName!
        : item.name;
    final String subtitle = item.type == MediaServerItemType.episode
        ? '${item.episodeCode} ${item.name}'.trim()
        : mediaServerItemMetadata(item);
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => shelfCoverCard(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        focusId: focusId,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ShelfCoverFrame(child: cover),
            ),
            _MediaServerCardCaption(title: title, subtitle: subtitle),
          ],
        ),
      ),
    );
  }

  static bool _hasDetail(MediaServerItemType type) =>
      type == MediaServerItemType.movie || type == MediaServerItemType.series;

  static IconData _placeholderIcon(MediaServerItemType type) => switch (type) {
    MediaServerItemType.movie => FushiIcons.video,
    MediaServerItemType.series ||
    MediaServerItemType.season ||
    MediaServerItemType.episode => FushiIcons.tv,
    MediaServerItemType.folder => FushiIcons.folder,
  };
}

/// 封面左上角的「详情」角标：视觉是常规 [CoverBadge]，命中区放大到 44×44
/// （2026-10 体验优化，触屏可点）。不进焦点遍历——键盘 / 手柄已有右键 /
/// 长按入口，多一个焦点停靠点只会拖慢方向键穿行。
class MediaServerInfoCorner extends StatelessWidget {
  const MediaServerInfoCorner({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: t.video_hero_detail_view,
      child: Semantics(
        button: true,
        label: t.video_hero_detail_view,
        child: GestureDetector(
          key: const ValueKey<String>('media-server-card-info'),
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: const SizedBox(
            width: 44,
            height: 44,
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.only(top: 6, left: 6),
                child: CoverBadge(icon: FushiIcons.info),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 库封面拼贴最多取几张条目海报（220 宽的 16:9 槽里三张 2:3 海报各裁掉约一成，
/// 再多就只剩细条）。
const int kMediaServerLibraryCollageCount = 3;

/// 「继续观看」横卡的宽度（16:9）。比媒体库横卡再宽一点：这一行是首页最常点
/// 的一行，缩略图要看得清是哪一集的画面。
const double kMediaServerContinueCardWidth = 260;

/// 「继续观看」横卡整卡高度：16:9 缩略图 + 两行文字。
double mediaServerContinueCardHeight(BuildContext context) =>
    kMediaServerContinueCardWidth * 9 / 16 + mediaServerCardTextBlock(context);

/// 「继续观看」横卡的候选图，按优先级排好；前一张取不回来（兼容层会报 tag 却
/// 404，BUG-2602）就换下一张，见 [MediaServerFallbackImage]。
///
/// - 集：自身 Thumb → 自身 Primary（Jellyfin / Emby 的集主图就是一帧 16:9 截图）
///   → 剧的 Thumb → 剧的 Backdrop。
/// - 电影：Thumb → Backdrop → Primary（2:3 海报，横槽里由
///   [PortraitCoverImage] 模糊垫底后完整显示）。
///
/// 上级图借 [MediaServerItem.parentThumbItemId] / `parentBackdropItemId`：把那个
/// id 包成一个只带对应图片旗子的条目交给 [MediaServerBrowser.coverUrl]，不用给
/// 契约再开一个「按 id 取图」的口子，缓存键也自然按剧共享。
List<ImageProvider> mediaServerContinueImages(
  MediaServerBrowser browser,
  MediaServerItem item,
) {
  final List<ImageProvider> images = <ImageProvider>[];
  void add(MediaServerItem source, MediaServerImageKind kind) {
    final ImageProvider? image = mediaServerCoverImage(
      browser,
      source,
      kind: kind,
    );
    if (image != null) images.add(image);
  }

  if (item.type == MediaServerItemType.episode) {
    add(item, MediaServerImageKind.thumb);
    add(item, MediaServerImageKind.primary);
    final String? parentThumb = item.parentThumbItemId;
    if (parentThumb != null && parentThumb.isNotEmpty) {
      add(
        MediaServerItem(
          id: parentThumb,
          name: '',
          type: MediaServerItemType.series,
          hasThumb: true,
        ),
        MediaServerImageKind.thumb,
      );
    }
    final String? parentBackdrop = item.parentBackdropItemId;
    if (parentBackdrop != null && parentBackdrop.isNotEmpty) {
      add(
        MediaServerItem(
          id: parentBackdrop,
          name: '',
          type: MediaServerItemType.series,
          hasBackdrop: true,
        ),
        MediaServerImageKind.backdrop,
      );
    }
  } else {
    add(item, MediaServerImageKind.thumb);
    add(item, MediaServerImageKind.backdrop);
    add(item, MediaServerImageKind.primary);
  }
  return images;
}

/// 「继续观看」横卡的角标：有断点且知道时长 →「剩余 N 分钟」（不足一分钟退回
/// 「已看至 mm:ss」）；有断点不知时长 →「已看至 mm:ss」；没断点的集（NextUp
/// 补进来的下一集）→「下一集」；其余 null（不画角标）。
String? mediaServerContinueBadge(MediaServerItem item) {
  final int position = item.positionMs;
  final int? duration = item.durationMs;
  if (position > 0) {
    if (duration != null && duration - position >= 60000) {
      return t.video_home_remaining_minutes(
        minutes: ((duration - position) / 60000).ceil(),
      );
    }
    return t.video_watched_up_to(time: formatMediaServerDuration(position));
  }
  if (item.type == MediaServerItemType.episode) return t.video_next_episode;
  return null;
}

/// 「继续观看」横卡的第二行：集 =「S01E02 集名」；电影 =「12:34 / 1:32:05」
/// （断点 / 总长，缺一个就只写另一个，都缺用常规元数据）。
String mediaServerContinueSubtitle(MediaServerItem item) {
  if (item.type == MediaServerItemType.episode) {
    return '${item.episodeCode} ${item.name}'.trim();
  }
  final String position = formatMediaServerDuration(item.positionMs);
  final String duration = formatMediaServerDuration(item.durationMs);
  if (position.isNotEmpty && duration.isNotEmpty) {
    return '$position / $duration';
  }
  if (position.isNotEmpty) return position;
  if (duration.isNotEmpty) return duration;
  return mediaServerItemMetadata(item);
}

/// 「继续观看」横卡：16:9 缩略图（候选图逐张回落，封面即卡片）+ 剧名 / 片名 +
/// 第二行。缩略图底边是服务器端进度条（Apple 是内缩胶囊），右下角标写明还剩
/// 多少或看到哪。
///
/// 视频本身是横屏的；继续观看要让人一眼认出「停在哪一集、看到哪」，所以这一行
/// 不用 2:3 海报竖卡——竖卡只认得出是哪部剧，进度只有一条 3px 细线。
class MediaServerContinueCard extends StatelessWidget {
  const MediaServerContinueCard({
    required this.browser,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.focusId,
    super.key,
  });

  final MediaServerBrowser browser;
  final MediaServerItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final double? progress = mediaServerProgress(item);
    final String? badge = mediaServerContinueBadge(item);
    final bool isEpisode = item.type == MediaServerItemType.episode;
    final String title = isEpisode && (item.seriesName?.isNotEmpty ?? false)
        ? item.seriesName!
        : item.name;
    final bool apple = isGlassDesign(context);
    // Apple 进度是内缩 8 的胶囊（底边留 8 + 4 高），角标要让到它上面。
    final double badgeBottom = progress == null ? 6 : (apple ? 18 : 10);
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => shelfCoverCard(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        focusId: focusId,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ShelfCoverFrame(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    MediaServerFallbackImage(
                      images: mediaServerContinueImages(browser, item),
                      placeholderIcon: isEpisode
                          ? FushiIcons.tv
                          : FushiIcons.video,
                    ),
                    if (badge != null)
                      Positioned(
                        right: 6,
                        bottom: badgeBottom,
                        child: CoverBadge(
                          key: const ValueKey<String>(
                            'media-server-continue-badge',
                          ),
                          label: badge,
                        ),
                      ),
                    if (progress != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: CoverProgressStrip(
                          progressKey: const ValueKey<String>(
                            'media-server-continue-progress',
                          ),
                          value: progress,
                          minHeight: 4,
                          trackOpacity: 0.45,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            _MediaServerCardCaption(
              title: title,
              subtitle: mediaServerContinueSubtitle(item),
            ),
          ],
        ),
      ),
    );
  }
}

/// 横槽里按顺序尝试 [images]：当前一张加载失败就换下一张，全失败（或本来就
/// 没有）画 [placeholderIcon] 占位。每张都走 [PortraitCoverImage] 横槽，竖图
/// 自动模糊垫底。
class MediaServerFallbackImage extends StatelessWidget {
  const MediaServerFallbackImage({
    required this.images,
    required this.placeholderIcon,
    super.key,
  });

  final List<ImageProvider> images;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) => _candidate(context, 0);

  Widget _candidate(BuildContext context, int index) {
    if (index >= images.length) {
      return ShelfCoverPlaceholder(icon: placeholderIcon);
    }
    return PortraitCoverImage(
      key: ValueKey<int>(index),
      image: images[index],
      landscapeSlot: true,
      errorBuilder: (BuildContext context) => _candidate(context, index + 1),
    );
  }
}

/// 媒体库卡（16:9 背景图卡，Apple TV「资料库」式）：库封面（或条目海报拼贴 /
/// 类型图标）铺满整卡，底部一层渐变压暗，左下角白字「类型图标 + 库名」。两套
/// 设计系统共用这一构图；外层是 M3E 抬升卡（[FushiCard]，20 圆角），封面内缩成
/// 12 圆角的同心小块。
///
/// 库自身没图（Jellyfin 库可以不配封面）或图取不回来时，用 [fallbackItems] 里
/// 前几条有海报的条目拼一张 [MediaServerLibraryCollage] 顶上，实在一张都没有
/// 才画类型图标。**图取不回来也要回退**（BUG-2602）：UHD Media Server 这类
/// Emby 兼容层会给每个库都报 `ImageTags.Primary`，其中一部分库的图片端点却任何
/// 变体都 404——按 `hasCover` 判完仍然可能拿到一张必失败的图。
class MediaServerLibraryCard extends StatelessWidget {
  const MediaServerLibraryCard({
    required this.browser,
    required this.library,
    required this.onTap,
    this.fallbackItems = const <MediaServerItem>[],
    this.focusId,
    super.key,
  });

  final MediaServerBrowser browser;
  final MediaServerLibrary library;
  final VoidCallback onTap;

  /// 库封面缺失 / 加载失败时拼贴用的条目（首页已经为每库拉了前 20 条，直接
  /// 复用，不多发请求）。
  final List<MediaServerItem> fallbackItems;
  final FushiFocusId? focusId;

  static IconData iconFor(MediaServerLibraryKind kind) => switch (kind) {
    MediaServerLibraryKind.movies => FushiIcons.video,
    MediaServerLibraryKind.tvShows => FushiIcons.tv,
    MediaServerLibraryKind.mixed => FushiIcons.collection,
  };

  @override
  Widget build(BuildContext context) {
    final ImageProvider? image = mediaServerLibraryCoverImage(browser, library);
    final IconData icon = iconFor(library.kind);
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context);
    final FushiTypography type = context.fushiType;
    final Widget fallback = MediaServerLibraryCollage(
      browser: browser,
      items: fallbackItems,
      placeholderIcon: icon,
    );
    // 墨水屏没有渐变（灰阶抖动成脏块）：库名改成页面底色的实心条压在底边。
    final Color labelColor = eink
        ? Theme.of(context).colorScheme.onSurface
        : Colors.white;
    final TextStyle labelStyle =
        (apple ? type.titleMediumEmphasized : type.titleSmallEmphasized)
            .copyWith(
              color: labelColor,
              shadows: eink
                  ? null
                  : const <Shadow>[
                      Shadow(color: Color(0x66000000), blurRadius: 6),
                    ],
            );
    // M3E 分区卡（2026-10 扫尾）：外层是 20 圆角的抬升卡（悬停弹到 level2、按下
    // 回弹，焦点环跟卡形），封面以 8 内缩成 12 圆角的同心小块——卡与封面两级
    // 圆角是 M3E 的「容器 / 内容」层次。Apple 由 [FushiCard] 自己换玻璃卡。
    return FushiCard(
      variant: FushiCardVariant.elevated,
      padding: const EdgeInsets.all(kMediaServerLibraryCardInset),
      onTap: onTap,
      focusId: focusId,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: FushiM3eShape.smallRadius,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (image == null)
                fallback
              else
                PortraitCoverImage(
                  image: image,
                  landscapeSlot: true,
                  errorBuilder: (_) => fallback,
                ),
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: eink
                        ? null
                        : const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: <double>[0.35, 1],
                            colors: <Color>[
                              Color(0x00000000),
                              Color(0xB3000000),
                            ],
                          ),
                  ),
                ),
              ),
              PositionedDirectional(
                start: 0,
                end: 0,
                bottom: 0,
                child: ColoredBox(
                  color: eink
                      ? Theme.of(context).colorScheme.surface
                      : Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      12,
                      6,
                      12,
                      10,
                    ),
                    child: Row(
                      children: <Widget>[
                        FushiIcon(icon, size: 18, color: labelColor),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            library.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: labelStyle,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 库封面的回退画面：[items] 里前 [kMediaServerLibraryCollageCount] 条有海报的
/// 条目并排铺满槽位（每列 cover 裁切），一张都没有时画 [placeholderIcon]。
///
/// 每列各自失败各自变成空底色，不再往下回退——一列 404 不该把已经画出来的另外
/// 两列一起抹掉。
class MediaServerLibraryCollage extends StatelessWidget {
  const MediaServerLibraryCollage({
    required this.browser,
    required this.items,
    required this.placeholderIcon,
    super.key,
  });

  final MediaServerBrowser browser;
  final List<MediaServerItem> items;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<(MediaServerItem, ImageProvider)> posters =
        <(MediaServerItem, ImageProvider)>[];
    for (final MediaServerItem item in items) {
      if (posters.length >= kMediaServerLibraryCollageCount) break;
      final ImageProvider? provider = mediaServerCoverImage(browser, item);
      if (provider != null) posters.add((item, provider));
    }
    if (posters.isEmpty) return ShelfCoverPlaceholder(icon: placeholderIcon);
    return ColoredBox(
      color: tokens.surfaces.group,
      // stretch：每列吃满槽高再 cover 裁切。缺省 center 时列只拿到松高度约束，
      // 竖海报按自身比例矮一截，上下各露出一条底色（像素预览实测）。
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final (MediaServerItem item, ImageProvider provider) in posters)
            Expanded(
              child: Image(
                key: ValueKey<String>('media-server-collage-${item.id}'),
                image: provider,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
}

/// 区块标题行尾的「查看全部 ›」文字按钮（Apple「See All」/ MD3 Expressive 文字
/// 按钮）。[focusId] 非空时把按钮自己的焦点节点登记进焦点控制器，焦点恢复 /
/// 方向键导航仍按这个 id 找回它。
class MediaServerViewAllButton extends StatefulWidget {
  const MediaServerViewAllButton({
    required this.onPressed,
    this.focusId,
    super.key,
  });

  final VoidCallback onPressed;
  final FushiFocusId? focusId;

  @override
  State<MediaServerViewAllButton> createState() =>
      _MediaServerViewAllButtonState();
}

class _MediaServerViewAllButtonState extends State<MediaServerViewAllButton> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'media-server-all');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget button = FushiTextButton.icon(
      focusNode: _focusNode,
      onPressed: widget.onPressed,
      iconAlignment: IconAlignment.end,
      icon: const FushiIcon(FushiIcons.chevronRight, size: 18),
      label: Text(t.media_server_row_view_all),
    );
    final FushiFocusId? id = widget.focusId;
    if (id == null) return button;
    return FushiFocusRegistration(id: id, focusNode: _focusNode, child: button);
  }
}

/// 服务器首页的一条横滚行：区块标题（[FushiSectionTitle]，可带「查看全部」）+
/// 定高横向懒构建列表。卡片在页面的进场窗口（[FushiEntranceScope]）里错峰淡入；
/// 列表上下按悬停抬升留白，放大的卡不被裁。与合集横滚行同一套鼠标拖拽 /
/// 桌面物理。
class MediaServerRow extends StatelessWidget {
  const MediaServerRow({
    required this.title,
    required this.itemCount,
    required this.itemWidth,
    required this.rowHeight,
    required this.itemBuilder,
    required this.storageKey,
    this.onViewAll,
    this.viewAllFocusId,
    super.key,
  });

  final String title;
  final int itemCount;
  final double itemWidth;
  final double rowHeight;
  final IndexedWidgetBuilder itemBuilder;

  /// 行内 ListView 的 PageStorage 键（带服务器前缀，切服务器不串滚动位置）。
  final String storageKey;
  final VoidCallback? onViewAll;
  final FushiFocusId? viewAllFocusId;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double headroom = mediaServerLiftHeadroom(rowHeight);
    final VoidCallback? viewAll = onViewAll;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiStaggeredEntrance(
          index: 0,
          child: FushiSectionTitle(
            title,
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              // 上一行底部已有悬停留白：两者合起来正好一个 section 节奏。
              tokens.spacing.section - headroom,
              tokens.spacing.page,
              tokens.spacing.gap / 2,
            ),
            trailing: viewAll == null
                ? null
                : MediaServerViewAllButton(
                    onPressed: viewAll,
                    focusId: viewAllFocusId,
                  ),
          ),
        ),
        SizedBox(
          height: rowHeight + headroom * 2,
          child: HorizontalDragScrollable(
            child: ListView.separated(
              key: PageStorageKey<String>(storageKey),
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.page,
                vertical: headroom,
              ),
              scrollDirection: Axis.horizontal,
              physics: desktopAwareScrollPhysics(),
              itemCount: itemCount,
              separatorBuilder: (_, __) => SizedBox(width: tokens.spacing.card),
              itemBuilder: (BuildContext context, int index) =>
                  FushiStaggeredEntrance(
                    index: index + 1,
                    child: SizedBox(
                      width: itemWidth,
                      child: itemBuilder(context, index),
                    ),
                  ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 分区内每层视图（服务器列表 / 首页 / 网格）的页面外壳：M3E 悬浮页头（返回圆胶囊
/// + 标题胶囊 + 动作组胶囊 + 可选的搜索 / 排序行，由 [FushiPageHeader] 画）**叠在
/// 正文上**——页头只是几颗自带底色的胶囊，背后内容可见。Material 下页头随正文
/// 「往下滚收起、往回滚出现」，收起只做位移 + 淡出（[FushiFloatingChromeOverlay]，
/// M3E default spatial 弹簧），不改正文视口；顶部可读性只靠共享的
/// `FushiTopFadeScrim` 一段短的无硬边渐隐（由 overlay 画），不再有整宽实色底带。
///
/// 正文的让位：正文经 [MediaServerBodyInset]（即 [FushiFloatingChromeInset]）拿到
/// 「外层库页工具区 + 本页头」的高度，主滚动视图把它加成顶部内边距（内容滚到
/// 胶囊底下），空态 / 错误整体让开。**视图 State 的 context 在本框架外面**，必须
/// 在正文子树里读（[MediaServerBodyInset]），否则读到的是外层的值。
///
/// 显隐 controller：挂在库页浮动外壳里（视频页「媒体服务器」分区）时与外壳的分区
/// 页签共用同一份（[FushiFloatingChromeScope]，外壳自己听滚动通知），页头排在页签
/// 下方、一起收；独立使用（无外壳 / 测试宿主）时自备一份、自己喂滚动通知。每层
/// 路由成为栈顶（push 进来 / 从上一层 pop 回来）时页头弹回。
///
/// Apple 设计系统的页头不是悬浮胶囊：保持「页头 + 正文」竖排、页头恒在，整体让开
/// 外层工具区（[FushiFloatingChromeInsetPadding]）。
///
/// 为什么不直接用 [FushiPageScaffold]：这些视图是分区嵌套 Navigator 里的路由，
/// 分区被壳 Offstage 保活时页面仍挂在树上；[FushiPageScaffold] 会把自己的滚动
/// 控制器登记进全局 `PageScrollRegistry`，切到别的分区后手柄 LB/RB 翻页会落到这
/// 张看不见的页上。仍要一个 [Scaffold] 作 Material 祖先（嵌套路由上方没有）。
class MediaServerPageFrame extends StatefulWidget {
  const MediaServerPageFrame({
    required this.header,
    required this.body,
    super.key,
  });

  /// 页头（通常是 [FushiPageHeader]）。
  final Widget header;

  /// 正文。顶部让位在正文子树里用 [MediaServerBodyInset] 读。
  final Widget body;

  @override
  State<MediaServerPageFrame> createState() => _MediaServerPageFrameState();
}

class _MediaServerPageFrameState extends State<MediaServerPageFrame> {
  /// 不在库页浮动外壳里时自备的显隐 controller（外壳在时不用）。
  final FushiFloatingChromeController _ownChrome =
      FushiFloatingChromeController();

  /// 上一次依赖变化时本路由是否是栈顶：变成栈顶时让页头弹回。
  bool _wasCurrent = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool current = ModalRoute.isCurrentOf(context) ?? true;
    if (current && !_wasCurrent) {
      // 依赖变化发生在 build 阶段，controller 通知会标脏祖先：等这一帧画完。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        (FushiFloatingChromeScope.peek(context) ?? _ownChrome).resetToTop();
      });
    }
    _wasCurrent = current;
  }

  @override
  void dispose() {
    _ownChrome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (isGlassDesign(context)) {
      return Scaffold(
        backgroundColor: tokens.surfaces.page,
        body: FushiFloatingChromeInsetPadding(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              widget.header,
              Expanded(child: widget.body),
            ],
          ),
        ),
      );
    }
    final FushiFloatingChromeController? outer =
        FushiFloatingChromeScope.maybeOf(context);
    return Scaffold(
      backgroundColor: tokens.surfaces.page,
      body: FushiFloatingChromeScope(
        controller: outer ?? _ownChrome,
        // 外壳在时由外壳听滚动通知（通知照常冒泡上去），这里只喂自备的那份。
        child: NotificationListener<ScrollNotification>(
          onNotification: (ScrollNotification notification) =>
              outer == null &&
              _ownChrome.handleScrollNotification(notification),
          child: FushiFloatingChromeOverlay(
            chrome: widget.header,
            child: widget.body,
          ),
        ),
      ),
    );
  }
}

/// [MediaServerPageFrame] 正文的顶部让位（外层库页工具区 + 本页头的高度，恒定、
/// 不随收起变）：主滚动视图把 [builder] 拿到的 `top` 加成顶部内边距，空态 /
/// 错误整体下移 `top`。必须挂在框架的正文子树里（视图 State 的 context 在框架
/// 外面，读不到本页头的高度）。
class MediaServerBodyInset extends StatelessWidget {
  const MediaServerBodyInset({required this.builder, super.key});

  final Widget Function(BuildContext context, double top) builder;

  @override
  Widget build(BuildContext context) =>
      builder(context, FushiFloatingChromeInset.of(context));
}

/// 加载骨架：一张 2:3 海报卡（封面块 + 两行文字条），与 [MediaServerItemCard]
/// 同几何，数据回来时版面不跳。
class MediaServerPosterSkeleton extends StatelessWidget {
  const MediaServerPosterSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const AspectRatio(aspectRatio: 2 / 3, child: FushiSkeleton()),
        const SizedBox(height: _kCaptionTop + 2),
        FushiSkeleton.line(widthFactor: 0.8),
        const SizedBox(height: 6),
        FushiSkeleton.line(widthFactor: 0.5, height: 10),
      ],
    );
  }
}

/// 加载骨架：一张 16:9 媒体库卡（外卡 20 + 内缩封面块，与 [MediaServerLibraryCard]
/// 同形）。
class MediaServerLibraryCardSkeleton extends StatelessWidget {
  const MediaServerLibraryCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const FushiCard(
      padding: EdgeInsets.all(kMediaServerLibraryCardInset),
      child: AspectRatio(aspectRatio: 16 / 9, child: FushiSkeleton()),
    );
  }
}

/// 加载骨架：分段列表里的一行（行首 [leadingWidth]×[leadingHeight] 块 + 两行
/// 文字条），外壳是不可点的分段卡格，首尾大圆角与真实列表一致。
class MediaServerListRowSkeleton extends StatelessWidget {
  const MediaServerListRowSkeleton({
    required this.index,
    required this.count,
    this.leadingWidth = 40,
    this.leadingHeight = 40,
    this.leadingCircle = false,
    super.key,
  });

  final int index;
  final int count;
  final double leadingWidth;
  final double leadingHeight;
  final bool leadingCircle;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double rowPad = tokens.spacing.rowHorizontal;
    return FushiGroupedListItem(
      index: index,
      count: count,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: rowPad,
          vertical: tokens.spacing.rowVertical,
        ),
        child: Row(
          children: <Widget>[
            FushiSkeleton(
              width: leadingWidth,
              height: leadingHeight,
              circle: leadingCircle,
            ),
            SizedBox(width: rowPad),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FushiSkeleton.line(widthFactor: 0.55, height: 14),
                  const SizedBox(height: 8),
                  FushiSkeleton.line(widthFactor: 0.35, height: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
