/// 首页头像右边的「默认配置」胶囊（拍板台 design-avatar-combo-placement 方案 a，
/// 2026-11-23）。
///
/// 头像只管账户 / 排行榜，切换配置是另一颗独立按钮：图标 + 配置名 + ▾，点开列出
/// 全部配置（当前项打勾）、一行「已绑定配置的作品仍用各自的配置」说明和「配置管理」。
/// 只有一份配置时整颗不出现——绝大多数用户只有一份，常驻一颗只有一项的切换钮是噪音。
///
/// 切换走设置页 / 悬浮球同一条 `ProfileViewModel.switchProfile`（由首页经
/// [HomeProfileChip.onSwitchProfile] 注入）。它切的是**默认层**：
/// 作品 / 媒体类型 / 语言命中绑定时打开作品仍按绑定用对应配置，所以菜单里写明这一点。
///
/// 显示用的配置列表与激活 id 直接听库（`profiles` / `preferences` 表的写入通知，与头像
/// 同一做法，BUG-3249），不在首页一挂载就建 `ProfileViewModel`：它装载时会「应用默认
/// 配置」，首页不该有这种副作用；只有用户真的点了切换才经它走。
///
/// 数据库与两个动作（配置管理、切换）都由首页注入，本文件不 import AppModel /
/// `profile_view_model`：否则这颗胶囊经首页被接进 lib/ 的 import 大环
/// （import_cycle_guard_test，2026-11-24 develop 627）。
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdate, TableUpdateQuery;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase, ProfileRow;
import 'package:fushi_engine/profile/combo/combo_profiles.dart'
    show listedComboProfiles;
import 'package:material_ui/material_ui.dart';

/// 胶囊里配置名的最大宽度：再长就省略号截断，不把顶栏动作组挤进「⋯」。
const double kHomeProfileChipMaxNameWidth = 132;

/// 菜单里「配置管理」那一项的值（配置 id 恒为正）。
const int _kManageProfiles = -1;

/// 有 [profileCount] 份配置时该不该出现胶囊：两份以上才出现。
bool homeProfileChipVisible(int profileCount) => profileCount >= 2;

/// 首页头像右边的默认配置胶囊。[extent] 与同排头像的边长一致（胶囊高 = 头像高）；
/// [floating] = 旧浮动工具栏形态（外面套一层与头像同款的浮动胶囊底）。
class HomeProfileChip extends StatefulWidget {
  const HomeProfileChip({
    super.key,
    required this.extent,
    required this.floating,
    required this.database,
    required this.onManageProfiles,
    required this.onSwitchProfile,
  });

  final double extent;
  final bool floating;

  /// 读配置列表 / 激活 id、听写入通知的库。
  final FushiDatabase database;

  /// 菜单里「配置管理」：打开配置管理页。
  final Future<void> Function() onManageProfiles;

  /// 切换默认配置；抛错时胶囊提示切换失败。
  final Future<void> Function(int profileId) onSwitchProfile;

  @override
  State<HomeProfileChip> createState() => _HomeProfileChipState();
}

class _HomeProfileChipState extends State<HomeProfileChip> {
  List<ProfileRow> _profiles = const <ProfileRow>[];
  int _activeId = -1;
  StreamSubscription<Set<TableUpdate>>? _changes;

  /// 读取代次：写入通知可能连发，只认最后一次发起的读取。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(HomeProfileChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.database, widget.database)) {
      unawaited(_changes?.cancel());
      _listen();
    }
  }

  void _listen() {
    final FushiDatabase db = widget.database;
    _changes = db
        .tableUpdates(
          TableUpdateQuery.onAllTables(
            <ResultSetImplementation<dynamic, dynamic>>[
              db.profiles,
              db.preferences,
            ],
          ),
        )
        .listen((Set<TableUpdate> _) => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    try {
      final FushiDatabase db = widget.database;
      // 作品上直接拆出的匿名组合不列（组合阶段 6）。
      final List<ProfileRow> profiles = await listedComboProfiles(db);
      final int activeId = await db.resolveActiveProfileId();
      if (!mounted || generation != _generation) return;
      setState(() {
        _profiles = profiles;
        _activeId = activeId;
      });
    } catch (e, st) {
      ErrorLogService.instance.log('HomeProfileChip.load', e, st);
    }
  }

  ProfileRow? get _active {
    for (final ProfileRow p in _profiles) {
      if (p.id == _activeId) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ProfileRow? shown = _active;
    if (!homeProfileChipVisible(_profiles.length) || shown == null) {
      return const SizedBox.shrink();
    }
    final double extent = widget.extent;
    final String tooltip = t.home_profile_chip_tooltip(name: shown.name);
    final bool apple = isGlassDesign(context);
    final FushiAppleColors? appleColors = apple ? appleColorsOf(context) : null;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color fill = appleColors?.fill ?? tokens.surfaces.primaryContainer;
    final Color onFill =
        appleColors?.label ?? Theme.of(context).colorScheme.onPrimaryContainer;
    final Widget content = SizedBox(
      height: extent,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(FushiIcons.profiles, size: 18, color: onFill),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: kHomeProfileChipMaxNameWidth,
              ),
              child: Text(
                shown.name,
                key: const ValueKey<String>('home-profile-chip-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: onFill,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 2),
            FushiIcon(FushiIcons.expandMore, size: 18, color: onFill),
          ],
        ),
      ),
    );
    // 与左边头像的间距算在胶囊里：胶囊不出现时头像后面不留空。
    final Widget chip = Semantics(
      key: const ValueKey<String>('home-profile-chip'),
      button: true,
      label: tooltip,
      excludeSemantics: true,
      child: FushiTooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Builder(
          builder: (BuildContext anchor) {
            void open() => unawaited(_openMenu(anchor, shown.id));
            if (apple) {
              return FushiPlainButton(
                onPressed: open,
                fill: fill,
                borderRadius: BorderRadius.circular(extent / 2),
                child: content,
              );
            }
            final Widget body = Material(
              shape: const StadiumBorder(),
              color: fill,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: open,
                child: content,
              ),
            );
            if (!widget.floating) return FushiPressScale(child: body);
            return FushiPressScale(
              child: FushiFloatingPill(
                color: fushiFloatingToolbarPalette(context).container,
                padding: const EdgeInsets.all(4),
                child: body,
              ),
            );
          },
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: chip,
    );
  }

  /// 锚在胶囊下方的配置菜单。点当前项或取消什么也不做。
  Future<void> _openMenu(BuildContext anchor, int activeId) async {
    final TextStyle? caption = Theme.of(anchor).textTheme.bodySmall?.copyWith(
      color: Theme.of(anchor).colorScheme.onSurfaceVariant,
    );
    final int? picked = await showFushiMenu<int>(
      context: anchor,
      positionBuilder: fushiMenuAnchorPosition(anchor),
      initialValue: activeId,
      items: <PopupMenuEntry<int>>[
        PopupMenuItem<int>(
          enabled: false,
          height: 32,
          child: Text(t.home_profile_menu_header, style: caption),
        ),
        for (final ProfileRow profile in _profiles)
          PopupMenuItem<int>(
            key: ValueKey<String>('home-profile-menu-${profile.id}'),
            value: profile.id,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 24,
                  child: profile.id == activeId
                      ? const FushiIcon(FushiIcons.check, size: 20)
                      : null,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    profile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<int>(
          enabled: false,
          child: Text(t.home_profile_menu_binding_note, style: caption),
        ),
        PopupMenuItem<int>(
          key: const ValueKey<String>('home-profile-menu-manage'),
          value: _kManageProfiles,
          child: Row(
            children: <Widget>[
              const FushiIcon(FushiIcons.settings, size: 20),
              const SizedBox(width: 12),
              Text(t.profile_management),
            ],
          ),
        ),
      ],
    );
    if (!mounted || picked == null || picked == activeId) return;
    if (picked == _kManageProfiles) {
      await widget.onManageProfiles();
      return;
    }
    try {
      await widget.onSwitchProfile(picked);
    } catch (error, stack) {
      ErrorLogService.instance.log('HomeProfileChip.switch', error, stack);
      if (!anchor.mounted) return;
      ScaffoldMessenger.maybeOf(
        anchor,
      )?.showSnackBar(FushiSnackBar(content: Text(t.profile_switch_failed)));
    }
  }
}
