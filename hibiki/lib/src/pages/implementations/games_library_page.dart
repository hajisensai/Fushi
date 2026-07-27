import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/collections/add_to_collection_dialog.dart';
import 'package:hibiki/src/media/collections/collection_context_dialog.dart';
import 'package:hibiki/src/media/collections/collection_grouping.dart';
import 'package:hibiki/src/media/collections/collection_shelf_row.dart'
    show CollectionShelfRow;
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/media_cover_service.dart';
import 'package:hibiki/src/mining/gal_hook_failure_text.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/galgame_cover_resolver.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/galgame_library_query.dart';
import 'package:hibiki/src/mining/galgame_repository.dart';
import 'package:hibiki/src/mining/galgame_scrape_dialog.dart';
import 'package:hibiki/src/pages/implementations/galgame_detail_page.dart';
import 'package:hibiki/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart'
    show DialogDangerAction, DialogQuickAction, MediaItemDialogFrame;
import 'package:hibiki/src/pages/implementations/tag_filter_bar.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_sheet.dart';
import 'package:hibiki/src/pages/implementations/tag_picker_page.dart';
import 'package:hibiki/utils.dart';

// 游戏进合集（统一媒体库）：mediaType 用 [MediaKind.game]（P5 枚举地基，取代旧
// 常量 kGameCollectionMediaType）。entryKey = `galgames.id`（添加时刻微秒时间戳
// 字符串）——**游戏本机局域身份**：与 exe 路径同为本机事实，跨端同步时对端无
// 对应 `galgames` 行则该成员静默忽略（合集同步引擎对 mediaType/entryKey 透传，
// 不解引用）。

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

  /// 合集分组映射（与书架 `_loadShelfMaps` 同款三件套）：合集字典、条目 → 主折叠
  /// 合集 id、条目在主折叠合集里的 sortIndex。[_reload] 时一并批量预取。
  Map<int, MediaCollectionRow> _collectionsById =
      const <int, MediaCollectionRow>{};
  Map<String, int> _primaryCollectionByEntry = const <String, int>{};
  Map<String, int> _memberSortIndex = const <String, int>{};

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

  /// 从 DB 全量重载（三个批量查询，无 N+1）+ 合集分组映射。
  Future<void> _reload() async {
    await _repo.load();
    await _loadCollectionMaps();
    _refresh();
  }

  /// 预取合集分组三件套（照书架 `_loadShelfMaps` 的口径：一次 getAllCollectionItems
  /// 内存分组，不逐合集 N+1；memberSortIndex 只记主折叠合集的行）。
  Future<void> _loadCollectionMaps() async {
    final HibikiDatabase db = _appModel.database;
    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    final Map<String, int> primaryMap =
        await db.getPrimaryCollectionIdByEntry();
    final Map<String, int> memberSortIndex = <String, int>{};
    for (final MediaCollectionItemRow m in await db.getAllCollectionItems()) {
      final String key = '${m.mediaType}|${m.entryKey}';
      if (primaryMap[key] == m.collectionId) memberSortIndex[key] = m.sortIndex;
    }
    _collectionsById = <int, MediaCollectionRow>{
      for (final MediaCollectionRow c in collections) c.id: c,
    };
    _primaryCollectionByEntry = primaryMap;
    _memberSortIndex = memberSortIndex;
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
  List<GalgameEntry> _visibleFor(Set<String>? allowedIds) =>
      applyGalgameLibraryView(_games, _view, allowedIds: allowedIds);

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
      HibikiToast.show(msg: t.game_already_added);
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
      HibikiToast.show(msg: t.game_drop_no_exe);
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
    HibikiToast.show(msg: t.game_drop_imported(count: added.length));
    for (final GalgameEntry entry in added) {
      unawaited(_autoCover(entry, silent: true));
    }
  }

  /// 自动获取封面：游戏目录里的封面图 → exe 内嵌图标（[autoResolveGameCover]）。
  ///
  /// [silent] = 添加游戏后的后台补齐（成功静默、失败不打扰）；用户从菜单主动触发时
  /// 为 false，两种结局都给 toast，否则「点了没反应」无从判断。
  Future<void> _autoCover(GalgameEntry game, {bool silent = false}) async {
    if (!silent) HibikiToast.show(msg: t.game_cover_searching);
    final ResolvedGameCover? resolved = await autoResolveGameCover(
      gameId: game.id,
      gameName: game.displayName,
      exePath: game.exePath,
      workdir: game.workdir,
    );
    if (resolved == null) {
      if (!silent) HibikiToast.show(msg: t.game_cover_not_found);
      return;
    }
    await _applyCover(game, resolved.path);
    if (!silent) HibikiToast.show(msg: t.game_cover_updated);
  }

  /// 手动设置封面：统一封面服务（P3）——[MediaCoverService.pickCoverImage] 平台
  /// 感知选图（移动端相册 / 桌面文件对话框），再经 [MediaCoverService.applyGameCover]
  /// 拷进 `<documents>/game_covers`（落盘 + 双键驱逐）→ 回填条目。与视频卡「设置
  /// 封面」同款语义（拷盘而非引用原图，原图移动/删除不会让封面消失）。
  ///
  /// 「没选到图」的三种形态（取消 / 空结果集 / 空 path）已在
  /// `pickGalleryImageFile` 内一次收敛为 `null`，这里只判 `null` 即与旧版
  /// `picked.files.isNotEmpty` + `source.isEmpty` 双守卫等价。
  Future<void> _setCover(GalgameEntry game) async {
    final File? picked = await MediaCoverService.pickCoverImage();
    if (picked == null) return;
    final String? saved = await MediaCoverService.applyGameCover(
      gameId: game.id,
      sourcePath: picked.path,
    );
    if (saved == null) {
      HibikiToast.show(msg: t.game_cover_not_found);
      return;
    }
    await _applyCover(game, saved);
    HibikiToast.show(msg: t.game_cover_updated);
  }

  /// 把新封面路径写回条目并刷新。
  ///
  /// 旧解码缓存驱逐（换封面常落同一 `<id>.<ext>` 路径，双键：裸 FileImage +
  /// ResizeImage）已由落盘收口 `MediaCoverService.applyCoverFile/applyCoverBytes`
  /// 在 `saveGameCover*` 内结构性保证，本方法只负责回填 DB + 刷新。
  Future<void> _applyCover(GalgameEntry game, String coverPath) async {
    // 后台补齐期间用户可能已删掉这条：仓储按 id 更新，行不在就是空操作。
    if (_repo.byId(game.id) == null) return;
    await _repo.setCoverPath(game.id, coverPath);
    _refresh();
  }

  /// 移除一个游戏（按 id 定位；元数据源与游玩会话经 FK cascade 连带清理）。
  ///
  /// 先弹统一确认框（与书架/合集同款 [HibikiDestructiveConfirmDialog]）：语义
  /// 只是**从库移除**，绝不删磁盘上的游戏文件——确认文案明说这点，免得用户
  /// 不敢点或误以为会连本体一起没。
  Future<void> _removeGame(GalgameEntry game) async {
    final HibikiDestructiveConfirmResult? result =
        await showAppDialog<HibikiDestructiveConfirmResult>(
      context: context,
      builder: (_) => HibikiDestructiveConfirmDialog(
        title: t.game_remove,
        message: t.game_remove_confirm,
        confirmLabel: t.game_remove,
      ),
    );
    if (result == null || !mounted) return;
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
  /// 走设计系统骨架（HibikiDialogFrame + HibikiModalSheetFrame + HibikiListItem，
  /// 替代旧裸 SimpleDialog）；radio 行为不变：点任意行即 pop 该状态。
  Future<void> _promptPlayStatus(GalgameEntry game) async {
    final GalgamePlayStatus? picked = await showAppDialog<GalgamePlayStatus>(
      context: context,
      builder: (BuildContext ctx) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
        return HibikiDialogFrame(
          maxWidth: 420,
          scrollable: false,
          child: HibikiModalSheetFrame(
            title: t.game_play_status,
            leadingIcon: Icons.flag_outlined,
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
                  HibikiListItem(
                    density: HibikiListDensity.compact,
                    leading: Icon(
                      game.playStatus == status
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                    ),
                    title: Text(galgamePlayStatusLabel(status)),
                    onTap: () => Navigator.of(ctx).pop(status),
                  ),
              ],
            ),
          ),
        );
      },
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

  /// 卡菜单「刮削元数据」：直接打开统一刮削弹窗（消灭旧「先进详情页编辑 tab
  /// 再点一次刮削」的二跳）。落库成功后整页重载（含合集分组映射）。
  Future<void> _scrapeGame(GalgameEntry game) async {
    final bool applied = await showGalgameScrapeDialog(
      context: context,
      game: game,
      repo: _repo,
    );
    if (!applied || !mounted) return;
    await _reload();
  }

  /// 单卡「加入合集」：与书/视频同走 [showAddToCollectionDialog]（同一条
  /// createMediaCollection / addToCollection DAO 路径）；成功后重取分组映射刷新。
  Future<void> _addGameToCollection(GalgameEntry game) async {
    final bool added = await showAddToCollectionDialog(
      context: context,
      database: _appModel.database,
      mediaType: MediaKind.game,
      entryKey: game.id,
      defaultNewName: game.displayName,
    );
    if (!added || !mounted) return;
    await _loadCollectionMaps();
    _refresh();
  }

  /// 合集横排行折叠开关（游戏库独立偏好命名空间，见
  /// [PreferencesRepository.gamesCollapsedCollectionIds]）。setPref 先同步刷内存
  /// 缓存，setState 重建即读到新值；落库 fire-and-forget（与书架同模式）。
  void _toggleCollectionCollapsed(int collectionId) {
    final Set<int> ids = _appModel.prefsRepo.gamesCollapsedCollectionIds;
    if (!ids.remove(collectionId)) ids.add(collectionId);
    unawaited(_appModel.prefsRepo.setGamesCollapsedCollectionIds(ids));
    setState(() {});
  }

  /// 行头「查看全部」→ 通用合集网格详情页。game 成员用游戏卡渲染、点击进详情页；
  /// 非 game 成员（混合合集里的书/视频）builder 返 null 由详情页跳过——书架/视频页
  /// 打开同一合集时依旧渲染它们自己的成员，互不越界。
  ///
  /// 不注入 [MediaCollectionGridDetailPage.onDeleteMembersMedia]：game 维度先只支持
  /// 解散合集不删游戏本体（对齐「删除合集不删媒体本体、勾选才删」语义的保守端——
  /// 游戏本体是用户安装目录，绝不能从合集路径误删）。
  void _openCollectionDetail(MediaCollectionRow collection) {
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => MediaCollectionGridDetailPage(
          database: _appModel.database,
          collection: collection,
          memberCardBuilder: (
            String mediaType,
            String entryKey, {
            VoidCallback? onRemoveFromCollection,
          }) =>
              buildGameCollectionMemberCard(
            games: _games,
            mediaType: mediaType,
            entryKey: entryKey,
          ),
          onOpenMember: _openCollectionMember,
          onChanged: () {
            unawaited(_reload());
          },
        ),
      ),
    );
  }

  /// 合集详情页「打开成员」：game 成员进详情页（含启动按钮，复用库页带再入守卫的
  /// [_launchGame]）；其它 mediaType 非本页职责，忽略。
  void _openCollectionMember(String mediaType, String entryKey) {
    if (MediaKind.tryParse(mediaType) != MediaKind.game) return;
    final GalgameEntry? game = _repo.byId(entryKey);
    if (game == null) return;
    unawaited(_openDetail(game));
  }

  /// 弹一个单行输入对话框返回用户输入的名称（取消返回 null）。
  ///
  /// controller 由对话框内容自己的 State 持有并在其 dispose 里释放——旧实现
  /// 在 `showDialog` 返回后立即 `controller.dispose()`，此时退出动画尚未结束、
  /// TextField 还挂在树上，属于过早释放。
  Future<String?> _promptName({required String initial}) {
    return showAppDialog<String>(
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
        HibikiToast.show(msg: t.game_launch_unsupported);
        return;
      }
      if (!File(game.exePath).existsSync()) {
        HibikiToast.show(msg: t.game_exe_missing);
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
      final GalHookSessionController session =
          widget.sessionController ?? GalHookSessionController.instance;
      final GalHookLaunchResult result = await session.launchGame(
        game.exePath,
        launchArguments: game.launchArgumentTokens,
        workdir: game.workdir,
      );
      if (!mounted) return;
      // 每种结果都播报（BUG-1089）。旧实现只在 `!launched` 时说话，可注入降级和
      // 「游戏窗口从未出现」这两条路径 `launchGame` 都返回 true，于是点完「启动游戏」
      // 既看不到游戏也看不到任何提示 —— 用户感知就是「点了没反应」。
      final GalHookSessionState state = session.state;
      final GalHookLaunchOutcome outcome = classifyGalHookLaunchOutcome(
        result: result,
        hasBoundWindow: state.boundWindow != null,
        injectorFailure: state.injectorFailure,
      );
      // message 为 null = 本次启动已被更新的操作取代，不该播报（BUG-1142）。
      final String? message = galHookLaunchOutcomeMessage(
        outcome: outcome,
        result: result,
        failure: state.injectorFailure,
        lastError: state.lastError,
      );
      if (message != null) HibikiToast.show(msg: message);
      if (!result.launched) return;
      widget.onLaunched?.call();
    } finally {
      _launching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<BookTagRow> allTags =
        ref.watch(allTagsProvider).valueOrNull ?? const <BookTagRow>[];
    final Set<String>? allowedIds =
        ref.watch(filteredGameIdsProvider).valueOrNull;
    final List<GalgameEntry> visible = _visibleFor(allowedIds);
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
          if (_games.isNotEmpty) _buildTagFilterBar(allTags),
          Expanded(child: grid),
        ],
      ),
    );
    final Widget addButton = FloatingActionButton.extended(
      onPressed: _addGame,
      icon: const Icon(Icons.add),
      label: Text(t.game_add),
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
                  hintText: t.game_search,
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
            tooltip: t.game_sort,
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
            tooltip: t.game_filter,
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

  Widget _buildTagFilterBar(List<BookTagRow> tags) {
    return HibikiTagFilterBar(
      tags: tags,
      onToggleFilter: _toggleTagFilter,
      onReorder: _reorderTags,
      onTagsChanged: () => ref.invalidate(gameTagMapProvider),
    );
  }

  void _toggleTagFilter(int tagId) {
    final Set<int> next = Set<int>.from(ref.read(selectedTagIdsProvider));
    if (!next.remove(tagId)) next.add(tagId);
    ref.read(selectedTagIdsProvider.notifier).state = next;
  }

  Future<void> _reorderTags(int oldIndex, int newIndex) async {
    final List<BookTagRow>? tags = ref.read(allTagsProvider).valueOrNull;
    if (tags == null) return;
    final List<BookTagRow> reordered = List<BookTagRow>.from(tags);
    final BookTagRow moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    await _appModel.database
        .reorderTags(reordered.map((BookTagRow tag) => tag.id).toList());
    ref.invalidate(allTagsProvider);
  }

  Future<void> _openTagPicker(GalgameEntry game) async {
    await Navigator.push(
      context,
      adaptivePageRoute(
        context: context,
        builder: (_) => TagPickerPage(
          media: MediaRef(kind: MediaKind.game, entryKey: game.id),
        ),
      ),
    );
    ref.invalidate(allTagsProvider);
    ref.invalidate(gameTagMapProvider);
    ref.invalidate(filteredGameIdsProvider);
  }

  /// 筛选面板：状态 / 本地·在线 / 标签多选 / NSFW 隐藏。改动即时生效并持久化。
  /// 走 [adaptiveModalSheet] + [HibikiModalSheetFrame]（与标签筛选面板同一 MD3
  /// sheet 骨架），间距/文字全走 [HibikiDesignTokens]。
  Future<void> _showFilterSheet() async {
    final List<String> allTags = collectGalgameTags(_games);
    await adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext ctx) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setSheetState) {
            void apply(GalgameLibraryView next) {
              setSheetState(() {});
              _setView(next);
            }

            Widget sectionLabel(String text) => Padding(
                  padding: EdgeInsets.only(
                    top: tokens.spacing.gap * 2,
                    bottom: tokens.spacing.gap,
                  ),
                  child: Text(text, style: tokens.type.sectionLabel),
                );

            return HibikiModalSheetFrame(
              title: t.game_filter,
              leadingIcon: Icons.filter_alt_outlined,
              scrollable: true,
              bodyPadding:
                  EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  sectionLabel(t.game_filter_status),
                  Wrap(
                    spacing: tokens.spacing.gap,
                    runSpacing: tokens.spacing.gap,
                    children: <Widget>[
                      HibikiSelectableChip(
                        label: t.game_filter_all,
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
                  sectionLabel(t.game_filter_source),
                  Wrap(
                    spacing: tokens.spacing.gap,
                    runSpacing: tokens.spacing.gap,
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
                    sectionLabel(t.game_filter_tags),
                    Wrap(
                      spacing: tokens.spacing.gap,
                      runSpacing: tokens.spacing.gap,
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
                  SizedBox(height: tokens.spacing.gap),
                  AdaptiveSettingsSwitchRow(
                    title: t.game_filter_hide_nsfw,
                    value: _view.hideNsfw,
                    onChanged: (bool value) =>
                        apply(_view.copyWith(hideNsfw: value)),
                  ),
                  SizedBox(height: tokens.spacing.gap),
                ],
              ),
              footer: Row(
                children: <Widget>[
                  const Spacer(),
                  TextButton(
                    onPressed: () => apply(_view.clearFilters()),
                    child: Text(t.game_filter_reset),
                  ),
                ],
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
            t.game_empty,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _addGame,
            icon: const Icon(Icons.add),
            label: Text(t.game_add),
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
            t.game_no_match,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  /// 游戏卡总高 = 3:4 竖版海报封面高（[cardWidth] × 4/3）+ 标题块。
  ///
  /// BUG-1184：此前网格用死比例 `childAspectRatio: 0.62`、合集横排行又单独抄了一遍
  /// `cardWidth / 0.62`。0.62 是按「3:4 封面 + **一行**标题」估出来的，于是窄屏上
  /// 文字区只剩约 0.28×卡宽（320dp 屏上 ≈38px），连两行都放不下——galgame 名普遍
  /// 20 字以上，一行只看得到开头六七个字。改为按真实行高算：封面保持精确 3:4，
  /// 标题块按两行 titleSmall + 内边距算出，并随文字缩放变化。两处共用此公式。
  static double _gameCardExtent(BuildContext context, double cardWidth) {
    final double titleLine = textLineHeight(
      context,
      Theme.of(context).textTheme.titleSmall ?? const TextStyle(fontSize: 14),
    );
    // 标题 padding 8(top)+2(bottom)（见 GalgamePosterCard 的 titleText）。
    return cardWidth * 4 / 3 + titleLine * 2 + 10 + kTextBlockSlack;
  }

  /// 游戏海报网格（对齐 ReinaManager 库页：3:4 竖版海报卡，见
  /// `docs/design/galgame-library-reina-visual-parity.md` §1）+ 合集分区。
  ///
  /// 不再套书架的 extent/比例：galgame 是竖版海报（3:4 封面 + 下方标题），与横向
  /// 偏方的书封不同形。目标卡宽≈168（ReinaManager 海报宽档），间距 16，
  /// childAspectRatio 按「3:4 封面 + 一行标题」估（约 0.62），标题超长由卡内省略。
  ///
  /// 合集渲染照书架分区范式（去碎片方案 A+顶部）：属合集的游戏折进
  /// [CollectionShelfRow] 横排行集中在前，散卡合成单一 SliverGrid 在后；排序/筛选
  /// 作用于 [_visible]（散卡序与成员存活），组内成员序走合集 sortIndex（与书架/
  /// 详情页同一顺序真相源）。
  Widget _buildGrid(BuildContext context, List<GalgameEntry> visible) {
    final List<CollectionGroup<GalgameEntry>> groups =
        groupByCollections<GalgameEntry>(
      items: <CollectionOrderingItem<GalgameEntry>>[
        for (final GalgameEntry game in visible)
          CollectionOrderingItem<GalgameEntry>(
            mediaType: MediaKind.game,
            entryKey: game.id,
            importedAt: game.addedAt.millisecondsSinceEpoch,
            payload: game,
          ),
      ],
      primaryCollectionIdByEntry: _primaryCollectionByEntry,
      collectionsById: _collectionsById,
      memberSortIndex: _memberSortIndex,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 复算 MaxCrossAxisExtent(168) 的列数/卡宽（ceil→卡宽 ≤168），供合集行
        // 成员卡与散卡网格取同一实际卡宽，行内卡与网格卡逐像素同尺寸。
        const double spacing = 16;
        const double targetExtent = 168;
        final double rawWidth = constraints.maxWidth - 32;
        final double available = rawWidth < 1 ? 1 : rawWidth;
        final int columns = ((available + spacing) / (targetExtent + spacing))
            .ceil()
            .clamp(1, 1 << 10);
        final double cardWidth =
            (available - (columns - 1) * spacing) / columns;
        final List<Widget> slivers = <Widget>[];
        final List<GalgameEntry> loose = <GalgameEntry>[];
        for (final CollectionGroup<GalgameEntry> group in groups) {
          final MediaCollectionRow? collection = group.collection;
          if (collection == null) {
            loose.add(group.coverItem.payload);
          } else {
            slivers.add(
              SliverToBoxAdapter(
                child: _buildCollectionRow(group, collection, cardWidth),
              ),
            );
          }
        }
        if (loose.isNotEmpty) {
          slivers.add(
            SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: spacing,
                crossAxisSpacing: spacing,
                // BUG-1184：原先是死比例 0.62（按「3:4 封面 + 一行标题」估）。窄屏
                // 上卡宽只有约 136px，文字区按比例只剩 38px，物理上放不下两行——
                // galgame 名普遍 20 字以上，单行等于只看得到开头几个字。改为按真实
                // 行高算出卡高（封面仍是精确的 3:4，不再被文字区挤压变形）。
                mainAxisExtent: _gameCardExtent(context, cardWidth),
              ),
              itemCount: loose.length,
              itemBuilder: (BuildContext context, int i) =>
                  _buildGameCard(loose[i]),
            ),
          );
        }
        return CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              sliver: SliverMainAxisGroup(slivers: slivers),
            ),
          ],
        );
      },
    );
  }

  /// 一个游戏合集的横排行：行头（合集名 + 数量 + 查看全部 → 详情页）+ 行内成员
  /// 游戏卡（与散卡同一渲染，交互/焦点自带）。折叠偏好走游戏库自己的命名空间。
  Widget _buildCollectionRow(
    CollectionGroup<GalgameEntry> group,
    MediaCollectionRow collection,
    double cardWidth,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    // BUG-1184：与散卡网格共用同一个 extent 公式，行内卡与网格卡逐像素同形
    // （此前两处各写一遍 0.62，改几何时极易漏掉一处）。
    final double rowHeight = _gameCardExtent(context, cardWidth);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: CollectionShelfRow(
        key: ValueKey<String>('games_collection_row_${collection.id}'),
        title: collection.name,
        countLabel: t.series_item_count(n: group.items.length),
        itemCount: group.items.length,
        itemWidth: cardWidth,
        rowHeight: rowHeight,
        itemGap: 16,
        headerFocusId: HibikiFocusId('games-collection-${collection.id}'),
        onOpenDetail: () => _openCollectionDetail(collection),
        // 合集行右键/长按：三库页统一的合集上下文菜单（打开详情/重命名/标签/
        // 删除合集）。删除支持「连同游戏一起删」勾选，与书/视频对称；语义同
        // [_removeGame]：**只从库移除**，绝不删磁盘上的游戏安装目录（确认框
        // 勾选文案明说这点）。
        onContextMenu: () => unawaited(
          showCollectionContextDialog(
            context: context,
            db: _appModel.database,
            collection: collection,
            onOpenDetail: () => _openCollectionDetail(collection),
            onChanged: () => unawaited(_reload()),
            onDeleteMembersMedia: _removeCollectionMemberGames,
            deleteMembersCheckboxLabel: t.delete_collection_also_games,
          ),
        ),
        collapsed: _appModel.prefsRepo.gamesCollapsedCollectionIds
            .contains(collection.id),
        onToggleCollapsed: () => _toggleCollectionCollapsed(collection.id),
        itemBuilder: (BuildContext _, int i) =>
            _buildGameCard(group.items[i].payload),
      ),
    );
  }

  /// 删合集时勾选「连同游戏一起删」的成员处置（与书/视频合集菜单对称）。
  ///
  /// 语义与卡菜单「移除游戏」完全一致：[GalgameRepository.remove] 只删库行
  /// （元数据源/游玩会话经 FK cascade 连带清理），**绝不碰磁盘上的游戏安装
  /// 目录**。混合合集里的书/视频成员跳过不误删（与视频页同一道防御）。
  Future<void> _removeCollectionMemberGames(
    List<MediaCollectionItemRow> members,
  ) async {
    for (final MediaCollectionItemRow m in members) {
      if (MediaKind.tryParse(m.mediaType) != MediaKind.game) continue;
      if (_repo.byId(m.entryKey) == null) continue;
      await _repo.remove(m.entryKey);
    }
  }

  /// 单张游戏卡（散卡网格与合集行内共用同一构造，回调全量接线）。
  Widget _buildGameCard(GalgameEntry game) {
    return _GameCard(
      game: game,
      sortLabel: galgameSortValueLabel(game, _view.sortField),
      onTap: () => unawaited(_launchGame(game)),
      onRename: () => unawaited(_renameGame(game)),
      onRemove: () => unawaited(_removeGame(game)),
      onSetCover: () => unawaited(_setCover(game)),
      onAutoCover: () => unawaited(_autoCover(game)),
      onPlayStatus: () => unawaited(_promptPlayStatus(game)),
      onDetail: () => unawaited(_openDetail(game)),
      onScrape: () => unawaited(_scrapeGame(game)),
      onAddToCollection: () => unawaited(_addGameToCollection(game)),
      onEditTags: () => unawaited(_openTagPicker(game)),
    );
  }
}

/// 合集详情页的 game 成员卡（纯查找 + 纯 widget，顶层函数供 widget 测试直接驱动）。
///
/// 非 game 成员返回 null（详情页跳过，混合合集里的书/视频由各自页面渲染）；game
/// 成员在 [games] 里找不到（已从库移除的孤儿引用）也返回 null。卡片不带 onTap——
/// 详情页网格统一接管激活（[MediaCollectionGridDetailPage.onOpenMember]）与
/// 上下文菜单（移出合集）。
Widget? buildGameCollectionMemberCard({
  required List<GalgameEntry> games,
  required String mediaType,
  required String entryKey,
}) {
  if (MediaKind.tryParse(mediaType) != MediaKind.game) return null;
  for (final GalgameEntry game in games) {
    if (game.id == entryKey) {
      return GalgamePosterCard(
        cover: GameCoverThumb(game: game),
        title: game.displayName,
      );
    }
  }
  return null;
}

/// 游玩状态的用户可读标签（枚举 `.name` 直接上屏是 17 语言用户的灾难）。
String galgamePlayStatusLabel(GalgamePlayStatus status) => switch (status) {
      GalgamePlayStatus.unset => t.game_status_unset,
      GalgamePlayStatus.wantToPlay => t.game_status_want_to_play,
      GalgamePlayStatus.played => t.game_status_played,
      GalgamePlayStatus.playing => t.game_status_playing,
      GalgamePlayStatus.onHold => t.game_status_on_hold,
      GalgamePlayStatus.dropped => t.game_status_dropped,
    };

/// 排序维度的用户可读标签。
String galgameSortFieldLabel(GalgameSortField field) => switch (field) {
      GalgameSortField.added => t.game_sort_added,
      GalgameSortField.releaseDate => t.game_sort_release,
      GalgameSortField.lastPlayed => t.game_sort_last_played,
      GalgameSortField.siteScore => t.game_sort_site_score,
      GalgameSortField.userRating => t.game_sort_user_rating,
      GalgameSortField.name => t.game_sort_name,
    };

/// 本地/在线筛选的用户可读标签。
String galgameLocalFilterLabel(GalgameLocalFilter filter) => switch (filter) {
      GalgameLocalFilter.all => t.game_filter_all,
      GalgameLocalFilter.localOnly => t.game_filter_local_only,
      GalgameLocalFilter.metadataOnly => t.game_filter_metadata_only,
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
      if (game.lastPlayedMs <= 0) return t.game_never_played;
      return formatGalgameDate(
          DateTime.fromMillisecondsSinceEpoch(game.lastPlayedMs));
    case GalgameSortField.siteScore:
      return game.siteScore?.toStringAsFixed(1);
    case GalgameSortField.userRating:
      return game.userRating?.toStringAsFixed(1);
  }
}

/// `YYYY-MM-DD` 本地日期（与 `galgame_sessions.dateKey` 同格式）。委托
/// [HibikiTimeFormat.dayKey]（G5 收敛）。
String formatGalgameDate(DateTime value) => HibikiTimeFormat.dayKey(value);

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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 420,
      scrollable: false,
      child: HibikiModalSheetFrame(
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
        body: HibikiTextField(
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
    required this.onAddToCollection,
    required this.onEditTags,
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
  final VoidCallback onAddToCollection;
  final VoidCallback onEditTags;

  /// 长按 / 右键的上下文菜单：与书卡/视频卡同款 [MediaItemDialogFrame]（封面块 +
  /// 快捷动作 chips + 底部危险区），替代旧手搓 SimpleDialog。菜单项与封面溢出菜单
  /// **共用** [_menuItems] 与 [_dispatchAction]，避免两份手抄。
  Future<void> _showContextMenu(BuildContext context) async {
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => MediaItemDialogFrame(
        cover: _dialogCover(dialogContext),
        title: game.displayName,
        showLaunchAction: false,
        quickActions: <DialogQuickAction>[
          for (final _GameMenuItem item in _menuItems)
            if (!item.danger)
              DialogQuickAction(
                label: item.label,
                icon: item.icon,
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _dispatchAction(item.action);
                },
              ),
        ],
        dangerActions: <DialogDangerAction>[
          for (final _GameMenuItem item in _menuItems)
            if (item.danger)
              DialogDangerAction(
                label: item.label,
                icon: item.icon,
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _dispatchAction(item.action);
                },
              ),
        ],
      ),
    );
  }

  /// 长按对话框顶部的封面块：有封面文件用降采样图（BoxFit.contain 整图可见），
  /// 无封面用与书架长按框同规格的占位图标（size 40 / onSurfaceVariant）。
  Widget _dialogCover(BuildContext context) {
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
        child: Icon(
          Icons.videogame_asset,
          size: 40,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 卡片菜单项单一真相源：`(action, 文案, 图标, 危险区)`。溢出菜单与长按/右键
  /// 对话框都从这一份生成，任一处漏项测试即红。
  ///
  /// 次序遵守三库页统一约定：重命名 → 封面类 → 刮削 → 加入合集 → 标签 → 删除；
  /// 游戏特有的「查看详情 / 游玩状态」保持最前。
  List<_GameMenuItem> get _menuItems => <_GameMenuItem>[
        (
          action: 'detail',
          label: t.game_view_detail,
          icon: Icons.info_outline,
          danger: false,
        ),
        (
          action: 'status',
          label: t.game_play_status,
          icon: Icons.flag_outlined,
          danger: false,
        ),
        (
          action: 'rename',
          label: t.game_rename,
          icon: Icons.drive_file_rename_outline,
          danger: false,
        ),
        (
          action: 'cover',
          label: t.game_set_cover,
          icon: Icons.image_outlined,
          danger: false,
        ),
        (
          action: 'autocover',
          label: t.game_auto_cover,
          icon: Icons.image_search,
          danger: false,
        ),
        (
          action: 'scrape',
          label: t.game_scrape,
          icon: Icons.cloud_download_outlined,
          danger: false,
        ),
        (
          action: 'collect',
          label: t.add_to_collection,
          icon: Icons.collections_bookmark_outlined,
          danger: false,
        ),
        (
          action: 'tags',
          label: t.tag_label,
          icon: Icons.sell_outlined,
          danger: false,
        ),
        (
          action: 'remove',
          label: t.game_remove,
          icon: Icons.delete_outline,
          danger: true,
        ),
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
      case 'collect':
        onAddToCollection();
      case 'tags':
        onEditTags();
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
      cover: GameCoverThumb(game: game),
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
        for (final _GameMenuItem item in _menuItems)
          PopupMenuItem<String>(value: item.action, child: Text(item.label)),
      ],
    );
  }
}

/// 游戏卡菜单项：action 键 + 文案 + 图标 + 是否落危险区（对话框底部红字）。
typedef _GameMenuItem = ({
  String action,
  String label,
  IconData icon,
  bool danger,
});

/// 游戏封面缩略图（库页卡片 / 合集行成员卡 / 合集详情成员卡共用）。
///
/// 有 coverPath 且文件真实存在 → 经 [ShelfFileCover] 降采样加载（BUG-959 同类：
/// 旧裸 `Image.file` 整帧解码游戏包装图会撑爆 ImageCache）；否则共享占位件
/// [ShelfCoverPlaceholder]（保留原 surfaceContainerHighest 底色 + 手柄图标 48）。
/// existsSync 短路语义保留：缺失文件直接画占位，不进图片加载失败路径。
class GameCoverThumb extends StatelessWidget {
  const GameCoverThumb({required this.game, super.key});

  final GalgameEntry game;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget placeholder = ShelfCoverPlaceholder(
      icon: Icons.videogame_asset,
      iconSize: 48,
      backgroundColor: colors.surfaceContainerHighest,
    );
    final String? cover = game.coverPath;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      return ShelfFileCover(path: cover, placeholder: placeholder);
    }
    return placeholder;
  }
}
