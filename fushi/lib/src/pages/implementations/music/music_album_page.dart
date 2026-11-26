/// 专辑页（设计 §11.2）：大封面、碟片分组、格式徽章（`FLAC 24/96` / `DSD64` / `Hi-Res`）、
/// 整碟播放（album ReplayGain）与随机播放（track ReplayGain）。
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdate, TableUpdateQuery;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/disc/music_disc.dart';

import 'package:fushi/src/media/links/media_link_entries.dart'
    show MediaLinkEntry;
import 'package:fushi/src/media/links/media_link_inference_host.dart'
    show mediaLinkInferCallback;
import 'package:fushi/src/media/links/media_link_opener.dart'
    show mediaLinkRemoteVideoSource, mediaLinkSearchAction, openMediaLinkEntry;
import 'package:fushi/src/media/links/media_links_section.dart'
    show MediaLinksSection;
import 'package:fushi/src/media/music/asr/music_subtitle_target.dart'
    show MusicSubtitleTargets;
import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_resume.dart';
import 'package:fushi/src/media/music/music_resume_points_watch.dart';
import 'package:fushi/src/media/selection/media_selection_controller.dart';
import 'package:fushi/src/media/selection/selection_gestures.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_album_dlsite_section.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_disc_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart'
    show openMusicPlayerPage;
import 'package:fushi/src/pages/implementations/music/music_playlist_actions.dart'
    show musicAddLocalTracksToPlaylist;
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart'
    show
        MusicDetailHero,
        kMusicAlbumDetailCoverSize,
        musicAlbumDetailCover,
        musicBrowseScaffold,
        musicDetailHeroGap;
import 'package:fushi/src/pages/implementations/music/music_subtitle_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart'
    show MusicItemMenu, MusicMenuAction;
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/pages/implementations/music/music_track_row_surface.dart';
import 'package:fushi/src/pages/implementations/music/music_collection_view.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockSize;
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart'
    show FushiCoverBlocks;
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiToolbarItem;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 一张专辑要显示的格式徽章（去重、按出现顺序；混格式专辑各列一枚）+ 是否 Hi-Res。
({List<String> badges, bool hiRes}) musicAlbumBadges(
  List<MusicTrackRow> tracks,
) {
  final List<String> badges = <String>[];
  bool hiRes = false;
  for (final MusicTrackRow t in tracks) {
    final String b = musicFormatBadge(
      codec: t.codec,
      isLossless: t.isLossless,
      sampleRate: t.sampleRate,
      bitDepth: t.bitDepth,
      bitrateKbps: t.isLossless ? null : t.bitrate,
    );
    if (b.isNotEmpty && !badges.contains(b)) badges.add(b);
    hiRes =
        hiRes ||
        musicIsHiRes(
          codec: t.codec,
          isLossless: t.isLossless,
          sampleRate: t.sampleRate,
          bitDepth: t.bitDepth,
        );
  }
  return (badges: badges, hiRes: hiRes);
}

class MusicAlbumPage extends ConsumerStatefulWidget {
  const MusicAlbumPage({
    super.key,
    required this.album,
    required this.tracks,
    this.embeddedCoverPath,
    this.disc,
  });

  final MusicAlbumRow album;

  /// 已按碟号 / 轨号排好的曲目。
  final List<MusicTrackRow> tracks;
  final String? embeddedCoverPath;

  /// 光盘来源（演唱会 / MV 合集 DVD·BD，§9.2）；普通专辑为 null。
  final MusicDiscSourceRow? disc;

  @override
  ConsumerState<MusicAlbumPage> createState() => _MusicAlbumPageState();
}

class _MusicAlbumPageState extends ConsumerState<MusicAlbumPage> {
  late MusicAlbumRow album = widget.album;

  /// 播放来源（最近播放按它归组，推荐页「最近播放」点回这张专辑）。
  MusicPlaySource get _source => MusicPlaySource.album(
    album.albumUid,
    title: album.title,
    cover: album.coverPath,
  );
  late List<MusicTrackRow> tracks = widget.tracks;
  late MusicDiscSourceRow? disc = widget.disc;
  StreamSubscription<Set<TableUpdate>>? _dbSub;
  bool _busy = false;

  /// 已经在退回曲库（专辑被移除）。
  bool _leaving = false;

  AppModel get _app => ref.read(appProvider);

  /// 曲目多选（拍板台 IDeN5PYaI7）：跨碟按曲目 uid 选，与曲目列表（[MusicTrackList]）
  /// 同一套控制器、底部动作条（[MusicTrackSelectionBar]）与勾选圈。
  final MediaSelectionController _selection = MediaSelectionController();

  /// 多选底栏浮层（第一次进多选时挂上，之后常驻，退出时播收起动效）。
  final OverlayPortalController _barPortal = OverlayPortalController();

  bool get _selecting => _selection.active;

  /// 曲目换了（重扫 / 批量移除之后）：可见顺序重登记，选中集剔掉已经不在的曲目。
  void _syncSelectionOrder() {
    final List<String> keys = <String>[
      for (final MusicTrackRow t in tracks) t.trackUid,
    ];
    _selection
      ..setVisibleOrder(loose: keys, collections: const <int>[])
      ..retainExisting(loose: keys.toSet(), collections: const <int>{});
  }

  /// 进入多选并选中 [trackUid]。
  void _enterSelection(String trackUid) {
    if (!_barPortal.isShowing) _barPortal.show();
    setState(() {
      _syncSelectionOrder();
      _selection.enterWith(SelectionSlot.loose(trackUid));
    });
  }

  void _exitSelection() => setState(_selection.exit);

  /// 点一首：多选态 = 勾选（Shift = 区间扩选）；桌面 Ctrl / ⌘ / Shift + 点击 = 直接进
  /// 多选；否则 [orElse]（起播）。
  void _tapTrack(String trackUid, VoidCallback orElse) {
    if (_selecting) {
      setState(
        () => _selection.applyTap(
          SelectionSlot.loose(trackUid),
          selectionTapKind(),
        ),
      );
      return;
    }
    if (selectionEntryModifierPressed(context)) {
      _enterSelection(trackUid);
      return;
    }
    orElse();
  }

  /// 长按：多选态 = 勾选，平时 = 进多选（触屏上的进入方式）。
  void _longPressTrack(String trackUid) =>
      _selecting ? _tapTrack(trackUid, () {}) : _enterSelection(trackUid);

  bool _isSelected(String trackUid) =>
      _selecting && _selection.looseKeys.contains(trackUid);

  /// 批量动作跑完：退出多选（选中的曲目可能已经不在这张专辑里了）。
  Future<void> _runBatch(
    Future<void> Function(List<MusicLibraryEntry> picked) action,
  ) async {
    final Set<String> keys = _selection.looseKeys;
    final List<MusicLibraryEntry> picked = <MusicLibraryEntry>[
      for (final MusicTrackRow t in tracks)
        if (keys.contains(t.trackUid)) MusicLocalEntry(t),
    ];
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

  Widget _selectionBar(Map<String, MusicAlbumRow> albums) {
    final AppModel app = _app;
    final MusicPlayerEngine engine = app.musicSession.engine;
    final bool db = app.isDatabaseReady;
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
                (List<MusicLibraryEntry> picked) =>
                    musicQueueEntries(engine, picked, albums, next: true),
              ),
            )
          : null,
      onAddToQueue: queue
          ? () => unawaited(
              _runBatch(
                (List<MusicLibraryEntry> picked) =>
                    musicQueueEntries(engine, picked, albums, next: false),
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
      onRemoveFromLibrary: db
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

  /// 把正文包上多选底栏浮层与「返回键先退出多选」。
  Widget _withSelection(Map<String, MusicAlbumRow> albums, Widget body) =>
      PopScope(
        canPop: !_selecting,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (!didPop && _selecting) _exitSelection();
        },
        child: OverlayPortal(
          controller: _barPortal,
          overlayChildBuilder: (BuildContext context) =>
              MusicTrackSelectionBarHost(
                visible: _selecting,
                bar: _selectionBar(albums),
              ),
          child: body,
        ),
      );

  @override
  void initState() {
    super.initState();
    _syncSelectionOrder();
    if (_app.isDatabaseReady) {
      final FushiDatabase db = _app.database;
      // 表级变更流（不是 drift .watch()：长驻页面订阅 watch 会在 dispose 时挂死测试）。
      // 章节导入 / MusicBrainz 对号 / 重扫都在别处落库，这里跟着重读。
      _dbSub = db
          .tableUpdates(
            TableUpdateQuery.onAllTables(
              <ResultSetImplementation<Object?, Object?>>[
                db.musicTracks,
                db.musicAlbums,
                db.musicDiscSources,
              ],
            ),
          )
          .listen((_) => unawaited(_reload()));
    }
  }

  @override
  void dispose() {
    unawaited(_dbSub?.cancel());
    super.dispose();
  }

  Future<void> _reload() async {
    final FushiDatabase db = _app.database;
    final MusicAlbumRow? a = await db.getMusicAlbum(album.albumUid);
    if (!mounted || _leaving) return;
    if (a == null) {
      // 专辑被移除（光盘从曲库移除）：退回曲库。
      _leave();
      return;
    }
    final List<MusicTrackRow> rows = sortAlbumTracks(
      await db.listMusicTracks(albumUid: album.albumUid),
    );
    if (!mounted || _leaving) return;
    if (a.discUid == null && rows.isEmpty) {
      // 普通专辑的曲目全被移出音乐库（整张移除 / 多选全移除）：专辑墙已不列它，退回曲库；
      // 撤销提示挂在曲库那层的 ScaffoldMessenger 上，照样能点。
      _leave();
      return;
    }
    final String? discUid = a.discUid;
    final MusicDiscSourceRow? d = discUid == null
        ? null
        : await db.getMusicDiscSource(discUid);
    if (!mounted) return;
    setState(() {
      album = a;
      tracks = rows;
      disc = d;
      _syncSelectionOrder();
    });
  }

  /// 退回曲库（只退一次：表变更会连发好几次重读）。只摘本页这条路由：本页上面压着别的
  /// 页（播放页、别的详情）时 `maybePop` 会把顶上那页弹掉，专辑页反而留着。
  void _leave() {
    if (_leaving) return;
    _leaving = true;
    final NavigatorState navigator = Navigator.of(context);
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route == null || route.isCurrent) {
      unawaited(navigator.maybePop());
    } else if (route.isActive) {
      navigator.removeRoute(route);
    }
  }

  /// 专辑动作（光盘的导入 / 对号 / 移除整张盘；普通专辑整张移出音乐库）。
  Future<void> _runAlbumAction(MusicAlbumMenuAction action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runMusicAlbumMenuAction(
        context: context,
        app: _app,
        action: action,
        album: album,
        disc: disc,
        tracks: tracks,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<MusicPlayItem> _items() => <MusicPlayItem>[
    for (final MusicTrackRow t in tracks) musicPlayItemOf(t, album: album),
  ];

  /// 「播放全部 / 随机播放」：从头放整张并直接进播放页（返回回到专辑页）。
  void _playAll(MusicPlayerEngine engine, {bool shuffle = false}) {
    unawaited(
      engine.playQueue(
        _items(),
        context: MusicQueueContext.album,
        shuffle: shuffle,
        source: _source,
      ),
    );
    openMusicPlayerPage(context);
  }

  @override
  Widget build(BuildContext context) => MusicViewStyleBuilder(
    kind: MusicViewKind.tracks,
    fallback: MusicViewStyle.list,
    builder: _buildPage,
  );

  /// [style]：各碟曲目排成单列曲目行（原有）或多列封面色块。
  Widget _buildPage(BuildContext context, MusicViewStyle style) {
    final String? embeddedCoverPath = widget.embeddedCoverPath;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    final ({List<String> badges, bool hiRes}) fmt = musicAlbumBadges(tracks);
    final Map<int?, List<MusicTrackRow>> discs = groupTracksByDisc(tracks);
    final Map<String, MusicAlbumRow> albumMap = <String, MusicAlbumRow>{
      album.albumUid: album,
    };
    final MusicDiscSourceRow? disc = this.disc;

    final String meta = <String>[
      album.albumArtistCredit ?? t.music_artist_unknown,
      if (album.releaseDate != null) album.releaseDate!,
      t.music_tracks_count(count: tracks.length),
    ].join(' · ');
    final List<Widget> discBadges = <Widget>[
      if (disc != null)
        IgnorePointer(
          child: MusicDiscBadge(
            key: const ValueKey<String>('music-album-disc-badge'),
            disc: disc,
          ),
        ),
    ];
    final List<Widget> actions = <Widget>[
      FushiPressScale(
        child: FushiFilledButton.icon(
          size: FushiButtonSize.m,
          key: const ValueKey<String>('music_album_play'),
          onPressed: tracks.isEmpty ? null : () => _playAll(engine),
          icon: const FushiIcon(FushiIcons.play),
          label: Text(t.music_play_all),
        ),
      ),
      FushiPressScale(
        child: FushiFilledButton.tonalIcon(
          size: FushiButtonSize.m,
          key: const ValueKey<String>('music_album_shuffle'),
          onPressed: tracks.isEmpty
              ? null
              : () => _playAll(engine, shuffle: true),
          icon: const FushiIcon(FushiIcons.shuffle),
          label: Text(t.music_shuffle_play),
        ),
      ),
      FushiPressScale(
        child: FushiFilledButton.tonalIcon(
          size: FushiButtonSize.m,
          key: const ValueKey<String>('music_album_add_to_playlist'),
          onPressed: tracks.isEmpty
              ? null
              : () => unawaited(
                  musicAddLocalTracksToPlaylist(context, <String>[
                    for (final MusicTrackRow tr in tracks) tr.trackUid,
                  ]),
                ),
          icon: const FushiIcon(FushiIcons.playlist),
          label: Text(t.music_action_add_to_playlist),
        ),
      ),
      // 广播剧 CD 一类整张专辑：一键排队生成日语字幕（已有生成字幕的曲目跳过）。
      if (musicSubtitleGenerationAvailableForAny(<String>[
        for (final MusicTrackRow t in tracks) t.path,
      ]))
        FushiPressScale(
          child: FushiFilledButton.tonalIcon(
            size: FushiButtonSize.m,
            key: const ValueKey<String>('music_album_generate_subtitles'),
            onPressed: () => unawaited(
              openMusicSubtitleGenerateSheet(
                context: context,
                appModel: _app,
                resolve: (MusicSubtitleTargets targets) =>
                    targets.forAlbum(album.albumUid),
              ),
            ),
            icon: const FushiIcon(FushiIcons.subtitles),
            label: Text(t.music_subtitle_generate_album),
          ),
        ),
      // 隐私：上锁与 NSFW（封面按「模糊 NSFW 封面」打模糊；DLsite 认出 R-18 时默认
      // 已标上 NSFW）。
      if (_app.isDatabaseReady)
        FushiPressScale(
          child: FushiFilledButton.tonalIcon(
            size: FushiButtonSize.m,
            key: const ValueKey<String>('music_album_privacy'),
            onPressed: () => unawaited(
              showMusicAlbumPrivacyDialog(context, _app.database, album),
            ),
            icon: const FushiIcon(FushiIcons.shield),
            label: Text(t.media_privacy_action),
          ),
        ),
      if (disc != null) ...<Widget>[
        FushiPressScale(
          child: FushiFilledButton.tonalIcon(
            size: FushiButtonSize.m,
            key: const ValueKey<String>('music_disc_import'),
            onPressed: _busy
                ? null
                : () => unawaited(
                    _runAlbumAction(MusicAlbumMenuAction.importChapters),
                  ),
            icon: const FushiIcon(FushiIcons.toc),
            label: Text(
              musicDiscImportLabel(disc, hasTracks: tracks.isNotEmpty),
            ),
          ),
        ),
        if (tracks.isNotEmpty && disc.kind != MusicDiscKind.cdda.wire)
          FushiPressScale(
            child: FushiFilledButton.tonalIcon(
              size: FushiButtonSize.m,
              key: const ValueKey<String>('music_disc_lookup'),
              onPressed: _busy
                  ? null
                  : () =>
                        unawaited(_runAlbumAction(MusicAlbumMenuAction.lookup)),
              icon: const FushiIcon(FushiIcons.search),
              label: Text(t.music_disc_lookup),
            ),
          ),
        FushiPressScale(
          child: FushiFilledButton.tonalIcon(
            size: FushiButtonSize.m,
            key: const ValueKey<String>('music_disc_remove'),
            onPressed: _busy
                ? null
                : () => unawaited(_runAlbumAction(MusicAlbumMenuAction.remove)),
            icon: const FushiIcon(FushiIcons.delete),
            label: Text(t.music_disc_remove),
          ),
        ),
      ] else if (tracks.isNotEmpty && _app.isDatabaseReady)
        // 整张专辑移出音乐库（拍板台 mmXVwo0Ibv）：磁盘文件不动，带撤销。
        FushiPressScale(
          child: FushiFilledButton.tonalIcon(
            size: FushiButtonSize.m,
            key: const ValueKey<String>('music_album_remove'),
            onPressed: _busy
                ? null
                : () => unawaited(_runAlbumAction(MusicAlbumMenuAction.remove)),
            icon: const FushiIcon(FushiIcons.removeCircle),
            label: Text(t.music_action_remove_from_library),
          ),
        ),
    ];
    final bool notImported = disc != null && tracks.isEmpty;

    final Widget header = MusicDetailHero(
      title: album.title,
      coverPath: album.coverPath,
      embeddedFromPath: embeddedCoverPath,
      eyebrow: t.music_section_albums,
      meta: meta,
      leadingBadges: discBadges,
      chips: fmt.badges,
      strongChips: <String>[if (fmt.hiRes) t.music_hi_res_badge],
      actions: actions,
      footer: notImported ? t.music_disc_not_imported : null,
      legacy: Wrap(
        spacing: tokens.spacing.section,
        runSpacing: tokens.spacing.gap,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: <Widget>[
          // 方形「唱片」材质大图（与专辑网格同一材质）；封面上不压角标，光盘规格
          // 徽标挪到右侧格式徽章那一排。
          musicAlbumDetailCover(
            MusicCover(
              coverPath: album.coverPath,
              embeddedFromPath: embeddedCoverPath,
              size: kMusicAlbumDetailCoverSize,
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: tokens.spacing.gap * 0.5,
              children: <Widget>[
                Text(album.title, style: context.fushiType.headlineSmall),
                Text(meta, style: context.fushiType.bodyMedium),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    ...discBadges,
                    for (final String b in fmt.badges) _Badge(text: b),
                    if (fmt.hiRes)
                      _Badge(text: t.music_hi_res_badge, strong: true),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: tokens.spacing.gap,
                  runSpacing: tokens.spacing.gap,
                  children: actions,
                ),
                if (notImported)
                  Text(
                    t.music_disc_not_imported,
                    style: context.fushiType.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    final List<Widget> children = <Widget>[
      header,
      // 音声 / ASMR 专辑：按作品编号（RJ…）显示 DLsite 资料；认不出编号整块不出现。
      if (_app.isDatabaseReady && musicAlbumHasDlsiteWork(album, tracks))
        MusicAlbumDlsiteSection(
          album: album,
          tracks: tracks,
          scraper: _app.musicScrape.dlsite,
        ),
      for (final MapEntry<int?, List<MusicTrackRow>> disc
          in discs.entries) ...<Widget>[
        if (disc.key != null)
          FushiSectionTitle(t.music_disc_label(n: disc.key!)),
        _AlbumDiscList(
          tracks: disc.value,
          allTracks: tracks,
          albums: albumMap,
          album: album,
          style: style,
          selection: _AlbumTrackSelection(
            active: _selecting,
            isSelected: _isSelected,
            tap: _tapTrack,
            longPress: _longPressTrack,
            enter: _enterSelection,
          ),
        ),
      ],
      // 跨模块「同一作品」（作品图谱 media_links）：专辑 → 动画合集 / 游戏，与曲目
      // 详情页同一个区块与「查找相关作品」入口。
      MediaLinksSection(
        remoteVideoSource: mediaLinkRemoteVideoSource(ref: ref),
        database: ref.read(appProvider).database,
        self: (kind: MediaLinkKind.musicAlbum, key: album.albumUid),
        onOpen: (MediaLinkEntry e) =>
            openMediaLinkEntry(context: context, ref: ref, entry: e),
        searchActionFor: (MediaLinkKind k) =>
            mediaLinkSearchAction(context: context, ref: ref, kind: k),
        onInfer: mediaLinkInferCallback(
          ref: ref,
          self: (kind: MediaLinkKind.musicAlbum, key: album.albumUid),
        ),
      ),
    ];

    final double heroGap = musicDetailHeroGap(context, tokens.spacing.gap);
    // 外壳与服务器 / 插件详情同一份（[musicBrowseScaffold]）：重设计外壳下是页头
    // 大字（标题已在色块里，页头只留返回键，滚过色块后页名淡入）；墨水屏照旧是
    // 悬浮顶栏 / Apple 系统页头。
    return musicBrowseScaffold(
      context,
      title: album.title,
      titleInBody: true,
      actions: <FushiToolbarItem>[
        if (musicTrackRowSurfaceActive(context))
          musicViewStyleToggle(MusicViewKind.tracks, style),
      ],
      body: (BuildContext context) => _withSelection(
        albumMap,
        FushiEntranceScope(
          // Builder：顶部让位读的是脚手架给正文的 MediaQuery（页头高度在里面），
          // 不是本页 build 的外层 context。
          child: Builder(
            builder: (BuildContext context) => ListView.separated(
              padding: withBottomSafeInset(
                context,
                EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  // 外壳把正文铺到悬浮页头底下，页头高度经 MediaQuery 顶部 padding
                  // 传下来，必须让出，否则封面被顶栏盖住（反馈 yglXWr9DTq）。与同目录
                  // 其它页同一约定。
                  MediaQuery.paddingOf(context).top + tokens.spacing.gap,
                  tokens.spacing.page,
                  tokens.spacing.section,
                ),
              ),
              itemCount: children.length,
              separatorBuilder: (_, int i) =>
                  SizedBox(height: i == 0 ? heroGap : tokens.spacing.gap),
              itemBuilder: fushiStaggeredItemBuilder(
                (BuildContext context, int i) => children[i],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 专辑页传给每一碟的多选状态与入口（选择状态归整页，跨碟一份）。
class _AlbumTrackSelection {
  const _AlbumTrackSelection({
    required this.active,
    required this.isSelected,
    required this.tap,
    required this.longPress,
    required this.enter,
  });

  final bool active;
  final bool Function(String trackUid) isSelected;
  final void Function(String trackUid, VoidCallback orElse) tap;
  final void Function(String trackUid) longPress;
  final void Function(String trackUid) enter;
}

/// 一碟的曲目。点一首 = 整张专辑为队列（album 语境），从这首开始。有会被续播的断点
/// （`music_resume.dart`）的轨：行尾显示剩余时间，下面一条细进度条（与 [MusicTrackList]
/// 同一套显示）——广播剧 CD 迁进来是一张专辑，按轨浏览主要在这里。
class _AlbumDiscList extends ConsumerStatefulWidget {
  const _AlbumDiscList({
    required this.tracks,
    required this.allTracks,
    required this.albums,
    required this.album,
    required this.selection,
    this.style = MusicViewStyle.list,
  });

  final _AlbumTrackSelection selection;
  final List<MusicTrackRow> tracks;
  final List<MusicTrackRow> allTracks;
  final Map<String, MusicAlbumRow> albums;
  final MusicAlbumRow album;

  /// 单列曲目行 / 多列封面色块（[MusicTrackBlock]，重设计外壳下）。
  final MusicViewStyle style;

  @override
  ConsumerState<_AlbumDiscList> createState() => _AlbumDiscListState();
}

class _AlbumDiscListState extends ConsumerState<_AlbumDiscList> {
  /// 这一碟的断点：挂上时按块查齐，之后只吃这一碟里那几首的改动。
  late final MusicResumePointsWatch _resume;

  List<MusicTrackRow> get tracks => widget.tracks;

  static Iterable<String> _uids(List<MusicTrackRow> tracks) =>
      tracks.map((MusicTrackRow t) => t.trackUid);

  @override
  void initState() {
    super.initState();
    _resume =
        ref
            .read(appProvider)
            .musicSession
            .watchResumePoints(_uids(widget.tracks))
          ..addListener(_onResumeChanged);
  }

  @override
  void didUpdateWidget(_AlbumDiscList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tracks, widget.tracks)) {
      _resume.watch(_uids(widget.tracks));
    }
  }

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

  @override
  Widget build(BuildContext context) {
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    final MusicResumeMode mode = watchMusicResumeMode(ref);
    final List<MusicTrackRow> allTracks = widget.allTracks;
    final MusicAlbumRow album = widget.album;
    final List<Duration?> resumes = <Duration?>[
      for (final MusicTrackRow t in tracks)
        musicTrackResumeOf(t, _resume[t.trackUid], mode),
    ];
    void play(int i) => unawaited(
      engine.playQueue(
        <MusicPlayItem>[
          for (final MusicTrackRow t in allTracks)
            musicPlayItemOf(t, album: album),
        ],
        startIndex: allTracks.indexOf(tracks[i]),
        context: MusicQueueContext.album,
        source: MusicPlaySource.album(
          album.albumUid,
          title: album.title,
          cover: album.coverPath,
        ),
      ),
    );
    final _AlbumTrackSelection sel = widget.selection;
    void tap(int i) => sel.tap(tracks[i].trackUid, () => play(i));
    void longPress(int i) => sel.longPress(tracks[i].trackUid);
    Widget check(int i) => MusicSelectionCheck(
      key: ValueKey<String>('music-album-track-check-${tracks[i].trackUid}'),
      selected: sel.isSelected(tracks[i].trackUid),
    );
    // 与曲目列表同一份本地曲目菜单（右键 / 上下文菜单键 / 行尾「⋯」/ 色块长按）：播放 /
    // 入队 / 详情 / 加入歌单 / 从音乐库移除，末尾追加「多选」。
    MusicItemMenu menuOf(int i) => musicLocalTrackMenu(
      context,
      tracks[i],
      onPlay: () => play(i),
      extra: <MusicMenuAction>[
        MusicMenuAction(
          id: 'select',
          label: t.music_selection_enter,
          icon: FushiIcons.checklist,
          run: (_) async => sel.enter(tracks[i].trackUid),
        ),
      ],
    );
    Widget withMenu(int i, Widget row) => menuOf(i).contextMenu(child: row);
    Widget? subtitleOf(int i) => musicTrackSubtitleWithResume(
      tracks[i],
      tracks[i].artistCredit == null ||
              tracks[i].artistCredit == album.albumArtistCredit
          ? null
          : Text(tracks[i].artistCredit!),
      resumes[i],
    );
    if (musicCoverBlocksActive(context, widget.style)) {
      // 一碟十几首、排在外层列表里：盒子版色块（一次建完），与库页同一套几何。
      // 外层列表已整块错峰进场，格子不再各自进场。
      return FushiCoverBlocks(
        staggerEntrance: false,
        itemCount: tracks.length,
        itemBuilder: (BuildContext context, int i, FushiCoverBlockSize size) =>
            withMenu(
              i,
              _selectableBlock(
                sel.active ? check(i) : null,
                MusicNowPlayingTrack(
                  trackUid: tracks[i].trackUid,
                  builder: (BuildContext context, bool playing) =>
                      MusicTrackBlock(
                        key: ValueKey<String>(
                          'music-album-track-${tracks[i].trackUid}',
                        ),
                        size: size,
                        title: tracks[i].title,
                        subtitle: <String>[
                          if (tracks[i].trackNo != null) '${tracks[i].trackNo}',
                          if (tracks[i].artistCredit != null &&
                              tracks[i].artistCredit != album.albumArtistCredit)
                            tracks[i].artistCredit!,
                        ].join(' · '),
                        coverPath: album.coverPath,
                        embeddedFromPath: tracks[i].path,
                        durationText: musicTrackTimeLabel(
                          tracks[i].durationMs,
                          resumes[i],
                        ),
                        playing: playing,
                        onTap: () => tap(i),
                        // 色块不放「⋯」：平时长按弹菜单（多选在菜单里），多选态长按 = 勾选。
                        onLongPress: sel.active ? () => longPress(i) : null,
                        menu: menuOf(i),
                      ),
                ),
              ),
            ),
      );
    }
    if (musicTrackRowSurfaceActive(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < tracks.length; i++)
            withMenu(
              i,
              MusicNowPlayingTrack(
                trackUid: tracks[i].trackUid,
                builder: (BuildContext context, bool playing) =>
                    MusicTrackRowSurface(
                      key: ValueKey<String>(
                        'music-album-track-${tracks[i].trackUid}',
                      ),
                      title: tracks[i].title,
                      subtitleWidget: subtitleOf(i),
                      ordinal: tracks[i].trackNo?.toString() ?? '',
                      coverPath: album.coverPath,
                      embeddedFromPath: tracks[i].path,
                      durationText: musicTrackTimeLabel(
                        tracks[i].durationMs,
                        resumes[i],
                      ),
                      playing: playing,
                      onTap: () => tap(i),
                      onLongPress: () => longPress(i),
                      // 触屏没有右键：行尾「⋯」打开与右键同一份菜单。
                      trailing: sel.active
                          ? <Widget>[check(i)]
                          : <Widget>[menuOf(i).button()],
                    ),
              ),
            ),
        ],
      );
    }
    return Column(
      children: <Widget>[
        for (int i = 0; i < tracks.length; i++)
          withMenu(
            i,
            FushiPressScale(
              child: FushiGroupedListItem(
                key: ValueKey<String>(
                  'music-album-track-${tracks[i].trackUid}',
                ),
                index: i,
                count: tracks.length,
                selected: sel.isSelected(tracks[i].trackUid),
                onTap: () => tap(i),
                onLongPress: () => longPress(i),
                child: FushiListItem(
                  leading: SizedBox(
                    width: 28,
                    child: Text(
                      tracks[i].trackNo?.toString() ?? '',
                      textAlign: TextAlign.end,
                      style: context.fushiType.bodySmall,
                    ),
                  ),
                  title: Text(
                    tracks[i].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: subtitleOf(i),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        musicTrackTimeLabel(tracks[i].durationMs, resumes[i]),
                        style: context.fushiType.bodySmall,
                      ),
                      if (sel.active) check(i) else menuOf(i).button(),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 多选态的色块：右上角压勾选圈（不吃指针，点按仍走色块自己的 onTap）。
  static Widget _selectableBlock(Widget? check, Widget block) {
    if (check == null) return block;
    return Stack(
      children: <Widget>[
        block,
        PositionedDirectional(
          top: 0,
          end: 0,
          child: IgnorePointer(child: check),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.strong = false});

  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: strong ? scheme.primaryContainer : scheme.secondaryContainer,
        borderRadius: FushiDesignTokens.of(context).radii.chipRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          text,
          style: context.fushiType.labelMedium.copyWith(
            color: strong
                ? scheme.onPrimaryContainer
                : scheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}
