import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_renderer.dart';
import 'package:fushi/src/settings/settings_schema_web_browser.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/settings_section_anchor.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_strings.dart';
import 'package:fushi/utils.dart';

/// 宽于此（逻辑像素）走「分组导航 + 内容」双栏；与设置主页的主从判据同值。
const double kWebBrowserSettingsWideMinWidth = 720;

/// 打开统一的「浏览器设置」：浏览页 ⋯ 菜单、播放器菜单「扩展设置」、系统设置里的浏览器
/// 入口都走这一处。[group] = 直接落到某一组（宽屏选中它；窄屏在总览上再推一层）。
Future<void> openWebBrowserSettings(
  BuildContext context, {
  WebBrowserSettingsGroup? group,
}) async {
  await WebBrowserExtensionStrings.instance.ensureLoaded();
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (BuildContext _) => WebBrowserSettingsPage(initialGroup: group),
    ),
  );
}

/// 浏览器设置：浏览器本身（通用 / 网页广告拦截）+ 浏览器扩展各组。
///
/// - 宽屏（横屏平板 / 桌面）：左侧分组导航、右侧当前组的设置，切组只换右栏；
/// - 窄屏（竖屏手机）：分组总览列表，点一组下钻到它的设置页。
///
/// 两种形态的行都来自同一批 schema（[WebBrowserSettingsGroup.destination]），经当前设计
/// 系统的设置渲染器（MD3 / Apple）画出来，与其它设置页同一套行、动效与焦点规则。
class WebBrowserSettingsPage extends ConsumerStatefulWidget {
  const WebBrowserSettingsPage({super.key, this.initialGroup});

  /// 进页时落到的分组；null = 第一组。
  final WebBrowserSettingsGroup? initialGroup;

  @override
  ConsumerState<WebBrowserSettingsPage> createState() =>
      _WebBrowserSettingsPageState();
}

class _WebBrowserSettingsPageState extends ConsumerState<WebBrowserSettingsPage>
    with SettingsContextHost<WebBrowserSettingsPage> {
  late WebBrowserSettingsGroup _selected =
      widget.initialGroup ?? WebBrowserSettingsGroup.general;

  /// 窄屏进页且指定了分组：总览之上再推一层，只推一次。
  bool _initialPushPending = false;

  bool _stringsReady = WebBrowserExtensionStrings.instance.isLoaded;

  /// 双栏下右栏各组自己的分组锚点登记处：不让它们登记到外层页壳的 spy，
  /// 否则页头下会冒出一排分组跳转 chip（分组导航已经在左栏）。
  final SettingsSectionSpy _paneSpy = SettingsSectionSpy();

  @override
  void dispose() {
    _paneSpy.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _initialPushPending = widget.initialGroup != null;
    if (!_stringsReady) {
      unawaited(
        WebBrowserExtensionStrings.instance.ensureLoaded().then((_) {
          if (mounted) setState(() => _stringsReady = true);
        }),
      );
    }
  }

  void _select(WebBrowserSettingsGroup group) {
    if (group == _selected) return;
    setState(() => _selected = group);
  }

  void _pushInitialGroupOnce(WebBrowserSettingsGroup group) {
    if (!_initialPushPending) return;
    _initialPushPending = false;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      unawaited(
        Navigator.of(context).push<void>(
          adaptivePageRoute<void>(
            context: context,
            builder: (BuildContext _) =>
                SettingsDetailPage.subPage(group.destination),
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final SettingsContext settingsContext = createSettingsContext(
      appModel: ref.read(appProvider),
      ref: ref,
    );
    final SettingsRenderer renderer = resolveSettingsRenderer(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide =
            constraints.maxWidth >= kWebBrowserSettingsWideMinWidth;
        if (!wide) {
          final WebBrowserSettingsGroup? initial = widget.initialGroup;
          if (initial != null && _stringsReady) _pushInitialGroupOnce(initial);
          return renderer.buildDetailPage(
            settingsContext: settingsContext,
            destination: webBrowserSettingsDestination(),
          );
        }
        // 宽屏打开过就不再补推（转回窄屏时停在总览，不突然跳页）。
        _initialPushPending = false;
        return renderer.buildDetailPage(
          settingsContext: settingsContext,
          destination: SettingsDestination(
            id: SettingsDestinationId.system,
            title: t.web_browser_menu_settings,
            icon: FushiIcons.globe,
            sections: const <SettingsSection>[],
            // 两栏各自滚动，要占满详情视口。
            bodyFillsViewport: true,
            body: (SettingsContext c) => SettingsSectionSpyScope(
              spy: _paneSpy,
              child: _TwoPane(
                settingsContext: c,
                renderer: renderer,
                selected: _selected,
                onSelected: _select,
                stringsReady: _stringsReady,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TwoPane extends StatelessWidget {
  const _TwoPane({
    required this.settingsContext,
    required this.renderer,
    required this.selected,
    required this.onSelected,
    required this.stringsReady,
  });

  final SettingsContext settingsContext;
  final SettingsRenderer renderer;
  final WebBrowserSettingsGroup selected;
  final ValueChanged<WebBrowserSettingsGroup> onSelected;
  final bool stringsReady;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool glass = isGlassDesign(context);
    final Duration switchDuration = fushiMotionDuration(
      context,
      FushiMotion.medium,
    );
    final Widget detail = !stringsReady && selected.extension != null
        ? const SizedBox.shrink()
        : KeyedSubtree(
            // 详情的身份就是当前分组：切组整棵重建，避免复用上一组同位置的开关 /
            // 滑杆 element（圆点滑动、滚动位置串组）。
            key: ValueKey<WebBrowserSettingsGroup>(selected),
            // 切组淡入淡出时新旧两组同时在树上：各自用隐式滚动位置，不共用
            // PrimaryScrollController（否则 Scrollbar 断言「一个控制器挂了两个位置」）。
            child: PrimaryScrollController.none(
              child: renderer.buildDetailContent(
                settingsContext: settingsContext,
                destination: selected.destination(),
              ),
            ),
          );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: MaterialSettingsRenderer.navPaneWidth + 32,
          child: FushiEntranceScope(
            child: ListView(
              key: const ValueKey<String>('web_browser_settings.nav'),
              primary: false,
              padding: EdgeInsets.only(
                top: tokens.spacing.gap,
                bottom:
                    tokens.spacing.page + MediaQuery.of(context).padding.bottom,
              ),
              children: _navChildren(context, tokens, glass),
            ),
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: switchDuration,
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
              fit: StackFit.expand,
              children: <Widget>[...previous, ?current],
            ),
            child: detail,
          ),
        ),
      ],
    );
  }

  List<Widget> _navChildren(
    BuildContext context,
    FushiDesignTokens tokens,
    bool glass,
  ) {
    final ThemeData theme = Theme.of(context);
    final List<Widget> out = <Widget>[];
    int index = 0;
    void heading(String text) {
      out.add(
        Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.rowHorizontal,
            out.isEmpty ? 0 : tokens.spacing.gap + 4,
            tokens.spacing.rowHorizontal,
            tokens.spacing.gap / 2,
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    for (final WebBrowserSettingsGroup g in WebBrowserSettingsGroup.values) {
      if (g == WebBrowserSettingsGroup.general) heading(t.web_browser_title);
      if (g == WebBrowserSettingsGroup.lookup) {
        heading(t.nav_browser_extension);
      }
      final String title = webBrowserSettingsGroupTitle(g);
      final IconData icon = webBrowserSettingsGroupIcon(g);
      final bool isSelected = g == selected;
      void tap() => onSelected(g);
      out.add(
        FushiStaggeredEntrance(
          key: ValueKey<WebBrowserSettingsGroup>(g),
          index: index++,
          child: glass
              ? GlassSettingsSidebarRow(
                  icon: icon,
                  title: title,
                  selected: isSelected,
                  onTap: tap,
                )
              : Md3SettingsNavRow(
                  icon: icon,
                  title: title,
                  selected: isSelected,
                  onTap: tap,
                ),
        ),
      );
    }
    return out;
  }
}
