// 反馈页面共用：状态 / 分类文案、状态徽标、错误转人话、时间线、图片压缩、入口。

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:fushi/src/feedback/feedback_entry_gate.dart';
import 'package:fushi/src/feedback/feedback_fix_progress.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/feedback/feedback_video.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_center_page.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_detail_page.dart';
import 'package:fushi/src/utils/misc/clipboard_image.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 打开反馈中心。[captureScreen] 时先截下当前画面（打开前截，截到的是用户正在看的
/// 页面），作为新反馈的默认截图。首页按钮与悬浮球共用这一个入口。
///
/// 经 [feedbackEntryGate]：已经开着时忽略重复点击；有页面转场在跑时等它走完再截，
/// 不会截到两页叠在一起的中间帧（BUG-3097）。
Future<void> openFeedbackCenter(
  BuildContext context, {
  bool captureScreen = true,
}) => feedbackEntryGate.open(
  context,
  captureScreen: captureScreen,
  route: (Uint8List? shot) => adaptivePageRoute<void>(
    context: context,
    builder: (_) => FeedbackCenterPage(initialScreenshot: shot),
  ),
);

/// 点了「开发者回复了你的反馈」的系统通知：直达那条反馈的详情。本机清单里已经没有
/// 这条（用户删了）就退到反馈中心。清单可能还没加载（被通知冷启动），先等它。
/// [context] 是根 navigator 的 context（通知回调里只有它）。
Future<void> openFeedbackTicket(BuildContext context, String feedbackId) async {
  final FeedbackService service = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(feedbackServiceProvider);
  await service.load();
  if (!context.mounted) return;
  if (service.byId(feedbackId) == null) {
    await openFeedbackCenter(context, captureScreen: false);
    return;
  }
  await Navigator.of(context).push(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => FeedbackDetailPage(feedbackId: feedbackId),
    ),
  );
}

String feedbackStatusLabel(FeedbackStatus status) => switch (status) {
  FeedbackStatus.open => t.feedback_status_open,
  FeedbackStatus.inProgress => t.feedback_status_in_progress,
  FeedbackStatus.resolved => t.feedback_status_resolved,
  FeedbackStatus.wontFix => t.feedback_status_wont_fix,
  FeedbackStatus.duplicate => t.feedback_status_duplicate,
  FeedbackStatus.closed => t.feedback_status_closed,
};

String feedbackCategoryLabel(FeedbackCategory category) => switch (category) {
  FeedbackCategory.bug => t.feedback_category_bug,
  FeedbackCategory.suggestion => t.feedback_category_suggestion,
  FeedbackCategory.other => t.feedback_category_other,
};

IconData feedbackCategoryIcon(FeedbackCategory category) => switch (category) {
  FeedbackCategory.bug => FushiIcons.error,
  FeedbackCategory.suggestion => FushiIcons.lightbulb,
  FeedbackCategory.other => FushiIcons.forum,
};

/// 服务端 / 网络错误 → 一句人话（提交失败、刷新失败共用）。
String feedbackErrorReason(Object error) {
  if (error is LeaderboardApiException) {
    if (error.status == 409 && error.code == 'duplicate_feedback') {
      return t.feedback_error_duplicate;
    }
    if (error.status == 429) return t.feedback_error_rate_limited;
    if (error.status == 503 || error.status == 507) {
      return t.feedback_error_unavailable;
    }
    return error.code;
  }
  return t.feedback_error_network;
}

/// 视频准备阶段的错误（太大 / 不是视频）给用户看的完整一句；别的错误返回 null
/// （调用方按 [feedbackErrorReason] 走通用文案）。
String? feedbackVideoErrorText(Object error) => switch (error) {
  FeedbackVideoTooLargeException(:final int bytes) =>
    t.feedback_video_too_large(
      size: FushiByteFormat.bytes(bytes),
      max: FushiByteFormat.bytes(FeedbackLimits.videoMaxBytes),
    ),
  FeedbackVideoUnsupportedException() => t.feedback_video_unsupported,
  _ => null,
};

/// 显示用户文字前剥掉伪装字符（双向控制符 / 零宽字符，emoji 的 ZWJ 保留）。服务端
/// 提交时已剥过，这里是纵深防御：旧数据或绕过服务端的内容也不会在处理台里「看到的和
/// 实际的不一样」。
String feedbackSafeText(String s) => s.replaceAll(
  RegExp(
    '[\u200B\u200C\u200E\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF\u00AD]',
  ),
  '',
);

String feedbackFlagLabel(FeedbackFlag flag) => switch (flag) {
  FeedbackInjectionFlag() => t.feedback_dev_flag_injection,
  FeedbackHiddenCharsFlag() => t.feedback_dev_flag_hidden_chars,
  FeedbackLinksFlag() => t.feedback_dev_flag_links,
  FeedbackDuplicateFlag(:final String ofId) => t.feedback_dev_flag_duplicate(
    id: ofId,
  ),
};

/// 风险标记徽标（开发者列表 / 详情）。不认识的标记不显示。
class FeedbackFlagChips extends StatelessWidget {
  const FeedbackFlagChips(this.flags, {super.key});

  final List<String> flags;

  @override
  Widget build(BuildContext context) {
    final List<FeedbackFlag> parsed = <FeedbackFlag>[
      for (final String raw in flags) ?FeedbackFlag.parse(raw),
    ];
    if (parsed.isEmpty) return const SizedBox.shrink();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: tokens.spacing.gap / 2,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        for (final FeedbackFlag f in parsed)
          DecoratedBox(
            key: ValueKey<String>('feedback-flag-${f.runtimeType}'),
            decoration: ShapeDecoration(
              color: colors.errorContainer,
              shape: const StadiumBorder(),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: Text(
                feedbackFlagLabel(f),
                style: tokens.type.metadata.copyWith(
                  color: colors.onErrorContainer,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String feedbackTime(int ms) =>
    FushiTimeFormat.dateHourMinute(DateTime.fromMillisecondsSinceEpoch(ms));

/// 状态徽标：未结案用强调色，已解决用成功色，其余中性。
class FeedbackStatusBadge extends StatelessWidget {
  const FeedbackStatusBadge(this.status, {super.key});

  final FeedbackStatus status;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final (Color bg, Color fg) = switch (status) {
      FeedbackStatus.open => (
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      FeedbackStatus.inProgress => (
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      FeedbackStatus.resolved => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      _ => (colors.outlineVariant, colors.onSurface),
    };
    return DecoratedBox(
      decoration: ShapeDecoration(color: bg, shape: const StadiumBorder()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Text(
          feedbackStatusLabel(status),
          style: tokens.type.metadata.copyWith(color: fg),
        ),
      ),
    );
  }
}

/// 列表上「已修复」的短标签（反馈中心每条反馈的副标题）。
String feedbackFixLabel(FeedbackFixProgress progress) => switch (progress) {
  FeedbackFixNoUpdateNeeded() => t.feedback_fix_no_update_needed,
  FeedbackFixInstalled() => t.feedback_fix_installed_label,
  FeedbackFixUpdateAvailable(:final String version) => t.feedback_fix_released(
    version: version,
  ),
  FeedbackFixFasterChannelOnly() ||
  FeedbackFixPlatformNotTracked() ||
  FeedbackFixPending() => t.feedback_fix_label,
};

/// 反馈人详情页状态区的修复进度：一句话 + 下一步（「检查更新」/「切换到 X 通道」）。
/// 通道 / 平台 / 本机版本取自 [feedbackFixEnvironmentProvider]。
class FeedbackFixNotice extends ConsumerStatefulWidget {
  const FeedbackFixNotice(this.fix, {super.key});

  final FeedbackFix fix;

  @override
  ConsumerState<FeedbackFixNotice> createState() => _FeedbackFixNoticeState();
}

class _FeedbackFixNoticeState extends ConsumerState<FeedbackFixNotice> {
  bool _switching = false;

  /// 切到更快的通道：先说明不稳定、用户确认后才写入；写完原地刷新进度
  /// （新通道已发布 → 变成「已在 X 修复」+「检查更新」）。
  Future<void> _switch(FeedbackFixEnvironment env, UpdateChannel to) async {
    final bool debug = to == UpdateChannel.debug;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: debug
          ? t.update_debug_channel
          : t.feedback_fix_channel_beta_switch,
      message: debug
          ? t.update_debug_channel_warning
          : t.feedback_fix_channel_beta_switch_confirm,
      confirmLabel: debug
          ? t.feedback_fix_channel_debug_switch
          : t.feedback_fix_channel_beta_switch,
      icon: FushiIcons.warning,
    );
    if (!ok || !mounted) return;
    setState(() => _switching = true);
    try {
      await env.switchChannel(to);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Widget _action({
    required String key,
    required String label,
    required VoidCallback? onPressed,
  }) => FushiPressScale(
    enabled: onPressed != null,
    child: FushiFilledButton.tonal(
      key: ValueKey<String>(key),
      onPressed: onPressed,
      child: Text(label),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final FeedbackFixEnvironment env = ref.watch(
      feedbackFixEnvironmentProvider,
    );
    final FeedbackFixProgress progress = env.progress(widget.fix);
    final (
      FushiNoticeSeverity severity,
      IconData icon,
      String? title,
      String message,
      List<Widget> actions,
    ) = switch (progress) {
      FeedbackFixNoUpdateNeeded() => (
        FushiNoticeSeverity.success,
        FushiIcons.verified,
        null,
        t.feedback_fix_no_update_needed,
        const <Widget>[],
      ),
      FeedbackFixInstalled() => (
        FushiNoticeSeverity.success,
        FushiIcons.verified,
        null,
        t.feedback_fix_installed,
        const <Widget>[],
      ),
      FeedbackFixUpdateAvailable(:final String version) => (
        FushiNoticeSeverity.info,
        FushiIcons.check,
        null,
        t.feedback_fix_released(version: version),
        <Widget>[
          _action(
            key: 'feedback-fix-check-update',
            label: t.settings_check_update_now,
            onPressed: () => unawaited(env.checkForUpdate(context)),
          ),
        ],
      ),
      FeedbackFixFasterChannelOnly(
        :final UpdateChannel current,
        :final UpdateChannel channel,
        :final String version,
      ) =>
        (
          FushiNoticeSeverity.info,
          FushiIcons.check,
          current == UpdateChannel.beta
              ? t.feedback_fix_next_beta
              : t.feedback_fix_next_stable,
          channel == UpdateChannel.debug
              ? t.feedback_fix_faster_debug_available(version: version)
              : t.feedback_fix_faster_beta_available(version: version),
          <Widget>[
            if (env.canSwitchChannel)
              _action(
                key: 'feedback-fix-switch-channel',
                label: channel == UpdateChannel.debug
                    ? t.feedback_fix_channel_debug_switch
                    : t.feedback_fix_channel_beta_switch,
                onPressed: _switching
                    ? null
                    : () => unawaited(_switch(env, channel)),
              ),
          ],
        ),
      FeedbackFixPlatformNotTracked() => (
        FushiNoticeSeverity.info,
        FushiIcons.check,
        null,
        t.feedback_fix_platform_not_tracked,
        const <Widget>[],
      ),
      FeedbackFixPending(:final bool building, :final UpdateChannel channel) =>
        (
          FushiNoticeSeverity.info,
          FushiIcons.schedule,
          null,
          building
              ? t.feedback_fix_building
              : channel == UpdateChannel.stable
              ? t.feedback_fix_pending_stable
              : t.feedback_fix_pending,
          const <Widget>[],
        ),
    };
    // 进度变化（例如切换通道后）淡入新文案，不是硬切。
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      child: FushiInlineNotice(
        key: ValueKey<String>('feedback-fix-${progress.runtimeType}'),
        severity: severity,
        icon: icon,
        title: title,
        message: message,
        actions: actions,
      ),
    );
  }
}

/// 处理记录时间线（反馈人与开发者两边的详情页共用）。
/// 反馈编号（服务端 id）：`#svSfwFdmdM` 等宽小字，点按或长按复制。
class FeedbackIdLabel extends StatelessWidget {
  const FeedbackIdLabel(this.id, {this.style, super.key});

  final String id;
  final TextStyle? style;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: id));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(FushiSnackBar(content: Text(t.feedback_id_copied)));
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiTooltip(
      message: t.feedback_id_copy_hint,
      child: Semantics(
        button: true,
        label: '${t.feedback_id_copy_hint} $id',
        excludeSemantics: true,
        child: InkWell(
          key: ValueKey<String>('feedback-id-$id'),
          borderRadius: FushiM3eShape.smallRadius,
          onTap: () => unawaited(_copy(context)),
          onLongPress: () => unawaited(_copy(context)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: Text(
              '#$id',
              style: (style ?? tokens.type.metadata).copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情页抬头那一行：分类 · #编号（可复制）· 提交时间。
class FeedbackMetaLine extends StatelessWidget {
  const FeedbackMetaLine(this.detail, {super.key});

  final FeedbackDetail detail;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = FushiDesignTokens.of(context).type.metadata;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          '${feedbackCategoryLabel(detail.summary.category)} · ',
          style: style,
        ),
        FeedbackIdLabel(detail.id, style: style),
        Text(' · ${feedbackTime(detail.summary.createdAt)}', style: style),
      ],
    );
  }
}

/// 「重新提交」关联：新反馈上「重新提交自 #原编号」、原反馈上「已被重新提交为 #新编号」。
/// [onOpen] 给了就能点过去；[canOpen] 判某一条打不打得开（反馈人那边，别的设备提交的
/// 那条本机没有 ticket 看不了）。打不开的只显示成不可点的标签，不画成能点的 chip
/// （BUG-3243：以前画成 chip、点了没反应）。
class FeedbackRelationLinks extends StatelessWidget {
  const FeedbackRelationLinks({
    required this.parentId,
    required this.reopenedAs,
    this.onOpen,
    this.canOpen,
    super.key,
  });

  final String? parentId;
  final List<String> reopenedAs;
  final void Function(String id)? onOpen;

  /// null = 凡是给了 [onOpen] 都能打开。
  final bool Function(String id)? canOpen;

  @override
  Widget build(BuildContext context) {
    if (parentId == null && reopenedAs.isEmpty) return const SizedBox.shrink();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final void Function(String id)? open = onOpen;
    Widget link(String id, String label) =>
        open != null && (canOpen?.call(id) ?? true)
        ? FushiActionChip(
            key: ValueKey<String>('feedback-relation-$id'),
            icon: FushiIcons.link,
            label: label,
            onPressed: () => open(id),
          )
        : FushiTag(
            key: ValueKey<String>('feedback-relation-$id'),
            icon: FushiIcons.link,
            text: label,
            tone: FushiTagTone.neutral,
            dense: true,
          );
    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        if (parentId != null)
          link(parentId!, t.feedback_reopen_of(id: parentId!)),
        for (final String id in reopenedAs)
          link(id, t.feedback_reopened_as(id: id)),
      ],
    );
  }
}

/// 「我的反馈」本机搜索：编号 / 标题 / 正文，统一归一化口径。
List<FeedbackTicket> filterFeedbackTickets(
  List<FeedbackTicket> tickets,
  String query,
) => filterByMediaSearch<FeedbackTicket>(
  tickets,
  query,
  (FeedbackTicket x) => <String>[x.id, x.title, x.body],
);

/// 反馈中心（反馈人）的状态筛选：比处理台少，只分「还在处理 / 已结案 / 有新回复」。
enum FeedbackTicketFilter { all, active, closed, unread }

String feedbackTicketFilterLabel(FeedbackTicketFilter filter) =>
    switch (filter) {
      FeedbackTicketFilter.all => t.feedback_filter_all,
      FeedbackTicketFilter.active => t.feedback_filter_active,
      FeedbackTicketFilter.closed => t.feedback_filter_closed,
      FeedbackTicketFilter.unread => t.feedback_filter_unread,
    };

/// 服务端已查不到（[FeedbackTicket.missing]）的条目状态不可信，只出现在「全部」里。
bool feedbackTicketMatchesFilter(
  FeedbackTicket ticket,
  FeedbackTicketFilter filter,
) => switch (filter) {
  FeedbackTicketFilter.all => true,
  FeedbackTicketFilter.active => !ticket.missing && !ticket.status.isClosed,
  FeedbackTicketFilter.closed => !ticket.missing && ticket.status.isClosed,
  FeedbackTicketFilter.unread => ticket.hasUnseenReply,
};

/// 反馈中心与处理台共用的分栏判据：宽够放下两栏，且是横向的（桌面窗口 / 平板横置）。
const double kFeedbackSplitMinWidth = 840;

/// 分栏时左列表的宽度。
const double kFeedbackSplitListWidth = 400;

/// 不分栏时列表的最大内容宽度：宽窗口里列表居中，不拉满整屏。
const double kFeedbackListMaxWidth = 720;

bool useFeedbackSplit(BoxConstraints c) =>
    c.maxWidth >= kFeedbackSplitMinWidth && c.maxWidth > c.maxHeight;

/// 反馈列表的左右内边距：窄屏是卡片边距，宽而不分栏时把内容收到
/// [kFeedbackListMaxWidth] 居中（滚动区仍是整宽，两侧空白也能拖动 / 下拉刷新）。
double feedbackListHorizontalPadding(double width, double base) =>
    math.max(base, (width - kFeedbackListMaxWidth) / 2);

/// 左列表右详情。[detailBuilder] 按 [selectedId] 出右栏；没选中时给 [emptyMessage]。
/// 窄屏 / 竖屏只出列表（点击由调用方 push 详情页）。分栏状态经 [listBuilder] 传回，
/// 调用方据此决定点击是选中还是 push。
class FeedbackSplitLayout extends StatelessWidget {
  const FeedbackSplitLayout({
    required this.keyPrefix,
    required this.listBuilder,
    required this.detailBuilder,
    required this.selectedId,
    required this.emptyMessage,
    super.key,
  });

  /// 分栏行与空占位的 key 前缀（`<prefix>-split` / `<prefix>-split-empty`）。
  final String keyPrefix;
  final Widget Function(BuildContext context, bool split, double hPadding)
  listBuilder;
  final Widget Function(String id) detailBuilder;
  final String? selectedId;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final double base = FushiDesignTokens.of(context).spacing.card;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!useFeedbackSplit(constraints)) {
          return listBuilder(
            context,
            false,
            feedbackListHorizontalPadding(constraints.maxWidth, base),
          );
        }
        final String? id = selectedId;
        return Row(
          key: ValueKey<String>('$keyPrefix-split'),
          children: <Widget>[
            SizedBox(
              width: kFeedbackSplitListWidth,
              child: listBuilder(context, true, base),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: id == null
                  ? FushiPlaceholderMessage(
                      key: ValueKey<String>('$keyPrefix-split-empty'),
                      icon: FushiIcons.forum,
                      message: emptyMessage,
                    )
                  : detailBuilder(id),
            ),
          ],
        );
      },
    );
  }
}

/// 反馈列表的紧凑行（反馈中心与处理台共用）：分类图标、标题、
/// 「元信息 · #编号」一行，[details] 是各自的附加行，[badges] 排在状态徽标前。
class FeedbackListTile extends StatelessWidget {
  const FeedbackListTile({
    required this.id,
    required this.category,
    required this.title,
    required this.meta,
    required this.status,
    required this.onTap,
    this.selected = false,
    this.details = const <Widget>[],
    this.badges = const <Widget>[],
    super.key,
  });

  final String id;
  final FeedbackCategory category;
  final String title;
  final String meta;
  final FeedbackStatus status;
  final VoidCallback onTap;
  final bool selected;
  final List<Widget> details;
  final List<Widget> badges;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap / 2),
      child: FushiCard(
        onTap: onTap,
        selected: selected,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.gap,
          vertical: tokens.spacing.gap / 2,
        ),
        child: FushiListItem(
          density: FushiListDensity.compact,
          leading: FushiIcon(feedbackCategoryIcon(category)),
          title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: tokens.spacing.gap / 2,
                children: <Widget>[Text(meta), FeedbackIdLabel(id)],
              ),
              ...details,
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final Widget b in badges)
                Padding(padding: const EdgeInsets.only(right: 8), child: b),
              FeedbackStatusBadge(status),
            ],
          ),
        ),
      ),
    );
  }
}

class FeedbackTimeline extends StatelessWidget {
  const FeedbackTimeline({
    required this.messages,
    this.developerView = false,
    super.key,
  });

  final List<FeedbackMessage> messages;

  /// 开发者处理页：反馈人的消息标「反馈人」而不是「你」。
  final bool developerView;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (messages.isEmpty) {
      return Text(
        t.feedback_detail_no_messages,
        style: tokens.type.listSubtitle,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < messages.length; i++)
          FushiStaggeredEntrance(
            index: i,
            child: _FeedbackMessageTile(
              message: messages[i],
              developerView: developerView,
              tokens: tokens,
              colors: colors,
            ),
          ),
      ],
    );
  }
}

class _FeedbackMessageTile extends StatelessWidget {
  const _FeedbackMessageTile({
    required this.message,
    required this.developerView,
    required this.tokens,
    required this.colors,
  });

  final FeedbackMessage message;
  final bool developerView;
  final FushiDesignTokens tokens;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final FeedbackMessage m = message;
    final String who = m.fromDeveloper
        ? t.feedback_detail_developer(name: m.nickname ?? '')
        : developerView
        ? t.feedback_dev_reporter
        : t.feedback_detail_you;
    final FeedbackStatus? status = m.status;
    // 反馈人在详情页点「标记为已完成」留下的事件。
    final bool reporterClosed =
        !m.fromDeveloper && status == FeedbackStatus.closed;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              width: 3,
              color: m.fromDeveloper ? colors.primary : colors.outlineVariant,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '$who · ${feedbackTime(m.createdAt)}',
                style: tokens.type.metadata,
              ),
              if (status != null)
                Text(
                  reporterClosed
                      ? (developerView
                            ? t.feedback_timeline_reporter_closed
                            : t.feedback_timeline_you_closed)
                      : t.feedback_detail_status_changed(
                          status: feedbackStatusLabel(status),
                        ),
                  style: tokens.type.metadata.copyWith(color: colors.primary),
                ),
              if (m.body.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: SelectableText(feedbackSafeText(m.body)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 用户选的图：是 PNG / JPEG / WebP、字节数与宽高都在服务端上限内就原样用，否则缩到
/// 长边 [kFeedbackScreenshotMaxSide] 再存 JPEG。解码 / 编码在后台 isolate。不是图片抛
/// [FormatException]。
Future<Uint8List> prepareFeedbackImage(Uint8List bytes) =>
    Isolate.run<Uint8List>(() => prepareFeedbackImageBytes(bytes));

/// [prepareFeedbackImage] 的同步内核（纯函数，可单测）。
///
/// 原样放行的图必须同时满足服务端的全部收图条件（`services/leaderboard` 的
/// `slotKind`：字节数、能读出宽高、单边与总像素上限）：只看字节数会把 Android 长截图
/// （如 1080×9000 PNG，几百 KB）原样放过去，服务端回 415 `bad_image_dimensions`，
/// 附件永远传不上去。
Uint8List prepareFeedbackImageBytes(Uint8List bytes) {
  final bool known =
      (bytes.length > 3 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff) ||
      (bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50) ||
      (bytes.length > 12 &&
          String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP');
  if (known &&
      bytes.length <= FeedbackLimits.screenshotMaxBytes &&
      feedbackImageDimensionsAcceptable(bytes)) {
    return bytes;
  }
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    decoded = null;
  }
  if (decoded == null) throw const FormatException('not a decodable image');
  final int longest = math.max(decoded.width, decoded.height);
  img.Image out = decoded;
  if (longest > kFeedbackScreenshotMaxSide) {
    out = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: kFeedbackScreenshotMaxSide)
        : img.copyResize(decoded, height: kFeedbackScreenshotMaxSide);
  }
  int quality = 85;
  Uint8List jpg = img.encodeJpg(out, quality: quality);
  while (jpg.length > FeedbackLimits.screenshotMaxBytes && quality > 40) {
    quality -= 15;
    jpg = img.encodeJpg(out, quality: quality);
  }
  return jpg;
}

/// 只读文件头（不解码像素）判断宽高是否在服务端可接受范围内：单边不超过
/// [FeedbackLimits.screenshotMaxSide]、总像素不超过 [FeedbackLimits.screenshotMaxPixels]、
/// 宽高都大于 0。读不出宽高按不可接受处理（服务端同样拒收），交给解码重编码那条路。
bool feedbackImageDimensionsAcceptable(Uint8List bytes) {
  final img.DecodeInfo? info;
  try {
    info = img.findDecoderForData(bytes)?.startDecode(bytes);
  } on Object {
    return false;
  }
  if (info == null) return false;
  final int w = info.width;
  final int h = info.height;
  return w > 0 &&
      h > 0 &&
      w <= FeedbackLimits.screenshotMaxSide &&
      h <= FeedbackLimits.screenshotMaxSide &&
      w * h <= FeedbackLimits.screenshotMaxPixels;
}

/// 从文件管理器复制的文件里，按扩展名认作图片的那些。
const Set<String> kFeedbackClipboardImageExtensions = <String>{
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.bmp',
  '.gif',
};

/// 被复制的单个图片文件读取上限：再大就不是截图了，也不该整个读进内存。
const int kFeedbackClipboardFileMaxBytes = 64 * 1024 * 1024;

/// 从系统剪贴板取出可加入反馈的图片，最多 [limit] 张，每张已按反馈上限处理过
/// （[prepareFeedbackImage]：超限转 JPEG 缩小）。
///
/// 截图工具放进来的位图优先，其次是在文件管理器里复制的图片文件（按扩展名过滤，
/// 非图片文件跳过）。剪贴板里没有图片返回空表；读剪贴板本身失败照常抛出。单个文件
/// 读不了 / 解不出来只跳过那一个并记日志。
Future<List<Uint8List>> readFeedbackImagesFromClipboard({
  required int limit,
}) async {
  if (limit <= 0) return const <Uint8List>[];
  final ClipboardImageData? data = await readClipboardImage();
  if (data == null) return const <Uint8List>[];
  final List<Uint8List> raw = <Uint8List>[?data.bytes];
  for (final String path in data.paths) {
    if (raw.length >= limit) break;
    if (!kFeedbackClipboardImageExtensions.contains(
      p.extension(path).toLowerCase(),
    )) {
      continue;
    }
    try {
      final File file = File(path);
      if (await file.length() > kFeedbackClipboardFileMaxBytes) continue;
      raw.add(await file.readAsBytes());
    } on FileSystemException catch (e, st) {
      ErrorLogService.instance.log('feedback.paste_image_file', e, st);
    }
  }
  final List<Uint8List> out = <Uint8List>[];
  for (final Uint8List bytes in raw.take(limit)) {
    try {
      out.add(await prepareFeedbackImage(bytes));
    } on FormatException catch (e, st) {
      ErrorLogService.instance.log('feedback.paste_image_decode', e, st);
    }
  }
  return out;
}

/// 反馈中心入口按钮上的未读数（有开发者新进展）。
int watchFeedbackUnseen(WidgetRef ref) => ref.watch(
  feedbackServiceProvider.select((FeedbackService s) => s.unseenCount),
);

/// 反馈回复提示条停留多久后自动收起。
const Duration kFeedbackReplyNoticeDuration = Duration(seconds: 6);

/// 开发者有新回复 / 改了状态时的应用内提示（snackbar，带「查看」直达反馈中心）。
/// [context] 要在导航之下（有 ScaffoldMessenger）；找不到就静默放弃——红点照常亮。
///
/// 这是被动的「有新进展」提醒，不是要用户拍板的决定：显式 `persist: false`，
/// 到 [kFeedbackReplyNoticeDuration] 自己收起。带动作的 SnackBar 默认常驻，
/// 曾经一直钉在底部、挡住反馈页的提交按钮（反馈 eiFcN3DZQ3）；错过了也无妨，
/// 入口按钮上的未读红点照常亮。
void showFeedbackReplyNotice(BuildContext context, int count) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null || count <= 0) return;
  messenger.showSnackBar(
    FushiSnackBar(
      key: const ValueKey<String>('feedback-reply-notice'),
      persist: false,
      duration: kFeedbackReplyNoticeDuration,
      content: Text(t.feedback_reply_notice(n: count)),
      action: SnackBarAction(
        label: t.feedback_reply_notice_open,
        onPressed: () =>
            unawaited(openFeedbackCenter(context, captureScreen: false)),
      ),
    ),
  );
}
