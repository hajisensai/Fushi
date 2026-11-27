/// 待确认身份的共享界面：库页提醒条、待确认清单、独立的待确认弹窗。
///
/// 视频、书 / 漫画、游戏三处同一套（BUG-5283）：视频的刮削任务面板把它的「待确认」
/// tab 交给 [PendingIdentityListView] 画；书架与游戏库页用 [PendingIdentityBannerHost]
/// 自己加载计数，点「去确认」开 [showPendingIdentityDialog]。各媒体只提供自己的
/// 动作（手动搜索 / AI 重试 / 视频的 AI 识别），忽略 / 撤销忽略是公共的。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';
import 'package:fushi/src/media/identity/pending_identity_text.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/apple/apple_text_style.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_engine/media/identity/pending_identity.dart';

// ─────────────────────────────────────────────────────────────────────────
// 提醒条
// ─────────────────────────────────────────────────────────────────────────

/// 提醒条该不该亮：有待确认条目，且不全是用户点「×」那一刻已经在提示的。
///
/// 「×」只记在本次会话里、不落盘：它是「知道了」，不是对这批条目下结论——要永久
/// 不再提示某一条，在待确认清单里逐条「忽略」（记得住、看得见、能撤销）。冒出
/// 一条新的待确认条目就重新亮出来（反馈 Fbchzxuq6f）。
bool pendingIdentityBannerVisible(
  Set<String> pendingKeys,
  Set<String> dismissedKeys,
) => pendingKeys.isNotEmpty && !dismissedKeys.containsAll(pendingKeys);

/// 库页顶部的待确认身份提醒条（无状态：计数与「×」状态由宿主持有）。
///
/// 这些条目刮不出资料**没有任何其他可见症状**——封面照样有（抽帧 / 首页兜底），
/// 卡片照样进库，用户只会觉得「封面怎么不对」而不知道有个确认队列在等他
/// （BUG-2201 / BUG-5283）。不该亮时零高度；出现 / 收起都带尺寸 + 淡入淡出过渡。
class PendingIdentityBanner extends StatelessWidget {
  const PendingIdentityBanner({
    super.key,
    required this.pendingKeys,
    required this.dismissedKeys,
    required this.message,
    required this.onDismiss,
    this.onOpen,
    this.keyPrefix = 'pending-identity-banner',
    this.actionLabel,
    this.dismissTooltip,
  });

  final Set<String> pendingKeys;
  final Set<String> dismissedKeys;

  /// 按条数出文案（[pendingIdentityBannerText]）。
  final String Function(int count) message;

  /// 「×」：宿主把当前的 [pendingKeys] 记成已收起。
  final VoidCallback onDismiss;

  /// 「去确认」；null 不画按钮。
  final VoidCallback? onOpen;

  /// 卡片 key = `ValueKey(keyPrefix)`，「×」= `ValueKey('$keyPrefix-dismiss')`。
  final String keyPrefix;
  final String? actionLabel;
  final String? dismissTooltip;

  @override
  Widget build(BuildContext context) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return FushiAnimatedSize(
      duration: duration,
      curve: FushiMotion.standard,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: FushiMotion.enter,
        switchOutCurve: FushiMotion.exit,
        child: pendingIdentityBannerVisible(pendingKeys, dismissedKeys)
            ? _buildCard(context)
            : const SizedBox.shrink(key: ValueKey<String>('hidden')),
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    if (isGlassDesign(context)) return _buildAppleCard(context);
    final VoidCallback? open = onOpen;
    return Padding(
      key: ValueKey<String>(keyPrefix),
      padding: const EdgeInsets.only(bottom: 8),
      child: FushiCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: <Widget>[
              const FushiIcon(FushiIcons.manageSearch, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(message(pendingKeys.length))),
              if (open != null) ...<Widget>[
                const SizedBox(width: 8),
                FushiPressScale(
                  child: FushiFilledButton.tonal(
                    key: ValueKey<String>('$keyPrefix-open'),
                    onPressed: open,
                    child: Text(
                      actionLabel ??
                          t.video_library_scrape_pending_banner_action,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              FushiIconButtonControl(
                key: ValueKey<String>('$keyPrefix-dismiss'),
                tooltip: dismissTooltip ?? t.identity_pending_banner_dismiss,
                onPressed: onDismiss,
                icon: const FushiIcon(FushiIcons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Cupertino：iOS 27 提示卡（TipKit 式）——与分组列表同一枚
  /// secondaryGroupedBackground 实色面、同心圆角，强调色单色图标 + 正文 +
  /// plain 强调色文字动作 + 灰色 xmark 关闭；不是 M3E 的 tonal 卡 + tonal 按钮。
  Widget _buildAppleCard(BuildContext context) {
    final VoidCallback? open = onOpen;
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final TextStyle body = appleTextStyle(
      context,
      size: m.subtitleSize,
      color: apple.label,
    );
    // xmark 关闭钮是正圆：半径 = 图标半宽 + 四周内边距（由度量推出，不另立圆角）。
    const double dismissPadding = 8;
    final BorderRadius dismissRadius = BorderRadius.all(
      Radius.circular(m.chevronSize / 2 + dismissPadding),
    );
    return Padding(
      key: ValueKey<String>(keyPrefix),
      padding: EdgeInsets.only(bottom: m.groupSpacing / 2),
      child: FushiAppleGroupSurface(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: m.rowHorizontal,
            vertical: m.rowVertical,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: m.rowMinHeight - 2 * m.rowVertical,
            ),
            child: Row(
              children: <Widget>[
                FushiIcon(
                  FushiIcons.manageSearch,
                  size: m.leadingIconSize,
                  color: apple.accent,
                ),
                SizedBox(width: m.leadingGap),
                Expanded(child: Text(message(pendingKeys.length), style: body)),
                if (open != null)
                  FushiTextButton(
                    key: ValueKey<String>('$keyPrefix-open'),
                    onPressed: open,
                    child: Text(
                      actionLabel ??
                          t.video_library_scrape_pending_banner_action,
                    ),
                  ),
                FushiPlainButton(
                  key: ValueKey<String>('$keyPrefix-dismiss'),
                  onPressed: onDismiss,
                  semanticLabel:
                      dismissTooltip ?? t.identity_pending_banner_dismiss,
                  borderRadius: dismissRadius,
                  child: Padding(
                    padding: const EdgeInsets.all(dismissPadding),
                    child: FushiIcon(
                      FushiIcons.close,
                      size: m.chevronSize,
                      color: apple.tertiaryLabel,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 自己加载计数的提醒条（书架 / 游戏库页用；视频页有补刮调度的专门刷新契约，
/// 直接用 [PendingIdentityBanner]）。
///
/// 进页面加载一次；[changes] 每来一次重算（库管家每趟结束、库内容变动）。加载失败
/// 保留上一次的数字：提醒条是附加信息，不打扰页面。
class PendingIdentityBannerHost extends StatefulWidget {
  const PendingIdentityBannerHost({
    super.key,
    required this.kind,
    required this.source,
    required this.onOpen,
    this.changes,
  });

  final PendingIdentityMediaKind kind;

  /// 数据源（每次加载现取：宿主的数据库 / 编排器可能换过）。null = 不显示。
  final PendingIdentitySource? Function() source;

  /// 「去确认」：通常是 [showPendingIdentityDialog]；返回后重算。
  final Future<void> Function() onOpen;
  final Stream<void>? changes;

  @override
  State<PendingIdentityBannerHost> createState() =>
      _PendingIdentityBannerHostState();
}

class _PendingIdentityBannerHostState extends State<PendingIdentityBannerHost>
    with StateResourceScope<PendingIdentityBannerHost> {
  Set<String> _pending = const <String>{};
  Set<String> _dismissed = const <String>{};
  bool _inFlight = false;
  bool _queued = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
    unawaited(_reload());
  }

  /// （重新）订阅变更流：同一槽位，换流时上一条自动取消；流为 null 时空撤销顶掉旧槽位。
  void _subscribe() {
    final Stream<void>? changes = widget.changes;
    if (changes == null) {
      onTeardown(() {}, slot: #changes);
      return;
    }
    ownSubscription(
      changes.listen((_) => unawaited(_reload())),
      slot: #changes,
    );
  }

  @override
  void didUpdateWidget(PendingIdentityBannerHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) _subscribe();
  }

  /// 在飞时又来一次：在飞那次读到的可能是旧状态，完成后再补一次（同视频页
  /// BUG-3085 的约定），不并发重复读。
  Future<void> _reload() async {
    if (_inFlight) {
      _queued = true;
      return;
    }
    _inFlight = true;
    try {
      do {
        _queued = false;
        final PendingIdentitySource? source = widget.source();
        if (source == null) return;
        try {
          final PendingIdentityListing listing = (await source.load()).only(
            widget.kind,
          );
          final Set<String> keys = <String>{
            for (final PendingIdentityEntry e in listing.pending) e.key,
          };
          if (mounted && !setEquals(keys, _pending)) {
            setState(() => _pending = keys);
          }
        } on Object {
          // 取不到就保留上一次的数字。
        }
      } while (_queued && mounted);
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _open() async {
    await widget.onOpen();
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) => PendingIdentityBanner(
    keyPrefix: 'pending-identity-banner-${widget.kind.wire}',
    pendingKeys: _pending,
    dismissedKeys: _dismissed,
    message: (int count) => pendingIdentityBannerText(widget.kind, count),
    onDismiss: () => setState(() => _dismissed = _pending),
    onOpen: () => unawaited(_open()),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// 待确认清单
// ─────────────────────────────────────────────────────────────────────────

/// 一行上的一个动作按钮。
class PendingIdentityRowAction {
  const PendingIdentityRowAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Key? key;
}

/// 清单里的一行（待确认或已忽略）。
class PendingIdentityRow {
  const PendingIdentityRow({
    required this.key,
    required this.title,
    required this.subtitle,
    this.leadingIcon = FushiIcons.folder,
    this.busy = false,
    this.actions = const <PendingIdentityRowAction>[],
    this.onSetIgnored,
    this.showIgnore = true,
  });

  /// 条目稳定键（行的 widget key 由它拼出）。
  final String key;
  final String title;
  final String subtitle;
  final IconData leadingIcon;

  /// 这一条有操作在跑：动作区换成「已提交」标签。
  final bool busy;

  /// 媒体自己的动作（手动搜索 / AI 重试……），按顺序排在「忽略」之前。
  final List<PendingIdentityRowAction> actions;

  /// 忽略 / 撤销忽略（待确认行是「忽略」，已忽略行是「撤销」）；切换在飞时为
  /// null（按钮置灰）。
  final VoidCallback? onSetIgnored;

  /// 画不画「忽略」按钮（宿主没接忽略存储时不画）。
  final bool showIgnore;
}

/// 待确认清单本体（无状态）：可选的结论卡 → 待确认各行（或加载 / 出错 / 为空的
/// 占位）→「已忽略（n）」分组头 + 各行。全部在**一个**滚动列表里：结论卡与
/// 占位不钉在列表外，矮窗口不会溢出。列表项错峰入场。
///
/// widget key（视频沿用既有的测试 key，[keyPrefix] = `video-source`）：
/// 列表 `PageStorageKey('$keyPrefix-pending-list')`，行 `'$keyPrefix-pending-work-<键>'`、
/// 原因 `'$keyPrefix-pending-reason-<键>'`、忽略 `'$keyPrefix-pending-ignore-<键>'`，
/// 已忽略头 `'$keyPrefix-ignored-header'`、行 `'$keyPrefix-ignored-work-<键>'`、
/// 撤销 `'$keyPrefix-ignored-restore-<键>'`。
class PendingIdentityListView extends StatelessWidget {
  const PendingIdentityListView({
    super.key,
    required this.keyPrefix,
    required this.pending,
    required this.ignored,
    required this.loading,
    required this.error,
    required this.onReload,
    this.notice,
    this.emptyMessage,
    this.ignoredHint,
    this.busyLabel,
  });

  final String keyPrefix;
  final List<PendingIdentityRow> pending;
  final List<PendingIdentityRow> ignored;
  final bool loading;
  final Object? error;
  final Future<void> Function() onReload;

  /// 最近一次操作的结论（AI 识别结果、错误），画在列表最前。
  final String? notice;
  final String? emptyMessage;
  final String? ignoredHint;

  /// 行在忙时的标签（默认「已提交」）。
  final String? busyLabel;

  @override
  Widget build(BuildContext context) {
    Widget? status;
    if (loading) {
      status = const FushiLoadingView();
    } else if (error case final Object e) {
      status = FushiPlaceholderMessage(
        tone: FushiPlaceholderTone.error,
        icon: FushiIcons.error,
        message: t.video_source_scrape_list_load_failed,
        detail: e.toString(),
        action: FushiFilledButton.tonalIcon(
          onPressed: () => unawaited(onReload()),
          icon: const FushiIcon(FushiIcons.refresh, size: 18),
          label: Text(t.video_source_scrape_list_reload),
        ),
      );
    } else if (pending.isEmpty) {
      status = FushiPlaceholderMessage(
        icon: FushiIcons.success,
        message: emptyMessage ?? t.identity_pending_empty,
      );
    }
    final int count = status == null ? pending.length : 1;
    final String? note = notice;
    final int lead = note == null ? 0 : 1;
    // 已忽略的接在待确认后面；加载中 / 出错时不画，免得和占位互相打架。
    final List<PendingIdentityRow> ignoredRows = loading || error != null
        ? const <PendingIdentityRow>[]
        : ignored;
    final int tail = ignoredRows.isEmpty ? 0 : 1 + ignoredRows.length;
    return FushiEntranceScope(
      child: ListView.builder(
        key: PageStorageKey<String>('$keyPrefix-pending-list'),
        itemCount: lead + count + tail,
        itemBuilder: fushiStaggeredItemBuilder((
          BuildContext context,
          int position,
        ) {
          if (note != null && position == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _NoticeCard(note),
            );
          }
          if (position >= lead + count) {
            final int index = position - lead - count - 1;
            return index < 0
                ? _buildIgnoredHeader(context, ignoredRows.length)
                : _buildIgnoredRow(ignoredRows, index);
          }
          if (status != null) return status;
          return _buildPendingRow(pending, position - lead);
        }),
      ),
    );
  }

  Widget _buildPendingRow(List<PendingIdentityRow> rows, int index) {
    final PendingIdentityRow row = rows[index];
    return FushiGroupedListItem(
      index: index,
      count: rows.length,
      child: FushiListItem(
        key: ValueKey<String>('$keyPrefix-pending-work-${row.key}'),
        density: FushiListDensity.compact,
        leading: FushiListLeadingIcon(row.leadingIcon, size: 36, iconSize: 20),
        title: Text(row.title),
        subtitle: Text(
          row.subtitle,
          key: ValueKey<String>('$keyPrefix-pending-reason-${row.key}'),
        ),
        trailing: row.busy
            ? FushiTag(
                dense: true,
                tone: FushiTagTone.accent,
                icon: FushiIcons.pending,
                text: busyLabel ?? t.video_source_scrape_queue_submitted,
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (final PendingIdentityRowAction a in row.actions)
                    FushiIconButtonControl(
                      key: a.key,
                      tooltip: a.tooltip,
                      onPressed: a.onPressed,
                      icon: FushiIcon(a.icon),
                    ),
                  if (row.showIgnore)
                    FushiIconButtonControl(
                      key: ValueKey<String>(
                        '$keyPrefix-pending-ignore-${row.key}',
                      ),
                      tooltip: t.video_source_scrape_pending_ignore,
                      onPressed: row.onSetIgnored,
                      icon: const FushiIcon(FushiIcons.visibilityOff),
                    ),
                ],
              ),
      ),
    );
  }

  /// 「已忽略（n）」分组头 + 一行说明：忽略意味着什么。
  Widget _buildIgnoredHeader(BuildContext context, int n) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    return Padding(
      key: ValueKey<String>('$keyPrefix-ignored-header'),
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.video_source_scrape_pending_ignored_header(count: n),
            style: type.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            ignoredHint ?? t.identity_pending_ignored_hint,
            style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildIgnoredRow(List<PendingIdentityRow> rows, int index) {
    final PendingIdentityRow row = rows[index];
    return FushiGroupedListItem(
      index: index,
      count: rows.length,
      child: FushiListItem(
        key: ValueKey<String>('$keyPrefix-ignored-work-${row.key}'),
        density: FushiListDensity.compact,
        leading: const FushiListLeadingIcon(
          FushiIcons.visibilityOff,
          size: 36,
          iconSize: 20,
        ),
        title: Text(row.title),
        subtitle: Text(row.subtitle),
        trailing: FushiIconButtonControl(
          key: ValueKey<String>('$keyPrefix-ignored-restore-${row.key}'),
          tooltip: t.video_source_scrape_pending_ignored_restore,
          onPressed: row.onSetIgnored,
          icon: const FushiIcon(FushiIcons.undo),
        ),
      ),
    );
  }
}

/// 结论卡（tertiary 色块 + AI 图标 + 可选中文案）。
class _NoticeCard extends StatelessWidget {
  const _NoticeCard(this.notice);

  final String notice;

  @override
  Widget build(BuildContext context) => FushiCard(
    tone: FushiCardTone.tertiary,
    padding: const EdgeInsets.all(12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const FushiIcon(FushiIcons.ai, size: 20),
        const SizedBox(width: 10),
        Expanded(child: SelectableText(notice)),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// 独立的待确认弹窗（书 / 漫画、游戏）
// ─────────────────────────────────────────────────────────────────────────

/// 一种媒体在待确认弹窗里的动作。返回的字符串是结论卡文案（null = 不显示）；
/// 动作结束后弹窗重读清单。
class PendingIdentityActions {
  const PendingIdentityActions({this.identifyManually, this.retryWithAi});

  /// 「手动搜索」：开该媒体既有的刮削界面。
  final Future<String?> Function(BuildContext context, PendingIdentityEntry e)?
  identifyManually;

  /// 「让 AI 重试」：对这一条重跑自动刮削（[BuildContext] 用于弹「会发送什么」的
  /// 一次性同意）。null = 不画（AI 模块关着时宿主传 null）。
  final Future<String?> Function(BuildContext context, PendingIdentityEntry e)?
  retryWithAi;
}

/// 打开 [kind] 的待确认弹窗。
Future<void> showPendingIdentityDialog({
  required BuildContext context,
  required PendingIdentityMediaKind kind,
  required PendingIdentitySource source,
  required PendingIdentityActions actions,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext context) =>
      PendingIdentityDialog(kind: kind, source: source, actions: actions),
);

/// 待确认弹窗（导出便于 widget 测试直接构造）。
class PendingIdentityDialog extends StatefulWidget {
  const PendingIdentityDialog({
    super.key,
    required this.kind,
    required this.source,
    required this.actions,
  });

  final PendingIdentityMediaKind kind;
  final PendingIdentitySource source;
  final PendingIdentityActions actions;

  @override
  State<PendingIdentityDialog> createState() => _PendingIdentityDialogState();
}

class _PendingIdentityDialogState extends State<PendingIdentityDialog> {
  PendingIdentityListing _listing = PendingIdentityListing.empty;
  bool _loading = true;
  Object? _error;
  String? _notice;
  int _generation = 0;
  final Set<String> _busy = <String>{};
  final Set<String> _toggling = <String>{};

  String get _prefix => 'identity-${widget.kind.wire}';

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    // 动作（AI 重试 / 手动搜索）跑着时用户可能已关掉弹窗：动作回来后不再重读。
    if (!mounted) return;
    final int generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final PendingIdentityListing listing = (await widget.source.load()).only(
        widget.kind,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _setIgnored(
    PendingIdentityEntry e, {
    required bool ignored,
  }) async {
    setState(() {
      _toggling.add(e.key);
      _notice = null;
    });
    try {
      await widget.source.setIgnored(<String>[e.key], ignored: ignored);
      await _reload();
    } on Object catch (error) {
      if (mounted) setState(() => _notice = error.toString());
    } finally {
      if (mounted) setState(() => _toggling.remove(e.key));
    }
  }

  Future<void> _run(
    PendingIdentityEntry e,
    Future<String?> Function() action,
  ) async {
    setState(() {
      _busy.add(e.key);
      _notice = null;
    });
    try {
      final String? notice = await action();
      if (mounted) setState(() => _notice = notice);
      await _reload();
    } on Object catch (error) {
      if (mounted) setState(() => _notice = error.toString());
    } finally {
      if (mounted) setState(() => _busy.remove(e.key));
    }
  }

  IconData get _leadingIcon => switch (widget.kind) {
    PendingIdentityMediaKind.game => FushiIcons.games,
    PendingIdentityMediaKind.video => FushiIcons.folder,
    PendingIdentityMediaKind.book ||
    PendingIdentityMediaKind.manga => FushiIcons.books,
  };

  PendingIdentityRow _pendingRow(PendingIdentityEntry e) {
    final Future<String?> Function(BuildContext, PendingIdentityEntry)? manual =
        widget.actions.identifyManually;
    final Future<String?> Function(BuildContext, PendingIdentityEntry)? retry =
        widget.actions.retryWithAi;
    return PendingIdentityRow(
      key: e.key,
      title: e.title,
      subtitle: describePendingIdentityEntry(e),
      leadingIcon: _leadingIcon,
      busy: _busy.contains(e.key),
      actions: <PendingIdentityRowAction>[
        if (retry != null)
          PendingIdentityRowAction(
            key: ValueKey<String>('$_prefix-pending-ai-${e.key}'),
            icon: FushiIcons.ai,
            tooltip: t.identity_pending_ai_retry,
            onPressed: () => unawaited(_run(e, () => retry(context, e))),
          ),
        if (manual != null)
          PendingIdentityRowAction(
            key: ValueKey<String>('$_prefix-pending-manual-${e.key}'),
            icon: FushiIcons.search,
            tooltip: t.identity_pending_manual_identify,
            onPressed: () => unawaited(_run(e, () => manual(context, e))),
          ),
      ],
      onSetIgnored: _toggling.contains(e.key)
          ? null
          : () => unawaited(_setIgnored(e, ignored: true)),
    );
  }

  PendingIdentityRow _ignoredRow(PendingIdentityEntry e) => PendingIdentityRow(
    key: e.key,
    title: e.title,
    subtitle: describePendingIdentityEntry(e),
    onSetIgnored: _toggling.contains(e.key)
        ? null
        : () => unawaited(_setIgnored(e, ignored: false)),
  );

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    return FushiAlertDialog(
      key: ValueKey<String>('$_prefix-dialog'),
      icon: const FushiIcon(FushiIcons.manageSearch),
      title: Text(t.identity_pending_dialog_title),
      content: SizedBox(
        width: 720,
        height: (MediaQuery.sizeOf(context).height * .6).clamp(240, 600),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiTag(
                  dense: true,
                  tone: _listing.pending.isEmpty
                      ? FushiTagTone.neutral
                      : FushiTagTone.accent,
                  text: '${_listing.pending.length}',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.identity_pending_dialog_hint,
                    style: type.bodyMedium.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: PendingIdentityListView(
                keyPrefix: _prefix,
                pending: <PendingIdentityRow>[
                  for (final PendingIdentityEntry e in _listing.pending)
                    _pendingRow(e),
                ],
                ignored: <PendingIdentityRow>[
                  for (final PendingIdentityEntry e in _listing.ignored)
                    _ignoredRow(e),
                ],
                loading: _loading,
                error: _error,
                onReload: _reload,
                notice: _notice,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_close,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
