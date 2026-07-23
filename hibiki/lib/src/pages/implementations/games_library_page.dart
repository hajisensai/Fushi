import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/galgame_cover.dart';
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

  /// 启动流程的**再入守卫**：一次启动含位数探测、helper 确认/下载对话框、注入会话等多个 await，
  /// 全程可能持续数秒。没有此守卫时，用户在等待期间重复点击游戏卡片会各自开一条 _launchGame，
  /// 叠出多个「需要下载 galgame 引擎组件」对话框（用户实测症状）。true 期间忽略新的启动点击。
  bool _launching = false;

  @override
  void initState() {
    super.initState();
    // 已有条目缺封面的懒回填（旧数据升级路径）：后台提取 exe 图标，成功才回写。
    unawaited(_backfillAutoCovers());
  }

  /// 覆写持久化 + 刷新本页。
  Future<void> _persist(List<GalgameEntry> next) async {
    await _appModel.setGalgames(next);
    if (!mounted) return;
    setState(() => _games = next);
  }

  /// 为无封面（或封面文件已丢失）的条目提取 exe 图标作默认封面。全程 best-effort：
  /// 一个都没提出来就不写库；期间用户增删改由 [_persist] 后重新读 `_games` 保证不覆盖。
  Future<void> _backfillAutoCovers() async {
    final List<GalgameEntry> snapshot = List<GalgameEntry>.of(_games);
    final Map<String, String> covers = <String, String>{};
    for (final GalgameEntry game in snapshot) {
      final String? existing = game.coverPath;
      if (existing != null &&
          existing.isNotEmpty &&
          File(existing).existsSync()) {
        continue;
      }
      if (!File(game.exePath).existsSync()) continue;
      final String? cover = await generateGalgameAutoCover(
        exePath: game.exePath,
        entryId: game.id,
      );
      if (cover != null) covers[game.id] = cover;
    }
    if (covers.isEmpty || !mounted) return;
    // 基于**当前**列表合并（回填期间可能有增删改），只补仍然无有效封面的条目。
    final List<GalgameEntry> next = _games.map((GalgameEntry g) {
      final String? cover = covers[g.id];
      if (cover == null) return g;
      final String? current = g.coverPath;
      final bool stillMissing =
          current == null || current.isEmpty || !File(current).existsSync();
      return stillMissing ? g.withCover(cover) : g;
    }).toList();
    await _persist(next);
  }

  /// 由一个 exe 路径构造条目并尝试自动封面（提取失败就无封面，占位图标兜底）。
  Future<GalgameEntry> _entryWithAutoCover(String exe, {DateTime? now}) async {
    final GalgameEntry entry = newGalgameEntryFromExe(exe, now: now);
    final String? cover = await generateGalgameAutoCover(
      exePath: exe,
      entryId: entry.id,
    );
    return cover == null ? entry : entry.copyWith(coverPath: cover);
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
    if (filterDroppedGameExes(_games, <String>[exe]).isEmpty) {
      HibikiToast.show(msg: t.games_already_added);
      return; // 已在库里：不重复添加
    }
    final GalgameEntry entry = await _entryWithAutoCover(exe);
    await _persist(<GalgameEntry>[..._games, entry]);
  }

  /// 拖入文件导入：筛出新的 `.exe` 批量添加（每条尝试自动封面），toast 汇报结果。
  Future<void> _handleDrop(List<String> paths, Offset _) async {
    final List<String> exes = filterDroppedGameExes(_games, paths);
    if (exes.isEmpty) {
      HibikiToast.show(msg: t.games_drop_no_exe);
      return;
    }
    // 批内 id 用「基准时刻 + 序号微秒」错开，避免同微秒撞 id。
    final DateTime base = DateTime.now();
    final List<GalgameEntry> added = <GalgameEntry>[];
    for (int i = 0; i < exes.length; i++) {
      added.add(await _entryWithAutoCover(
        exes[i],
        now: base.add(Duration(microseconds: i)),
      ));
    }
    if (!mounted) return;
    await _persist(<GalgameEntry>[..._games, ...added]);
    HibikiToast.show(msg: t.games_drop_imported(count: added.length));
  }

  /// 设置自定义封面：选一张图片拷贝进 app 封面目录并回写条目。
  Future<void> _pickCover(GalgameEntry game) async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
    );
    final String? source = (picked != null && picked.files.isNotEmpty)
        ? picked.files.first.path
        : null;
    if (source == null || source.isEmpty) {
      return; // 用户取消
    }
    final String? cover = await importGalgameCustomCover(
      sourcePath: source,
      entryId: game.id,
    );
    if (cover == null) {
      HibikiToast.show(msg: t.games_cover_failed);
      return;
    }
    // 换下封面后清掉被替换的旧封面文件（自动图标保留，恢复默认时还能复用）。
    final String? old = game.coverPath;
    if (old != null && old != cover && !isGalgameAutoCover(old)) {
      await deleteGalgameCoverFile(old);
    }
    await _persist(
      _games
          .map((GalgameEntry g) => g.id == game.id ? g.withCover(cover) : g)
          .toList(),
    );
  }

  /// 恢复默认封面：删掉自定义封面文件，重新提取 exe 图标（提不出则回退占位）。
  Future<void> _resetCover(GalgameEntry game) async {
    final String? old = game.coverPath;
    if (old != null && !isGalgameAutoCover(old)) {
      await deleteGalgameCoverFile(old);
    }
    final String? cover = await generateGalgameAutoCover(
      exePath: game.exePath,
      entryId: game.id,
    );
    await _persist(
      _games
          .map((GalgameEntry g) => g.id == game.id ? g.withCover(cover) : g)
          .toList(),
    );
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
    if (_launching) return; // 再入守卫：启动进行中，忽略重复点击（避免多开确认对话框）。
    _launching = true;
    try {
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
    } finally {
      _launching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = HibikiFileDropTarget(
      debugLabel: 'games-library',
      onDrop: (List<String> paths, Offset position) =>
          unawaited(_handleDrop(paths, position)),
      child: _games.isEmpty ? _buildEmpty(context) : _buildGrid(context),
    );
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
            onSetCover: () => unawaited(_pickCover(_games[i])),
            onResetCover: () => unawaited(_resetCover(_games[i])),
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
    required this.onSetCover,
    required this.onResetCover,
    required this.onRemove,
  });

  final GalgameEntry game;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onSetCover;
  final VoidCallback onResetCover;
  final VoidCallback onRemove;

  /// 是否有用户自定义封面（决定要不要给「恢复默认封面」入口）。
  bool get _hasCustomCover {
    final String? cover = game.coverPath;
    return cover != null && cover.isNotEmpty && !isGalgameAutoCover(cover);
  }

  /// 分发菜单动作（溢出菜单与长按/右键菜单共用）。
  void _onMenuAction(String action) {
    switch (action) {
      case 'rename':
        onRename();
      case 'cover':
        onSetCover();
      case 'coverReset':
        onResetCover();
      case 'remove':
        onRemove();
    }
  }

  /// 长按 / 右键的上下文菜单：与封面溢出菜单同项（重命名 / 封面 / 移除）。
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
            onPressed: () => Navigator.of(ctx).pop('cover'),
            child: Text(t.games_set_cover),
          ),
          if (_hasCustomCover)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop('coverReset'),
              child: Text(t.games_reset_cover),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('remove'),
            child: Text(t.games_remove),
          ),
        ],
      ),
    );
    if (action != null) _onMenuAction(action);
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
                    onSelected: _onMenuAction,
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'rename',
                        child: Text(t.games_rename),
                      ),
                      PopupMenuItem<String>(
                        value: 'cover',
                        child: Text(t.games_set_cover),
                      ),
                      if (_hasCustomCover)
                        PopupMenuItem<String>(
                          value: 'coverReset',
                          child: Text(t.games_reset_cover),
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
  /// 自动提取的 exe 图标是小方图，用 contain + 边距贴在底色上（cover 裁切会糊）；
  /// 用户自定义封面按海报图 cover 填满。
  Widget _buildCover(ColorScheme colors) {
    final String? cover = game.coverPath;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      final bool auto = isGalgameAutoCover(cover);
      final Widget image = Image.file(
        File(cover),
        fit: auto ? BoxFit.contain : BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            _defaultCover(colors),
      );
      if (!auto) return image;
      return Container(
        color: colors.surfaceContainerHighest,
        padding: const EdgeInsets.all(24),
        child: image,
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
