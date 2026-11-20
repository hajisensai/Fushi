import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/music_local_video.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/music_resume.dart';
import 'package:fushi/src/media/music/music_resume_points_watch.dart';
import 'package:fushi/src/media/selection/media_selection_controller.dart';
import 'package:fushi/src/media/selection/selection_gestures.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/music/music_mv_page.dart'
    show openMusicTrackVideo;
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_detail_chrome.dart'
    show MusicDetailHero, musicDetailHeroGap;
import 'package:fushi/src/pages/implementations/music/music_local_playlist_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart'
    show musicBrowsePagePadding, musicBrowseScaffold;
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_track_detail_page.dart';
import 'package:fushi/src/pages/implementations/music/music_track_row_surface.dart';
import 'package:fushi/src/pages/implementations/music/music_collection_view.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockSize;
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiChromeReveal, FushiToolbarItem;
import 'package:fushi/src/utils/components/fushi_bottom_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiSnackBar;
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show ShelfSelectionCheck;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show shellRedesignActive;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

part 'music_track_selection.part.dart';

/// `mm:ss`。
String formatMusicDuration(int? ms) {
  if (ms == null || ms <= 0) return '';
  final int s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// 打开曲目详情（出现在哪些集 / 同一作品）。
void openMusicTrackDetail(BuildContext context, String trackUid) {
  unawaited(
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => MusicTrackDetailPage(trackUid: trackUid),
      ),
    ),
  );
}

/// 本地曲目的菜单（行尾按钮之外的整行右键）：播放 / 曲目详情 / 加入歌单 / 从音乐库移除
/// （只从曲库隐藏、不碰磁盘文件，重扫不复活，带撤销）；[extra] 追加在末尾（歌单页的
/// 「从这个歌单移除」、曲目列表的「多选」）。
MusicItemMenu musicLocalTrackMenu(
  BuildContext context,
  MusicTrackRow track, {
  required VoidCallback onPlay,
  List<MusicMenuAction> extra = const <MusicMenuAction>[],
}) => MusicItemMenu(
  buttonKey: ValueKey<String>('music-track-menu-${track.trackUid}'),
  open: (MusicMenuAnchor? anchor) => unawaited(
    showMusicActionMenu(
      context,
      anchor: anchor,
      errorText: (Object e) => t.music_action_failed(error: '$e'),
      actions: <MusicMenuAction>[
        MusicMenuAction(
          id: 'play',
          label: t.music_play_all,
          icon: FushiIcons.play,
          run: (_) async => onPlay(),
        ),
        ...musicQueueMenuActions(
          ProviderScope.containerOf(
            context,
            listen: false,
          ).read(appProvider).musicSession.engine,
          () => musicPlayItemOf(track),
        ),
        // 本地 MV（拍板台 jeNKF9u0WJ）：在视频播放页看画面（ASS 特效字幕 / 暂停识别
        // 画面文字）。视频模块关掉时不给入口。
        if (isMusicLocalVideoTrack(track) &&
            _appOf(context).moduleVisibility.isEnabled(ModuleId.video))
          MusicMenuAction(
            id: 'watchVideo',
            label: t.music_mv_watch_in_player,
            icon: FushiIcons.video,
            run: (BuildContext c) =>
                openMusicTrackVideo(context: c, track: track),
          ),
        MusicMenuAction(
          id: 'detail',
          label: t.music_track_detail,
          icon: FushiIcons.info,
          run: (BuildContext c) async =>
              openMusicTrackDetail(c, track.trackUid),
        ),
        if (_appOf(context) case final AppModel app when app.isDatabaseReady)
          MusicMenuAction(
            id: 'addToLocalPlaylist',
            label: t.music_action_add_to_playlist,
            icon: FushiIcons.playlist,
            run: (BuildContext c) async {
              await musicAddItemsToLocalPlaylist(
                c,
                app.database,
                <MusicPlayItem>[musicPlayItemOf(track)],
              );
            },
          ),
        if (_appOf(context) case final AppModel app when app.isDatabaseReady)
          MusicMenuAction(
            id: 'removeFromLibrary',
            label: t.music_action_remove_from_library,
            icon: FushiIcons.removeCircle,
            run: (BuildContext c) async {
              await musicRemoveEntriesFromLibrary(
                c,
                app.database,
                <MusicLibraryEntry>[MusicLocalEntry(track)],
              );
            },
          ),
        ...extra,
      ],
    ),
  ),
);

AppModel _appOf(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false).read(appProvider);

/// 远程曲目（YouTube / 在线插件 / 服务器曲目，v148 / v149）在曲库 / 歌单里的菜单：播放（能播
/// 时）/ 移出音乐库（在库时）/ 加入歌单；[extra] 追加在末尾（歌单页的「从这个歌单移除」）。
/// 入库 / 加歌单直接用落库的行，不经播放项（服务器曲目的服务器不在时也能移出、整理歌单）。
MusicItemMenu musicRemoteEntryMenu(
  BuildContext context,
  MusicRemoteEntry entry, {
  required VoidCallback onPlay,
  List<MusicMenuAction> extra = const <MusicMenuAction>[],
}) {
  final MusicRemoteTrackRow track = entry.track;
  return MusicItemMenu(
    buttonKey: ValueKey<String>('music-remote-track-menu-${track.trackUid}'),
    open: (MusicMenuAnchor? anchor) {
      final AppModel app = _appOf(context);
      unawaited(
        showMusicActionMenu(
          context,
          anchor: anchor,
          errorText: (Object e) => t.music_action_failed(error: '$e'),
          actions: <MusicMenuAction>[
            if (entry.available)
              MusicMenuAction(
                id: 'play',
                label: t.music_play_all,
                icon: FushiIcons.play,
                run: (_) async => onPlay(),
              ),
            // 条目能列出来就说明这一种在本平台可用（musicRemoteEntriesOf 已按
            // musicRemoteKindAvailable 滤过）；种类不认识的条目不会到这里。
            if (app.isDatabaseReady && entry.kind != null)
              ...musicRemoteTrackLibraryActions(
                app.database,
                musicRemoteTrackCompanionOfRow(track),
                inLibrary: track.libraryAddedAt != null,
              ),
            ...extra,
          ],
        ),
      );
    },
  );
}

/// 远程曲目行副标题里的来源名（YouTube / 插件 id / 服务器名）；服务器曲目的服务器在这台
/// 设备上没配时写明不可用。
String musicRemoteSourceLabel(MusicRemoteEntry entry) => switch (entry.kind) {
  MusicRemoteTrackKind.youtube => 'YouTube',
  MusicRemoteTrackKind.server =>
    entry.server?.browser.displayName ?? t.music_remote_server_missing,
  MusicRemoteTrackKind.plugin || null => entry.track.sourceKey,
};

/// 行尾拖拽把手（48dp 命中区，只从这里起拖；整行仍可点、可右键）。必须放在
/// [FushiReorderableColumn]（`useDragHandles: true`）的行里。
class MusicPlaylistDragHandle extends StatelessWidget {
  const MusicPlaylistDragHandle({super.key});

  @override
  Widget build(BuildContext context) => FushiTooltip(
    message: t.music_action_reorder,
    child: const FushiReorderableDragHandle(
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(child: FushiIcon(FushiIcons.dragIndicator)),
      ),
    ),
  );
}

/// 曲目列表所在的本地歌单：每行多出「从这个歌单移除」（按条目 id 删，同一首出现两次时只删
/// 点的那一条）。[entryIds] 与列表条目一一对应。[onReorder] 非空时每行行尾有拖拽把手
/// （只从把手起拖），回调「第 from 条挪到最终下标 to」。
class MusicTrackListPlaylist {
  const MusicTrackListPlaylist({
    required this.playlist,
    required this.entryIds,
    this.onReorder,
  });

  final MusicPlaylistRow playlist;
  final List<int> entryIds;
  final FushiReorderCallback? onReorder;
}

/// 曲目列表（歌曲分区 / 艺人 / 专辑碟内 / 本地歌单）：点一首 = 以该列表为队列从这首开始播；
/// 长按 / 行尾「详情」= 曲目详情页。有没听完的断点（点开会接着放的，`music_resume.dart`）
/// 的行：行尾显示剩余时间，副标题下一条细进度条。
///
/// 条目可以是本地曲库曲目，也可以是加入音乐库 / 歌单的远程曲目（[MusicLibraryEntry]，v148）：
/// 两种排在同一条队列里，远程曲目行带封面缩略图与来源名、行尾是「更多」菜单。
///
/// 多选（拍板台 IDeN5PYaI7）：每行菜单的「多选」或桌面 Ctrl / ⌘ / Shift + 点击进入；多选态
/// 下点行 = 勾选（Shift = 区间），底部浮出 [MusicTrackSelectionBar]（接着播 / 加入队列 /
/// 加入歌单 / 从歌单移除 / 从音乐库移除），返回键先退出多选。选择语义用库页共用的
/// [MediaSelectionController]。
class MusicTrackList extends ConsumerStatefulWidget {
  /// 只有本地曲库曲目的列表（专辑 / 艺人 / 歌曲分区）。
  const MusicTrackList({
    super.key,
    required List<MusicTrackRow> tracks,
    required this.albums,
    required this.context,
    this.shrinkWrap = false,
    this.showTrackNumbers = false,
    this.header,
    this.style = MusicViewStyle.list,
  }) : _tracks = tracks,
       _entries = null,
       playlist = null,
       source = null;

  /// 本地与远程曲目混排的列表（歌曲分区含远程曲目、本地歌单）。
  const MusicTrackList.entries({
    super.key,
    required List<MusicLibraryEntry> entries,
    required this.albums,
    required this.context,
    this.shrinkWrap = false,
    this.showTrackNumbers = false,
    this.playlist,
    this.source,
    this.header,
    this.style = MusicViewStyle.list,
  }) : _entries = entries,
       _tracks = null;

  final List<MusicTrackRow>? _tracks;
  final List<MusicLibraryEntry>? _entries;

  /// 调用方传进来的那份列表（判断「列表换了没有」用身份，不逐项比）。
  Object get _source => _entries ?? _tracks!;

  /// 列表条目（本地构造时现包一层）。
  List<MusicLibraryEntry> get entries =>
      _entries ??
      <MusicLibraryEntry>[
        for (final MusicTrackRow t in _tracks!) MusicLocalEntry(t),
      ];
  final Map<String, MusicAlbumRow> albums;

  /// 队列语境（决定 ReplayGain 模式）。
  final MusicQueueContext context;
  final bool shrinkWrap;
  final bool showTrackNumbers;

  /// 列表所在的本地歌单（多出「从这个歌单移除」）；不在歌单页为 null。
  final MusicTrackListPlaylist? playlist;

  /// 起播时记进播放流的来源（歌单页 = 这个歌单）；null = 不记。
  final MusicPlaySource? source;

  /// 排在第一行之前、随列表一起滚动的头部（独立页的 [MusicDetailHero]）。只用于
  /// 自己负责滚动的列表（非 [shrinkWrap]、非可重排）；给了头部时列表顶部让出
  /// 外壳页头的高度（`MediaQuery.paddingOf(context).top`），头部与第一行之间隔一档
  /// [musicDetailHeroGap]。
  final Widget? header;

  /// 曲目排成单列曲目行（缺省）或多列封面色块（[MusicTrackBlock]，重设计外壳下）。
  /// 可重排的歌单恒为单列行（拖拽把手只在行上）。
  final MusicViewStyle style;

  @override
  ConsumerState<MusicTrackList> createState() => _MusicTrackListState();
}

class _MusicTrackListState extends ConsumerState<MusicTrackList> {
  /// 这一列曲目的断点：挂上时按块查齐，之后只吃这一列里那几首的改动。
  late final MusicResumePointsWatch _resume;

  /// [MusicTrackList.entries] 的缓存：调用方的列表换了才重包。
  late List<MusicLibraryEntry> _list = widget.entries;

  List<MusicLibraryEntry> get entries => _list;

  /// 本列表里本地曲目的 uid → 音频路径（找专辑内嵌封面所在的那首用），随 [_list] 重算。
  late Map<String, String> _pathByUid = musicLocalTrackPathsOf(_list);

  static List<String> _uids(List<MusicLibraryEntry> entries) => <String>[
    for (final MusicLibraryEntry e in entries) e.trackUid,
  ];

  /// 多选状态（散卡键 = [_selectionKey]）。
  final MediaSelectionController _selection = MediaSelectionController();

  /// 多选底栏浮层（第一次进多选时挂上，之后常驻：退出时还要播收起动效，收起后
  /// [FushiChromeReveal] 不占指针、不进语义树）。
  final OverlayPortalController _barPortal = OverlayPortalController();

  bool get _selecting => _selection.active;

  /// 第 [i] 行的选择身份：歌单里同一首可以出现两次，按条目 id；其余列表按曲目 uid。
  String _selectionKey(int i) {
    final MusicTrackListPlaylist? p = widget.playlist;
    if (p != null && p.entryIds.length == entries.length) {
      return 'entry-${p.entryIds[i]}';
    }
    return entries[i].trackUid;
  }

  List<String> get _selectionKeys => <String>[
    for (int i = 0; i < entries.length; i++) _selectionKey(i),
  ];

  /// 列表换了：可见顺序重登记，选中集剔掉已经不在的行（批量移除之后的那些）。
  void _syncSelectionOrder() {
    final List<String> keys = _selectionKeys;
    _selection
      ..setVisibleOrder(loose: keys, collections: const <int>[])
      ..retainExisting(loose: keys.toSet(), collections: const <int>{});
  }

  /// 选中且可见的行号（按列表顺序）。
  List<int> get _selectedIndexes {
    final Set<String> keys = _selection.looseKeys;
    return <int>[
      for (int i = 0; i < entries.length; i++)
        if (keys.contains(_selectionKey(i))) i,
    ];
  }

  List<MusicLibraryEntry> get _selectedEntries => <MusicLibraryEntry>[
    for (final int i in _selectedIndexes) entries[i],
  ];

  @override
  void initState() {
    super.initState();
    _resume = ref.read(appProvider).musicSession.watchResumePoints(_uids(_list))
      ..addListener(_onResumeChanged);
    _syncSelectionOrder();
  }

  @override
  void didUpdateWidget(MusicTrackList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget._source, widget._source)) return;
    final List<MusicLibraryEntry> previous = _list;
    _list = widget.entries;
    _pathByUid = musicLocalTrackPathsOf(_list);
    if (!listEquals(_uids(previous), _uids(_list))) _resume.watch(_uids(_list));
    _syncSelectionOrder();
  }

  /// 进入多选并选中第 [i] 行（已在多选态 = 切换这一行）。
  void _enterSelection(int i) {
    if (!_barPortal.isShowing) _barPortal.show();
    setState(() {
      _syncSelectionOrder();
      _selection.enterWith(SelectionSlot.loose(_selectionKey(i)));
    });
  }

  void _exitSelection() => setState(_selection.exit);

  /// 点一行：多选态 = 勾选（Shift = 区间扩选）；桌面 Ctrl / ⌘ / Shift + 点击 = 直接进多选；
  /// 否则 [orElse]（起播）。
  void _tapRow(int i, VoidCallback orElse) {
    if (_selecting) {
      setState(
        () => _selection.applyTap(
          SelectionSlot.loose(_selectionKey(i)),
          selectionTapKind(),
        ),
      );
      return;
    }
    if (selectionEntryModifierPressed(context)) {
      _enterSelection(i);
      return;
    }
    orElse();
  }

  bool _isSelected(int i) =>
      _selecting && _selection.looseKeys.contains(_selectionKey(i));

  /// 每行菜单末尾的「多选」。
  MusicMenuAction _selectAction(int i) => MusicMenuAction(
    id: 'select',
    label: t.music_selection_enter,
    icon: FushiIcons.checklist,
    run: (_) async {
      if (mounted) _enterSelection(i);
    },
  );

  /// 每行菜单的追加项：歌单页的「从这个歌单移除」+「多选」。
  List<MusicMenuAction> _rowExtras(int i) => <MusicMenuAction>[
    ..._playlistActions(i),
    _selectAction(i),
  ];

  AppModel get _app => ref.read(appProvider);

  /// 批量动作跑完：退出多选（选中的行可能已经不在列表里了）。
  Future<void> _runBatch(
    Future<void> Function(List<MusicLibraryEntry> picked) action,
  ) async {
    final List<MusicLibraryEntry> picked = _selectedEntries;
    if (picked.isEmpty) return;
    try {
      await action(picked);
    } catch (e) {
      FushiToast.show(
        msg: t.music_action_failed(error: '$e'),
        severity: ToastSeverity.error,
      );
      return;
    }
    if (mounted) _exitSelection();
  }

  Widget _selectionBar() {
    final AppModel app = _app;
    final MusicPlayerEngine engine = app.musicSession.engine;
    final bool db = app.isDatabaseReady;
    final MusicTrackListPlaylist? playlist = widget.playlist;
    final bool queue = musicQueueEditable(engine);
    return MusicTrackSelectionBar(
      count: _selection.length,
      onSelectAll: () => setState(
        () => _selection.selectAll(
          loose: _selection.visibleLooseKeys,
          collections: const <int>[],
        ),
      ),
      onExit: _exitSelection,
      onPlayNext: queue
          ? () => unawaited(
              _runBatch(
                (List<MusicLibraryEntry> picked) => musicQueueEntries(
                  engine,
                  picked,
                  widget.albums,
                  next: true,
                ),
              ),
            )
          : null,
      onAddToQueue: queue
          ? () => unawaited(
              _runBatch(
                (List<MusicLibraryEntry> picked) => musicQueueEntries(
                  engine,
                  picked,
                  widget.albums,
                  next: false,
                ),
              ),
            )
          : null,
      onAddToPlaylist: db
          ? () => unawaited(
              _runBatch(
                (List<MusicLibraryEntry> picked) =>
                    musicAddEntriesToLocalPlaylist(
                      context,
                      app.database,
                      picked,
                    ),
              ),
            )
          : null,
      onRemoveFromPlaylist:
          db && playlist != null && playlist.entryIds.length == entries.length
          ? () {
              final List<int> ids = <int>[
                for (final int i in _selectedIndexes) playlist.entryIds[i],
              ];
              unawaited(
                _runBatch(
                  (_) => musicRemoveEntriesFromPlaylist(
                    context,
                    app.database,
                    playlist.playlist,
                    ids,
                  ),
                ),
              );
            }
          : null,
      // 歌单页的「移除」默认指从歌单移除；从音乐库移除只在曲库视图（歌曲 / 专辑 / 艺人）出。
      onRemoveFromLibrary: db && playlist == null
          ? () => unawaited(
              _runBatch(
                (List<MusicLibraryEntry> picked) =>
                    musicRemoveEntriesFromLibrary(
                      context,
                      app.database,
                      picked,
                    ),
              ),
            )
          : null,
    );
  }

  /// 把列表包上多选底栏浮层与「返回键先退出多选」。
  Widget _withSelection(Widget list) => PopScope(
    canPop: !_selecting,
    onPopInvokedWithResult: (bool didPop, Object? _) {
      if (!didPop && _selecting) _exitSelection();
    },
    child: OverlayPortal(
      controller: _barPortal,
      overlayChildBuilder: (BuildContext context) =>
          MusicTrackSelectionBarHost(visible: _selecting, bar: _selectionBar()),
      child: list,
    ),
  );

  @override
  void dispose() {
    _resume
      ..removeListener(_onResumeChanged)
      ..dispose();
    super.dispose();
  }

  void _onResumeChanged() {
    if (mounted) setState(() {});
  }

  /// 以整列为队列从第 [index] 条起播。换不成播放项的条目（将来版本写的远程种类、这台设备
  /// 没配服务器的服务器曲目）不进队列；点的正是这种条目时不起播。
  void _play(int index) {
    final List<MusicPlayItem> items = <MusicPlayItem>[];
    int? start;
    for (int i = 0; i < entries.length; i++) {
      final MusicPlayItem? item = entries[i].playItem(widget.albums);
      if (item == null) continue;
      if (i == index) start = items.length;
      items.add(item);
    }
    if (start == null) return;
    unawaited(
      ref
          .read(appProvider)
          .musicSession
          .engine
          .playQueue(
            items,
            startIndex: start,
            context: widget.context,
            source: widget.source,
          ),
    );
  }

  /// 歌单页每行的「从这个歌单移除」；不在歌单页回空。
  List<MusicMenuAction> _playlistActions(int index) {
    final MusicTrackListPlaylist? p = widget.playlist;
    if (p == null || index >= p.entryIds.length) {
      return const <MusicMenuAction>[];
    }
    return <MusicMenuAction>[
      MusicMenuAction(
        id: 'removeFromPlaylist',
        label: t.music_action_remove_from_playlist,
        icon: FushiIcons.close,
        run: (_) async {
          await ref
              .read(appProvider)
              .database
              .removeMusicPlaylistEntry(
                p.playlist.playlistUid,
                p.entryIds[index],
                at: DateTime.now().millisecondsSinceEpoch,
              );
          FushiToast.show(
            msg: t.music_action_removed_from_playlist(name: p.playlist.name),
            severity: ToastSeverity.success,
          );
        },
      ),
    ];
  }

  /// 歌单页且可重排时的回调（行尾出拖拽把手）；否则 null。
  FushiReorderCallback? get _onReorder {
    final MusicTrackListPlaylist? p = widget.playlist;
    if (p == null || p.entryIds.length != entries.length) return null;
    return p.onReorder;
  }

  Widget _row(BuildContext c, int i, MusicResumeMode mode) =>
      switch (entries[i]) {
        MusicLocalEntry(:final MusicTrackRow track) => _localRow(
          c,
          i,
          track,
          mode,
        ),
        final MusicRemoteEntry entry => _remoteRow(c, i, entry, mode),
      };

  @override
  Widget build(BuildContext buildContext) {
    final MusicResumeMode mode = watchMusicResumeMode(ref);
    final bool shrinkWrap = widget.shrinkWrap;
    final FushiDesignTokens tokens = FushiDesignTokens.of(buildContext);
    final FushiReorderCallback? onReorder = _onReorder;
    if (onReorder != null) {
      // 可重排的歌单：整列一次排好（[FushiReorderableColumn] 不是惰性列表），只用在外层
      // 已经负责滚动的 shrinkWrap 场景（本地歌单页）。
      assert(shrinkWrap, 'reorderable playlist track list must be shrinkWrap');
      final List<int> ids = widget.playlist!.entryIds;
      return _withSelection(
        FushiEntranceScope(
          child: FushiReorderableColumn(
            itemCount: entries.length,
            useDragHandles: true,
            keyForIndex: (int i) =>
                ValueKey<String>('music-playlist-reorder-${ids[i]}'),
            onReorder: onReorder,
            itemBuilder: (BuildContext c, int i) =>
                FushiStaggeredEntrance(index: i, child: _row(c, i, mode)),
          ),
        ),
      );
    }
    final Widget? header = shrinkWrap ? null : widget.header;
    if (widget.style == MusicViewStyle.blocks &&
        musicTrackRowSurfaceActive(buildContext)) {
      return _withSelection(
        MusicStyledCollection(
          style: MusicViewStyle.blocks,
          itemCount: entries.length,
          shrinkWrap: shrinkWrap,
          padding: shrinkWrap
              ? EdgeInsets.zero
              : withBottomSafeInset(
                  buildContext,
                  EdgeInsets.fromLTRB(
                    tokens.spacing.page,
                    (header == null
                            ? 0
                            : MediaQuery.paddingOf(buildContext).top) +
                        tokens.spacing.gap,
                    tokens.spacing.page,
                    tokens.spacing.section,
                  ),
                ),
          header: header,
          headerGap: musicDetailHeroGap(buildContext, tokens.spacing.gap),
          rowBuilder: (BuildContext c, int i) => _row(c, i, mode),
          blockBuilder: (BuildContext c, int i, FushiCoverBlockSize size) =>
              _block(c, i, size, mode),
        ),
      );
    }
    final int lead = header == null ? 0 : 1;
    return _withSelection(
      FushiEntranceScope(
        child: ListView.builder(
          shrinkWrap: shrinkWrap,
          primary: shrinkWrap ? false : null,
          physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
          padding: shrinkWrap
              ? EdgeInsets.zero
              : withBottomSafeInset(
                  buildContext,
                  EdgeInsets.fromLTRB(
                    tokens.spacing.page,
                    // 带头部的独立页：外壳把正文铺到页头底下，经 MediaQuery 顶部
                    // padding 让出页头。
                    (header == null
                            ? 0
                            : MediaQuery.paddingOf(buildContext).top) +
                        tokens.spacing.gap,
                    tokens.spacing.page,
                    tokens.spacing.section,
                  ),
                ),
          itemCount: entries.length + lead,
          itemBuilder: fushiStaggeredItemBuilder((BuildContext c, int i) {
            if (header != null && i == 0) {
              return Padding(
                padding: EdgeInsets.only(
                  bottom: musicDetailHeroGap(c, tokens.spacing.gap),
                ),
                child: header,
              );
            }
            return _row(c, i - lead, mode);
          }),
        ),
      ),
    );
  }

  Widget _localRow(
    BuildContext c,
    int i,
    MusicTrackRow track,
    MusicResumeMode mode,
  ) {
    final Duration? resume = musicTrackResumeOf(
      track,
      _resume[track.trackUid],
      mode,
    );
    final Text subtitle = Text(
      <String>[
        track.artistCredit ?? t.music_artist_unknown,
        ...musicLocalTrackBadges(track),
      ].join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    void play() => _play(i);
    void tap() => _tapRow(i, play);
    void longPress() =>
        _selecting ? _tapRow(i, play) : openMusicTrackDetail(c, track.trackUid);
    final bool selected = _isSelected(i);
    final MusicItemMenu menu = musicLocalTrackMenu(
      c,
      track,
      onPlay: play,
      extra: _rowExtras(i),
    );
    if (musicTrackRowSurfaceActive(c)) {
      // 封面来源与旧列表行同一份（[musicLocalTrackCoverOf]，BUG-4494）：行首画
      // 专辑封面（没有内嵌封面的曲目借专辑封面曲目的），取色也用这一份。
      final MusicTrackCoverSource cover = _localCoverSource(track);
      return menu.contextMenu(
        child: _surfaceRow(
          i,
          (bool playing) => MusicTrackRowSurface(
            key: ValueKey<String>(_rowKey('music-track', i, track.trackUid)),
            title: track.title,
            subtitleWidget: musicTrackSubtitleWithResume(
              track,
              subtitle,
              resume,
            ),
            ordinal: widget.showTrackNumbers
                ? track.trackNo?.toString() ?? ''
                : null,
            leading: widget.showTrackNumbers ? null : _localCover(track),
            coverPath: cover.coverPath,
            embeddedFromPath: cover.embeddedFromPath,
            durationText: musicTrackTimeLabel(track.durationMs, resume),
            playing: playing,
            onTap: tap,
            onLongPress: longPress,
            trailing: _selecting
                ? <Widget>[_check(i, selected)]
                : <Widget>[
                    FushiIconButton(
                      key: ValueKey<String>(
                        _rowKey('music-track-detail', i, track.trackUid),
                      ),
                      icon: FushiIcons.info,
                      tooltip: t.music_track_detail,
                      onTap: () => openMusicTrackDetail(c, track.trackUid),
                    ),
                    // 触屏没有右键：行尾「⋯」打开与右键同一份菜单（多选 / 从歌单移除…）。
                    menu.button(),
                    if (_onReorder != null) const MusicPlaylistDragHandle(),
                  ],
          ),
        ),
      );
    }
    return menu.contextMenu(
      child: FushiPressScale(
        child: FushiGroupedListItem(
          key: ValueKey<String>(_rowKey('music-track', i, track.trackUid)),
          index: i,
          count: entries.length,
          selected: selected,
          onTap: tap,
          onLongPress: longPress,
          child: FushiListItem(
            leading: widget.showTrackNumbers
                ? SizedBox(
                    width: 28,
                    child: Text(
                      track.trackNo?.toString() ?? '',
                      textAlign: TextAlign.end,
                      style: c.fushiType.bodySmall,
                    ),
                  )
                : _localCover(track),
            title: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: musicTrackSubtitleWithResume(track, subtitle, resume),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  musicTrackTimeLabel(track.durationMs, resume),
                  style: c.fushiType.bodySmall,
                ),
                if (_selecting)
                  _check(i, selected)
                else ...<Widget>[
                  FushiIconButton(
                    key: ValueKey<String>(
                      _rowKey('music-track-detail', i, track.trackUid),
                    ),
                    icon: FushiIcons.info,
                    tooltip: t.music_track_detail,
                    onTap: () => openMusicTrackDetail(c, track.trackUid),
                  ),
                  menu.button(),
                  if (_onReorder != null) const MusicPlaylistDragHandle(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 本地曲目的封面来源（自带内嵌封面 / 专辑目录封面 / 专辑封面曲目的内嵌封面）。
  MusicTrackCoverSource _localCoverSource(MusicTrackRow track) =>
      musicLocalTrackCoverOf(
        track,
        album: track.albumUid == null ? null : widget.albums[track.albumUid],
        pathByUid: _pathByUid,
      );

  /// 本地曲目行的封面缩略图（与远程行同尺寸同材质）。
  Widget _localCover(MusicTrackRow track) {
    final MusicTrackCoverSource cover = _localCoverSource(track);
    return musicMaterialCover(
      MusicCover(
        coverPath: cover.coverPath,
        embeddedFromPath: cover.embeddedFromPath,
        size: 40,
      ),
      size: 40,
      compact: true,
    );
  }

  Widget _remoteRow(
    BuildContext c,
    int i,
    MusicRemoteEntry entry,
    MusicResumeMode mode,
  ) {
    final MusicRemoteTrackRow track = entry.track;
    final bool available = entry.available;
    final MusicResumePointRow? point = _resume[track.trackUid];
    final Duration? resume = point == null
        ? null
        : musicResumeDisplayStart(
            mode: mode,
            savedPositionMs: point.positionMs,
            durationMs: track.durationMs ?? point.durationMs,
          );
    final Text subtitle = Text(
      <String>[
        track.artist ?? t.music_artist_unknown,
        musicRemoteSourceLabel(entry),
      ].join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    void play() => _play(i);
    // 多选态下不可用的行也能勾（可移出 / 整理歌单）；平时点了不起播。
    final VoidCallback? tap = available || _selecting
        ? () => _tapRow(i, available ? play : () {})
        : null;
    final bool selected = _isSelected(i);
    final MusicItemMenu menu = musicRemoteEntryMenu(
      c,
      entry,
      onPlay: play,
      extra: _rowExtras(i),
    );
    if (musicTrackRowSurfaceActive(c)) {
      return menu.contextMenu(
        // 服务器在这台设备上没配：行留着（可移出 / 整理歌单），点了不起播、整行减淡。
        child: Opacity(
          opacity: available ? 1 : 0.5,
          child: _surfaceRow(
            i,
            (bool playing) => MusicTrackRowSurface(
              key: ValueKey<String>(_rowKey('music-track', i, track.trackUid)),
              title: track.title,
              subtitleWidget: musicSubtitleWithResume(
                track.trackUid,
                track.durationMs,
                subtitle,
                resume,
              ),
              leading: musicMaterialCover(
                MusicCover(coverPath: entry.coverUrl, size: 40),
                size: 40,
                compact: true,
              ),
              coverPath: entry.coverUrl,
              durationText: musicTrackTimeLabel(track.durationMs, resume),
              playing: playing,
              onTap: tap,
              onLongPress: _selecting ? tap : null,
              trailing: _selecting
                  ? <Widget>[_check(i, selected)]
                  : <Widget>[
                      menu.button(),
                      if (_onReorder != null) const MusicPlaylistDragHandle(),
                    ],
            ),
          ),
        ),
      );
    }
    return menu.contextMenu(
      child: FushiPressScale(
        child: FushiGroupedListItem(
          key: ValueKey<String>(_rowKey('music-track', i, track.trackUid)),
          index: i,
          count: entries.length,
          // 服务器在这台设备上没配：行留着（可移出 / 整理歌单），点了不起播、整行减淡。
          onTap: tap,
          onLongPress: _selecting ? tap : null,
          selected: selected,
          child: FushiListItem(
            leading: musicMaterialCover(
              MusicCover(coverPath: entry.coverUrl, size: 40),
              size: 40,
              compact: true,
            ),
            title: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: available
                  ? null
                  : TextStyle(color: Theme.of(c).colorScheme.onSurfaceVariant),
            ),
            subtitle: musicSubtitleWithResume(
              track.trackUid,
              track.durationMs,
              subtitle,
              resume,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  musicTrackTimeLabel(track.durationMs, resume),
                  style: c.fushiType.bodySmall,
                ),
                if (_selecting)
                  _check(i, selected)
                else ...<Widget>[
                  menu.button(),
                  if (_onReorder != null) const MusicPlaylistDragHandle(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 色块样式的一格（[MusicTrackBlock]）：点按 / 右键菜单 / 长按（本地曲目 = 曲目
  /// 详情）与行同一套，副行是歌手（远程曲目再跟来源名），底行 chip 是时长 / 剩余。
  Widget _block(
    BuildContext c,
    int i,
    FushiCoverBlockSize size,
    MusicResumeMode mode,
  ) => _selectableBlock(i, _blockBody(c, i, size, mode));

  /// 多选态的色块：右上角压勾选圈（不吃指针，点按仍走色块自己的 onTap）。
  Widget _selectableBlock(int i, Widget block) {
    if (!_selecting) return block;
    return Stack(
      children: <Widget>[
        block,
        PositionedDirectional(
          top: 0,
          end: 0,
          child: IgnorePointer(child: _check(i, _isSelected(i))),
        ),
      ],
    );
  }

  Widget _blockBody(
    BuildContext c,
    int i,
    FushiCoverBlockSize size,
    MusicResumeMode mode,
  ) {
    void play() => _play(i);
    void tap() => _tapRow(i, play);
    switch (entries[i]) {
      case MusicLocalEntry(:final MusicTrackRow track):
        final Duration? resume = musicTrackResumeOf(
          track,
          _resume[track.trackUid],
          mode,
        );
        final MusicItemMenu menu = musicLocalTrackMenu(
          c,
          track,
          onPlay: play,
          extra: _rowExtras(i),
        );
        return menu.contextMenu(
          child: _surfaceRow(
            i,
            (bool playing) => MusicTrackBlock(
              key: ValueKey<String>(_rowKey('music-track', i, track.trackUid)),
              size: size,
              title: track.title,
              subtitle: track.artistCredit ?? t.music_artist_unknown,
              coverPath: entries[i].playItem(widget.albums)?.coverPath,
              embeddedFromPath: track.path,
              durationText: musicTrackTimeLabel(track.durationMs, resume),
              playing: playing,
              onTap: tap,
              onLongPress: _selecting
                  ? tap
                  : () => openMusicTrackDetail(c, track.trackUid),
            ),
          ),
        );
      case final MusicRemoteEntry entry:
        final MusicRemoteTrackRow track = entry.track;
        final bool available = entry.available;
        final MusicResumePointRow? point = _resume[track.trackUid];
        final Duration? resume = point == null
            ? null
            : musicResumeDisplayStart(
                mode: mode,
                savedPositionMs: point.positionMs,
                durationMs: track.durationMs ?? point.durationMs,
              );
        final MusicItemMenu menu = musicRemoteEntryMenu(
          c,
          entry,
          onPlay: play,
          extra: _rowExtras(i),
        );
        return menu.contextMenu(
          // 服务器在这台设备上没配：格子留着（可移出 / 整理歌单），点了不起播、减淡。
          child: Opacity(
            opacity: available ? 1 : 0.5,
            child: _surfaceRow(
              i,
              (bool playing) => MusicTrackBlock(
                key: ValueKey<String>(
                  _rowKey('music-track', i, track.trackUid),
                ),
                size: size,
                title: track.title,
                subtitle: <String>[
                  track.artist ?? t.music_artist_unknown,
                  musicRemoteSourceLabel(entry),
                ].join(' · '),
                coverPath: entry.coverUrl,
                durationText: musicTrackTimeLabel(track.durationMs, resume),
                playing: playing,
                onTap: available || _selecting
                    ? () => _tapRow(i, available ? play : () {})
                    : null,
                onLongPress: _selecting ? tap : null,
              ),
            ),
          ),
        );
    }
  }

  /// 多选态行尾的勾选圈（key `music-track-check-<行 key>`，测试按它认选中态）。
  Widget _check(int i, bool selected) => MusicSelectionCheck(
    key: ValueKey<String>(_rowKey('music-track-check', i, entries[i].trackUid)),
    selected: selected,
  );

  /// 重设计外壳的曲目行（[MusicTrackRowSurface]）接上「正在播放」：第 [i] 行的
  /// 播放项（与 [_play] 排进队列的同一份）是引擎当前曲时常驻铺色 + 标题水印。
  Widget _surfaceRow(int i, Widget Function(bool playing) row) {
    final String? uid = entries[i].playItem(widget.albums)?.trackUid;
    if (uid == null) return row(false);
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    return MusicNowPlayingMatch(
      listenable: engine,
      isCurrent: () => engine.current?.trackUid == uid,
      builder: (BuildContext context, bool playing) => row(playing),
    );
  }

  /// 行 key：歌单里同一首可以出现两次，歌单页的 key 带上行号免得撞。
  String _rowKey(String prefix, int i, String uid) =>
      widget.playlist == null ? '$prefix-$uid' : '$prefix-$i-$uid';
}

/// 本地曲目行缩略图的来源（[MusicCover] 的两个参数）。
typedef MusicTrackCoverSource = ({String? coverPath, String? embeddedFromPath});

/// [entries] 里本地曲目的 uid → 音频路径。
Map<String, String> musicLocalTrackPathsOf(List<MusicLibraryEntry> entries) =>
    <String, String>{
      for (final MusicLibraryEntry e in entries)
        if (e case MusicLocalEntry(:final MusicTrackRow track))
          track.trackUid: track.path,
    };

/// 本地曲目行用哪张封面：与专辑网格 / 「继续收听」同一来源——专辑的目录封面
/// （[MusicAlbumRow.coverPath]）优先，其次专辑选定的内嵌封面曲目
/// （[MusicAlbumRow.coverTrackUid]，同一张专辑的各行共用一次读取）；那首不在本列表里
/// （[pathByUid] 查不到）时退回这首自己的内嵌封面；都没有给占位（两个都为 null）。
MusicTrackCoverSource musicLocalTrackCoverOf(
  MusicTrackRow track, {
  required MusicAlbumRow? album,
  required Map<String, String> pathByUid,
}) {
  final String? albumEmbedded = switch (album?.coverTrackUid) {
    final String uid => pathByUid[uid],
    null => null,
  };
  return (
    coverPath: album?.coverPath,
    embeddedFromPath:
        albumEmbedded ?? (track.hasEmbeddedCover ? track.path : null),
  );
}

/// 当前的断点续播模式（设置 `music_resume_mode`）；设置里切档时调用方跟着重建。
MusicResumeMode watchMusicResumeMode(WidgetRef ref) => ref.watch(
  appProvider.select(
    (AppModel a) =>
        a.isPreferencesReady ? a.musicResumeMode : MusicResumeMode.longTracks,
  ),
);

/// [track] 点开会从哪接着放（与打开时同一判据）；null = 从头（不显示进度）。
Duration? musicTrackResumeOf(
  MusicTrackRow track,
  MusicResumePointRow? row,
  MusicResumeMode mode,
) => row == null
    ? null
    : musicResumeDisplayStart(
        mode: mode,
        savedPositionMs: row.positionMs,
        durationMs: track.durationMs ?? row.durationMs,
      );

/// 行尾时间：有断点显示「剩余 m:ss」，否则曲长。
String musicTrackTimeLabel(int? durationMs, Duration? resume) =>
    resume == null || durationMs == null
    ? formatMusicDuration(durationMs)
    : t.music_track_remaining(
        time: formatMusicDuration(durationMs - resume.inMilliseconds),
      );

/// 有断点的行：副标题下加一条细进度条（key `music-track-resume-<uid>`）。
Widget? musicTrackSubtitleWithResume(
  MusicTrackRow track,
  Widget? subtitle,
  Duration? resume,
) =>
    musicSubtitleWithResume(track.trackUid, track.durationMs, subtitle, resume);

/// [musicTrackSubtitleWithResume] 的通用形（远程曲目也用：只要 uid 与曲长）。
Widget? musicSubtitleWithResume(
  String trackUid,
  int? durationMs,
  Widget? subtitle,
  Duration? resume,
) {
  if (resume == null || durationMs == null) return subtitle;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      if (subtitle != null) ...<Widget>[subtitle, const SizedBox(height: 4)],
      _MusicResumeBar(
        key: ValueKey<String>('music-track-resume-$trackUid'),
        fraction: resume.inMilliseconds / durationMs,
      ),
    ],
  );
}

/// 断点进度条（细、平直；值变化时按动效时长补间，减弱动态效果下瞬间到位）。
class _MusicResumeBar extends StatelessWidget {
  const _MusicResumeBar({super.key, required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(end: fraction.clamp(0, 1).toDouble()),
    duration: fushiMotionDuration(context, FushiMotion.medium),
    curve: FushiMotion.enter,
    builder: (BuildContext context, double value, _) =>
        FushiLinearProgressIndicator(value: value, minHeight: 3, wavy: false),
  );
}

/// 一列曲目的独立页（艺人）。
class MusicTrackListPage extends StatelessWidget {
  const MusicTrackListPage({
    super.key,
    required this.title,
    required this.tracks,
    required this.albums,
  });

  final String title;
  final List<MusicTrackRow> tracks;
  final Map<String, MusicAlbumRow> albums;

  @override
  Widget build(BuildContext context) => MusicViewStyleBuilder(
    kind: MusicViewKind.tracks,
    fallback: MusicViewStyle.list,
    builder: _buildPage,
  );

  /// [style]：曲目排成单列曲目行（原有）或多列封面色块。
  Widget _buildPage(BuildContext context, MusicViewStyle style) {
    // 重设计外壳：页头大字外壳 + 列表最前一块艺人色块（艺人没有图，色块颜色由
    // 名字折叠出色相，水印大字 = 艺人名）；墨水屏照旧是悬浮顶栏 + 纯列表。
    final bool redesign = shellRedesignActive(context);
    return musicBrowseScaffold(
      context,
      title: title,
      titleInBody: redesign,
      actions: <FushiToolbarItem>[
        if (musicViewStyleSwitchable(context))
          musicViewStyleToggle(MusicViewKind.tracks, style),
      ],
      body: (BuildContext context) => MusicTrackList(
        tracks: tracks,
        albums: albums,
        context: MusicQueueContext.mixed,
        style: style,
        header: redesign
            ? MusicDetailHero(
                title: title,
                showCover: false,
                eyebrow: t.music_section_artists,
                meta: t.music_tracks_count(count: tracks.length),
                legacy: const SizedBox.shrink(),
              )
            : null,
      ),
    );
  }
}

/// 按播放项身份（[trackUid]，与排进引擎队列的 `MusicPlayItem.trackUid` 同一口径）
/// 认「正在播放」：从 [appProvider] 取音乐引擎交给 [MusicNowPlayingMatch]。
/// 放在这里而不是行外观文件（`music_track_row_surface.dart`）：外观层不接
/// AppModel，否则它会被拉进 import 大环（`import_cycle_guard_test`）。
/// [trackUid] 为 null（认不出身份的行）恒为 false，不挂监听。
class MusicNowPlayingTrack extends ConsumerWidget {
  const MusicNowPlayingTrack({
    required this.trackUid,
    required this.builder,
    super.key,
  });

  final String? trackUid;
  final Widget Function(BuildContext context, bool playing) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? uid = trackUid;
    if (uid == null) return builder(context, false);
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    return MusicNowPlayingMatch(
      listenable: engine,
      isCurrent: () => engine.current?.trackUid == uid,
      builder: builder,
    );
  }
}
