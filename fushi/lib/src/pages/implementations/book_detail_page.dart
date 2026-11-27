import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/async_file_existence_cache.dart'
    show PendingCoverImage;
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/detail/item_scrape_detail.dart';
import 'package:fushi/src/media/detail/item_scrape_detail_view.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/detail/media_poster_detail.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show shellRedesignActive;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';

/// 书 / 漫画 / 字幕书详情页此刻的书架侧状态（标题 / 作者 / 封面 / 进度）。
///
/// 详情页不自己解析书架身份：调用方（书架页）给一个现取函数，详情页在首帧、刮削
/// 写回后、从阅读器返回后各取一次——改名 / 换封面 / 读了几页都即时反映，不存镜像。
@immutable
class BookDetailSnapshot {
  const BookDetailSnapshot({
    required this.title,
    this.author,
    this.cover,
    this.progress = 0,
    this.completed = false,
    this.coverFallbackIcon = FushiIcons.books,
  });

  /// 显示名（已应用改名覆盖）。
  final String title;
  final String? author;

  /// 封面；null = 没有封面（海报位不占、背景不垫模糊封面）。
  final ImageProvider? cover;

  /// 阅读进度 0..1（与书卡副行同一个口径）。
  final double progress;
  final bool completed;

  /// 没有封面 / 封面解码失败时海报位的图标。
  final IconData coverFallbackIcon;

  /// 打开过（有进度且未读完）：主按钮写「继续阅读」。
  bool get started => progress > 0 && !completed;
}

/// 单本书 / 漫画卷 / 字幕书（有声书）的元数据详情页：与视频作品详情同一套
/// 海报面板外观（[MediaPosterDetailTheme] + [MediaPosterDetailChrome] +
/// [MediaPosterDetailLayout] + [MediaPosterDetailHero]），墨水屏回落
/// [MediaDetailLayout] + [CollectionDetailHero]（同视频）。
///
/// 数据：书架侧状态经 [snapshot] 现取；刮削资料（`item_scrape_meta`）与横版背景
/// / 艺术字（`item_images`）经 [loadDetail] 读，[changes] 每发一次重读（刮削写回、
/// 控制通道脚本改资料都会触发）。没有任何刮削数据时照常显示封面 / 书名 / 作者 /
/// 进度，并给「刮削资料」行动点。
///
/// 动作全部回调给书架页：主按钮 [onOpen] 与点书卡完全同一条路径（漫画先进作品页），
/// [onScrape] 是书卡菜单「在线刮削封面」的同一个流程（门面写封面 + 资料 + 背景）。
class BookDetailPage extends StatefulWidget {
  const BookDetailPage({
    required this.snapshot,
    required this.loadDetail,
    required this.onOpen,
    this.onScrape,
    this.changes,
    this.launchLink,
    super.key,
  });

  final BookDetailSnapshot Function() snapshot;
  final Future<ItemScrapeDetail> Function() loadDetail;
  final Future<void> Function() onOpen;

  /// null = 刮削不可用（「在线服务」模块关着），不出刮削按钮。
  final Future<void> Function()? onScrape;
  final Stream<void>? changes;

  /// 「查看条目」打开外链（测试接缝；null = 系统浏览器）。
  final Future<void> Function(Uri uri)? launchLink;

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage>
    with StateResourceScope<BookDetailPage> {
  ItemScrapeDetail _detail = ItemScrapeDetail.empty;
  bool _opening = false;
  bool _scraping = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
    final Stream<void>? changes = widget.changes;
    if (changes != null) {
      ownSubscription(changes.listen((_) => unawaited(_reload())));
    }
  }

  Future<void> _reload() async {
    try {
      final ItemScrapeDetail detail = await widget.loadDetail();
      if (!mounted) return;
      setState(() => _detail = detail);
    } catch (e, st) {
      // 资料读不到时页面照样可用（封面 / 书名 / 进度来自书架侧），只记诊断。
      ErrorLogService.instance.log('book_detail', 'load failed: $e', st);
    }
  }

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await widget.onOpen();
    } finally {
      // 从阅读器回来：进度 / 读完状态经 [BookDetailPage.snapshot] 重取。
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _scrape() async {
    final Future<void> Function()? onScrape = widget.onScrape;
    if (onScrape == null || _scraping) return;
    setState(() => _scraping = true);
    try {
      await onScrape();
    } finally {
      if (mounted) setState(() => _scraping = false);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final BookDetailSnapshot snap = widget.snapshot();
    final ImageProvider? cover = snap.cover is PendingCoverImage
        ? null
        : snap.cover;
    final String title = snap.title;
    final ItemScrapeDetailView view = ItemScrapeDetailView(
      _detail,
      title: title,
      author: snap.author,
    );
    final ImageProvider? backdrop = view.backdrop;
    final ImageProvider? logo = view.logo;
    final String? originalTitle = view.originalTitle;
    final String? summary = view.summary;
    final String? author = view.author;
    final String? sourceLabel = view.sourceLabel;
    final bool scraped = view.scraped;

    final List<MediaDetailChip> pills = <MediaDetailChip>[
      ...view.metaPills(),
      if (snap.completed)
        MediaDetailChip(
          t.media_detail_status_completed,
          icon: FushiIcons.check,
          tone: MediaDetailChipTone.secondary,
        ),
    ];
    final String? progressLabel = snap.started
        ? t.book_read_progress(
            percent: (snap.progress * 100).floor().clamp(1, 99),
          )
        : null;
    final String primaryLabel = MediaDetailResumeFab.labelFor(
      watching: false,
      started: snap.started,
    );
    // 次操作一律是同尺寸的 tonal 图标钮（文字进 tooltip / Semantics），跟主按钮
    // 同一行，放不下才从末尾收进「⋯」（[MediaDetailMoreButton] 的自适应平铺）。
    final List<MediaDetailMenuItem> actionItems = <MediaDetailMenuItem>[
      if (widget.onScrape != null)
        view.scrapeAction(
          enabled: !_scraping,
          onSelected: () => unawaited(_scrape()),
        ),
      ?view.sourceLinkAction(launch: widget.launchLink),
    ];
    final Widget? more = actionItems.isEmpty
        ? null
        : MediaDetailMoreButton(
            buttonKey: const ValueKey<String>('book-detail-more'),
            items: actionItems,
          );
    final Widget? footer = scraped || widget.onScrape == null
        ? null
        : Text(
            t.book_detail_unscraped_hint,
            key: const ValueKey<String>('book-detail-unscraped-hint'),
            style: context.fushiType.bodyMedium.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget? factsSection = view.factsSection(context);
    final List<Widget> slivers = <Widget>[
      if (factsSection != null)
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
          sliver: SliverToBoxAdapter(
            child: FushiStaggeredEntrance(index: 3, child: factsSection),
          ),
        ),
    ];
    final Widget fab = MediaDetailResumeFab(
      buttonKey: const ValueKey<String>('book-detail-resume-fab'),
      watching: false,
      started: snap.started,
      icon: FushiIcons.books,
      onPressed: _opening ? null : () => unawaited(_open()),
    );

    if (shellRedesignActive(context)) {
      return Scaffold(
        backgroundColor: fushiPageBackgroundColor(context),
        body: MediaPosterDetailTheme(
          image: cover,
          fallbackKey: title,
          child: MediaPosterDetailChrome(
            title: title,
            child: FushiEntranceScope(
              child: MediaPosterDetailLayout(
                bottomPadding: tokens.spacing.page,
                fab: fab,
                header: MediaPosterDetailHero(
                  title: title,
                  titleKey: const ValueKey<String>('book-detail-title'),
                  kicker: sourceLabel,
                  originalTitle: originalTitle ?? author,
                  selectableHeading: true,
                  poster: cover == null
                      ? null
                      : SizedBox.expand(
                          key: const ValueKey<String>('book-detail-poster'),
                          child: PortraitCoverImage(
                            image: cover,
                            errorBuilder: (BuildContext _) =>
                                MediaDetailCoverPlaceholder(
                                  icon: snap.coverFallbackIcon,
                                ),
                          ),
                        ),
                  posterImage: cover,
                  backdrop: backdrop,
                  backdropFallback: cover,
                  logo: logo,
                  logoSemanticsName: title,
                  pills: pills,
                  continueLabel: progressLabel,
                  summary: summary,
                  summaryKey: const ValueKey<String>('book-detail-summary'),
                  primaryAction: MediaDetailPrimaryButton(
                    buttonKey: const ValueKey<String>('book-detail-open'),
                    icon: FushiIcons.books,
                    label: primaryLabel,
                    busy: _opening,
                    onPressed: _opening ? null : () => unawaited(_open()),
                  ),
                  more: more,
                  footer: footer,
                ),
                slivers: slivers,
              ),
            ),
          ),
        ),
      );
    }
    // 墨水屏：与视频作品详情同一套 M3E 骨架（背景图优先、没有就封面模糊垫底）。
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: FushiAppBar(),
      body: FushiEntranceScope(
        child: MediaDetailLayout(
          backdrop: collectionHeroBackdropImage(
            backdrop: backdrop,
            cover: cover,
          ),
          backdropBlur: collectionHeroBackdropBlur(backdrop: backdrop),
          bottomPadding: tokens.spacing.page,
          fab: fab,
          header: CollectionDetailHero(
            backdrop: backdrop,
            cover: cover,
            coverMaterial: ShelfCoverMaterial.glossyPoster,
            logo: logo,
            title: title,
            originalTitle: originalTitle ?? author,
            airDate: view.meta?.airDate,
            chips: pills,
            summary: summary,
            continueLabel: progressLabel,
            playLabel: primaryLabel,
            playIcon: FushiIcons.books,
            playButtonKey: const ValueKey<String>('book-detail-open'),
            onPlay: _opening ? null : () => unawaited(_open()),
            moreItems: actionItems,
            footer: footer,
          ),
          slivers: slivers,
        ),
      ),
    );
  }
}
