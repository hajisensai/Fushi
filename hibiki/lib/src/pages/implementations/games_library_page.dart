import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/galgame_session_controller.dart';
import 'package:hibiki/utils.dart';

/// 首页「游戏」tab：galgame 库。展示用户添加的游戏网格，点击一个游戏经
/// [GalgameSessionController.launch]（引擎-hook launch 路径）拉起并注入——台词自动喂进悬浮
/// 查词面板（与剪贴板查词同去向），用户在面板里点词查词 / 制卡，制卡自动带该句语音 + 游戏
/// 窗口封面。不再进独立文本页（texthooker tab / TexthookerPage 已删）。
///
/// 仿书籍/视频库的网格布局，但**不含**「继续游戏」（续玩恢复）与「活动热力图」——只是
/// 干净的游戏网格 + 添加入口。
///
/// 持久化走偏好表单一 JSON key（[AppModel.galgames] / [AppModel.setGalgames]），不建
/// Drift 表。仅 Windows 桌面有注入能力；非 Windows 点击启动时优雅提示不支持，添加/管理
/// 列表仍可用。
class GamesLibraryPage extends ConsumerStatefulWidget {
  const GamesLibraryPage({super.key});

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
  Future<String?> _promptName({required String initial}) async {
    final TextEditingController controller =
        TextEditingController(text: initial);
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: Text(t.games_rename),
          content: TextField(
            controller: controller,
            autofocus: true,
            onSubmitted: (String v) => Navigator.of(ctx).pop(v.trim()),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t.dialog_cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: Text(t.dialog_ok),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  /// 启动一个游戏 → 台词进查词弹窗：非 Windows 优雅提示不支持；Windows 上交给
  /// [GalgameSessionController.launch]（拉起游戏 + 注入引擎-hook + 接文本 hook）。台词从此
  /// 自动喂进悬浮查词面板，用户在面板里点词查词 / 制卡（制卡自动带该句语音 + 游戏窗口封面）。
  /// 不再 push 独立文本页——galgame 台词与剪贴板查词统一走同一去向路由（UX 统一）。
  Future<void> _launchGame(GalgameEntry game) async {
    if (!Platform.isWindows) {
      HibikiToast.show(msg: t.games_launch_unsupported);
      return;
    }
    if (!File(game.exePath).existsSync()) {
      HibikiToast.show(msg: t.games_exe_missing);
      return;
    }
    await GalgameSessionController.instance.launch(game);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.games),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addGame,
        icon: const Icon(Icons.add),
        label: Text(t.games_add),
      ),
      body: _games.isEmpty ? _buildEmpty(context) : _buildGrid(context),
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
  Widget _buildGrid(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.72,
      ),
      itemCount: _games.length,
      itemBuilder: (BuildContext context, int i) => _GameCard(
        game: _games[i],
        onTap: () => unawaited(_launchGame(_games[i])),
        onRename: () => unawaited(_renameGame(_games[i])),
        onRemove: () => unawaited(_removeGame(_games[i])),
      ),
    );
  }
}

/// 单个游戏卡：封面（有 coverPath 用图，否则默认手柄图标）+ 名称 + 溢出菜单
/// （重命名 / 移除）。点击卡片启动游戏进入制卡。
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

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
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
                      icon: Icon(
                        Icons.more_vert,
                        color: colors.onSurface,
                        shadows: const <Shadow>[
                          Shadow(blurRadius: 4, color: Colors.black54),
                        ],
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text(
                game.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
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
