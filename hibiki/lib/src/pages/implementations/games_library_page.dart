import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
// 书架卡片规格单一真相源（kShelfBookCardAspectRatio / kShelfTitleFooterHeight）。
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart'
    show kShelfBookCardAspectRatio, kShelfTitleFooterHeight;
import 'package:hibiki/utils.dart';

/// 首页「游戏」tab：galgame 库。展示用户添加的游戏网格，点击一个游戏经
/// [GalHookSessionController.launchGame]（引擎-hook launch 路径）拉起并注入。
/// 台词进入同一个捕获会话，原生浮窗点词与工作台制卡共享稳定 lineId。
///
/// 仿书籍/视频库的网格布局，但**不含**「继续游戏」（续玩恢复）与「活动热力图」——只是
/// 干净的游戏网格 + 添加入口。
///
/// 持久化走偏好表单一 JSON key（[AppModel.galgames] / [AppModel.setGalgames]），不建
/// Drift 表。仅 Windows 桌面有注入能力；非 Windows 点击启动时优雅提示不支持，添加/管理
/// 列表仍可用。
class GamesLibraryPage extends ConsumerStatefulWidget {
  const GamesLibraryPage({
    super.key,
    this.embedded = false,
    this.sessionController,
    this.onLaunched,
  });

  final bool embedded;
  final GalHookSessionController? sessionController;
  final VoidCallback? onLaunched;

  @override
  ConsumerState<GamesLibraryPage> createState() => _GamesLibraryPageState();
}

class _GamesLibraryPageState extends ConsumerState<GamesLibraryPage> {
  /// 缓存 [AppModel]（`appProvider` 单例，实例不变）。
  late final AppModel _appModel = ref.read(appProvider);

  /// 本页持有的游戏列表（从持久化载入，增删改后回写并 setState 刷新）。
  late List<GalgameEntry> _games = List<GalgameEntry>.of(_appModel.galgames);

  /// 覆写持久化 + 刷新本页。
  Future<void> _persist(List<GalgameEntry> next) async {
    await _appModel.setGalgames(next);
    if (!mounted) return;
    setState(() => _games = next);
  }

  /// 添加游戏：文件选择器选一个 `.exe`，以文件名去扩展名作默认名，追加进列表。
  Future<void> _addGame() async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['exe'],
    );
    final String? exe = (picked != null && picked.files.isNotEmpty)
        ? picked.files.first.path
        : null;
    if (exe == null || exe.isEmpty) {
      return; // 用户取消
    }
    final GalgameEntry entry = newGalgameEntryFromExe(exe);
    await _persist(<GalgameEntry>[..._games, entry]);
  }

  /// 移除一个游戏（按 id 定位）。
  Future<void> _removeGame(GalgameEntry game) async {
    await _persist(
      _games.where((GalgameEntry g) => g.id != game.id).toList(),
    );
  }

  /// 重命名一个游戏：弹输入框改显示名（空名回退不改）。
  Future<void> _renameGame(GalgameEntry game) async {
    final String? name = await _promptName(initial: game.name);
    if (name == null || name.isEmpty || name == game.name) {
      return;
    }
    await _persist(
      _games
          .map((GalgameEntry g) => g.id == game.id ? g.copyWith(name: name) : g)
          .toList(),
    );
  }

  /// 弹一个单行输入对话框返回用户输入的名称（取消返回 null）。
  ///
  /// controller 由对话框内容自己的 State 持有并在其 dispose 里释放——旧实现
  /// 在 `showDialog` 返回后立即 `controller.dispose()`，此时退出动画尚未结束、
  /// TextField 还挂在树上，属于过早释放。
  Future<String?> _promptName({required String initial}) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => _RenameGameDialog(initial: initial),
    );
  }

  /// 启动一个游戏 → 台词进查词弹窗：非 Windows 优雅提示不支持；Windows 上交给
  /// 启动前先按 exe 位数确保 helper 就位，再交给 app 级 Hook 会话。
  Future<void> _launchGame(GalgameEntry game) async {
    if (!Platform.isWindows) {
      HibikiToast.show(msg: t.games_launch_unsupported);
      return;
    }
    if (!File(game.exePath).existsSync()) {
      HibikiToast.show(msg: t.games_exe_missing);
      return;
    }
    final bool is32Bit =
        await EngineHookGalAudioSource.exeIs32Bit(game.exePath) ?? false;
    if (GalHookSessionController.defaultInjectorResolver(is32Bit: is32Bit) ==
        null) {
      if (!mounted) return;
      final bool installed = await GalgameHelperInstaller().ensureInjector(
        is32Bit: is32Bit,
        context: context,
      );
      if (!installed || !mounted) return;
    }
    final bool launched =
        await (widget.sessionController ?? GalHookSessionController.instance)
            .launchGame(game.exePath);
    if (!mounted) return;
    if (!launched) {
      final String? reason =
          (widget.sessionController ?? GalHookSessionController.instance)
              .state
              .lastError;
      HibikiToast.show(msg: reason ?? t.game_capture_launch_failed);
      return;
    }
    widget.onLaunched?.call();
  }

  @override
  Widget build(BuildContext context) {
    final Widget body =
        _games.isEmpty ? _buildEmpty(context) : _buildGrid(context);
    final Widget addButton = FloatingActionButton.extended(
      onPressed: _addGame,
      icon: const Icon(Icons.add),
      label: Text(t.games_add),
    );
    if (widget.embedded) {
      return Stack(
        children: <Widget>[
          Positioned.fill(child: body),
          Positioned(right: 16, bottom: 16, child: addButton),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(t.games),
      ),
      floatingActionButton: addButton,
      body: body,
    );
  }

  /// 空态：居中图标 + 提示 + 添加按钮。
  Widget _buildEmpty(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.videogame_asset_outlined,
            size: 64,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            t.games_empty,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _addGame,
            icon: const Icon(Icons.add),
            label: Text(t.games_add),
          ),
        ],
      ),
    );
  }

  /// 游戏网格（无「继续游戏」/热力图，纯列表）。
  ///
  /// 卡槽规格对齐书架（巡检 C4：旧硬编码 180/0.72 自成一派）：extent 走书架的
  /// 响应式断点 [readerShelfGridExtentForLayout]，槽比用 [kShelfBookCardAspectRatio]，
  /// 标题在固定 40px footer（[kShelfTitleFooterHeight]）里，同一封面在书架与游戏库
  /// 同形同宽。
  Widget _buildGrid(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: readerShelfGridExtentForLayout(
              mediaWidth: MediaQuery.sizeOf(context).width,
              contentWidth: constraints.maxWidth,
            ),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: kShelfBookCardAspectRatio,
          ),
          itemCount: _games.length,
          itemBuilder: (BuildContext context, int i) => _GameCard(
            game: _games[i],
            onTap: () => unawaited(_launchGame(_games[i])),
            onRename: () => unawaited(_renameGame(_games[i])),
            onRemove: () => unawaited(_removeGame(_games[i])),
          ),
        );
      },
    );
  }
}

/// 重命名输入对话框：内容自身持有 [TextEditingController] 并在 State.dispose
/// 释放（路由完全退出后由框架回收，修过早 dispose）。确认返回 trimmed 名称。
class _RenameGameDialog extends StatefulWidget {
  const _RenameGameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameGameDialog> createState() => _RenameGameDialogState();
}

class _RenameGameDialogState extends State<_RenameGameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.games_rename),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: t.games_rename_label),
        onSubmitted: (String v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(t.dialog_ok),
        ),
      ],
    );
  }
}

/// 单个游戏卡：封面（有 coverPath 用图，否则默认手柄图标）+ 固定 footer 名称 +
/// 溢出菜单（重命名 / 移除）。点击卡片启动游戏进入制卡。
///
/// 走 [HibikiCard]（巡检 G1 根因修复）：注册 `game-card-<id>` 焦点站点，手柄/
/// 方向键可选中、A/Enter 启动；长按（手柄 hold A 之外的触摸长按）与鼠标右键弹
/// 出与封面溢出菜单相同的重命名/移除菜单，封面上的 [PopupMenuButton] 保留供
/// 鼠标点按。
class _GameCard extends StatelessWidget {
  const _GameCard({
    required this.game,
    required this.onTap,
    required this.onRename,
    required this.onRemove,
  });

  final GalgameEntry game;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  /// 长按 / 右键的上下文菜单：与封面溢出菜单同两项（重命名 / 移除）。
  Future<void> _showContextMenu(BuildContext context) async {
    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: Text(
          game.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('rename'),
            child: Text(t.games_rename),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('remove'),
            child: Text(t.games_remove),
          ),
        ],
      ),
    );
    if (action == 'rename') {
      onRename();
    } else if (action == 'remove') {
      onRemove();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiCard(
      padding: EdgeInsets.zero,
      focusId: HibikiFocusId('game-card-${game.id}'),
      onTap: onTap,
      onLongPress: () => unawaited(_showContextMenu(context)),
      onSecondaryTap: () => unawaited(_showContextMenu(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _buildCover(colors),
                Positioned(
                  top: 0,
                  right: 0,
                  child: PopupMenuButton<String>(
                    // 半透明 scrim 圆底承托图标（书架选择勾同款调性），替代
                    // Colors.black54 阴影——浅色封面上阴影对比不足且 eink 下发灰。
                    icon: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: tokens.surfaces.page.withValues(
                          alpha: isEinkTheme(context) ? 1 : 0.7,
                        ),
                        border: Border.all(color: tokens.surfaces.outline),
                      ),
                      child: Icon(
                        Icons.more_vert,
                        size: 18,
                        color: colors.onSurface,
                      ),
                    ),
                    onSelected: (String value) {
                      if (value == 'rename') {
                        onRename();
                      } else if (value == 'remove') {
                        onRemove();
                      }
                    },
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'rename',
                        child: Text(t.games_rename),
                      ),
                      PopupMenuItem<String>(
                        value: 'remove',
                        child: Text(t.games_remove),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 与书架书卡同款固定标题 footer（40px，长名不推挤网格）。
          SizedBox(
            height: kShelfTitleFooterHeight,
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                tokens.spacing.gap * 0.75,
                tokens.spacing.gap / 2,
                tokens.spacing.gap * 0.75,
                0,
              ),
              child: Align(
                alignment: Alignment.topCenter,
                child: Text(
                  game.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  softWrap: true,
                  style: tokens.type.metadata.copyWith(
                    color: tokens.surfaces.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 封面：有 coverPath 且文件存在则显示图片，否则默认手柄图标占位。
  Widget _buildCover(ColorScheme colors) {
    final String? cover = game.coverPath;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      return Image.file(
        File(cover),
        fit: BoxFit.cover,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            _defaultCover(colors),
      );
    }
    return _defaultCover(colors);
  }

  Widget _defaultCover(ColorScheme colors) {
    return Container(
      color: colors.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.videogame_asset,
        size: 48,
        color: colors.onSurfaceVariant,
      ),
    );
  }
}
