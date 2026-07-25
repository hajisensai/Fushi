import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/mining/gal_hook_failure_text.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/galgame_cover_resolver.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/galgame_library_query.dart';
import 'package:hibiki/src/mining/galgame_repository.dart';
import 'package:hibiki/src/pages/implementations/galgame_detail_page.dart';
import 'package:hibiki/utils.dart';

/// 首页「游戏」tab：galgame 库。展示用户添加的游戏网格，点击一个游戏经
/// [GalHookSessionController.launchGame]（引擎-hook launch 路径）拉起并注入。
/// 台词进入同一个捕获会话，原生浮窗点词与工作台制卡共享稳定 lineId。
///
/// 顶部工具条提供搜索 / 排序 / 筛选（纯函数实现在 `galgame_library_query.dart`，
/// 排序与筛选偏好走现有偏好体系持久化）；卡片点击**仍然是启动游戏**（不破坏肌肉
/// 记忆），长按 / 右键菜单里进详情页（[GalgameDetailPage]）。
///
/// 持久化自 v55 起走 Drift 表 `galgames`（[GalgameRepository]），旧偏好 JSON key
/// 已由 DB 迁移一次性回填。仅 Windows 桌面有注入能力；非 Windows 点击启动时优雅提示
/// 不支持，添加/管理列表仍可用。
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

  /// 游戏库仓储（Drift 表真相源）。`late final` 惰性求值，非游戏路径不碰 DB。
  late final GalgameRepository _repo = _appModel.galgameRepo;

  /// 本页持有的**全量**游戏列表（渲染前经 [_view] 过滤排序）。
  late List<GalgameEntry> _games = _repo.games;

  /// 搜索 / 排序 / 筛选视图状态（除搜索词外持久化）。
  late GalgameLibraryView _view =
      GalgameLibraryView.decode(_appModel.galgameLibraryView);

  final TextEditingController _searchController = TextEditingController();

  /// 启动流程的**再入守卫**：一次启动含位数探测、helper 确认/下载对话框、注入会话等多个 await，
  /// 全程可能持续数秒。没有此守卫时，用户在等待期间重复点击游戏卡片会各自开一条 _launchGame，
  /// 叠出多个「需要下载 galgame 引擎组件」对话框（用户实测症状）。true 期间忽略新的启动点击。
  bool _launching = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 从 DB 全量重载（三个批量查询，无 N+1）。
  Future<void> _reload() async {
    await _repo.load();
    _refresh();
  }

  /// 把仓储缓存同步到本页（仓储的每个写方法内部已重载）。
  void _refresh() {
    if (!mounted) return;
    setState(() => _games = _repo.games);
  }

  /// 改视图状态并持久化（搜索词不落库，见 [GalgameLibraryView]）。
  void _setView(GalgameLibraryView next) {
    setState(() => _view = next);
    unawaited(_appModel.setGalgameLibraryView(next.encode()));
  }

  /// 当前要渲染的列表（筛选 + 搜索 + 排序，纯函数）。
  List<GalgameEntry> get _visible => applyGalgameLibraryView(_games, _view);

  /// 添加游戏：文件选择器选一个 `.exe`，以文件名去扩展名作默认名，追加进列表。
  ///
  /// 落库后**不等封面**就返回（卡片先用默认占位图出现），封面解析在后台跑完再回填：
  /// 目录扫描 + exe 图标解析是磁盘/CPU 活，让它阻塞「添加」这一步会让 UI 无谓地卡住。
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
    final GalgameEntry entry = newGalgameEntryFromExe(exe);
    await _repo.addAll(<GalgameEntry>[entry]);
    _refresh();
    unawaited(_autoCover(entry, silent: true));
  }

  /// 拖入文件导入：筛出新的 `.exe` 批量添加，toast 汇报数量；每条落库后走
  /// 与「添加游戏」同一套 [_autoCover] 后台补齐封面（#370 目录级联 + exe 图标）。
  Future<void> _handleDrop(List<String> paths, Offset _) async {
    final List<String> exes = filterDroppedGameExes(_games, paths);
    if (exes.isEmpty) {
      HibikiToast.show(msg: t.games_drop_no_exe);
      return;
    }
    // 批内 id 用「基准时刻 + 序号微秒」错开，避免同微秒撞 id。
    final DateTime base = DateTime.now();
    final List<GalgameEntry> added = <GalgameEntry>[
      for (int i = 0; i < exes.length; i++)
        newGalgameEntryFromExe(exes[i],
            now: base.add(Duration(microseconds: i))),
    ];
    await _repo.addAll(added);
    _refresh();
    HibikiToast.show(msg: t.games_drop_imported(count: added.length));
    for (final GalgameEntry entry in added) {
      unawaited(_autoCover(entry, silent: true));
    }
  }

  /// 自动获取封面：游戏目录里的封面图 → exe 内嵌图标（[autoResolveGameCover]）。
  ///
  /// [silent] = 添加游戏后的后台补齐（成功静默、失败不打扰）；用户从菜单主动触发时
  /// 为 false，两种结局都给 toast，否则「点了没反应」无从判断。
  Future<void> _autoCover(GalgameEntry game, {bool silent = false}) async {
    if (!silent) HibikiToast.show(msg: t.games_cover_searching);
    final ResolvedGameCover? resolved = await autoResolveGameCover(
      gameId: game.id,
      gameName: game.displayName,
      exePath: game.exePath,
      workdir: game.workdir,
    );
    if (resolved == null) {
      if (!silent) HibikiToast.show(msg: t.games_cover_not_found);
      return;
    }
    await _applyCover(game, resolved.path);
    if (!silent) HibikiToast.show(msg: t.games_cover_updated);
  }

  /// 手动设置封面：选一张图 → 拷进 `<documents>/game_covers` → 回填条目。
  /// 与视频卡「设置封面」同款语义（拷盘而非引用原图，原图移动/删除不会让封面消失）。
  Future<void> _setCover(GalgameEntry game) async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    final String? source = (picked != null && picked.files.isNotEmpty)
        ? picked.files.first.path
        : null;
    if (source == null || source.isEmpty) return;
    final String? saved = await saveGameCoverFromFile(
      gameId: game.id,
      sourcePath: source,
    );
    if (saved == null) {
      HibikiToast.show(msg: t.games_cover_not_found);
      return;
    }
    await _applyCover(game, saved);
    HibikiToast.show(msg: t.games_cover_updated);
  }

  /// 把新封面路径写回条目并刷新。
  ///
  /// 必须先 `imageCache.evict`：[FileImage] 按 `(path, scale)` 缓存解码结果，换封面
  /// 常常落在**同一个** `<id>.<ext>` 路径上，不驱逐旧条目的话 UI 重建会命中旧解码，
  /// 用户看到的还是换之前那张图（与视频封面同一个坑，见 `setVideoCoverFromPickedFile`）。
  Future<void> _applyCover(GalgameEntry game, String coverPath) async {
    PaintingBinding.instance.imageCache.evict(FileImage(File(coverPath)));
    // 后台补齐期间用户可能已删掉这条：仓储按 id 更新，行不在就是空操作。
    if (_repo.byId(game.id) == null) return;
    await _repo.setCoverPath(game.id, coverPath);
    _refresh();
  }

  /// 移除一个游戏（按 id 定位；元数据源与游玩会话经 FK cascade 连带清理）。
  Future<void> _removeGame(GalgameEntry game) async {
    await _repo.remove(game.id);
    _refresh();
  }

  /// 重命名一个游戏：弹输入框改显示名（空名回退不改）。
  ///
  /// 写的是**用户覆盖层** `customDataJson.name`（契约 §1.3），不动 `galgames.name`
  /// 那个「exe 文件名推导的本地默认名」——这样详情页「清空自定义名」能干净回落。
  Future<void> _renameGame(GalgameEntry game) async {
    final String? name = await _promptName(initial: game.displayName);
    if (name == null || name.isEmpty || name == game.displayName) {
      return;
    }
    await _repo.setCustomData(game.id, game.customData.copyWith(name: name));
    _refresh();
  }

  /// 改游玩状态（契约 §1.5 的 5 个状态 + 未设置）。
  Future<void> _setPlayStatus(
      GalgameEntry game, GalgamePlayStatus status) async {
    await _repo.setPlayStatus(game.id, status);
    _refresh();
  }

  /// 弹状态选择对话框（菜单顺序：想玩 → 在玩 → 玩过 → 搁置 → 弃坑 + 未设置）。
  Future<void> _promptPlayStatus(GalgameEntry game) async {
    final GalgamePlayStatus? picked = await showDialog<GalgamePlayStatus>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: Text(t.games_play_status),
        children: <Widget>[
          for (final GalgamePlayStatus status in <GalgamePlayStatus>[
            ...kGalgamePlayStatusMenuOrder,
            GalgamePlayStatus.unset,
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(status),
              child: Row(
                children: <Widget>[
                  Icon(
                    game.playStatus == status
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  const SizedBox(width: 12),
                  Text(galgamePlayStatusLabel(status)),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == game.playStatus) return;
    await _setPlayStatus(game, picked);
  }

  /// 打开详情页（长按 / 右键菜单入口）。返回后重载，把详情页里的编辑/刮削同步回列表。
  Future<void> _openDetail(GalgameEntry game, {int initialTab = 0}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext ctx) => GalgameDetailPage(
          gameId: game.id,
          initialTab: initialTab,
          onLaunch: () {
            final GalgameEntry? latest = _repo.byId(game.id);
            if (latest != null) unawaited(_launchGame(latest));
          },
        ),
      ),
    );
    await _reload();
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
        final GalHookSessionState state =
            (widget.sessionController ?? GalHookSessionController.instance)
                .state;
        // 同 texthooker：先给用户可执行的处置，再退回内部消息。
        HibikiToast.show(
          msg: galHookFailureLabel(state.injectorFailure) ??
              state.lastError ??
              t.game_capture_launch_failed,
        );
        return;
      }
      widget.onLaunched?.call();
    } finally {
      _launching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<GalgameEntry> visible = _visible;
    final Widget grid = _games.isEmpty
        ? _buildEmpty(context)
        : (visible.isEmpty
            ? _buildNoMatch(context)
            : _buildGrid(context, visible));
    final Widget body = HibikiFileDropTarget(
      debugLabel: 'games-library',
      onDrop: (List<String> paths, Offset position) =>
          unawaited(_handleDrop(paths, position)),
      child: Column(
        children: <Widget>[
          if (_games.isNotEmpty) _buildToolbar(context),
          Expanded(child: grid),
        ],
      ),
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

  /// 顶部工具条：搜索框 + 排序入口 + 筛选入口。
  Widget _buildToolbar(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SizedBox(
              height: 40,
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: t.games_search,
                  border: const OutlineInputBorder(),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  suffixIcon: _view.search.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _view = _view.copyWith(search: ''));
                          },
                        ),
                ),
                // 搜索词只影响本次会话，不落库（见 GalgameLibraryView 注释）。
                onChanged: (String value) =>
                    setState(() => _view = _view.copyWith(search: value)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<GalgameSortField>(
            tooltip: t.games_sort,
            icon: const Icon(Icons.sort),
            onSelected: (GalgameSortField field) => _setView(
              field == _view.sortField
                  // 再点当前维度 = 翻转方向（少一个独立的升降序按钮）。
                  ? _view.copyWith(ascending: !_view.ascending)
                  : _view.copyWith(sortField: field),
            ),
            itemBuilder: (BuildContext context) =>
                <PopupMenuEntry<GalgameSortField>>[
              for (final GalgameSortField field in GalgameSortField.values)
                PopupMenuItem<GalgameSortField>(
                  value: field,
                  child: Row(
                    children: <Widget>[
                      Expanded(child: Text(galgameSortFieldLabel(field))),
                      if (field == _view.sortField)
                        Icon(
                          _view.ascending
                              ? Icons.arrow_upward
                              : Icons.arrow_downward,
                          size: 16,
                        ),
                    ],
                  ),
                ),
            ],
          ),
          IconButton(
            tooltip: t.games_filter,
            onPressed: () => unawaited(_showFilterSheet()),
            icon: Icon(
              _view.hasActiveFilter
                  ? Icons.filter_alt
                  : Icons.filter_alt_outlined,
              color: _view.hasActiveFilter ? colors.primary : null,
            ),
          ),
        ],
      ),
    );
  }

  /// 筛选面板：状态 / 本地·在线 / 标签多选 / NSFW 隐藏。改动即时生效并持久化。
  Future<void> _showFilterSheet() async {
    final List<String> allTags = collectGalgameTags(_games);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setSheetState) {
            void apply(GalgameLibraryView next) {
              setSheetState(() {});
              _setView(next);
            }

            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            t.games_filter,
                            style: Theme.of(ctx).textTheme.titleMedium,
                          ),
                        ),
                        TextButton(
                          onPressed: () => apply(_view.clearFilters()),
                          child: Text(t.games_filter_reset),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(t.games_filter_status,
                        style: Theme.of(ctx).textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        HibikiSelectableChip(
                          label: t.games_filter_all,
                          selected: _view.status == null,
                          onSelected: (_) =>
                              apply(_view.copyWith(clearStatus: true)),
                        ),
                        for (final GalgamePlayStatus status
                            in <GalgamePlayStatus>[
                          ...kGalgamePlayStatusMenuOrder,
                          GalgamePlayStatus.unset,
                        ])
                          HibikiSelectableChip(
                            label: galgamePlayStatusLabel(status),
                            selected: _view.status == status,
                            onSelected: (bool selected) => apply(
                              selected
                                  ? _view.copyWith(status: status)
                                  : _view.copyWith(clearStatus: true),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(t.games_filter_source,
                        style: Theme.of(ctx).textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final GalgameLocalFilter filter
                            in GalgameLocalFilter.values)
                          HibikiSelectableChip(
                            label: galgameLocalFilterLabel(filter),
                            selected: _view.localFilter == filter,
                            onSelected: (_) =>
                                apply(_view.copyWith(localFilter: filter)),
                          ),
                      ],
                    ),
                    if (allTags.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 16),
                      Text(t.games_filter_tags,
                          style: Theme.of(ctx).textTheme.labelLarge),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          for (final String tag in allTags)
                            HibikiSelectableChip(
                              label: tag,
                              selected: _view.tags.contains(tag),
                              onSelected: (bool selected) {
                                final Set<String> next =
                                    Set<String>.of(_view.tags);
                                if (selected) {
                                  next.add(tag);
                                } else {
                                  next.remove(tag);
                                }
                                apply(_view.copyWith(tags: next));
                              },
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(t.games_filter_hide_nsfw),
                      value: _view.hideNsfw,
                      onChanged: (bool value) =>
                          apply(_view.copyWith(hideNsfw: value)),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
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

  /// 「库里有游戏但被筛掉了」态：与空库分开，否则用户以为数据没了。
  Widget _buildNoMatch(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.search_off, size: 48, color: colors.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            t.games_no_match,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  /// 游戏海报网格（对齐 ReinaManager 库页：3:4 竖版海报卡，见
  /// `docs/design/galgame-library-reina-visual-parity.md` §1）。
  ///
  /// 不再套书架的 extent/比例：galgame 是竖版海报（3:4 封面 + 下方标题），与横向
  /// 偏方的书封不同形。maxCrossAxisExtent≈168（ReinaManager 海报宽档），间距 16，
  /// childAspectRatio 按「3:4 封面 + 一行标题」估（约 0.62），标题超长由卡内省略。
  Widget _buildGrid(BuildContext context, List<GalgameEntry> visible) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 168,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.62,
          ),
          itemCount: visible.length,
          itemBuilder: (BuildContext context, int i) => _GameCard(
            game: visible[i],
            sortLabel: galgameSortValueLabel(visible[i], _view.sortField),
            onTap: () => unawaited(_launchGame(visible[i])),
            onRename: () => unawaited(_renameGame(visible[i])),
            onRemove: () => unawaited(_removeGame(visible[i])),
            onSetCover: () => unawaited(_setCover(visible[i])),
            onAutoCover: () => unawaited(_autoCover(visible[i])),
            onPlayStatus: () => unawaited(_promptPlayStatus(visible[i])),
            onDetail: () => unawaited(_openDetail(visible[i])),
            onScrape: () => unawaited(_openDetail(visible[i], initialTab: 2)),
          ),
        );
      },
    );
  }
}

/// 游玩状态的用户可读标签（枚举 `.name` 直接上屏是 17 语言用户的灾难）。
String galgamePlayStatusLabel(GalgamePlayStatus status) => switch (status) {
      GalgamePlayStatus.unset => t.games_status_unset,
      GalgamePlayStatus.wantToPlay => t.games_status_want_to_play,
      GalgamePlayStatus.played => t.games_status_played,
      GalgamePlayStatus.playing => t.games_status_playing,
      GalgamePlayStatus.onHold => t.games_status_on_hold,
      GalgamePlayStatus.dropped => t.games_status_dropped,
    };

/// 排序维度的用户可读标签。
String galgameSortFieldLabel(GalgameSortField field) => switch (field) {
      GalgameSortField.added => t.games_sort_added,
      GalgameSortField.releaseDate => t.games_sort_release,
      GalgameSortField.lastPlayed => t.games_sort_last_played,
      GalgameSortField.siteScore => t.games_sort_site_score,
      GalgameSortField.userRating => t.games_sort_user_rating,
      GalgameSortField.name => t.games_sort_name,
    };

/// 本地/在线筛选的用户可读标签。
String galgameLocalFilterLabel(GalgameLocalFilter filter) => switch (filter) {
      GalgameLocalFilter.all => t.games_filter_all,
      GalgameLocalFilter.localOnly => t.games_filter_local_only,
      GalgameLocalFilter.metadataOnly => t.games_filter_metadata_only,
    };

/// 卡片「排序字段浮层」的文案：显示当前排序维度在这条游戏上的值。
///
/// 按添加时间/名称排序时返回 null（日期没信息量、名字就在标题里），不画浮层。
String? galgameSortValueLabel(GalgameEntry game, GalgameSortField field) {
  switch (field) {
    case GalgameSortField.added:
    case GalgameSortField.name:
      return null;
    case GalgameSortField.releaseDate:
      return game.effectiveReleaseDate;
    case GalgameSortField.lastPlayed:
      if (game.lastPlayedMs <= 0) return t.games_never_played;
      return formatGalgameDate(
          DateTime.fromMillisecondsSinceEpoch(game.lastPlayedMs));
    case GalgameSortField.siteScore:
      return game.siteScore?.toStringAsFixed(1);
    case GalgameSortField.userRating:
      return game.userRating?.toStringAsFixed(1);
  }
}

/// `YYYY-MM-DD` 本地日期（与 `galgame_sessions.dateKey` 同格式）。
String formatGalgameDate(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)}';
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
/// 溢出菜单。点击卡片启动游戏进入制卡，长按/右键出同款菜单（含「查看详情」）。
///
/// 走 [HibikiCard]（巡检 G1 根因修复）：注册 `game-card-<id>` 焦点站点，手柄/
/// 方向键可选中、A/Enter 启动；长按（手柄 hold A 之外的触摸长按）与鼠标右键弹
/// 出与封面溢出菜单相同的菜单，封面上的 [PopupMenuButton] 保留供鼠标点按。
class _GameCard extends StatelessWidget {
  const _GameCard({
    required this.game,
    required this.onTap,
    required this.onRename,
    required this.onRemove,
    required this.onSetCover,
    required this.onAutoCover,
    required this.onPlayStatus,
    required this.onDetail,
    required this.onScrape,
    this.sortLabel,
  });

  final GalgameEntry game;

  /// 当前排序维度在这条游戏上的值（null = 不画浮层）。
  final String? sortLabel;

  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onRemove;
  final VoidCallback onSetCover;
  final VoidCallback onAutoCover;
  final VoidCallback onPlayStatus;
  final VoidCallback onDetail;
  final VoidCallback onScrape;

  /// 长按 / 右键的上下文菜单：与封面溢出菜单同项。两处菜单**共用**
  /// [_menuItems] 与 [_dispatchAction]，避免两份手抄。
  Future<void> _showContextMenu(BuildContext context) async {
    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: Text(
          game.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        children: <Widget>[
          for (final (String value, String label) item in _menuItems)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(item.$1),
              child: Text(item.$2),
            ),
        ],
      ),
    );
    if (action != null) _dispatchAction(action);
  }

  /// 卡片菜单项单一真相源：`(action, 文案)`。
  List<(String, String)> get _menuItems => <(String, String)>[
        ('detail', t.games_view_detail),
        ('status', t.games_play_status),
        ('scrape', t.games_scrape),
        ('rename', t.games_rename),
        ('cover', t.games_set_cover),
        ('autocover', t.games_auto_cover),
        ('remove', t.games_remove),
      ];

  void _dispatchAction(String action) {
    switch (action) {
      case 'detail':
        onDetail();
      case 'status':
        onPlayStatus();
      case 'scrape':
        onScrape();
      case 'rename':
        onRename();
      case 'cover':
        onSetCover();
      case 'autocover':
        onAutoCover();
      case 'remove':
        onRemove();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String? sort = sortLabel;
    // 竖版海报卡（对齐 ReinaManager 库页观感）：封面 3:4 + 标题居中 + 底部排序
    // 浮层 + hover 放大 + 主色选中环，全部由共享组件 [GalgamePosterCard] 负责。
    // focusId 沿用 `game-card-<id>`（手柄/键盘可 requestById 聚焦，focus 测试守）。
    return GalgamePosterCard(
      cover: _buildCover(colors),
      title: game.displayName,
      overlayText: sort,
      focusId: HibikiFocusId('game-card-${game.id}'),
      onTap: onTap,
      onLongPress: () => unawaited(_showContextMenu(context)),
      onSecondaryTap: () => unawaited(_showContextMenu(context)),
      trailing: _menuButton(context, colors, tokens),
      semanticLabel: game.displayName,
    );
  }

  /// 卡片右上角的更多菜单按钮（半透明 scrim 圆底承托图标，浅色封面上也清晰）。
  Widget _menuButton(
    BuildContext context,
    ColorScheme colors,
    HibikiDesignTokens tokens,
  ) {
    return PopupMenuButton<String>(
      icon: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: tokens.surfaces.page.withValues(
            alpha: isEinkTheme(context) ? 1 : 0.7,
          ),
          border: Border.all(color: tokens.surfaces.outline),
        ),
        child: Icon(Icons.more_vert, size: 18, color: colors.onSurface),
      ),
      onSelected: _dispatchAction,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        for (final (String value, String label) item in _menuItems)
          PopupMenuItem<String>(value: item.$1, child: Text(item.$2)),
      ],
    );
  }

  // ── 旧的手搭卡片（HibikiCard + Stack + 手抄标题 footer）已由上面的
  //    GalgamePosterCard 取代，_buildCover / _defaultCover 仍复用。──

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
