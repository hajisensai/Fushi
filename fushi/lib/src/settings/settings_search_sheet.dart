import 'package:flutter/material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';

/// 从一条搜索结果跳到它所在的页面并高亮那一行（窄屏 / 从任意设置子页发起）：
/// 登记一次性定位挂点，push 顶层分类详情页，再沿子页链逐级 push，挂点由最里层
/// 页面的目标行消费（滚入视口 + 闪烁高亮）。
///
/// [pushTopLevel] 为 false 时不推顶层分类页（宽屏主从已经在右窗格切到该分类，
/// 只需要推子页）。
void openSettingsSearchEntry(
  NavigatorState navigator,
  SettingsSearchEntry entry, {
  bool pushTopLevel = true,
}) {
  SettingsSearchReveal.pendingItemId = entry.hasRevealTarget
      ? entry.item.id
      : null;
  if (pushTopLevel) {
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsDetailPage(destination: entry.destination),
      ),
    );
  }
  for (final SettingsNavigationItem hop in entry.subPagePath) {
    final SettingsDestination Function() child = hop.child!;
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsDetailPage.subPage(child),
      ),
    );
  }
}

/// 打开全局设置搜索（任意设置子页页头的搜索按钮）：全屏搜索页，输入即搜全部
/// 设置项（标题 / 说明 / 选项 / 同义词），点结果关掉搜索页并直达该项。
Future<void> showSettingsSearch(BuildContext context) async {
  final NavigatorState navigator = Navigator.of(context);
  final SettingsSearchEntry? picked = await navigator.push<SettingsSearchEntry>(
    PageRouteBuilder<SettingsSearchEntry>(
      opaque: true,
      transitionDuration: fushiMotionDuration(context, FushiMotion.medium),
      reverseTransitionDuration: fushiMotionDuration(
        context,
        FushiMotion.short,
      ),
      pageBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) => const SettingsSearchPage(),
      transitionsBuilder:
          (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
            Widget child,
          ) {
            // 从页头搜索按钮的位置「长出来」：淡入 + 轻微放大（emphasized
            // decelerate），退场反向加速。
            final Animation<double> curved = CurvedAnimation(
              parent: animation,
              curve: FushiMotion.enter,
              reverseCurve: FushiMotion.exit,
            );
            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
                alignment: Alignment.topRight,
                child: child,
              ),
            );
          },
    ),
  );
  if (picked == null) return;
  openSettingsSearchEntry(navigator, picked);
}

/// 设置子页页头的「搜索设置」按钮（[SettingsFloatingHeader] 的动作组里用）。
class SettingsSearchAction extends StatelessWidget {
  const SettingsSearchAction({super.key});

  @override
  Widget build(BuildContext context) {
    return FushiIconButtonControl(
      key: const ValueKey<String>('settings-search-action'),
      icon: const FushiIcon(FushiIcons.search),
      tooltip: t.settings_search_open,
      onPressed: () => showSettingsSearch(context),
    );
  }
}

/// 全屏设置搜索页：浮动页头（返回）+ 自动聚焦的搜索栏 + 分组高亮结果。
/// 选中结果时以该条目 pop（由 [showSettingsSearch] 负责导航）。
class SettingsSearchPage extends BasePage {
  const SettingsSearchPage({super.key});

  @override
  BasePageState<SettingsSearchPage> createState() => _SettingsSearchPageState();
}

class _SettingsSearchPageState extends BasePageState<SettingsSearchPage>
    with SettingsContextHost<SettingsSearchPage> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';
  List<SettingsSearchEntry> _results = const <SettingsSearchEntry>[];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SettingsContext settingsContext = createSettingsContext(
      appModel: appModel,
      ref: ref,
    );
    final List<SettingsDestination> destinations =
        buildSettingsSchema(settingsContext)
            .where((SettingsDestination d) => d.isVisible(settingsContext))
            .toList(growable: false);
    _results = _query.trim().isEmpty
        ? const <SettingsSearchEntry>[]
        : filterSettingsEntries(
            flattenVisibleSettings(destinations, settingsContext),
            _query,
          );
    final bool apple = SettingsKitStyle.of(context) == SettingsKitStyle.apple;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = tokens.spacing.page;
    return Material(
      color: apple
          ? appleColorsOf(context).groupedBackground
          : tokens.surfaces.page,
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SettingsFloatingHeader(
              title: t.settings_search_open,
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, tokens.spacing.gap),
              child: SettingsSearchBar(
                controller: _controller,
                autofocus: true,
                onChanged: (String value) => setState(() => _query = value),
                onSubmitted: (_) {
                  if (_results.isNotEmpty) {
                    Navigator.of(context).pop(_results.first);
                  }
                },
                onArrowDown: () => FocusManager.instance.primaryFocus
                    ?.focusInDirection(TraversalDirection.down),
              ),
            ),
            Expanded(
              child: _query.trim().isEmpty
                  ? Center(
                      child: SettingsEmptyState(
                        icon: FushiIcons.manageSearch,
                        title: t.settings_search_hint,
                        message: t.settings_search_empty_hint,
                      ),
                    )
                  : SettingsSearchResultsView(
                      results: _results,
                      query: _query,
                      padding: EdgeInsets.fromLTRB(
                        inset,
                        tokens.spacing.gap,
                        inset,
                        tokens.spacing.page +
                            MediaQuery.of(context).padding.bottom,
                      ),
                      onOpen: (SettingsSearchEntry entry) =>
                          Navigator.of(context).pop(entry),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
