/// 发现页共享交互件：搜索防抖、滚到底自动翻页、来源失败横幅、横滑行。
///
/// 口径以视频发现页（`video_discovery_page.dart`）为准——那一页的交互是 2026-09 用户
/// 拍板的「发现页该有的样子」（`docs/specs/2026-09-27-browse-module.md` 阶段 3）。
/// 书 / 有声书 / galgame 资源站发现页（`media_discovery_page.dart`）与漫画发现页
/// （`manga_discovery_page.dart`）从这里取同一份实现，而不是各抄一遍常量：抄出去的
/// 350 / 600 迟早漂成三个数，横幅文案的判据也会各说各话。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi/utils.dart';

/// 搜索框输入到发请求之间的防抖间隔。
const Duration kDiscoverySearchDebounce = Duration(milliseconds: 350);

/// 离列表底部还剩多少逻辑像素时预取下一页。
const double kDiscoveryAutoLoadExtent = 600;

/// 当前滚动位置是否该预取下一页（离底不足 [kDiscoveryAutoLoadExtent]）。
///
/// 只看纵向：横滑行冒泡上来的 [ScrollNotification] 也会带着自己的 metrics，拿它
/// 判「快到底了」会在横向拖一条卡片行时把下一页拉下来。
bool discoveryShouldLoadMore(ScrollMetrics metrics) =>
    metrics.axis == Axis.vertical &&
    metrics.extentAfter < kDiscoveryAutoLoadExtent;

/// 搜索防抖器：每次 [schedule] 取消上一次尚未触发的动作。
///
/// 调用方负责「输入一变就作废在途请求」（视频页 `_scheduleSearch` 那条纪律：等防抖
/// 触发才作废的话，上一个关键词的晚到结果会在用户已经在打下一个词时短暂顶掉列表），
/// 本类只管计时。
class DiscoverySearchDebouncer {
  DiscoverySearchDebouncer({this.delay = kDiscoverySearchDebounce});

  final Duration delay;
  Timer? _timer;

  /// 是否有尚未触发的动作。
  bool get isPending => _timer?.isActive ?? false;

  void schedule(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => cancel();
}

/// 失败按 `providerId:operation:kind` 去重（翻页追加的失败与首页同源同因时只记一次）。
List<ExternalProviderFailure> deduplicateDiscoveryFailures(
  Iterable<ExternalProviderFailure> failures,
) {
  final Set<String> seen = <String>{};
  return <ExternalProviderFailure>[
    for (final ExternalProviderFailure failure in failures)
      if (seen.add(
        '${failure.providerId}:${failure.operation}:${failure.kind.name}',
      ))
        failure,
  ];
}

/// 横幅文案取决于失败**性质**，不是「有失败就说不可用」。
///
/// BUG-2430：MAL 走 Jikan 公共接口，1 秒一发、不重试，撞上 429 是家常便饭。那是
/// 「等一会儿再搜」，不是「这个来源不可用」——后者会让用户跑去设置页找一个根本不
/// 存在的开关。混合了多种性质时退回最泛的说法。
String discoveryProviderWarningMessage(List<ExternalProviderFailure> failures) {
  bool allOf(Set<ExternalProviderFailureKind> kinds) =>
      failures.every((ExternalProviderFailure e) => kinds.contains(e.kind));
  if (allOf(const <ExternalProviderFailureKind>{
    ExternalProviderFailureKind.rateLimited,
    ExternalProviderFailureKind.quotaExceeded,
  })) {
    return t.video_discovery_provider_rate_limited;
  }
  if (allOf(const <ExternalProviderFailureKind>{
    ExternalProviderFailureKind.unavailable,
    ExternalProviderFailureKind.unauthorized,
    ExternalProviderFailureKind.forbidden,
    ExternalProviderFailureKind.unsupported,
  })) {
    return t.video_discovery_provider_warning;
  }
  return t.video_discovery_provider_failed;
}

/// 部分来源失败时压在结果上方的横幅：失败性质文案 + 失败来源的**展示名**。
///
/// 只在「还有结果可看」时用；一个来源都没成功时调用方应换成整页
/// `FushiPlaceholderMessage` + 重试，而不是一条横幅压着空列表。
class DiscoveryProviderWarningBanner extends StatelessWidget {
  const DiscoveryProviderWarningBanner({
    required this.failures,
    required this.displayNameFor,
    super.key,
  });

  final List<ExternalProviderFailure> failures;

  /// [ExternalProviderFailure.providerId] -> 用户可见来源名。印品牌名而不是接线用
  /// 的 id（BUG-2430）。
  final String Function(String providerId) displayNameFor;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Set<String> providerNames = <String>{
      for (final ExternalProviderFailure failure in failures)
        displayNameFor(failure.providerId),
    };
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        0,
      ),
      child: FushiCard(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.rowHorizontal,
          vertical: tokens.spacing.rowVertical,
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.cloud_off_outlined),
            SizedBox(width: tokens.spacing.gap),
            Expanded(child: Text(discoveryProviderWarningMessage(failures))),
            if (providerNames.isNotEmpty)
              Flexible(
                child: Text(
                  providerNames.join(' · '),
                  style: tokens.type.metadata,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 列表尾：翻页加载中给转圈，否则留一段页尾空白。
class DiscoveryLoadMoreFooter extends StatelessWidget {
  const DiscoveryLoadMoreFooter({required this.loading, super.key});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (!loading) return SizedBox(height: tokens.spacing.section);
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Center(child: adaptiveIndicator(context: context)),
    );
  }
}

/// 一条带标题的横滑卡片行（「热门」「本季新番」「某来源热门」）。
///
/// [loading] 为真时行头出小转圈，卡片条**照样占住 [height]**：加载完成那一刻不会
/// 凭空插入一整条卡片高度把下方内容整体顶下去（漫画来源行的既有纪律）。
///
/// 桌面端默认 dragDevices 不含 mouse，横滑行必须包 [HorizontalDragScrollable]
/// （`horizontal_drag_scroll_guard_test.dart` 守的就是这一条）。
class DiscoveryShelf extends StatelessWidget {
  const DiscoveryShelf({
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    required this.height,
    required this.itemWidth,
    this.loading = false,
    this.trailing,
    this.storageKey,
    super.key,
  });

  final String title;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// 卡片条高度（不含行头）。
  final double height;

  /// 单张卡片宽度。
  final double itemWidth;

  final bool loading;

  /// 行头右侧附加件（如「查看全部」）。
  final Widget? trailing;

  /// 横向列表的 [PageStorageKey] 值：保活页里来回切换时保住横向滚动位置。
  final String? storageKey;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? storage = storageKey;
    final Widget? trailingWidget = trailing;
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (loading)
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: tokens.spacing.gap,
                    ),
                    child: const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (trailingWidget != null) trailingWidget,
              ],
            ),
          ),
          SizedBox(height: tokens.spacing.card),
          SizedBox(
            height: height,
            child: loading
                ? null
                : HorizontalDragScrollable(
                    child: ListView.separated(
                      key: storage == null
                          ? null
                          : PageStorageKey<String>(storage),
                      padding: EdgeInsets.symmetric(
                        horizontal: tokens.spacing.page,
                      ),
                      scrollDirection: Axis.horizontal,
                      itemCount: itemCount,
                      separatorBuilder: (BuildContext context, int index) =>
                          SizedBox(width: tokens.spacing.gap),
                      itemBuilder: (BuildContext context, int index) =>
                          SizedBox(
                            width: itemWidth,
                            child: itemBuilder(context, index),
                          ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
