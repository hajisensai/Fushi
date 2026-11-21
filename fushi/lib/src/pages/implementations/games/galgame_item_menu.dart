import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/add_to_collection_dialog.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/nsfw/media_nsfw_cover.dart';
import 'package:fushi/src/media/nsfw/media_nsfw_dialog.dart'
    show loadMediaNsfwToggleState;
import 'package:fushi/src/media/privacy/media_privacy_dialog.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart';
import 'package:fushi/src/mining/galgame_cover_resolver.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/galgame_japanese_locale_prompt.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/mining/galgame_scrape_dialog.dart';
import 'package:fushi/src/mining/magpie_upscaling.dart';
import 'package:fushi/src/mining/magpie_upscaling_prompt.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart'
    show
        galgamePlayStatusIcon,
        galgamePlayStatusLabel,
        isGameCollectionMemberVisible;
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart'
    show
        DialogActionGroup,
        DialogDangerAction,
        DialogQuickAction,
        DialogToggleAction,
        DialogWorkbenchAction,
        ItemMenuSlot,
        MediaItemDialogFrame,
        mediaPrivacyToggleAction,
        showMediaItemActions;
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart'
    show GalgameDetailPage, kGalgameDetailEditTab;
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart'
    show DialogListAction;
import 'package:fushi/src/pages/implementations/media_item_stats_dialog.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart'
    show allTagsProvider, filteredGameIdsProvider, gameTagMapProvider;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_destructive_confirm_dialog.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart'
    show currentRevealHost, revealFirstOf;
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 游戏条目长按 / 右键的上下文菜单（游戏首页的首块 / 继续块用；游戏库卡片经
/// [showGalgameItemActionsMenu] 用同一份）。
///
/// 项目、次序、分组与危险区（单一真相源 [galgameItemMenuItems]）：详情 → 游玩
/// 状态 → 统计 → 重命名 → 设封面 → 自动封面 → 刮削 → 加入合集 → 标签 → 私密 →
/// 内容语言 →（Windows）超分 / 转区 →（桌面）打开文件位置 → 移除。写操作全部经
/// [GalgameRepository]（落库后它自己 `load()` 通知监听者，调用方随之重算），不在
/// 这里维护镜像状态。
///
/// [onDetail] 由调用方给：首页的「详情」走从原位放大（[pushGalgameDetailFromOrigin]），
/// 菜单只负责关掉自己再转交。
Future<void> showGalgameItemMenu({
  required BuildContext context,
  required WidgetRef ref,
  required GalgameEntry game,
  required VoidCallback onDetail,
  VoidCallback? onLaunch,
}) => showGalgameItemActionsMenu(
  context: context,
  actions: GalgameItemActions(
    context: context,
    ref: ref,
    game: game,
    onDetail: onDetail,
    onLaunch: onLaunch,
  ),
);

/// 用调用方已构造好的 [actions] 弹菜单：[context] 只用来定位 / 弹出菜单路由
/// （卡片自己的 context，库页的「排序」入口挂在卡片祖先上），各动作的对话框用
/// [GalgameItemActions.context]。
Future<void> showGalgameItemActionsMenu({
  required BuildContext context,
  required GalgameItemActions actions,
}) async {
  final GalgameEntry game = actions.game;
  final List<GalgameItemMenuItem> items = galgameItemMenuItems(game);
  final VoidCallback? launch = actions.onLaunch;
  await showMediaItemActions<void>(
    context: context,
    builder: (BuildContext dialogContext) => MediaItemDialogFrame(
      cover: _dialogCover(dialogContext, game),
      coverBackdrop: _dialogCoverBackdrop(game),
      coverMaterial: ShelfCoverMaterial.gameCase,
      nsfw: MediaNsfwTarget.game(game.id, adult: game.isNsfw),
      title: game.displayName,
      progressLabel: game.playStatus == GalgamePlayStatus.unset
          ? null
          : galgamePlayStatusLabel(game.playStatus),
      // 主按钮「启动游戏」（#4b）：与点卡同一入口；调用方没给启动回调时不画。
      showLaunchAction: launch != null,
      launchLabel: t.game_launch,
      onLaunch: launch == null
          ? null
          : () {
              Navigator.pop(dialogContext);
              launch();
            },
      quickActions: <DialogQuickAction>[
        for (final GalgameItemMenuItem item in items)
          // 私密是开关行、工作台是整行入口，二者在下面的 listActions 里。
          if (!item.danger &&
              item.action != GalgameItemAction.privacy &&
              item.action != GalgameItemAction.hookWorkbench)
            DialogQuickAction(
              label: item.label,
              icon: item.icon,
              group: item.group,
              slot: item.slot,
              selected: item.selected,
              onPressed: () {
                Navigator.pop(dialogContext);
                actions.dispatch(item.action);
              },
            ),
      ],
      listActions: <DialogListAction>[
        // 私密：开关行就地拨动（与书 / 视频 / 合集同一份定义）。
        if (items.any(
          (GalgameItemMenuItem i) => i.action == GalgameItemAction.privacy,
        ))
          mediaPrivacyToggleAction(
            actions.context,
            db: actions._appModel.database,
            kind: TagHostKind.game,
            entryKey: game.id,
            title: game.displayName,
          ),
        // NSFW：与书 / 视频 / 合集同一行开关，写游戏自己的「成人向」覆盖。
        galgameNsfwToggleAction(
          repo: actions._repo,
          db: actions._appModel.database,
          gameId: game.id,
          onPressed: () {
            Navigator.pop(dialogContext);
            unawaited(openGalgameEditTab(actions.context, game.id));
          },
          onChanged: actions.onChanged,
        ),
        for (final GalgameItemMenuItem item in items)
          if (item.action == GalgameItemAction.hookWorkbench)
            DialogWorkbenchAction(
              label: item.label,
              icon: item.icon,
              subtitle: t.item_menu_game_workbench_hint,
              onPressed: () {
                Navigator.pop(dialogContext);
                actions.dispatch(item.action);
              },
            ),
      ],
      dangerActions: <DialogDangerAction>[
        for (final GalgameItemMenuItem item in items)
          if (item.danger)
            DialogDangerAction(
              label: item.label,
              icon: item.icon,
              onPressed: () {
                Navigator.pop(dialogContext);
                actions.dispatch(item.action);
              },
            ),
      ],
    ),
  );
}

/// 「通关」开关拨动后要写的游玩状态：没通关 → 玩过；已通关 → 在玩。
///
/// 取消通关落「在玩」而不是「未设置」：拨掉通关的语义是「还没玩完」，写回
/// unset 会把游戏从「在玩」等分组里整个抹掉，拨错再拨回也回不到原状态。要设成
/// 其它状态走「游玩状态」选择器。
GalgamePlayStatus galgameClearedToggleTarget(GalgamePlayStatus current) =>
    current == GalgamePlayStatus.played
    ? GalgamePlayStatus.playing
    : GalgamePlayStatus.played;

/// 菜单动作键。
enum GalgameItemAction {
  detail,
  status,

  /// 标记通关 / 取消（游玩状态「玩过」的一键开关，#4b 主操作行）。
  cleared,
  stats,
  rename,
  cover,

  /// 「在线搜索封面」：在刮削源里搜条目，只取所选候选的封面（不绑元数据）。
  onlineCover,
  autoCover,
  scrape,
  collect,
  tags,
  privacy,
  language,

  /// 「文本 Hook 与制卡」工作台入口（Windows）：进详情页的编辑 tab（文本处理 /
  /// 制卡覆盖都在那里）。
  hookWorkbench,
  upscaling,
  japaneseLocale,
  fileLocation,
  remove,
}

/// 打开游戏详情页的编辑 tab（文本处理 / 制卡覆盖 / 「成人向」都在那里）。
Future<void> openGalgameEditTab(BuildContext context, String gameId) =>
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext ctx) => GalgameDetailPage(
          gameId: gameId,
          initialTab: kGalgameDetailEditTab,
        ),
      ),
    );

/// 游戏卡菜单的 NSFW 开关行（#4b，与书 / 视频 / 合集同一行）。
///
/// 游戏的 NSFW 有两处来源：自己的「成人向」覆盖（`GalgameCustomData.nsfw`，压过
/// 刮削源分级，编辑页同一字段）与通用 `media_nsfw_flags` 表（合集继承 / 互联同步
/// 过来的标记）。开关显示二者之一为真；拨动写「成人向」覆盖（[GalgameRepository.setNsfw]），
/// 关掉时顺带清掉表里自己那行，免得关了封面还模糊。合集继承来的拨不掉（locked，
/// 点行走 [onPressed] 去编辑页）。
DialogToggleAction galgameNsfwToggleAction({
  required GalgameRepository repo,
  required FushiDatabase db,
  required String gameId,
  required VoidCallback onPressed,
  VoidCallback? onChanged,
}) => DialogToggleAction(
  label: t.media_nsfw_action,
  icon: FushiIcons.visibilityOff,
  onPressed: onPressed,
  loadState: () async {
    final ({bool value, bool locked}) table = await loadMediaNsfwToggleState(
      db,
      TagHostKind.game,
      gameId,
    );
    final bool adult = repo.byId(gameId)?.isNsfw ?? false;
    return (value: adult || table.value, locked: table.locked);
  },
  onChanged: (bool value) async {
    try {
      await repo.setNsfw(gameId, value);
      if (!value && await db.isMediaNsfw(TagHostKind.game, gameId)) {
        await db.setMediaNsfw(TagHostKind.game, gameId, false);
      }
    } on Object catch (error) {
      FushiToast.show(
        msg: t.media_nsfw_save_failed(reason: error.toString()),
        severity: ToastSeverity.error,
      );
      rethrow;
    }
    FushiToast.show(
      msg: value ? t.media_nsfw_marked_toast : t.media_nsfw_cleared_toast,
      severity: ToastSeverity.success,
    );
    onChanged?.call();
  },
);

/// 一项菜单：动作、文案、图标、分组、是否进危险区。
@immutable
class GalgameItemMenuItem {
  const GalgameItemMenuItem({
    required this.action,
    required this.label,
    required this.icon,
    required this.group,
    this.danger = false,
    this.slot,
    this.selected = false,
  });

  final GalgameItemAction action;
  final String label;
  final IconData icon;
  final DialogActionGroup group;
  final bool danger;

  /// 右键菜单里的落点（见 [ItemMenuSlot]）；null = 按 [group] 推断。
  final ItemMenuSlot? slot;

  /// 开关类动作当前开着（已通关）。
  final bool selected;
}

/// 菜单项清单（单一真相源；见 [showGalgameItemMenu] 的次序说明）。
List<GalgameItemMenuItem> galgameItemMenuItems(
  GalgameEntry game,
) => <GalgameItemMenuItem>[
  GalgameItemMenuItem(
    action: GalgameItemAction.detail,
    label: t.game_view_detail,
    group: DialogActionGroup.content,
    icon: FushiIcons.info,
    slot: ItemMenuSlot.primary,
  ),
  GalgameItemMenuItem(
    action: GalgameItemAction.status,
    label: t.game_play_status,
    group: DialogActionGroup.progress,
    icon: FushiIcons.flag,
    slot: ItemMenuSlot.primary,
  ),
  GalgameItemMenuItem(
    action: GalgameItemAction.cleared,
    label: t.item_menu_game_cleared,
    group: DialogActionGroup.progress,
    icon: FushiIcons.check,
    slot: ItemMenuSlot.primary,
    selected: game.playStatus == GalgamePlayStatus.played,
  ),
  GalgameItemMenuItem(
    action: GalgameItemAction.stats,
    label: t.media_stats_action,
    group: DialogActionGroup.progress,
    icon: FushiIcons.statistics,
  ),
  GalgameItemMenuItem(
    action: GalgameItemAction.rename,
    label: t.game_rename,
    group: DialogActionGroup.organize,
    slot: ItemMenuSlot.edit,
    icon: FushiIcons.rename,
  ),
  GalgameItemMenuItem(
    action: GalgameItemAction.cover,
    label: t.game_set_cover,
    group: DialogActionGroup.organize,
    slot: ItemMenuSlot.edit,
    icon: FushiIcons.image,
  ),
  // 拍板 left3612：设置封面也能用刮削源的封面，紧跟「设置封面」（与视频单集
  // 「选择封面图片」旁的「在线搜索封面」同位）。
  GalgameItemMenuItem(
    action: GalgameItemAction.onlineCover,
    label: t.game_cover_online_search,
    group: DialogActionGroup.organize,
    slot: ItemMenuSlot.edit,
    icon: FushiIcons.travelExplore,
  ),
  GalgameItemMenuItem(
    action: GalgameItemAction.autoCover,
    label: t.game_auto_cover,
    group: DialogActionGroup.organize,
    slot: ItemMenuSlot.edit,
    icon: FushiIcons.imageSearch,
  ),
  GalgameItemMenuItem(
    action: GalgameItemAction.scrape,
    label: t.game_scrape,
    group: DialogActionGroup.organize,
    slot: ItemMenuSlot.edit,
    icon: FushiIcons.cloudDownload,
  ),
  GalgameItemMenuItem(
    action: GalgameItemAction.collect,
    label: t.add_to_collection,
    group: DialogActionGroup.organize,
    icon: FushiIcons.collection,
  ),
  GalgameItemMenuItem(
    action: GalgameItemAction.tags,
    label: t.tag_label,
    group: DialogActionGroup.organize,
    icon: FushiIcons.tag,
  ),
  GalgameItemMenuItem(
    action: GalgameItemAction.privacy,
    label: t.media_privacy_action,
    group: DialogActionGroup.organize,
    icon: FushiIcons.lock,
  ),
  GalgameItemMenuItem(
    action: GalgameItemAction.language,
    label: t.book_language_action,
    group: DialogActionGroup.settings,
    icon: FushiIcons.language,
  ),
  // 工作台入口：galgame Hook 只做 Windows。
  if (Platform.isWindows)
    GalgameItemMenuItem(
      action: GalgameItemAction.hookWorkbench,
      label: t.item_menu_game_workbench,
      group: DialogActionGroup.content,
      icon: FushiIcons.textFields,
      slot: ItemMenuSlot.workbench,
    ),
  // 超分 / 转区：每游戏一档，Windows-only（galgame Hook、Magpie、Locale
  // Emulator 都只做 Windows），档位写在菜单项上。
  if (Platform.isWindows)
    GalgameItemMenuItem(
      action: GalgameItemAction.upscaling,
      label:
          '${t.game_upscaling} · '
          '${MagpieUpscalingModeDialog.modeLabel(magpieUpscalingModeFromKey(game.upscalingMode))}',
      group: DialogActionGroup.settings,
      icon: Icons.aspect_ratio_outlined,
    ),
  if (Platform.isWindows)
    GalgameItemMenuItem(
      action: GalgameItemAction.japaneseLocale,
      label:
          '${t.game_japanese_locale} · '
          '${GalJapaneseLocaleModeDialog.modeLabel(galJapaneseLocaleModeFromKey(game.japaneseLocaleMode))}',
      group: DialogActionGroup.settings,
      icon: FushiIcons.language,
    ),
  // 桌面才有文件管理器契约（移动端 [currentRevealHost] 为 null）。
  if (currentRevealHost() != null)
    GalgameItemMenuItem(
      action: GalgameItemAction.fileLocation,
      label: t.media_file_location_open,
      group: DialogActionGroup.organize,
      icon: FushiIcons.folderOpen,
      slot: ItemMenuSlot.more,
    ),
  GalgameItemMenuItem(
    action: GalgameItemAction.remove,
    label: t.game_remove,
    group: DialogActionGroup.organize,
    icon: FushiIcons.delete,
    danger: true,
  ),
];

/// 菜单头部封面：有封面文件整图可见，没有画手柄图标占位。
Widget _dialogCover(BuildContext context, GalgameEntry game) {
  final String? cover = game.coverPath;
  if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
    return ShelfFileCover(
      path: cover,
      placeholder: const SizedBox.shrink(),
      fit: BoxFit.contain,
    );
  }
  return SizedBox(
    height: 120,
    child: Center(
      child: FushiIcon(
        FushiIcons.games,
        size: 40,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

ImageProvider? _dialogCoverBackdrop(GalgameEntry game) {
  final String? cover = game.coverPath;
  if (cover == null || cover.isEmpty) return null;
  final File file = File(cover);
  return file.existsSync() ? FileImage(file) : null;
}

/// 菜单各项的执行体。持有菜单弹出前的 [context]（首页 State 的 context），
/// 每个 await 之后先判 `context.mounted`。
class GalgameItemActions {
  GalgameItemActions({
    required this.context,
    required this.ref,
    required this.game,
    required this.onDetail,
    this.onChanged,
    this.onLaunch,
    this.onOpenWorkbench,
  });

  final BuildContext context;
  final WidgetRef ref;
  final GalgameEntry game;
  final VoidCallback onDetail;

  /// 启动这个游戏（与点卡同一入口）；null = 菜单不画「启动游戏」主按钮。
  final VoidCallback? onLaunch;

  /// 打开「文本 Hook 与制卡」工作台（详情页编辑 tab）；null = 直接推详情页。
  final VoidCallback? onOpenWorkbench;

  /// 每个动作（「详情」除外）执行完、[context] 仍挂载时调一次。仓储写操作自己会
  /// 通知监听者；不在仓储里的派生状态（游戏库的合集映射）由调用方在这里重取。
  final VoidCallback? onChanged;

  AppModel get _appModel => ref.read(appProvider);
  GalgameRepository get _repo => _appModel.galgameRepo;

  void dispatch(GalgameItemAction action) {
    if (action == GalgameItemAction.detail) {
      onDetail();
      return;
    }
    unawaited(_perform(action));
  }

  Future<void> _perform(GalgameItemAction action) async {
    switch (action) {
      case GalgameItemAction.detail:
        onDetail();
        return;
      case GalgameItemAction.status:
        await _promptPlayStatus();
      case GalgameItemAction.cleared:
        await _repo.setPlayStatus(
          game.id,
          galgameClearedToggleTarget(game.playStatus),
        );
      case GalgameItemAction.hookWorkbench:
        final VoidCallback? open = onOpenWorkbench;
        if (open != null) {
          open();
        } else {
          await openGalgameEditTab(context, game.id);
        }
      case GalgameItemAction.stats:
        await showMediaItemStatsDialog(
          context,
          database: _appModel.database,
          target: MediaItemStatsTarget(
            mediaKind: kActivityMediaGame,
            mediaKeys: <String>{game.id},
            title: game.displayName,
          ),
        );
      case GalgameItemAction.rename:
        await _rename();
      case GalgameItemAction.cover:
        await _setCover();
      case GalgameItemAction.onlineCover:
        await showGalgameOnlineCoverDialog(
          context: context,
          game: game,
          repo: _repo,
        );
      case GalgameItemAction.autoCover:
        await _autoCover();
      case GalgameItemAction.scrape:
        await showGalgameScrapeDialog(
          context: context,
          game: game,
          repo: _repo,
        );
      case GalgameItemAction.collect:
        await _addToCollection();
      case GalgameItemAction.tags:
        await _editTags();
      case GalgameItemAction.privacy:
        await showMediaPrivacyDialog(
          context,
          db: _appModel.database,
          kind: TagHostKind.game,
          entryKey: game.id,
          title: game.displayName,
        );
      case GalgameItemAction.language:
        await _editLanguage();
      case GalgameItemAction.upscaling:
        await _editUpscaling();
      case GalgameItemAction.japaneseLocale:
        await _editJapaneseLocale();
      case GalgameItemAction.fileLocation:
        await _openFileLocation();
      case GalgameItemAction.remove:
        await _remove();
    }
    final VoidCallback? changed = onChanged;
    if (changed != null && context.mounted) changed();
  }

  /// 游玩状态单选框（想玩 → 在玩 → 玩过 → 搁置 → 弃坑 + 未设置）。
  Future<void> _promptPlayStatus() async {
    final GalgamePlayStatus? picked = await showAppDialog<GalgamePlayStatus>(
      context: context,
      builder: (BuildContext ctx) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        return FushiDialogFrame(
          maxWidth: 420,
          scrollable: false,
          child: FushiModalSheetFrame(
            title: t.game_play_status,
            leadingIcon: FushiIcons.flag,
            scrollable: true,
            bodyPadding: EdgeInsets.fromLTRB(
              tokens.spacing.gap,
              0,
              tokens.spacing.gap,
              tokens.spacing.card,
            ),
            body: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final GalgamePlayStatus status in <GalgamePlayStatus>[
                  ...kGalgamePlayStatusMenuOrder,
                  GalgamePlayStatus.unset,
                ])
                  FushiListItem(
                    density: FushiListDensity.compact,
                    selected: game.playStatus == status,
                    leading: FushiListLeadingIcon(
                      galgamePlayStatusIcon(status),
                      size: 36,
                      iconSize: 20,
                      shape: game.playStatus == status
                          ? FushiLeadingShape.cookie
                          : FushiLeadingShape.circle,
                      tone: game.playStatus == status
                          ? FushiCardTone.primary
                          : FushiCardTone.secondary,
                    ),
                    title: Text(galgamePlayStatusLabel(status)),
                    trailing: game.playStatus == status
                        ? FushiIcon(
                            FushiIcons.check,
                            size: 20,
                            color: Theme.of(ctx).colorScheme.primary,
                          )
                        : null,
                    onTap: () => Navigator.of(ctx).pop(status),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || picked == game.playStatus) return;
    await _repo.setPlayStatus(game.id, picked);
  }

  /// 改显示名：写用户覆盖层 `customDataJson.name`，不动本地默认名。
  Future<void> _rename() async {
    final String? name = await showAppDialog<String>(
      context: context,
      builder: (BuildContext ctx) =>
          GalgameRenameDialog(initial: game.displayName),
    );
    if (name == null || name.isEmpty || name == game.displayName) return;
    await _repo.setCustomData(game.id, game.customData.copyWith(name: name));
  }

  /// 手动设封面：统一封面服务选图 → 拷进 `game_covers` → 回填条目。
  Future<void> _setCover() async {
    final File? picked = await MediaCoverService.pickCoverImage();
    if (picked == null) return;
    final String? saved = await MediaCoverService.applyGameCover(
      gameId: game.id,
      sourcePath: picked.path,
    );
    if (saved == null) {
      FushiToast.show(
        msg: t.game_cover_not_found,
        severity: ToastSeverity.error,
      );
      return;
    }
    await _applyCover(saved);
    FushiToast.show(msg: t.game_cover_updated, severity: ToastSeverity.success);
  }

  /// 自动封面：游戏目录里的封面图 → exe 内嵌图标。用户主动触发，两种结局都播报。
  Future<void> _autoCover() async {
    FushiToast.show(msg: t.game_cover_searching, severity: ToastSeverity.info);
    final ResolvedGameCover? resolved = await autoResolveGameCover(
      gameId: game.id,
      gameName: game.displayName,
      exePath: game.exePath,
      workdir: game.workdir,
    );
    if (resolved == null) {
      FushiToast.show(
        msg: t.game_cover_not_found,
        severity: ToastSeverity.error,
      );
      return;
    }
    await _applyCover(resolved.path);
    FushiToast.show(msg: t.game_cover_updated, severity: ToastSeverity.success);
  }

  Future<void> _applyCover(String coverPath) async {
    // 期间用户可能已删掉这条：行不在就是空操作。
    if (_repo.byId(game.id) == null) return;
    await _repo.setCoverPath(game.id, coverPath);
  }

  Future<void> _addToCollection() async {
    await showAddToCollectionDialog(
      context: context,
      database: _appModel.database,
      mediaType: MediaKind.game,
      entryKey: game.id,
      defaultNewName: game.displayName,
      isMemberVisible: (String mediaType, String entryKey) =>
          isGameCollectionMemberVisible(
            games: _repo.games,
            mediaType: mediaType,
            entryKey: entryKey,
          ),
    );
  }

  Future<void> _editTags() async {
    await showTagPicker(
      context,
      targets: TagTargets(
        media: <MediaRef>[MediaRef(kind: MediaKind.game, entryKey: game.id)],
      ),
    );
    if (!context.mounted) return;
    ref.invalidate(allTagsProvider);
    ref.invalidate(gameTagMapProvider);
    ref.invalidate(filteredGameIdsProvider);
  }

  Future<void> _editLanguage() async {
    await showContentLanguagePicker(
      context: context,
      title: t.book_language_action,
      description: t.book_language_description,
      current: game.language,
      autoDetected: '',
      onSelected: (String? tag) => unawaited(_repo.setLanguage(game.id, tag)),
    );
  }

  Future<void> _editUpscaling() async {
    final MagpieUpscalingMode? picked = await pickMagpieUpscalingMode(
      context,
      current: magpieUpscalingModeFromKey(game.upscalingMode),
      gameName: game.displayName,
    );
    if (picked == null) return;
    await _repo.setUpscalingMode(game.id, magpieUpscalingModeToKey(picked));
  }

  Future<void> _editJapaneseLocale() async {
    final GalJapaneseLocaleMode? picked = await pickGalJapaneseLocaleMode(
      context,
      current: galJapaneseLocaleModeFromKey(game.japaneseLocaleMode),
      gameName: game.displayName,
    );
    if (picked == null) return;
    await _repo.setJapaneseLocaleMode(
      game.id,
      galJapaneseLocaleModeToKey(picked),
    );
  }

  /// 先选中 exe，exe 不在了退回工作目录；两个都打不开才提示。
  Future<void> _openFileLocation() async {
    final bool revealed = await revealFirstOf(<String>[
      game.exePath,
      game.workdir,
    ]);
    if (revealed || !context.mounted) return;
    FushiToast.show(
      msg: t.media_file_location_failed,
      severity: ToastSeverity.error,
    );
  }

  /// 从库移除（不删磁盘文件）；勾了「同时删除统计数据」先清统计再删行
  /// （统计删除 best-effort：失败只记日志，不拦移除）。
  Future<void> _remove() async {
    final FushiDestructiveConfirmResult? result =
        await showAppDialog<FushiDestructiveConfirmResult>(
          context: context,
          builder: (_) => FushiDestructiveConfirmDialog(
            title: t.game_remove,
            message: t.game_remove_confirm,
            confirmLabel: t.game_remove,
            statisticsSubtitle: t.delete_statistics_game_desc,
          ),
        );
    if (result == null || !context.mounted) return;
    if (result.deleteStatistics) {
      try {
        await _appModel.database.deleteGameStatisticsForId(game.id);
      } catch (e, stack) {
        ErrorLogService.instance.log('GameHome.deleteGameStatistics', e, stack);
      }
    }
    await _repo.remove(game.id);
  }
}

/// 重命名输入框：controller 由自身 State 持有、在 dispose 里释放。确认返回
/// trimmed 名称。
class GalgameRenameDialog extends StatefulWidget {
  const GalgameRenameDialog({required this.initial, super.key});

  final String initial;

  @override
  State<GalgameRenameDialog> createState() => _GalgameRenameDialogState();
}

class _GalgameRenameDialogState extends State<GalgameRenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 420,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.game_rename,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: FushiTextField(
          controller: _controller,
          labelText: t.game_rename_label,
          autofocus: true,
          onSubmitted: (String v) => Navigator.of(context).pop(v.trim()),
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: () =>
                  Navigator.of(context).pop(_controller.text.trim()),
              child: Text(t.dialog_ok),
            ),
          ],
        ),
      ),
    );
  }
}
