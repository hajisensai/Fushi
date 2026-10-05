/// 首页 dashboard 顶部的更新横幅（v101）。
///
/// 只在**有未读**时挂载：没有更新的日子里首页不该多一块常驻空卡。
///
/// 2026-10 首页重设计：从整张列表卡收成一条可关闭的小横幅（首屏让给「继续」
/// 主角卡）。关闭只对**当前这批未读**生效：记下关闭时的总数，之后未读数涨上去
/// （有新更新）才再出现；未读被看掉、总数回落时同步下调记录，免得下一批新更新
/// 被旧的大数字压住。记录只活在本进程（重启 app 后有未读照常提醒）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/pages/implementations/updates_center_open.dart';
import 'package:fushi/src/pages/implementations/updates_center_page.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/utils.dart';

class UpdatesDashboardBanner extends StatefulWidget {
  const UpdatesDashboardBanner({super.key, required this.service});

  final UpdateFeedService service;

  /// 测试复位进程级关闭记录（见 [_UpdatesDashboardBannerState]）。
  @visibleForTesting
  static void debugResetDismissed() =>
      _UpdatesDashboardBannerState._dismissedAtTotal = null;

  @override
  State<UpdatesDashboardBanner> createState() => _UpdatesDashboardBannerState();
}

class _UpdatesDashboardBannerState extends State<UpdatesDashboardBanner> {
  /// 用户关掉横幅时的未读总数（进程级；null = 没关过）。见库注释。
  static int? _dismissedAtTotal;

  Map<UpdateFeedKind, int> _counts = const <UpdateFeedKind, int>{};
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    // 走 service 的 tableUpdates 信号流，**不是**裸 `select(...).watch()`：drift 的
    // QueryStream 在 dispose 取消时会排一个 Timer.run，widget 测试里「构建再卸载」
    // 的用例会因此全红（BUG-834）。
    _changes = widget.service.watchChanged().listen((_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  Future<void> _reload() async {
    final Map<UpdateFeedKind, int> counts = await widget.service.unseenCounts();
    if (!mounted) return;
    final int total = counts.values.fold<int>(0, (int a, int b) => a + b);
    final int? dismissed = _dismissedAtTotal;
    if (dismissed != null && total < dismissed) _dismissedAtTotal = total;
    setState(() => _counts = counts);
  }

  void _dismiss() {
    setState(() => _dismissedAtTotal = _total);
  }

  int get _total => _counts.values.fold<int>(0, (int a, int b) => a + b);

  Future<void> _openCenter() async {
    await openUpdatesCenter(context, widget.service);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final int total = _total;
    final int? dismissed = _dismissedAtTotal;
    final bool visible = total > 0 && (dismissed == null || total > dismissed);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 出现 / 关闭都走尺寸 + 淡入淡出过渡（减弱动态效果 / 墨水屏下零时长）。
    // 下间距挂在**有内容的那一支**上，不在调用方：调用方在构建时还不知道计数
    // （异步），在外面写死一个 SizedBox 会让没有更新时首页顶部空出一条。
    return AnimatedSize(
      duration: einkSafeDuration(context, const Duration(milliseconds: 220)),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: einkSafeDuration(context, const Duration(milliseconds: 180)),
        child: visible
            ? Padding(
                key: const ValueKey<String>('updates-banner'),
                padding: EdgeInsets.only(bottom: tokens.spacing.card),
                child: _banner(context, tokens, total),
              )
            : const SizedBox(
                key: ValueKey<String>('updates-banner-hidden'),
                width: double.infinity,
              ),
      ),
    );
  }

  Widget _banner(BuildContext context, FushiDesignTokens tokens, int total) {
    final ThemeData theme = Theme.of(context);
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final Color fill = apple
        ? appleColorsOf(context).secondaryGroupedBackground
        : theme.colorScheme.secondaryContainer;
    final Color onFill = apple
        ? tokens.surfaces.onSurface
        : theme.colorScheme.onSecondaryContainer;
    return FushiPressScale(
      child: Material(
        color: eink ? Colors.transparent : fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(apple ? 12 : 28),
          side: eink
              ? BorderSide(color: tokens.surfaces.outline)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openCenter,
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              start: tokens.spacing.card,
              end: tokens.spacing.gap / 2,
              top: tokens.spacing.gap / 2,
              bottom: tokens.spacing.gap / 2,
            ),
            child: Row(
              children: <Widget>[
                FushiBadgeControl(
                  label: Text('$total'),
                  child: FushiIcon(
                    Icons.notifications_active_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                ),
                SizedBox(width: tokens.spacing.card),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(
                          text: t.updates_center_title,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(text: '  ${_summary()}'),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata.copyWith(color: onFill),
                  ),
                ),
                FushiIconButton(
                  key: const ValueKey<String>('updates-banner-dismiss'),
                  tooltip: t.home_updates_dismiss,
                  label: t.home_updates_dismiss,
                  icon: Icons.close_rounded,
                  onTap: _dismiss,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「番剧新集 3 · 漫画新章 12」——按域列未读数，用户一眼看出是哪类更新。
  String _summary() => <String>[
        for (final UpdateFeedKind kind in UpdateFeedKind.values)
          if ((_counts[kind] ?? 0) > 0)
            '${updateFeedKindLabel(kind)} ${_counts[kind]}',
      ].join(' · ');
}
