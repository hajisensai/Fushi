// Apple（Cupertino，iOS 27 / macOS 27）下载页「订阅」的版式（方案 A，清单第 41
// 行：inset 列表 + 行 ⋯ 菜单 / push 编辑）。
//
// 挂在 [_VideoDownloadSubscriptionsViewState] 上的 extension（part 文件）：搜索 /
// 排序 / 自动关闭档 / 忙碌锁 / 逐集展开 / 各行动作全部复用原 State 与
// [_VideoDownloadSubscriptionCard] 已绑好的回调，只换外观、不改行为。
//
// - 汇总组：「n 个订阅 · m 个启用」+ 调度说明，行尾「全部检查」；
// - 搜索框 + 排序 / 自动关闭两颗 pull-down；
// - 订阅一组 inset 分组行：小封面、标题、「类型 · 来源 · 模式」、调度、状态行、
//   规则 / 停用原因（文字，不用 tag）、逐集计数；行尾开关 +「⋯」（立即检查 /
//   编辑 / 逐集状态 / 删除）；点行 = 编辑（push 编辑页；不能编辑的行展开逐集）；
//   长按 / 右键同「⋯」。
part of '../../../pages/implementations/video_download_subscriptions_panel.dart';

enum _AppleSubscriptionCommand { check, edit, items, delete }

extension _AppleVideoDownloadSubscriptions
    on _VideoDownloadSubscriptionsViewState {
  Widget _appleSummary(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final int enabled = widget.subscriptions
        .where((VideoDownloadSubscriptionRow row) => row.enabled)
        .length;
    return FushiAppleGroupSurface(
      key: const ValueKey<String>('video-subscriptions-header'),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          metrics.rowHorizontal,
          12,
          metrics.rowHorizontal - 4,
          12,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    t.download_subscription_summary(
                      n: widget.subscriptions.length,
                      enabled: enabled,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metrics
                        .titleStyle(context)
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t.download_subscription_running_hint,
                    style: metrics.footnoteStyle(context),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (widget.checkingAll)
              const SizedBox.square(
                dimension: 18,
                child: FushiCircularProgressIndicator.adaptive(strokeWidth: 2),
              )
            else
              AppleDownloadTextAction(
                key: const ValueKey<String>('video-subscription-check-all'),
                label: t.download_subscription_check_all,
                onTap: enabled == 0 ? null : widget.onCheckAll,
              ),
          ],
        ),
      ),
    );
  }

  Widget _appleToolbar(BuildContext context) {
    final List<Widget> pullDowns = <Widget>[
      FushiOverflowMenu<VideoDownloadSubscriptionSort>(
        key: const ValueKey<String>('video-subscription-sort'),
        tooltip: t.sort_by,
        padding: EdgeInsets.zero,
        onSelected: (VideoDownloadSubscriptionSort value) =>
            _appleUpdate(() => _sort = value),
        items: <PopupMenuEntry<VideoDownloadSubscriptionSort>>[
          for (final VideoDownloadSubscriptionSort value
              in VideoDownloadSubscriptionSort.values)
            FushiPopupMenuItem<VideoDownloadSubscriptionSort>(
              value: value,
              label: _VideoDownloadSubscriptionsViewState._sortLabel(value),
              selected: _sort == value,
            ),
        ],
        child: FushiApplePopUpButtonFace(
          label: _VideoDownloadSubscriptionsViewState._sortLabel(_sort),
        ),
      ),
      if (widget.onAutoDisableDaysChanged != null)
        FushiOverflowMenu<int>(
          key: const ValueKey<String>('video-subscription-auto-disable'),
          tooltip: t.subscription_auto_disable_tooltip,
          padding: EdgeInsets.zero,
          onSelected: widget.onAutoDisableDaysChanged!,
          items: <PopupMenuEntry<int>>[
            for (final int days in kVideoDownloadSubscriptionAutoDisableChoices)
              FushiPopupMenuItem<int>(
                value: days,
                label:
                    _VideoDownloadSubscriptionsViewState._autoDisableChoiceLabel(
                      days,
                    ),
                selected: widget.autoDisableDays == days,
              ),
          ],
          child: FushiApplePopUpButtonFace(
            label: t.subscription_auto_disable_label(
              period:
                  _VideoDownloadSubscriptionsViewState._autoDisableChoiceLabel(
                    widget.autoDisableDays,
                  ),
            ),
            active: widget.autoDisableDays > 0,
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiSearchBar(
          fieldKey: const ValueKey<String>('video-subscription-search'),
          controller: _searchController,
          focusNode: _searchFocusNode,
          hintText: t.subscription_search_hint,
          onQueryChanged: (String value) =>
              _appleUpdate(() => _searchQuery = value),
          onSubmitted: (String value) =>
              _appleUpdate(() => _searchQuery = value),
          onClear: () => _appleUpdate(() => _searchQuery = ''),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: pullDowns),
      ],
    );
  }

  Widget _buildApple(
    BuildContext context,
    List<VideoDownloadSubscriptionRow> visible,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double page = tokens.spacing.page;
    final double chromeInset = FushiFloatingChromeInset.of(context);
    final Widget body;
    if (widget.subscriptions.isEmpty || visible.isEmpty) {
      body = SliverFillRemaining(
        hasScrollBody: false,
        child: widget.subscriptions.isEmpty
            ? _VideoDownloadSubscriptionMessage(
                icon: FushiIcons.notifications,
                title: t.download_subscription_empty_title,
                body: t.download_subscription_empty_body,
              )
            : _VideoDownloadSubscriptionMessage(
                icon: FushiIcons.searchOff,
                title: t.subscription_no_match,
              ),
      );
    } else {
      body = SliverPadding(
        padding: EdgeInsets.fromLTRB(page, 24, page, 24),
        sliver: SliverList.builder(
          itemCount: visible.length,
          // 错峰只排前 8 行，之后与第 8 行同拍。
          itemBuilder: (BuildContext context, int index) =>
              FushiStaggeredEntrance(
                index: index > 8 ? 8 : index,
                child: _AppleSubscriptionRow(
                  card:
                      _buildCard(visible[index])
                          as _VideoDownloadSubscriptionCard,
                  index: index,
                  count: visible.length,
                ),
              ),
        ),
      );
    }
    return FushiEntranceScope(
      replayKey: _sort,
      child: FushiRefreshIndicator(
        onRefresh: widget.onCheckAll,
        child: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(child: SizedBox(height: chromeInset)),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(page, 8, page, 0),
              sliver: SliverToBoxAdapter(
                child: FushiStaggeredEntrance(
                  index: 0,
                  child: _appleSummary(context),
                ),
              ),
            ),
            if (widget.remoteSection != null)
              SliverToBoxAdapter(child: widget.remoteSection),
            if (widget.subscriptions.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(page, 16, page, 0),
                sliver: SliverToBoxAdapter(child: _appleToolbar(context)),
              ),
            body,
          ],
        ),
      ),
    );
  }
}

/// 一条订阅的 Apple 行。[card] 是 M3E 卡的配置（同一组已绑定的回调 / 计数），
/// 这里只换画法。
class _AppleSubscriptionRow extends StatelessWidget {
  const _AppleSubscriptionRow({
    required this.card,
    required this.index,
    required this.count,
  });

  final _VideoDownloadSubscriptionCard card;
  final int index;
  final int count;

  VideoDownloadSubscriptionRow get _sub => card.subscription;

  List<PopupMenuEntry<_AppleSubscriptionCommand>> _menuItems(
    BuildContext context,
  ) {
    final String id = _sub.subscriptionId;
    final bool legacy = card._isLegacy;
    return <PopupMenuEntry<_AppleSubscriptionCommand>>[
      if (!legacy)
        FushiPopupMenuItem<_AppleSubscriptionCommand>(
          key: ValueKey<String>('video-subscription-check-$id'),
          value: _AppleSubscriptionCommand.check,
          icon: FushiIcons.refresh,
          label: t.download_subscription_check_now,
          enabled: !card.busy && card.onCheck != null,
        ),
      if (card.onEdit != null && !legacy)
        FushiPopupMenuItem<_AppleSubscriptionCommand>(
          key: ValueKey<String>('video-subscription-edit-$id'),
          value: _AppleSubscriptionCommand.edit,
          icon: FushiIcons.edit,
          label: t.subscription_edit_title,
          enabled: !card.busy,
        ),
      if (card.onToggleExpanded != null)
        FushiPopupMenuItem<_AppleSubscriptionCommand>(
          key: ValueKey<String>('video-subscription-expand-$id'),
          value: _AppleSubscriptionCommand.items,
          icon: FushiIcons.history,
          label: t.subscription_show_items,
          selected: card.expanded,
        ),
      const PopupMenuDivider(),
      FushiPopupMenuItem<_AppleSubscriptionCommand>(
        key: ValueKey<String>('video-subscription-delete-$id'),
        value: _AppleSubscriptionCommand.delete,
        icon: FushiIcons.delete,
        label: t.download_subscription_delete,
        color: appleColorsOf(context).destructive,
        enabled: !card.busy,
      ),
    ];
  }

  void _run(_AppleSubscriptionCommand command) {
    switch (command) {
      case _AppleSubscriptionCommand.check:
        if (!card.busy) card.onCheck?.call();
      case _AppleSubscriptionCommand.edit:
        if (!card.busy) card.onEdit?.call();
      case _AppleSubscriptionCommand.items:
        card.onToggleExpanded?.call();
      case _AppleSubscriptionCommand.delete:
        if (!card.busy) card.onDelete();
    }
  }

  Future<void> _openMenu(BuildContext context, {Offset? at}) async {
    final _AppleSubscriptionCommand? command =
        await showFushiMenu<_AppleSubscriptionCommand>(
          context: context,
          position: appleDownloadMenuPosition(context, at: at),
          items: _menuItems(context),
        );
    if (command != null) _run(command);
  }

  Widget _cover(BuildContext context, FushiAppleMetrics metrics) {
    final double width = (metrics.desktop ? 24 : 32) * metrics.scale;
    final FushiAppleColors apple = appleColorsOf(context);
    final Widget fallback = Container(
      width: width,
      height: width * 1.5,
      decoration: BoxDecoration(
        color: apple.fill,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: FushiIcon(
          FushiIcons.video,
          size: width * 0.55,
          color: apple.label,
        ),
      ),
    );
    return AnimatedOpacity(
      opacity: _sub.enabled ? 1 : 0.45,
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      child: DownloadTaskCoverThumb(
        url: _sub.coverUrl,
        width: width,
        fallback: fallback,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final DateTime now = DateTime.now();
    final double k = metrics.scale;
    final String id = _sub.subscriptionId;
    final TextStyle meta = metrics
        .subtitleStyle(context)
        .copyWith(
          fontSize: (metrics.desktop ? 11 : 13) * k,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );
    final String title = _sub.year == null
        ? _sub.title
        : '${_sub.title} (${_sub.year})';
    final String modeLabel = _sub.mode == 'oneShot'
        ? t.subscription_mode_one_shot
        : t.subscription_mode_ongoing;
    final String mediaLabel = _sub.mediaKind == 'movie'
        ? t.collection_relation_movie
        : t.series;
    final int? next = _sub.nextCheckAt;
    final String schedule = <String>[
      if (_sub.enabled && next != null)
        t.subscription_next_check(
          time: _VideoDownloadSubscriptionCard._futureTime(next, now),
        ),
      t.download_subscription_last_checked(
        time: _VideoDownloadSubscriptionCard._pastTime(_sub.lastCheckedAt, now),
      ),
      if (_sub.lastMatchedAt != null)
        t.subscription_last_matched(
          time: _VideoDownloadSubscriptionCard._pastTime(
            _sub.lastMatchedAt,
            now,
          ),
        ),
      if (_sub.startAfterEpisode case final int episode)
        t.download_subscription_start_episode(episode: episode),
    ].join(' · ');
    final bool fulfilled = !_sub.enabled && _sub.fulfilledAt != null;
    final bool stale =
        !_sub.enabled &&
        card.showStale &&
        isVideoDownloadSubscriptionStale(
          _sub,
          nowAt: now.millisecondsSinceEpoch,
          days: card.autoDisableDays,
          latestDiscoveredAt: card.latestDiscoveredAt,
        );
    final List<String> rules = videoDownloadSubscriptionFilterSummary(
      _sub.filterJson,
    );
    final int failed =
        card.itemCounts[VideoDownloadSubscriptionItemStatus.failed] ?? 0;
    final String counts = card._itemCountsLine;
    final Widget? status = card._buildStatus(context);
    const String dot = ' · ';
    final List<InlineSpan> badges = <InlineSpan>[
      if (fulfilled)
        TextSpan(
          text: t.subscription_fulfilled_chip,
          style: TextStyle(color: apple.success),
        ),
      if (stale)
        TextSpan(
          text: t.subscription_stale_chip(
            period: _VideoDownloadSubscriptionsViewState.autoDisablePeriodLabel(
              card.autoDisableDays,
            ),
          ),
          style: TextStyle(color: apple.destructive),
        ),
      if (card._isLegacy)
        TextSpan(
          text: t.subscription_legacy_badge,
          style: TextStyle(color: apple.warning),
        ),
      for (final String rule in rules) TextSpan(text: rule),
    ];
    final List<InlineSpan> countSpans = <InlineSpan>[
      if (failed > 0)
        TextSpan(
          text:
              '${_VideoDownloadSubscriptionCard.itemStatusLabel(VideoDownloadSubscriptionItemStatus.failed)} $failed',
          style: TextStyle(
            color: apple.destructive,
            fontWeight: FontWeight.w600,
          ),
        ),
      if (counts.isNotEmpty) TextSpan(text: counts),
    ];
    List<InlineSpan> joined(List<InlineSpan> spans) => <InlineSpan>[
      for (int i = 0; i < spans.length; i++) ...<InlineSpan>[
        if (i > 0) const TextSpan(text: dot),
        spans[i],
      ],
    ];
    final VoidCallback? tap = !card._isLegacy && card.onEdit != null
        ? (card.busy ? null : card.onEdit)
        : card.onToggleExpanded;
    final Widget content = Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        metrics.rowHorizontal,
        10 * k,
        (metrics.desktop ? 6 : 4) * k,
        10 * k,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _cover(context, metrics),
          SizedBox(width: 12 * k),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: 2 * k,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: metrics
                      .titleStyle(context)
                      .copyWith(
                        fontSize: (metrics.desktop ? 13 : 15) * k,
                        fontWeight: FontWeight.w500,
                      ),
                ),
                FushiTooltip(
                  message: _sub.resourceProvider,
                  child: Text.rich(
                    TextSpan(
                      style: meta,
                      children: <InlineSpan>[
                        TextSpan(
                          text:
                              '$mediaLabel$dot'
                              '${_VideoDownloadSubscriptionCard._providerLabel(_sub.resourceProvider)}'
                              '$dot',
                        ),
                        TextSpan(
                          text: modeLabel,
                          style: TextStyle(
                            color: _sub.enabled ? apple.accent : null,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  schedule,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: meta,
                ),
                if (badges.isNotEmpty)
                  Semantics(
                    container: true,
                    label: t.subscription_rules_title,
                    child: Text.rich(
                      TextSpan(style: meta, children: joined(badges)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ?status,
                if (countSpans.isNotEmpty)
                  Text.rich(
                    TextSpan(style: meta, children: joined(countSpans)),
                    key: ValueKey<String>('video-subscription-items-$id'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          SizedBox(width: 4 * k),
          FushiSwitch.adaptive(
            key: ValueKey<String>('video-subscription-toggle-$id'),
            value: _sub.enabled,
            onChanged: card.busy ? null : card.onToggle,
          ),
          Builder(
            builder: (BuildContext anchor) =>
                FushiOverflowMenu<_AppleSubscriptionCommand>(
                  key: ValueKey<String>('video-subscription-menu-$id'),
                  tooltip: t.common_more_actions,
                  onSelected: _run,
                  items: _menuItems(anchor),
                ),
          ),
        ],
      ),
    );
    final Widget history = card.expanded && card.itemsWatcher != null
        ? Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              metrics.rowHorizontal,
              0,
              metrics.rowHorizontal,
              12,
            ),
            child: _SubscriptionItemsSection(
              subscription: _sub,
              itemsWatcher: card.itemsWatcher!,
            ),
          )
        : const SizedBox(width: double.infinity);
    return AppleDownloadTaskSlice(
      key: ValueKey<String>('video-subscription-card-$id'),
      index: index,
      count: count,
      separatorIndent:
          metrics.rowHorizontal + (metrics.desktop ? 24 : 32) * k + 12 * k,
      child: Builder(
        builder: (BuildContext rowContext) => GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapUp: (TapUpDetails details) =>
              unawaited(_openMenu(rowContext, at: details.globalPosition)),
          child: FushiPressScale(
            enabled: tap != null,
            child: FushiAppleRow(
              onTap: tap,
              onLongPress: () => unawaited(_openMenu(rowContext)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  content,
                  FushiAnimatedSize(
                    duration: fushiMotionDuration(context, FushiMotion.medium),
                    curve: FushiMotion.standard,
                    alignment: Alignment.topCenter,
                    child: history,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
