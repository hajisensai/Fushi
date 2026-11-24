/// 音乐库页（设计 §11.2）：分区 专辑 · 艺人 · 歌曲 · 作品 · 歌单。不做统计概况卡（D9）。
/// 「作品」分区的数据来自作品图谱（docs/specs/2026-10-24-cross-media-links.md），P0 先空态。
library;

import 'dart:async';
import 'dart:io' show FileSystemEntity;

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdate, TableUpdateQuery;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_corpus/fushi_corpus.dart'
    show CorpusHit, CorpusSourceKind;
import 'package:fushi_music/fushi_music.dart'
    show MusicPluginCapability, MusicPluginManifest, MusicPluginSearchType;

import 'package:fushi/src/corpus/library_corpus_service.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart'
    show CompanionLibraryKind;
import 'package:fushi/src/second_screen/companion/modules/library_companion_hook.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:fushi/src/mining/mined_origin_navigation.dart'
    show playMusicOriginClip;
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isGlassDesign;
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart'
    show FushiCoverBlocks;
import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/music/music_audio_intake.dart'
    show MusicAudioIntake, MusicAudioIntakeResult;
import 'package:fushi/src/media/music/music_disc_art.dart'
    show MusicDiscArtIndex, shareMusicDiscArtAcrossVersions;
import 'package:fushi/src/media/music/music_file_drop.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart';
import 'package:fushi/src/pages/implementations/music/music_cd_detail.dart';
import 'package:fushi/src/utils/components/fushi_header_more_button.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_disc_actions.dart';
import 'package:fushi/src/models/library_grid_columns.dart'
    show LibraryGridDomain;
import 'package:fushi/src/pages/implementations/library_layout/library_chrome_spec.dart';
import 'package:fushi/src/pages/implementations/library_view_options.dart'
    show libraryGridSizeClassOf;
import 'package:fushi/src/pages/implementations/library_layout/library_layout.dart';
import 'package:fushi/src/pages/implementations/music/music_import_view.dart';
import 'package:fushi/src/pages/implementations/music/apple/apple_music_browse_widgets.dart'
    show AppleMusicEntityRow;
import 'package:fushi/src/pages/implementations/music/apple/apple_music_playlists_layout.dart';
import 'package:fushi/src/pages/implementations/music/music_local_playlist_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_local_playlist_page.dart';
import 'package:fushi/src/pages/implementations/music/music_playlist_actions.dart'
    show musicImportPlaylistFile;
import 'package:fushi/src/pages/implementations/music/music_plugin_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart'
    show MusicBarReserve, MusicFloatingBarHost, openMusicPlayerPage;
import 'package:fushi_engine/media/media_extensions.dart'
    show kAudioExtensions, kVideoExtensions;
import 'package:fushi_engine/media/music/server/music_server.dart'
    show MusicServerBrowser;
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_collection_view.dart';
import 'package:fushi/src/pages/implementations/music/music_shortcuts.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_gate.dart';
import 'package:fushi/src/pages/implementations/music/music_sources_page.dart';
import 'package:fushi/src/pages/implementations/music/music_sources_recommend.dart';
import 'package:fushi/src/media/music/music_online_sources.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart'
    show MusicPlaylistTarget, musicCreatePlaylist;
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/pages/implementations/music/music_unified_search.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart'
    show MediaSourcesViewState;
import 'package:fushi/src/pages/implementations/media_library_shell.dart'
    show LibrarySectionGroup, libraryImportChromeButton;
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show
        FushiFloatingChromeBar,
        FushiFloatingChromeController,
        FushiFloatingChromeInset,
        FushiFloatingChromeInsetSpacer,
        FushiFloatingChromeOverlay,
        FushiFloatingChromeScope,
        FushiFloatingChromeScrollInset;
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart'
    show fushiNotificationDrivesPageChrome;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/pages/shared/library_section_tabs.dart';
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

part 'music_library_companion.part.dart';

/// 曲库分区（浏览维度）。格式 / 来源 / 有无逐字歌词是筛选条件，不做成分区（§11.2）。
///
/// [recommend] 是插件音源的推荐页（docs/specs/2026-10-28-music-plugins.md §4 `home`）：只在
/// 装了声明 `home` 能力的插件时出现，没配音源不显示。
///
/// 页签只表示「看什么类型」（用户 2026-10-29 拍板，设计稿
/// `fushi/build/music_design/music_ia.html`）。首页只负责浏览：搜索一律走右上角按钮推入的
/// 二级搜索页（宽窄屏同一套，用户 2026-10-29 拍板），不在页签里就地过滤。
///
/// [discs]（设计稿 #music M1「曲库 tab 增加『光盘』」）：光盘专辑——从光盘添加的
/// （DVD / BD / 音频 CD，带 `discUid`）与目录里有盘面扫描图的 CD 专辑
/// （[MusicDiscArtIndex]）。
///
/// [sources] / [plugins]：「在线」组的「来源」（音源排序与开关 + 歌词来源）与「插件」
/// （安装 / 启停 / 登录），与书 / 漫画 / 视频库「在线」组的「来源」「扩展」同位
/// （拍板台 4GBgF6TrNr：音乐不再从曲库页「⋯」单独推一页来源）。
enum MusicLibrarySection {
  recommend,
  songs,
  albums,
  artists,
  playlists,
  works,
  discs,
  sources,
  plugins,
}

/// 音乐分区所属的一级分组（与书 / 漫画 / 视频 / 游戏库同一分法，见
/// [LibrarySectionGroup]）：推荐 / 来源 / 插件归「在线」；其余是本地曲库。
LibrarySectionGroup musicLibrarySectionGroupOf(MusicLibrarySection s) =>
    switch (s) {
      MusicLibrarySection.recommend ||
      MusicLibrarySection.sources ||
      MusicLibrarySection.plugins => LibrarySectionGroup.online,
      MusicLibrarySection.songs ||
      MusicLibrarySection.albums ||
      MusicLibrarySection.artists ||
      MusicLibrarySection.playlists ||
      MusicLibrarySection.works ||
      MusicLibrarySection.discs => LibrarySectionGroup.library,
    };

/// 「在线」组此刻的成员（按页签序）：推荐只在有带首页的来源时出（[hasRecommend]），
/// 来源恒在（Apple Music / 服务器 / 歌词来源都在这里开），插件只在本机能跑插件时出
/// （[pluginsAvailable]，iOS 合规门下没有）。纯函数。
List<MusicLibrarySection> musicOnlineSections({
  required bool hasRecommend,
  required bool pluginsAvailable,
}) => <MusicLibrarySection>[
  if (hasRecommend) MusicLibrarySection.recommend,
  MusicLibrarySection.sources,
  if (pluginsAvailable) MusicLibrarySection.plugins,
];

/// 在线来源重读后音乐页停在哪个分区。打开音乐页恒落在曲库（与书 / 漫画 / 视频 /
/// 游戏库一致，用户 2026-11-21 拍板）：装了带推荐的插件也不把默认页抢成推荐，推荐
/// 只在用户点「推荐」时进入；推荐来源没了，停在推荐页的回到 [lastLibrary]。纯函数。
MusicLibrarySection musicLibrarySectionAfterSourcesChanged({
  required MusicLibrarySection current,
  required MusicLibrarySection lastLibrary,
  required bool hasRecommend,
}) => !hasRecommend && current == MusicLibrarySection.recommend
    ? lastLibrary
    : current;

String musicLibrarySectionLabel(MusicLibrarySection s) => switch (s) {
  MusicLibrarySection.recommend => t.music_section_recommend,
  MusicLibrarySection.albums => t.music_section_albums,
  MusicLibrarySection.artists => t.music_section_artists,
  MusicLibrarySection.songs => t.music_section_songs,
  MusicLibrarySection.works => t.music_section_works,
  MusicLibrarySection.playlists => t.music_section_playlists,
  MusicLibrarySection.discs => t.music_section_discs,
  MusicLibrarySection.sources => t.library_view_sources,
  MusicLibrarySection.plugins => t.music_view_plugins,
};

/// 音乐分区在 Apple 侧栏子项里的图标。
IconData musicLibrarySectionIcon(MusicLibrarySection s) => switch (s) {
  MusicLibrarySection.recommend => FushiIcons.home,
  MusicLibrarySection.songs => FushiIcons.music,
  MusicLibrarySection.albums => FushiIcons.collections,
  MusicLibrarySection.artists => FushiIcons.person,
  MusicLibrarySection.playlists => FushiIcons.playlist,
  MusicLibrarySection.works => FushiIcons.bookmarks,
  MusicLibrarySection.discs => FushiIcons.mic,
  MusicLibrarySection.sources => FushiIcons.server,
  MusicLibrarySection.plugins => FushiIcons.widgets,
};

/// 生效的来源过滤：指向的插件已不在（被停用 / 卸载）时回到全部来源（`null`）。
String? _musicEffectiveSourceFilter(
  String? filter,
  List<MusicPluginManifest> searchPlugins, [
  List<MusicServerBrowser> searchServers = const <MusicServerBrowser>[],
]) {
  if (filter == null || filter == kMusicSearchLocalSource) return filter;
  return searchPlugins.any((MusicPluginManifest m) => m.id == filter) ||
          searchServers.any((MusicServerBrowser b) => b.serverId == filter)
      ? filter
      : null;
}

/// 按来源过滤后参与搜索的服务器（歌单类型服务器不参与，由结果视图自己判断）。
List<MusicServerBrowser> _musicFilteredServers(
  String? effectiveFilter,
  List<MusicServerBrowser> searchServers,
) {
  if (effectiveFilter == kMusicSearchLocalSource) {
    return const <MusicServerBrowser>[];
  }
  return <MusicServerBrowser>[
    for (final MusicServerBrowser b in searchServers)
      if (effectiveFilter == null || b.serverId == effectiveFilter) b,
  ];
}

/// 按来源过滤后参与搜索的插件；[type] 非空时只留支持该类型的。[effectiveFilter] 取
/// [_musicEffectiveSourceFilter] 的结果。
List<MusicPluginManifest> _musicFilteredSources(
  String? effectiveFilter,
  List<MusicPluginManifest> searchPlugins, [
  MusicPluginSearchType? type,
]) {
  if (effectiveFilter == kMusicSearchLocalSource) {
    return const <MusicPluginManifest>[];
  }
  return <MusicPluginManifest>[
    for (final MusicPluginManifest m in searchPlugins)
      if ((type == null || m.searchTypes.contains(type.wire)) &&
          (effectiveFilter == null || m.id == effectiveFilter))
        m,
  ];
}

/// 来源过滤是否保留本地结果（全部来源 / 只看本地）。
bool _musicSearchIncludesLocal(String? effectiveFilter) =>
    effectiveFilter == null || effectiveFilter == kMusicSearchLocalSource;

/// 本地（含混排服务器专辑）按 [query] 筛出的条目。搜索走统一归一化
/// （[filterByMediaSearch]）：大小写 / 全半角 / 假名同口径。
MusicSearchLocalItems _musicLocalMatches(
  MusicLibrarySnapshot snap,
  List<MusicServerAlbumRef> serverAlbums,
  String query,
) => MusicSearchLocalItems(
  albums: filterByMediaSearch<MusicAlbumRow>(
    snap.albums,
    query,
    (MusicAlbumRow a) => <String>[a.title, ?a.albumArtistCredit],
  ),
  serverAlbums: filterByMediaSearch<MusicServerAlbumRef>(
    serverAlbums,
    query,
    (MusicServerAlbumRef a) => <String>[a.album.title, ?a.album.artist],
  ),
  artists: filterByMediaSearch<MusicArtistRow>(
    snap.artists,
    query,
    (MusicArtistRow a) => <String>[a.name],
  ),
  tracks: filterByMediaSearch<MusicTrackRow>(
    snap.tracks,
    query,
    (MusicTrackRow r) => <String>[r.title, ?r.artistCredit],
  ),
  playlists: filterByMediaSearch<MusicPlaylistRow>(
    snap.playlists,
    query,
    (MusicPlaylistRow p) => <String>[p.name],
  ),
  albumByUid: snap.albumByUid,
);

/// 二级搜索页要的曲库数据：曲库页数据变化（扫描完成 / 插件启停）时推给已打开的搜索页。
typedef _MusicSearchInputs = ({
  MusicLibrarySnapshot snapshot,
  List<MusicServerAlbumRef> serverAlbums,
  List<MusicPluginManifest> searchPlugins,
  List<MusicServerBrowser> searchServers,
});

class MusicLibraryPage extends ConsumerStatefulWidget {
  const MusicLibraryPage({
    super.key,
    this.snapshotLoader,
    this.serverAlbumsLoader,
  });

  /// 测试注入：替代读数据库。
  final Future<MusicLibrarySnapshot> Function()? snapshotLoader;

  /// 测试注入：替代读「混排进曲库」的服务器专辑。
  final Future<List<MusicServerAlbumRef>> Function()? serverAlbumsLoader;

  @override
  ConsumerState<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends ConsumerState<MusicLibraryPage> {
  MusicLibrarySection _section = MusicLibrarySection.albums;

  /// 「我的」组（曲库）上次停留的分区：在推荐页时点组页签回到这里。
  MusicLibrarySection _lastLibrarySection = MusicLibrarySection.albums;

  /// 「在线」组上次停留的分区（推荐 / 来源 / 插件）：在曲库时点组页签回到这里；已下线
  /// （推荐没了）就退回组内第一个（[_onlineGroupValue]）。
  MusicLibrarySection? _lastOnlineSection;

  /// 「在线」组此刻的成员（[musicOnlineSections]）。
  List<MusicLibrarySection> get _onlineSections => musicOnlineSections(
    hasRecommend: _hasRecommend,
    pluginsAvailable: isMusicPluginSourcesAvailable,
  );

  /// 「在线」组页签此刻代表的分区（与库页壳 `_groupValue` 同一规则）。
  MusicLibrarySection _onlineGroupValue(List<MusicLibrarySection> members) {
    if (members.contains(_section)) return _section;
    final MusicLibrarySection? last = _lastOnlineSection;
    return last != null && members.contains(last) ? last : members.first;
  }

  /// 「导入」视图是否打开（IM12：导入钮切视图，不再弹菜单；选中态跟着它）。
  /// 不进 [MusicLibrarySection]：分区是「看什么类型」的页签，导入不是一种类型。
  bool _importOpen = false;

  /// 导入视图来源区的状态句柄（区头「添加来源」/「网络共享」方式块经它调用）。
  final GlobalKey<MediaSourcesViewState> _sourcesKey =
      GlobalKey<MediaSourcesViewState>();

  MusicLibrarySnapshot? _snapshot;

  /// 显式 opt-in 混排进曲库的服务器专辑（服务器曲库 P5）。与本地快照分开取：服务器慢或
  /// 不在线不拖住本地曲库。
  List<MusicServerAlbumRef> _serverAlbums = const <MusicServerAlbumRef>[];
  bool _scanning = false;
  StreamSubscription<Set<TableUpdate>>? _dbSub;
  StreamSubscription<void>? _pluginSub;

  /// 有盘面扫描图的专辑（专辑 uid → 图路径，[MusicDiscArtIndex.albums]）：画成
  /// 「封面 + 唱片」色块、点开走 CD 详情（设计稿 M3）。快照读出后在后台识别。
  Map<String, String> get _discArt => MusicDiscArtIndex.instance.albums.value;

  void _onDiscArtChanged() {
    if (mounted) setState(() {});
  }

  /// 顶栏动作槽：本页把动作登记进来，由 [FushiFloatingChromeBar] 的动作组画出。
  final FushiShellActionsSlot _actionsSlot = FushiShellActionsSlot();

  /// 重设计外壳下页头大字的显隐 / 收缩（滚动驱动，与书架 / 视频 / 游戏库同一个
  /// [FushiFloatingChromeController]）。只有内容会滚到大字底下的分区（推荐页，
  /// [_chromeFloats]）把滚动喂给它；其余分区的列表自己不让位页头，照旧
  /// 排在大字下面、大字不收。
  final FushiFloatingChromeController _chrome = FushiFloatingChromeController();

  /// 本帧的当前分区是否浮在页头大字底下（[_chromeFloats] 的快照，滚动回调里用）。
  bool _floatingNow = false;

  /// 推荐页选中的来源 key（null = 全部）。重设计外壳下来源页签画在页头大字行里，
  /// 选中值由本页持有（[musicRecommendSourceTabs]）。
  String? _recommendSource;

  /// 推荐页「刷新全部来源」的外部入口：Apple macOS 档工具栏的刷新键经它调推荐
  /// 列表的刷新（与 iOS 下拉刷新、⌘R 同一个动作）。
  final MusicRecommendRefreshHandle _recommendRefresh =
      MusicRecommendRefreshHandle();

  /// 当前分区的内容是否滚到页头大字底下（大字随滚动收缩、底板模糊渐入）：重设计
  /// 外壳下的推荐页。只看外壳、不看库页布局——拼贴与封面网格共用同一套页头 / 页签
  /// （来源页签都在大字行里），布局只换卡片（2026-11-12 用户：「这两套布局顶部栏
  /// 和侧边栏和底部栏都应该是公用的」）。推荐页两种卡片版式的滚动视图都按
  /// `MediaQuery` 顶部内边距让位（[musicBrowsePagePadding]），能接住页头的让位；曲库
  /// 各分区的列表顶部只留固定间距（`music_track_list.dart` 等），接不住，保持排在
  /// 大字下面。
  /// 停在「在线 › 来源 / 插件」这两个管理视图：它们自挂 `.fushiplug` 落点，也不带
  /// 「继续收听」卡。
  bool get _inOnlineManageView =>
      !_importOpen &&
      (_section == MusicLibrarySection.sources ||
          _section == MusicLibrarySection.plugins);

  bool _chromeFloats(BuildContext context) =>
      shellRedesignActive(context) &&
      !_importOpen &&
      _section == MusicLibrarySection.recommend;

  bool _onChromeScroll(ScrollNotification notification) {
    if (!_floatingNow) return false;
    // 隐藏的保活分区 / 横滚卡片行发来的通知不算（后者 controller 内按轴过滤）。
    if (!fushiNotificationDrivesPageChrome(notification)) return false;
    return _chrome.handleScrollNotification(notification);
  }

  void _selectRecommendSource(String? key) {
    if (key == _recommendSource) return;
    // 换了来源面板，新面板从顶部开始：页头回来、大字展开。
    _chrome.resetToTop();
    setState(() => _recommendSource = key);
  }

  /// 已启用、校验通过的插件音源（合规门没过的平台恒为空）。
  List<MusicPluginManifest> _pluginSources = const <MusicPluginManifest>[];

  List<MusicPluginManifest> _pluginsWith(MusicPluginCapability cap) =>
      <MusicPluginManifest>[
        for (final MusicPluginManifest m in _pluginSources)
          if (m.can(cap)) m,
      ];

  /// 在线来源（插件音源 + 服务器）按「来源」页的顺序与显示开关。
  List<MusicOrderedSource> _onlineSources = const <MusicOrderedSource>[];

  /// 「推荐」来源 chip 列的来源：显示中、且有首页可看。
  List<MusicOnlineSource> get _recommendSources => <MusicOnlineSource>[
    for (final MusicOnlineSource s in enabledMusicOnlineSources(_onlineSources))
      if (musicSourceHasRecommend(s)) s,
  ];

  bool get _hasRecommend => _recommendSources.isNotEmpty;

  /// 有搜索能力、显示中的插件（来源 chip 列它们），按「来源」页顺序。
  List<MusicPluginManifest> get _searchPlugins => <MusicPluginManifest>[
    for (final MusicOnlineSource s in enabledMusicOnlineSources(_onlineSources))
      if (s is MusicPluginOnlineSource &&
          s.manifest.can(MusicPluginCapability.search))
        s.manifest,
  ];

  /// 显示中的服务器来源（统一搜索里与插件并列）。
  List<MusicServerBrowser> get _searchServers => <MusicServerBrowser>[
    for (final MusicOnlineSource s in enabledMusicOnlineSources(_onlineSources))
      if (s is MusicServerOnlineSource) s.browser,
  ];

  /// 已打开的二级搜索页读这里；曲库数据变化时经 [_publishSearchInputs] 推新值。
  final ValueNotifier<_MusicSearchInputs> _searchInputs =
      ValueNotifier<_MusicSearchInputs>((
        snapshot: MusicLibrarySnapshot.empty,
        serverAlbums: const <MusicServerAlbumRef>[],
        searchPlugins: const <MusicPluginManifest>[],
        searchServers: const <MusicServerBrowser>[],
      ));

  void _publishSearchInputs() {
    _searchInputs.value = (
      snapshot: _snapshot ?? MusicLibrarySnapshot.empty,
      serverAlbums: _serverAlbums,
      searchPlugins: _searchPlugins,
      searchServers: _searchServers,
    );
  }

  /// 右上角搜索按钮：推入二级搜索页（首页只负责浏览，不做就地搜索）。查询词只活在那一页里，返回后曲库页原样。
  Future<void> _openSearchPage() async {
    _publishSearchInputs();
    // 插件可能刚在设置里装上 / 启用：搜索页打开时顺手重读，读完经 notifier 推过去。
    unawaited(_reloadOnlineSources());
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => _MusicLibrarySearchPage(
          inputs: _searchInputs,
          localActions: _localActions,
        ),
      ),
    );
  }

  /// 最近播放的那首（播放事件流最新一条）；null = 没听过 / 测试注入快照。
  /// 最近播放过的曲目，每张专辑（散曲按曲目）只留最近那首、按最近播放排；
  /// 首个是「继续收听」主卡，其余是宽屏时主卡旁的封面行。
  List<MusicTrackRow> _recentTracks = const <MusicTrackRow>[];

  AppModel get _app => ref.read(appProvider);

  /// Dual-screen companion (Library tab, Main mode): see
  /// `music_library_companion.part.dart`.
  late final LibraryCompanionHook _companion = _createMusicCompanion();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Album cards are plain focusable controls (not managed focus targets):
    // follow the primary focus itself.
    _companion.attach(context, focusChanges: FocusManager.instance);
  }

  /// 「色块 / 列表」样式切了：重画分区与页头切换键。
  void _onViewStyleChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    MusicViewStyleStore.instance.addListener(_onViewStyleChanged);
    MusicDiscArtIndex.instance.albums.addListener(_onDiscArtChanged);
    unawaited(_reload());
    unawaited(_reloadServerAlbums());
    unawaited(_reloadOnlineSources());
    // 「在线 › 插件」/ 来源页拖放装上、卸掉、启停的插件：推荐页签与搜索来源跟着变。
    if (widget.snapshotLoader == null &&
        _app.isPreferencesReady &&
        isMusicPluginSourcesUsable) {
      _pluginSub = _app.musicPluginManager.changes.listen(
        (_) => unawaited(_reloadOnlineSources()),
      );
    }
    if (widget.snapshotLoader == null && _app.isDatabaseReady) {
      final FushiDatabase db = _app.database;
      // 表级变更流（不是 drift .watch()：长驻页面订阅 watch 会在 dispose 时挂死测试）。
      _dbSub = db
          .tableUpdates(
            TableUpdateQuery.onAllTables(
              <ResultSetImplementation<Object?, Object?>>[
                db.musicTracks,
                db.musicAlbums,
                db.musicPlaylists,
                db.musicPlaylistEntries,
                db.musicRemoteTracks,
                db.musicDiscSources,
                db.musicPlayEvents,
                // 专辑上锁 / 解除上锁。
                db.mediaLockedFlags,
              ],
            ),
          )
          .listen((_) => unawaited(_reload()));
      // 解锁 / 重新隐藏上锁的作品。
      MediaLockSession.instance.unlocked.addListener(_onLockSessionChanged);
    }
  }

  void _onLockSessionChanged() => unawaited(_reload());

  @override
  void dispose() {
    MusicViewStyleStore.instance.removeListener(_onViewStyleChanged);
    MusicDiscArtIndex.instance.albums.removeListener(_onDiscArtChanged);
    _companion.dispose();
    _recommendRefresh.dispose();
    unawaited(_dbSub?.cancel());
    MediaLockSession.instance.unlocked.removeListener(_onLockSessionChanged);
    unawaited(_pluginSub?.cancel());
    _searchInputs.dispose();
    _actionsSlot.dispose();
    _chrome.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final Future<MusicLibrarySnapshot> Function()? loader =
        widget.snapshotLoader;
    // 上锁（未解锁）的专辑与它的曲目不进曲库页的任何分区（[MediaVisibility]）。
    final MediaVisibility visibility = loader == null && _app.isDatabaseReady
        ? await MediaVisibility.load(_app.database)
        : MediaVisibility.all;
    final MusicLibrarySnapshot snap =
        (loader != null
                ? await loader()
                : (_app.isDatabaseReady
                      ? await MusicLibrarySnapshot.load(_app.database)
                      : MusicLibrarySnapshot.empty))
            .withoutAlbums(visibility.hidesMusicAlbum);
    final List<MusicTrackRow> recent = loader == null && _app.isDatabaseReady
        ? await _app.database.listRecentlyPlayedMusicTracks(limit: 40)
        : const <MusicTrackRow>[];
    if (!mounted) return;
    final Set<String> seen = <String>{};
    setState(() {
      _snapshot = snap;
      _recentTracks = <MusicTrackRow>[
        for (final MusicTrackRow t in recent)
          if (t.albumUid == null || !visibility.hidesMusicAlbum(t.albumUid!))
            if (seen.add(t.albumUid ?? 'track:${t.trackUid}')) t,
      ].take(13).toList();
    });
    _publishSearchInputs();
    unawaited(_resolveDiscArt(snap));
  }

  /// 识别快照里各专辑的盘面扫描图（后台 isolate 列目录，按目录缓存）。
  Future<void> _resolveDiscArt(MusicLibrarySnapshot snap) async {
    final Map<String, List<String>> tracksByAlbum = <String, List<String>>{};
    for (final MusicTrackRow t in snap.tracks) {
      final String? album = t.albumUid;
      if (album == null) continue;
      tracksByAlbum.putIfAbsent(album, () => <String>[]).add(t.path);
    }
    final Map<String, String> resolved = tracksByAlbum.isEmpty
        ? const <String, String>{}
        : await MusicDiscArtIndex.instance.resolve(tracksByAlbum);
    // 标签不一致被拆成两张专辑的同一张 CD（一份带扫图、一份不带）共用盘面图。
    final Map<String, String> found = shareMusicDiscArtAcrossVersions(
      found: resolved,
      albums: <String, ({String title, List<String> trackPaths})>{
        for (final MapEntry<String, List<String>> e in tracksByAlbum.entries)
          if (snap.albumByUid[e.key] case final MusicAlbumRow a)
            e.key: (title: a.title, trackPaths: e.value),
      },
    );
    if (!mounted || !identical(snap, _snapshot)) return;
    MusicDiscArtIndex.instance.publish(found);
  }

  /// 「继续收听」：进播放页接着听。上次那首就是引擎此刻的当前曲（迷你条上那首）时
  /// 不重建队列、不从头重播，暂停着就接着放；否则从它所在专辑、那一首起播（散曲只播
  /// 它自己）。两种情况都进播放页，与专辑页「播放全部」、迷你条点按一致。
  void _continueListening(MusicTrackRow track, MusicLibrarySnapshot snap) {
    final MusicPlayerEngine engine = _app.musicSession.engine;
    if (engine.current?.trackUid == track.trackUid) {
      if (!engine.isPlaying) unawaited(engine.play());
    } else {
      final MusicAlbumRow? album = track.albumUid == null
          ? null
          : snap.albumByUid[track.albumUid];
      final List<MusicTrackRow> tracks = album == null
          ? <MusicTrackRow>[track]
          : snap.tracksOfAlbum(album.albumUid);
      final int start = tracks.indexWhere(
        (MusicTrackRow t) => t.trackUid == track.trackUid,
      );
      unawaited(
        engine.playQueue(
          <MusicPlayItem>[
            for (final MusicTrackRow t in tracks)
              musicPlayItemOf(t, album: album),
          ],
          startIndex: start < 0 ? 0 : start,
          context: album == null
              ? MusicQueueContext.mixed
              : MusicQueueContext.album,
        ),
      );
    }
    openMusicPlayerPage(context);
  }

  /// 曲库顶部「继续收听」区：所有库页共用的「继续」组件
  /// [FushiContinueSpotlight]（2026-10-31 方案 A + 合一）。主卡是上次那首（专辑
  /// 封面 + 专辑名 + 曲名 · 艺人）；宽屏时最近听过的其余专辑排在旁边。点按 =
  /// 续播并进播放页，长按 / 右键 = 打开专辑（卡上不放按钮）。
  Widget? _buildContinueHero(MusicLibrarySnapshot snap) {
    if (_recentTracks.isEmpty) return null;
    MusicAlbumRow? albumOf(MusicTrackRow track) =>
        track.albumUid == null ? null : snap.albumByUid[track.albumUid];
    Widget coverOf(MusicTrackRow track) {
      final MusicAlbumRow? album = albumOf(track);
      return MusicCover(
        coverPath: album?.coverPath,
        embeddedFromPath: album == null
            ? track.path
            : snap.embeddedCoverPathOf(album),
      );
    }

    String? artistOf(MusicTrackRow track) =>
        track.artistCredit ?? albumOf(track)?.albumArtistCredit;

    // 封面色块版式（[FushiContinueSpotlight] 在重设计外壳 + 拼贴 / 规整色块下）：
    // 与专辑墙色块同一张直角封面、同一个取色图源（目录 / 缓存封面文件；只有内嵌
    // 封面的专辑取不到，退回中性底色）。
    Widget blockCoverOf(MusicTrackRow track) {
      final MusicAlbumRow? album = albumOf(track);
      return MusicCover(
        coverPath: album?.coverPath,
        embeddedFromPath: album == null
            ? track.path
            : snap.embeddedCoverPathOf(album),
        borderRadius: BorderRadius.zero,
      );
    }

    ImageProvider? tintOf(MusicTrackRow track) =>
        musicCoverImageProvider(albumOf(track)?.coverPath, size: 128);

    // 有盘面扫描图的专辑在色块版式下画成「封面 + 唱片」（W 原型）；没有就不画。
    Widget? discOf(MusicTrackRow track) {
      final String? path = _discArt[track.albumUid];
      return path == null ? null : musicDiscArtImage(path);
    }

    final MusicTrackRow track = _recentTracks.first;
    final MusicAlbumRow? album = albumOf(track);
    return FushiContinueSpotlight(
      sideRowKey: const ValueKey<String>('music-continue-side-row'),
      blockLabel: t.music_continue_listening,
      main: FushiContinueEntry(
        key: const ValueKey<String>('music-continue-hero'),
        focusId: const FushiFocusId('music-continue-hero'),
        cover: coverOf(track),
        blockCover: blockCoverOf(track),
        blockDisc: discOf(track),
        colorSource: tintOf(track),
        coverAspectRatio: 1,
        eyebrow: t.music_continue_listening,
        title: album?.title ?? track.title,
        metaLines: <String>[
          <String>[
            if (album != null) track.title,
            if (artistOf(track) case final String artist) artist,
          ].join(' · '),
        ],
        onOpen: () => _continueListening(track, snap),
        onLongPress: album == null ? null : () => _openAlbum(album),
      ),
      side: <FushiContinueEntry>[
        for (final MusicTrackRow t in _recentTracks.skip(1))
          if (albumOf(t) case final MusicAlbumRow? a)
            FushiContinueEntry(
              key: ValueKey<String>('music-continue-side/${t.trackUid}'),
              material: ShelfCoverMaterial.glossyAlbum,
              cover: coverOf(t),
              blockCover: blockCoverOf(t),
              blockDisc: discOf(t),
              colorSource: tintOf(t),
              coverAspectRatio: 1,
              title: a?.title ?? t.title,
              subtitle: artistOf(t),
              onOpen: () => _continueListening(t, snap),
              onLongPress: a == null ? null : () => _openAlbum(a),
            ),
      ],
    );
  }

  Future<void> _reloadServerAlbums() async {
    final Future<List<MusicServerAlbumRef>> Function()? loader =
        widget.serverAlbumsLoader;
    final List<MusicServerAlbumRef> albums = loader != null
        ? await loader()
        : (_app.isDatabaseReady
              ? await loadMixedServerAlbums(_app)
              : const <MusicServerAlbumRef>[]);
    if (!mounted) return;
    setState(() => _serverAlbums = albums);
    _publishSearchInputs();
  }

  /// 「在线 › 来源」里音源的顺序 / 开关 / 启用 / 服务器变了：重读推荐与搜索用的来源，
  /// 以及混排进曲库的服务器专辑。
  ///
  /// 来源视图在写完偏好后才回调：那时用户可能已经切走（来源视图已 dispose），本页
  /// 也可能已关掉，所以先判 mounted（之后的重读要经 ref 取 AppModel）。
  void _onOnlineSourcesChanged() {
    if (!mounted) return;
    unawaited(_reloadOnlineSources());
    unawaited(_reloadServerAlbums());
  }

  /// 「⋯ › 已移除的曲目」：从音乐库移除过的本地曲目（墓碑，拍板台 IDeN5PYaI7）在这里
  /// 恢复。它管的是本地曲库，跟着重扫一起放在曲库页的「⋯」里。
  Future<void> _openHiddenTracks() => Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => const MusicHiddenTracksPage(),
    ),
  );

  Future<void> _addFolder() async {
    final String? path = await pickRealDirectoryPath(
      context: context,
      appModel: _app,
      dialogTitle: t.music_folder_add,
    );
    if (path == null || !mounted) return;
    setState(() => _scanning = true);
    try {
      final AddLocalFolderResult result = await addLocalFolderAsSource(
        db: _app.database,
        // 音乐来源不扫书，没有有声书要转录。
        transcribeAudiobook: null,
        mediaKind: SourceLibraryKind.music.dbValue,
        path: path,
      );
      if (result.outcome == AddLocalFolderOutcome.duplicate) {
        FushiToast.show(msg: t.music_folder_duplicate);
      } else {
        await _reportScan();
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    MusicDiscArtIndex.instance.invalidate();
    await _reload();
  }

  /// 「从本地添加 › 音频文件…」：指名的几个音频 / MV 交给音乐库（已被音乐来源覆盖的
  /// 重扫那个来源，其余「仅此一次」导入）。收的格式与音乐来源扫描一致：纯音频 + 视频
  /// 容器（MV，拍板台 left3568）。
  Future<void> _addAudioFiles() async {
    final List<String> paths = await pickRealFilePaths(
      context: context,
      appModel: _app,
      allowedExtensions: <String>{
        for (final String ext in kAudioExtensions) ext.substring(1),
        for (final String ext in kVideoExtensions) ext.substring(1),
      },
    );
    if (paths.isEmpty || !mounted) return;
    setState(() => _scanning = true);
    try {
      await _importMusicFiles(paths);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    MusicDiscArtIndex.instance.invalidate();
    await _reload();
  }

  /// 曲目文件交给音乐库并报结果（选文件与拖放共用）。
  Future<void> _importMusicFiles(List<String> paths) async {
    final MusicAudioIntakeResult result = await MusicAudioIntake(
      _app.database,
    ).importMusicFiles(paths);
    if (result.errors.isNotEmpty) {
      FushiToast.show(
        msg: t.music_scan_failed(error: result.errors.first),
        severity: ToastSeverity.warning,
      );
    } else {
      await _reportScan();
    }
  }

  /// 拖进音乐页（曲库各分区与导入视图同一个处理，拍板台 left3568）：目录登记成音乐来源
  /// 并扫描，曲目文件（纯音频 + MV 视频容器）导入曲库，其余给「本页收什么」的提示
  /// （[planMusicDrop]）。扫描进行中不再叠一轮。
  Future<void> _handleMusicDrop(List<String> paths, Offset _) async {
    if (_scanning) {
      FushiToast.show(msg: t.music_drop_busy, severity: ToastSeverity.info);
      return;
    }
    final MusicDropPlan plan = planMusicDrop(
      paths,
      isDirectory: FileSystemEntity.isDirectorySync,
    );
    if (!plan.hasAny) {
      FushiToast.show(
        msg: t.drag_drop_unsupported_on_music,
        severity: ToastSeverity.info,
      );
      return;
    }
    setState(() => _scanning = true);
    try {
      bool scannedFolder = false;
      for (final String folder in plan.folders) {
        final AddLocalFolderResult result = await addLocalFolderAsSource(
          db: _app.database,
          // 音乐来源不扫书，没有有声书要转录。
          transcribeAudiobook: null,
          mediaKind: SourceLibraryKind.music.dbValue,
          path: folder,
        );
        if (result.outcome == AddLocalFolderOutcome.duplicate) {
          FushiToast.show(msg: t.music_folder_duplicate);
        } else {
          scannedFolder = true;
        }
      }
      if (plan.files.isNotEmpty) {
        await _importMusicFiles(plan.files);
      } else if (scannedFolder) {
        await _reportScan();
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    MusicDiscArtIndex.instance.invalidate();
    await _sourcesKey.currentState?.reload();
    await _reload();
  }

  /// 「光盘 › 光盘镜像…」：选 `.iso` 文件登记成光盘专辑。
  Future<void> _addDiscImages() async {
    setState(() => _scanning = true);
    try {
      await pickAndAddMusicDiscImages(context: context, app: _app);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    await _reload();
  }

  /// 顶栏动作：搜索 · 视图平铺，来源与重扫在本页自己的「⋯」里；整组放不下时
  /// 再由 [FushiShellHeaderActions] 从尾部往前收。
  void _claimHeaderActions() {
    final bool idle = !_scanning;
    // 当前分区的「色块 / 列表」切换键（推荐 / 作品 / 墨水屏没有）。
    final (MusicViewKind, MusicViewStyle)? view =
        !_importOpen && musicViewStyleSwitchable(context)
        ? _libraryViewKind(_section)
        : null;
    _actionsSlot.claim(
      this,
      visible: true,
      actions: FushiShellHeaderActions(
        actions: <Widget>[
          // Apple macOS 档（方案 A 拍板 Q7）：推荐页的刷新在工具栏（iOS 是下拉
          // 刷新，M3E 在各来源段头）。刷新中 / 没有插件推荐列表（单个服务器来源）
          // 时禁用。
          if (!_importOpen &&
              _section == MusicLibrarySection.recommend &&
              isGlassDesign(context) &&
              fushiAppleUsesMacMetrics(context))
            ListenableBuilder(
              listenable: _recommendRefresh,
              builder: (BuildContext context, Widget? _) => FushiIconButton(
                key: const ValueKey<String>('music-recommend-refresh'),
                icon: FushiIcons.refresh,
                tooltip: t.music_plugin_home_refresh,
                onTap:
                    _recommendRefresh.available && !_recommendRefresh.refreshing
                    ? () => unawaited(_recommendRefresh.refresh())
                    : null,
              ),
            ),
          FushiIconButton(
            key: const ValueKey<String>('music_open_search'),
            icon: FushiIcons.search,
            tooltip: t.music_library_search_hint,
            onTap: () => unawaited(_openSearchPage()),
          ),
          if (view != null)
            musicViewStyleToggleButton(
              view.$1,
              _libraryStyle(context, _section),
            ),
          // 低频的本地曲库维护（重扫 / 已移除的曲目）收进「⋯」（设计稿 M1：顶栏只
          // 平铺 搜索 · 视图 · 添加；「添加」是工具栏右端的导入钮）。来源与插件不在
          // 这里：它们是「在线」组的页签，与书 / 漫画 / 视频库同位（拍板台
          // 4GBgF6TrNr）。
          FushiHeaderMoreButton(
            buttonKey: const ValueKey<String>('music-library-more'),
            entries: <FushiHeaderMoreEntry>[
              FushiHeaderMoreEntry(
                key: const ValueKey<String>('music_hidden_tracks'),
                icon: FushiIcons.visibilityOff,
                label: t.music_hidden_tracks_title,
                onSelected: _openHiddenTracks,
              ),
              FushiHeaderMoreEntry(
                key: const ValueKey<String>('music_rescan'),
                icon: FushiIcons.refresh,
                label: t.music_library_rescan,
                enabled: idle,
                onSelected: _rescan,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 导入钮（IM12）：与书 / 漫画 / 视频 / 游戏同一个导入钮，切到「导入」视图
  /// （[MusicImportView]），再点一次回到进来前的分区。原菜单里的动作（音乐文件夹 /
  /// 音频文件 / 光盘文件夹 / 光盘镜像 / 音频 CD）全部成了视图里的方式块。
  void _toggleImport() => setState(() {
    _chrome.resetToTop();
    _importOpen = !_importOpen;
  });

  /// 空曲库「去导入」（IM20：与书 / 视频 / 游戏同一个 CTA）。
  void _openImport() {
    if (_importOpen) return;
    _toggleImport();
  }

  /// 来源区一次扫描收尾：盘面图可能随新目录进来，失效后重读曲库。
  void _onSourcesChanged() {
    MusicDiscArtIndex.instance.invalidate();
    unawaited(_reload());
  }

  /// 「导入」视图：方式块动作就是原导入菜单那批函数（扫描中标记 / 重读都在这里）。
  Widget _buildImportView() => MusicImportView(
    key: const ValueKey<String>('music-import-view'),
    sourcesKey: _sourcesKey,
    onAddFolder: _addFolder,
    onAddAudioFiles: _addAudioFiles,
    onAddDiscFolder: _addDisc,
    onAddDiscImages: _addDiscImages,
    onReadCd: _readCd,
    audioCdSupported: musicAudioCdSupported(),
    onLibraryChanged: _onSourcesChanged,
    onDrop: _handleMusicDrop,
    busy: _scanning,
  );

  void _selectSection(MusicLibrarySection v) => setState(() {
    // 换了分区，新页面从顶部开始：页头回来、大字展开。
    if (v != _section || _importOpen) _chrome.resetToTop();
    // 点任一分区页签都离开导入视图。
    _importOpen = false;
    _section = v;
    switch (musicLibrarySectionGroupOf(v)) {
      case LibrarySectionGroup.library:
        _lastLibrarySection = v;
      case LibrarySectionGroup.online:
        _lastOnlineSection = v;
    }
  });

  /// 「在线 › 来源」里「添加来源 › 音源插件」：就地切到「在线 › 插件」（与其它库页
  /// 「来源」去「扩展」同一做法）。
  void _selectPlugins() => _selectSection(MusicLibrarySection.plugins);

  /// 顶栏行（页签 + 动作组 + 导入钮）；[secondary] 只在页头大字顶栏里给。
  Widget _buildChromeBar({Widget? secondary}) => FushiFloatingChromeBar(
    tabs: _buildTopTabs(),
    slot: _actionsSlot,
    secondary: secondary,
    trailing: libraryImportChromeButton(
      selected: _importOpen,
      onTap: _toggleImport,
      focusIdPrefix: 'music-library-view',
    ),
  );

  /// 一级「曲库 / 在线」两组（与书 / 漫画 / 视频 / 游戏库壳同一分法）：在线组只有一个
  /// 成员时以它命名，否则叫「在线」（[LibrarySectionGroup.online]）。
  Widget _buildTopTabs() {
    final bool inLibrary =
        musicLibrarySectionGroupOf(_section) == LibrarySectionGroup.library;
    final MusicLibrarySection libraryValue = inLibrary
        ? _section
        : _lastLibrarySection;
    final List<MusicLibrarySection> online = _onlineSections;
    return LibrarySectionTabs<MusicLibrarySection>(
      tabs: <LibrarySectionTab<MusicLibrarySection>>[
        LibrarySectionTab<MusicLibrarySection>(
          value: libraryValue,
          label: t.music_library_tab,
          orderId: LibrarySectionGroup.library.name,
        ),
        LibrarySectionTab<MusicLibrarySection>(
          value: _onlineGroupValue(online),
          label: online.length == 1
              ? musicLibrarySectionLabel(online.single)
              : t.library_view_online,
          labelKey: const ValueKey<String>('music-library-online-tab'),
          orderId: LibrarySectionGroup.online.name,
        ),
      ],
      // 停在导入视图时高亮「曲库」组：导入管理的就是本地曲库。此时高亮只是视觉锚点、
      // 不是当前视图，点它照常切回曲库（与库页壳同一规则，BUG-4706）。
      selected: _importOpen ? libraryValue : _section,
      selectedIsCurrent: !_importOpen,
      onChanged: _selectSection,
      focusIdPrefix: 'music-library-view',
      floating: true,
    );
  }

  /// 当前组的二级胶囊（曲库：歌曲 / 专辑 / 艺人 / 歌单 / 作品；在线：推荐 / 来源 /
  /// 插件）；组内只有一个分区或在导入视图时为空。
  Widget _buildSubTabs(FushiDesignTokens tokens) {
    final Widget? tabs = _buildSubTabsBody();
    if (tabs == null) return const SizedBox.shrink();
    return Padding(
      // 与顶栏胶囊、页面内容同一条页边；二级下划线页签贴着顶栏（与书架 / 视频 /
      // 游戏库同一间距）。
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: Align(alignment: AlignmentDirectional.centerStart, child: tabs),
    );
  }

  /// 当前组的二级页签本体（不带页边 / 对齐）；组内只有一个分区或在导入视图时为
  /// null。页头大字顶栏里交给大字行（[FushiFloatingChromeBar.secondary]）。
  Widget? _buildSubTabsBody() {
    // 导入视图不属于任何分区：不画二级页签。
    if (_importOpen) return null;
    if (musicLibrarySectionGroupOf(_section) == LibrarySectionGroup.online) {
      final List<MusicLibrarySection> online = _onlineSections;
      if (online.length < 2) return null;
      return LibrarySectionTabs<MusicLibrarySection>(
        // 换组即换一份页签（段数与段值都变），不复用旧 controller。
        key: const ValueKey<String>('music-library-online-subtabs'),
        tabs: <LibrarySectionTab<MusicLibrarySection>>[
          for (final MusicLibrarySection s in online)
            LibrarySectionTab<MusicLibrarySection>(
              value: s,
              label: musicLibrarySectionLabel(s),
              labelKey: ValueKey<String>('music-online-tab-${s.name}'),
            ),
        ],
        selected: _section,
        onChanged: _selectSection,
        focusIdPrefix: 'music-library-online',
        secondary: true,
        // 与库页壳一样，各组的二级页签各自记顺序（反馈 ndQ5eXLcqp）。
        orderKey: 'music-library-online',
      );
    }
    return LibrarySectionTabs<MusicLibrarySection>(
      key: const ValueKey<String>('music-library-library-subtabs'),
      tabs: <LibrarySectionTab<MusicLibrarySection>>[
        for (final MusicLibrarySection s in MusicLibrarySection.values)
          if (musicLibrarySectionGroupOf(s) == LibrarySectionGroup.library)
            LibrarySectionTab<MusicLibrarySection>(
              value: s,
              label: musicLibrarySectionLabel(s),
            ),
      ],
      selected: _section,
      onChanged: _selectSection,
      focusIdPrefix: 'music-library-subview',
      secondary: true,
      // 二级用 M3 secondary tabs（文字 + 横贯下划线），不再是第二枚浮动胶囊：
      // 与一级按钮组胶囊拉开层级（2026-10-30 用户拍板方案 B）。
      // 反馈 ndQ5eXLcqp：长按 / 右键页签栏自定义曲库分区顺序。
      orderKey: 'music-library',
    );
  }

  Future<void> _rescan() async {
    setState(() => _scanning = true);
    try {
      final SourceLibraryScanner scanner = SourceLibraryScanner(
        _app.database,
        transcribeAudiobook: null,
      );
      String? error;
      for (final MediaSourceRow source
          in await _app.database.getMediaSourcesByKind(
            SourceLibraryKind.music.dbValue,
          )) {
        final SourceScanSummary summary = await scanner.scan(source);
        error ??= summary.error;
      }
      if (error != null) {
        FushiToast.show(msg: t.music_scan_failed(error: error));
      } else {
        await _reportScan();
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    // 重扫后重新识别盘面图（用户可能刚把扫图放进专辑目录）。
    MusicDiscArtIndex.instance.invalidate();
    await _reload();
  }

  Future<void> _addDisc() async {
    setState(() => _scanning = true);
    try {
      await pickAndAddMusicDiscs(context: context, app: _app);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    await _reload();
  }

  Future<void> _readCd() async {
    setState(() => _scanning = true);
    try {
      await readAudioCdIntoLibrary(context: context, app: _app);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    await _reload();
  }

  Future<void> _reportScan() async {
    final int count = (await _app.database.listMusicTracks()).length;
    FushiToast.show(msg: t.music_scan_done(count: count));
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) =>
      handleMusicShortcutKey(
        event,
        registry: _app.shortcutRegistry,
        engine: _app.musicSession.engine,
        // 曲库：裸方向键留给网格焦点移动（播放页才有裸 ←/→ ±5 秒）。
        surface: MusicShortcutSurface.library,
      );

  /// 打开专辑：有盘面扫描图的 CD 专辑从被点的色块原位（[origin]，全局矩形）放大成
  /// CD 详情（设计稿 M3），其余进专辑页。
  void _openAlbum(MusicAlbumRow album, [Rect? origin]) {
    final MusicLibrarySnapshot snap = _snapshot ?? MusicLibrarySnapshot.empty;
    final String? discArt = _discArt[album.albumUid];
    if (discArt != null) {
      unawaited(
        showMusicCdDetail(
          context: context,
          album: album,
          tracks: snap.tracksOfAlbum(album.albumUid),
          embeddedCoverPath: snap.embeddedCoverPathOf(album),
          discArtPath: discArt,
          origin: origin,
          onOpenAlbumPage: () => _openAlbumPage(album),
        ),
      );
      return;
    }
    _openAlbumPage(album);
  }

  /// 完整专辑页（CD 详情右上角「专辑详情」也进这里）。
  void _openAlbumPage(MusicAlbumRow album) {
    final MusicLibrarySnapshot snap = _snapshot ?? MusicLibrarySnapshot.empty;
    unawaited(
      Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => MusicAlbumPage(
            album: album,
            tracks: snap.tracksOfAlbum(album.albumUid),
            embeddedCoverPath: snap.embeddedCoverPathOf(album),
            disc: snap.discOf(album),
          ),
        ),
      ),
    );
  }

  Future<void> _openArtist(MusicArtistRow artist) async {
    final List<MusicTrackRow> tracks = await _app.database
        .listMusicTracksByArtist(artist.artistUid);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => MusicTrackListPage(
          title: artist.name,
          tracks: tracks,
          albums: (_snapshot ?? MusicLibrarySnapshot.empty).albumByUid,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicLibrarySnapshot? snap = _snapshot;
    // 首页的悬浮条宿主不给各 tab 加底部留白（会截短别的 tab 的列表），音乐页自己让位。
    _claimHeaderActions();
    final bool redesign = shellRedesignActive(context);
    final bool floats = _chromeFloats(context);
    _floatingNow = floats;
    // 「继续收听」属于曲库与推荐：「在线 › 来源 / 插件」是管理页，不在其上方钉播放卡。
    final Widget? hero = snap == null || _importOpen || _inOnlineManageView
        ? null
        : _buildContinueHero(snap);
    final Widget sections = _importOpen
        ? _buildImportView()
        : _buildSectionsNavigator(
            context,
            snap,
            // 内容浮在页头大字底下时「继续收听」跟着推荐列表一起滚（交给推荐页当首块），
            // 不再钉在列表上方。
            recommendLeading: floats && hero != null
                ? Padding(
                    padding: EdgeInsets.only(bottom: tokens.spacing.gap * 1.5),
                    child: hero,
                  )
                : null,
          );
    // 整页落点（拍板台 left3568）：导入视图自己带落点与虚线框（同一个处理），开着时
    // 外层这层让位，免得一次拖放被两层各处理一遍。
    return FushiFileDropTarget(
      debugLabel: 'music-library',
      // 「在线 › 来源 / 插件」自己挂 .fushiplug 落点（BUG-4712），同理让位。
      enabled: !_importOpen && !_inOnlineManageView,
      onDrop: _handleMusicDrop,
      child: MusicBarReserve(
        child: Focus(
          canRequestFocus: false,
          onKeyEvent: _handleKey,
          // 顶栏与书架 / 漫画 / 视频 / 游戏库页同一套 M3E 浮动工具栏行
          // （[FushiFloatingChromeBar]，用户 2026-10-30「音乐的顶栏和其他的不太
          // 一样」）：宽窗下页面名胶囊（外壳经 [FushiShellInlineTitle] 交给本行画）
          // + 分区页签胶囊 + 右侧动作组同一行；动作登记进本页自己的 [_actionsSlot]，
          // 放不下按优先级收进「⋯」。
          child: FushiShellTitleScope(
            title: FushiShellTitleScope.maybeTitleOf(context) ?? '',
            actionsSlot: _actionsSlot,
            child: SafeArea(
              bottom: false,
              child: redesign
                  ? _buildMastheadPage(
                      tokens: tokens,
                      hero: floats ? null : hero,
                      sections: sections,
                      floats: floats,
                    )
                  : _buildClassicPage(
                      tokens: tokens,
                      hero: hero,
                      sections: sections,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// 重设计外壳：页头大字叠在内容上（[FushiFloatingChromeOverlay]，与书架 / 视频 /
  /// 游戏库同一套），滚动驱动大字收缩与 90% 底色模糊底板。二级页签交给大字行：曲库
  /// 组是歌曲 / 专辑 / 艺人 / 歌单 / 作品，推荐页是来源页签
  /// （[musicRecommendSourceTabs]）。
  ///
  /// 只有 [floats] 的分区（[_chromeFloats]）把内容铺到大字底下、把滚动喂给
  /// [_chrome]；其余分区整体排在大字下面（顶部让出 `MediaQuery` 里的让位 + 一档
  /// 间距，与改前的固定页头同一版面），滚动与版面通知都不往上报，大字不收。
  Widget _buildMastheadPage({
    required FushiDesignTokens tokens,
    required Widget? hero,
    required Widget sections,
    required bool floats,
  }) {
    // 推荐页内容浮在大字底下时，分区行下面再跟一行推荐的来源页签（三级，只属于
    // 推荐页）。
    final Widget? recommendTabs = floats
        ? musicRecommendSourceTabs(
            sources: _recommendSources,
            selected: _recommendSource,
            onSelect: _selectRecommendSource,
          )
        : null;
    final Widget body = NotificationListener<ScrollMetricsNotification>(
      // 不浮的分区：它的列表不是页头的主滚动区，版面通知（列表长度变了）不能
      // 拿去改大字的收缩进度。
      onNotification: (ScrollMetricsNotification _) => !_floatingNow,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onChromeScroll,
        // 页头让位并进 `MediaQuery` 顶部内边距：推荐页的滚动视图
        // （[musicBrowsePagePadding]）据此从大字下方起排、往下滚时滚到大字
        // 底下。树形恒定（只换内边距），切分区不重挂分区导航。
        child: FushiFloatingChromeScrollInset(
          child: Builder(
            builder: (BuildContext context) {
              final double top = MediaQuery.paddingOf(context).top;
              return Stack(
                children: <Widget>[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: EdgeInsets.only(
                          top: floats ? 0 : top + tokens.spacing.gap,
                        ),
                        child: hero == null
                            ? const SizedBox(width: double.infinity)
                            : Padding(
                                padding: EdgeInsets.fromLTRB(
                                  tokens.spacing.page,
                                  0,
                                  tokens.spacing.page,
                                  tokens.spacing.gap * 1.5,
                                ),
                                child: hero,
                              ),
                      ),
                      Expanded(
                        child: MediaQuery.removePadding(
                          context: context,
                          removeTop: !floats,
                          child: sections,
                        ),
                      ),
                    ],
                  ),
                  if (_scanning)
                    Positioned(
                      top: top,
                      left: 0,
                      right: 0,
                      child: const FushiLinearProgressIndicator(),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
    return LibraryLayout<MusicLibrarySection>(
      spec: _chromeSpec(accessory: recommendTabs),
      body: body,
      // M3E：音乐自己的页头大字（二级页签与推荐来源页签同排进大字行，不叠嵌套
      // 工具区），与改前逐像素相同。
      materialBuilder: (BuildContext context) {
        final Widget? groupTabs = _buildSubTabsBody();
        final Widget? secondary = groupTabs != null && recommendTabs != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: tokens.spacing.gap / 2,
                children: <Widget>[groupTabs, recommendTabs],
              )
            : groupTabs ?? recommendTabs;
        return FushiFloatingChromeScope(
          controller: _chrome,
          child: FushiFloatingChromeOverlay(
            masthead: true,
            chrome: _buildChromeBar(secondary: secondary),
            child: body,
          ),
        );
      },
    );
  }

  /// 库页外壳要画什么（Apple 外壳由它画；M3E 走上面的 materialBuilder）。与
  /// [_buildTopTabs] / [_buildSubTabsBody] 同一份分组、同一组焦点 id 与顺序键。
  LibraryChromeSpec<MusicLibrarySection> _chromeSpec({Widget? accessory}) {
    final bool inLibrary =
        musicLibrarySectionGroupOf(_section) == LibrarySectionGroup.library;
    final MusicLibrarySection libraryValue = inLibrary
        ? _section
        : _lastLibrarySection;
    final List<MusicLibrarySection> online = _onlineSections;
    return LibraryChromeSpec<MusicLibrarySection>(
      title: FushiShellTitleScope.maybeTitleOf(context) ?? '',
      groups: <LibraryChromeGroup<MusicLibrarySection>>[
        LibraryChromeGroup<MusicLibrarySection>(
          group: LibrarySectionGroup.library,
          label: t.music_library_tab,
          value: libraryValue,
          members: <LibrarySectionTab<MusicLibrarySection>>[
            for (final MusicLibrarySection s in MusicLibrarySection.values)
              if (musicLibrarySectionGroupOf(s) == LibrarySectionGroup.library)
                LibrarySectionTab<MusicLibrarySection>(
                  value: s,
                  label: musicLibrarySectionLabel(s),
                ),
          ],
          subFocusIdPrefix: 'music-library-subview',
          orderKey: 'music-library',
        ),
        LibraryChromeGroup<MusicLibrarySection>(
          group: LibrarySectionGroup.online,
          label: online.length == 1
              ? musicLibrarySectionLabel(online.single)
              : t.library_view_online,
          value: _onlineGroupValue(online),
          members: <LibrarySectionTab<MusicLibrarySection>>[
            for (final MusicLibrarySection s in online)
              LibrarySectionTab<MusicLibrarySection>(
                value: s,
                label: musicLibrarySectionLabel(s),
              ),
          ],
          subFocusIdPrefix: 'music-library-online',
          orderKey: 'music-library-online',
        ),
      ],
      // 停在导入视图时高亮「曲库」组（视觉锚点，BUG-4706）。
      selected: _importOpen ? libraryValue : _section,
      currentGroup: _importOpen ? null : musicLibrarySectionGroupOf(_section),
      selectedIsCurrent: !_importOpen,
      onSelect: _selectSection,
      focusIdPrefix: 'music-library-view',
      actionsSlot: _actionsSlot,
      chrome: _chrome,
      import: LibraryChromeImport(
        selected: _importOpen,
        onTap: _toggleImport,
        focusIdPrefix: 'music-library-view',
      ),
      iconOf: musicLibrarySectionIcon,
      accessory: accessory,
    );
  }

  /// 原外壳（墨水屏）：固定页头 + 曲库二级页签，下面是分区内容。
  Widget _buildClassicPage({
    required FushiDesignTokens tokens,
    required Widget? hero,
    required Widget sections,
  }) {
    // 外壳给库页留的顶部呼吸（[FushiFloatingChromeInset]）由页头上方的
    // 定高空白吃掉：本页工具栏是固定页头、不随滚动收起，下面各分区自己滚。
    // 子树 inset 归零，分区的滚动视图不再重复让位。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const FushiFloatingChromeInsetSpacer(),
        Expanded(
          child: FushiFloatingChromeInset(
            top: 0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 一级只放「曲库 / 推荐」两组（2026-10-30 用户拍板方案 D，
                // 与书 / 漫画 / 视频 / 游戏库同一分法）；入库动作收在右端的
                // 导入视图里（IM12）。
                _buildChromeBar(),
                _buildSubTabs(tokens),
                SizedBox(height: tokens.spacing.gap),
                if (hero != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      tokens.spacing.page,
                      0,
                      tokens.spacing.page,
                      tokens.spacing.gap * 1.5,
                    ),
                    child: hero,
                  ),
                if (_scanning) const FushiLinearProgressIndicator(),
                Expanded(child: sections),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 分区内容：触屏横滑切相邻分区，序即两级页签的视觉序（曲库各分区 → 推荐 → 来源
  /// → 插件），跨组照样接着滑；首 / 末再往外交给首页外壳切模块（与书架 / 视频 / 游戏库
  /// 同一层 [SectionSwipeNavigator]）。
  Widget _buildSectionsNavigator(
    BuildContext context,
    MusicLibrarySnapshot? snap, {
    Widget? recommendLeading,
  }) => SectionSwipeNavigator<MusicLibrarySection>(
    sections: <MusicLibrarySection>[
      for (final MusicLibrarySection s in MusicLibrarySection.values)
        if (musicLibrarySectionGroupOf(s) == LibrarySectionGroup.library) s,
      ..._onlineSections,
    ],
    selected: _section,
    onSelect: _selectSection,
    child: snap == null
        ? const FushiLoadingView()
        : AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            // 每个分区一份自己的主滚动控制器：切区淡出期间新旧两个主滚动视图同时在
            // 树上（tab 被藏起时 ticker 静音、旧子树一直不移除），共用外壳那一个会让
            // Scrollbar 断言「attached to more than one ScrollPosition」。与视频库
            // 外壳的保活分区同一套做法。
            child: KeyedSubtree(
              key: ValueKey<MusicLibrarySection>(_section),
              child: SectionPrimaryScrollScope(
                child: _buildSection(
                  context,
                  snap,
                  recommendLeading: recommendLeading,
                ),
              ),
            ),
          ),
  );

  Future<void> _reloadOnlineSources() async {
    if (widget.snapshotLoader != null || !_app.isPreferencesReady) return;
    final List<MusicOrderedSource> ordered =
        await loadOrderedMusicOnlineSources(_app);
    if (!mounted) return;
    setState(() {
      _onlineSources = ordered;
      // 账号歌单等不受「来源」页显示开关影响：列全部插件音源。
      _pluginSources = <MusicPluginManifest>[
        for (final MusicOrderedSource o in ordered)
          if (o.source case final MusicPluginOnlineSource p) p.manifest,
      ];
      _section = musicLibrarySectionAfterSourcesChanged(
        current: _section,
        lastLibrary: _lastLibrarySection,
        hasRecommend: _hasRecommend,
      );
    });
    _publishSearchInputs();
  }

  /// 统一搜索里本地条目的卡片与跳转（本地专辑卡带光盘菜单 / 格式徽章，复用曲库网格的）。
  MusicSearchLocalActions _localActions(MusicLibrarySnapshot snap) =>
      MusicSearchLocalActions(
        albumCard: (BuildContext context, MusicAlbumRow album) => _AlbumCard(
          key: ValueKey<String>('music-album-${album.albumUid}'),
          album: album,
          tracks: snap.tracksOfAlbum(album.albumUid),
          embeddedCoverPath: snap.embeddedCoverPathOf(album),
          disc: snap.discOf(album),
          discArtPath: _discArt[album.albumUid],
          onTap: (Rect? origin) => _openAlbum(album, origin),
        ),
        openAlbum: _openAlbum,
        openArtist: (MusicArtistRow a) => unawaited(_openArtist(a)),
      );

  /// [recommendLeading]：推荐页内容浮在页头大字底下时（[_chromeFloats]）交给推荐
  /// 列表当首块的「继续收听」；此时来源选中值也由本页持有、页签画在大字行里。
  Widget _buildSection(
    BuildContext context,
    MusicLibrarySnapshot snap, {
    Widget? recommendLeading,
  }) {
    if (_section == MusicLibrarySection.recommend) {
      final bool hosted = _chromeFloats(context);
      return MusicSourcesRecommendView(
        sources: _recommendSources,
        onSourcesChanged: () => unawaited(_reloadOnlineSources()),
        selectedSource: hosted ? _recommendSource : null,
        onSelectSource: hosted ? _selectRecommendSource : null,
        leading: recommendLeading,
        refreshHandle: _recommendRefresh,
      );
    }
    if (_section == MusicLibrarySection.sources) {
      return MusicOnlineSourcesView(
        key: const ValueKey<String>('music-section-sources'),
        onChanged: _onOnlineSourcesChanged,
        onOpenPlugins: isMusicPluginSourcesAvailable ? _selectPlugins : null,
      );
    }
    if (_section == MusicLibrarySection.plugins) {
      return const MusicPluginsView(
        key: ValueKey<String>('music-section-plugins'),
      );
    }
    final List<MusicPluginManifest> accountLists = _pluginsWith(
      MusicPluginCapability.library,
    );
    final bool accountPlaylists =
        _section == MusicLibrarySection.playlists && accountLists.isNotEmpty;
    if (snap.isEmpty &&
        _serverAlbums.isEmpty &&
        !accountPlaylists &&
        _section != MusicLibrarySection.works) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.music,
          message: t.music_library_empty,
          detail: t.music_library_empty_hint,
          // IM20：与书 / 视频 / 游戏同一个「去导入」，进导入视图选方式。
          action: FushiFilledButton.icon(
            key: const ValueKey<String>('music_empty_go_import'),
            onPressed: _openImport,
            icon: const FushiIcon(FushiIcons.libraryAdd),
            label: Text(t.library_empty_go_import),
          ),
        ),
      );
    }
    if (_section == MusicLibrarySection.playlists && isGlassDesign(context)) {
      return _ApplePlaylists(
        accounts: accountLists,
        playlists: snap.playlists,
        counts: snap.playlistTrackCounts,
        style: _libraryStyle(context, MusicLibrarySection.playlists),
      );
    }
    if (accountPlaylists) {
      return _playlistsWithAccounts(
        context,
        accountLists,
        snap.playlists,
        snap.playlistTrackCounts,
      );
    }
    return _localSection(context, _section, snap);
  }

  /// 专辑 / 光盘网格当前尺寸档下的「每行数量」，null = 自动。
  int? _gridFixedColumns(BuildContext context) =>
      _app.prefsRepo.libraryGridColumns(
        LibraryGridDomain.music,
        libraryGridSizeClassOf(context),
      );

  /// 写回「每行数量」（null = 自动）。
  void _setGridColumns(int? columns) {
    unawaited(
      _app.prefsRepo.setLibraryGridColumns(
        LibraryGridDomain.music,
        libraryGridSizeClassOf(context),
        columns,
      ),
    );
    setState(() {});
  }

  /// 本地（含混排服务器专辑）分区内容。
  Widget _localSection(
    BuildContext context,
    MusicLibrarySection section,
    MusicLibrarySnapshot snap,
  ) {
    return switch (section) {
      MusicLibrarySection.albums => _AlbumGrid(
        snapshot: snap,
        albums: snap.albums,
        serverAlbums: _serverAlbums,
        discArt: _discArt,
        onOpen: _openAlbum,
        style: _libraryStyle(context, MusicLibrarySection.albums),
        fixedColumns: _gridFixedColumns(context),
        onColumnsChanged: _setGridColumns,
      ),
      MusicLibrarySection.discs => _discSection(context, snap),
      MusicLibrarySection.artists => _ArtistList(
        snapshot: snap,
        artists: snap.artists,
        onOpen: (MusicArtistRow a) => unawaited(_openArtist(a)),
        style: _libraryStyle(context, MusicLibrarySection.artists),
      ),
      // 本地曲目在前，加入音乐库的远程曲目（YouTube / 在线插件，v148）随后，同一条队列。
      // 在线组的分区不走这里（[_buildSection] 先分走），与歌曲同画法只为穷尽。
      MusicLibrarySection.songs ||
      MusicLibrarySection.recommend ||
      MusicLibrarySection.sources ||
      MusicLibrarySection.plugins => MusicTrackList.entries(
        entries: snap.songEntries,
        albums: snap.albumByUid,
        context: MusicQueueContext.mixed,
        style: _libraryStyle(context, MusicLibrarySection.songs),
      ),
      MusicLibrarySection.works => Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.music,
          message: t.music_section_works,
          detail: t.music_works_empty,
        ),
      ),
      MusicLibrarySection.playlists =>
        snap.playlists.isEmpty
            ? Center(
                child: FushiPlaceholderMessage(
                  icon: FushiIcons.playlist,
                  message: t.music_playlists_empty,
                  action: const _LocalPlaylistActions(),
                ),
              )
            : _PlaylistList(
                playlists: snap.playlists,
                counts: snap.playlistTrackCounts,
                style: _libraryStyle(context, MusicLibrarySection.playlists),
              ),
    };
  }

  /// 「光盘」分区：从光盘添加的专辑 + 有盘面扫描图的 CD 专辑，与专辑分区同一套
  /// 卡片 / 样式。
  Widget _discSection(BuildContext context, MusicLibrarySnapshot snap) {
    final List<MusicAlbumRow> discs = <MusicAlbumRow>[
      for (final MusicAlbumRow a in snap.albums)
        if (a.discUid != null || _discArt.containsKey(a.albumUid)) a,
    ];
    if (discs.isEmpty) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.storage,
          message: t.music_section_discs,
          detail: t.music_discs_empty,
        ),
      );
    }
    return _AlbumGrid(
      key: const ValueKey<String>('music-library-discs'),
      snapshot: snap,
      albums: discs,
      discArt: _discArt,
      onOpen: _openAlbum,
      style: _libraryStyle(context, MusicLibrarySection.discs),
      fixedColumns: _gridFixedColumns(context),
      onColumnsChanged: _setGridColumns,
    );
  }

  Widget _groupTitle(BuildContext context, String text) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(
        top: tokens.spacing.section,
        bottom: tokens.spacing.gap,
      ),
      child: Text(text, style: context.fushiType.titleMedium),
    );
  }

  /// 歌单页签：先列已登录账号的歌单（每个声明 `library` 的插件一段），再列本地歌单。
  Widget _playlistsWithAccounts(
    BuildContext context,
    List<MusicPluginManifest> accounts,
    List<MusicPlaylistRow> local,
    Map<String, int> localCounts,
  ) {
    final List<Widget> blocks = <Widget>[
      for (final MusicPluginManifest m in accounts)
        MusicPluginLibrarySection(
          key: ValueKey<String>('music-plugin-library-${m.id}'),
          manifest: m,
        ),
      _groupTitle(context, t.music_playlists_local),
      if (local.isEmpty) ...<Widget>[
        Text(t.music_playlists_empty, style: context.fushiType.bodySmall),
        const Align(
          alignment: AlignmentDirectional.centerStart,
          child: _LocalPlaylistActions(),
        ),
      ] else
        _PlaylistList(
          playlists: local,
          counts: localCounts,
          shrinkWrap: true,
          style: _libraryStyle(context, MusicLibrarySection.playlists),
        ),
    ];
    return FushiEntranceScope(
      child: ListView.builder(
        key: const ValueKey<String>('music-library-playlists-accounts'),
        padding: musicBrowsePagePadding(context),
        itemCount: blocks.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int i) => blocks[i],
        ),
      ),
    );
  }
}

/// 曲库各分区记样式的视图种类与原有画法（[MusicViewStyleStore]）；推荐 / 作品没有。
(MusicViewKind, MusicViewStyle)? _libraryViewKind(MusicLibrarySection s) =>
    switch (s) {
      // 光盘分区是专辑的子集，与专辑分区共用同一份样式记忆。
      MusicLibrarySection.albums || MusicLibrarySection.discs => (
        MusicViewKind.albums,
        MusicViewStyle.blocks,
      ),
      MusicLibrarySection.artists => (
        MusicViewKind.artists,
        MusicViewStyle.list,
      ),
      MusicLibrarySection.songs => (MusicViewKind.tracks, MusicViewStyle.list),
      MusicLibrarySection.playlists => (
        MusicViewKind.playlists,
        MusicViewStyle.list,
      ),
      MusicLibrarySection.recommend ||
      MusicLibrarySection.works ||
      MusicLibrarySection.sources ||
      MusicLibrarySection.plugins => null,
    };

/// [s] 分区在本页生效的样式（推荐 / 作品不用，给列表）。
MusicViewStyle _libraryStyle(BuildContext context, MusicLibrarySection s) {
  final (MusicViewKind, MusicViewStyle)? view = _libraryViewKind(s);
  return view == null
      ? MusicViewStyle.list
      : musicViewStyleOf(context, view.$1, view.$2);
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({
    required this.snapshot,
    required this.albums,
    required this.onOpen,
    required this.style,
    this.discArt = const <String, String>{},
    this.serverAlbums = const <MusicServerAlbumRef>[],
    this.fixedColumns,
    this.onColumnsChanged,
    super.key,
  });

  final MusicLibrarySnapshot snapshot;

  /// 曲库「每行数量」（`library_grid_columns` 的 music 格；null = 自动）。
  final int? fixedColumns;

  /// 写回「每行数量」（Apple 外壳的捏合 / ⌘± / 滑杆）。
  final ValueChanged<int?>? onColumnsChanged;

  /// 本地专辑（[snapshot] 用来取各专辑的曲目）。
  final List<MusicAlbumRow> albums;

  /// 打开专辑；第二个参数是被点卡片的全局矩形（CD 详情从这里放大）。
  final void Function(MusicAlbumRow album, Rect? origin) onOpen;

  /// 有盘面扫描图的专辑（专辑 uid → 图路径）。
  final Map<String, String> discArt;

  /// 色块（封面网格布局下是原有的唱片网格卡）/ 单列行。
  final MusicViewStyle style;

  /// 混排进来的服务器专辑：排在本地专辑之后，卡片带云朵、点开走服务器专辑页。
  final List<MusicServerAlbumRef> serverAlbums;

  /// 第 [i] 格：本地专辑在前、服务器专辑在后；[block] 非 null = 封面色块卡，
  /// [row] = 单列行，都没给 = 原有的唱片网格卡。
  Widget _cell(int i, {FushiCoverBlockSize? block, bool row = false}) {
    if (i >= albums.length) {
      final MusicServerAlbumRef ref = serverAlbums[i - albums.length];
      final Key key = ValueKey<String>(
        'music-server-album-${ref.browser.serverId}-${ref.album.id}',
      );
      if (row) {
        return MusicServerAlbumListRow(
          key: key,
          browser: ref.browser,
          album: ref.album,
        );
      }
      if (block != null) {
        return MusicServerAlbumBlockCard(
          key: key,
          browser: ref.browser,
          album: ref.album,
          size: block,
        );
      }
      return MusicServerAlbumCard(
        key: key,
        browser: ref.browser,
        album: ref.album,
      );
    }
    final MusicAlbumRow album = albums[i];
    return _AlbumCard(
      key: ValueKey<String>('music-album-${album.albumUid}'),
      album: album,
      tracks: snapshot.tracksOfAlbum(album.albumUid),
      embeddedCoverPath: snapshot.embeddedCoverPathOf(album),
      disc: snapshot.discOf(album),
      discArtPath: discArt[album.albumUid],
      onTap: (Rect? origin) => onOpen(album, origin),
      block: block,
      row: row,
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final EdgeInsets padding = withBottomSafeInset(
      context,
      EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.section,
      ),
    );
    // 专辑一律是方形「唱片」材质（用户 2026-10-26 拍板）；封面网格布局下行高按
    // 新卡算（[musicAlbumGridDelegate]：方形封面 + ShelfCardMeta 文字块），色块布局
    // （拼贴 / 规整色块）按目标块宽自动定列。
    return MusicStyledCollection(
      style: style,
      itemCount: albums.length + serverAlbums.length,
      padding: padding,
      gridMaterial: ShelfCoverMaterial.glossyAlbum,
      gridDelegate: musicAlbumGridDelegateFor(fixedColumns: fixedColumns),
      gridColumnsOf: (BuildContext context, double width) =>
          fixedColumns ?? musicAlbumGridColumns(context, width),
      onGridColumnsChanged: onColumnsChanged,
      gridCardBuilder: (BuildContext context, int i) => _cell(i),
      blockBuilder: (BuildContext context, int i, FushiCoverBlockSize size) =>
          _cell(i, block: size),
      rowBuilder: (BuildContext context, int i) => _cell(i, row: true),
    );
  }
}

class _AlbumCard extends ConsumerWidget {
  const _AlbumCard({
    super.key,
    required this.album,
    required this.tracks,
    required this.embeddedCoverPath,
    required this.onTap,
    this.disc,
    this.discArtPath,
    this.block,
    this.row = false,
  });

  /// 非 null = 封面色块卡（库页布局为拼贴 / 规整色块）。
  final FushiCoverBlockSize? block;

  /// 单列行（列表样式）：封面、专辑名、艺人 · 年份 · 曲目数。
  final bool row;

  final MusicAlbumRow album;
  final List<MusicTrackRow> tracks;
  final String? embeddedCoverPath;

  /// 点按；参数是卡片的全局矩形（CD 详情从这里放大，取不到为 null）。
  final ValueChanged<Rect?> onTap;

  /// 光盘来源：盘是一张带 `DVD` / `BD` 角标的专辑，右键 / 长按菜单里另有「章节导入为
  /// 曲目」（§9.2）；普通专辑的菜单只有「从音乐库移除」（拍板台 mmXVwo0Ibv）。
  final MusicDiscSourceRow? disc;

  /// 专辑目录里的盘面扫描图（设计稿 M3）：给了就是「封面 + 唱片」色块，chip 写
  /// 「CD」；没有就不画唱片（不造假唱片）。
  final String? discArtPath;

  /// 右键 / 长按菜单（[showMusicAlbumMenu]）：光盘专辑的盘动作，普通专辑整张移出音乐库。
  void _showAlbumMenu(BuildContext context, WidgetRef ref, Offset position) {
    final AppModel app = ref.read(appProvider);
    if (!app.isDatabaseReady) return;
    unawaited(
      showMusicAlbumMenu(
        context: context,
        app: app,
        globalPosition: position,
        album: album,
        disc: disc,
        tracks: tracks,
      ),
    );
  }

  /// 卡片中心处唤出菜单（长按用）。
  void _showAlbumMenuAtCenter(BuildContext context, WidgetRef ref) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox) return;
    _showAlbumMenu(
      context,
      ref,
      box.localToGlobal(box.size.center(Offset.zero)),
    );
  }

  /// [context] 所在卡片的全局矩形。
  static Rect? _originOf(BuildContext context) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// 色块卡：有盘面图时是「封面 + 唱片」摆法（右下角 chip「CD」）；否则是普通方形
  /// 专辑块（副行歌手 · 年份，音频规格进 chip）。没有封面来源时不放 [MusicCover]，
  /// 色块按标题生成封面（设计稿 M2）。
  Widget _block(FushiCoverBlockSize size, String badge, Widget? discBadge) {
    final bool hasCover = musicHasCoverSource(
      album.coverPath,
      embeddedCoverPath,
    );
    final String? discArt = discArtPath;
    return MusicCoverTintSource(
      coverPath: album.coverPath,
      embeddedFromPath: embeddedCoverPath,
      builder: (BuildContext context, ImageProvider? tint) => FushiCoverBlock(
        size: size,
        art: FushiCoverBlockArt.square,
        metaKey: ValueKey<String>('music-album-meta-${album.albumUid}'),
        title: album.title,
        covers: <Widget>[
          if (hasCover)
            MusicCover(
              coverPath: album.coverPath,
              embeddedFromPath: embeddedCoverPath,
              borderRadius: BorderRadius.zero,
              title: album.title,
            ),
        ],
        tintImage: tint,
        disc: discArt == null ? null : musicDiscArtImage(discArt),
        // 与书架 / 漫画 / 视频同一套文字区：副行「歌手 · 年份」，音频规格进
        // chip（有盘面图时 chip 是「CD」、规格不再重复），光盘规格徽标排在文字区
        // 底部。
        subtitle: <String>[
          album.albumArtistCredit ?? t.music_artist_unknown,
          ?_releaseYear(album.releaseDate),
          if (disc != null && tracks.isEmpty) t.music_disc_not_imported,
        ].join(' · '),
        chip: discArt != null ? 'CD' : (badge.isEmpty ? null : badge),
        trailing: discBadge,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MusicDiscSourceRow? disc = this.disc;
    final MusicTrackRow? first = tracks.isEmpty ? null : tracks.first;
    final String badge = first == null
        ? ''
        : musicFormatBadge(
            codec: first.codec,
            isLossless: first.isLossless,
            sampleRate: first.sampleRate,
            bitDepth: first.bitDepth,
            bitrateKbps: first.bitrate,
          );
    final String subtitle = <String>[
      album.albumArtistCredit ?? t.music_artist_unknown,
      if (badge.isNotEmpty) badge,
      if (disc != null && tracks.isEmpty) t.music_disc_not_imported,
    ].join(' · ');
    final Widget? discBadge = disc == null
        ? null
        : IgnorePointer(child: MusicDiscBadge(disc: disc));
    if (row) {
      final Widget line = Builder(
        builder: (BuildContext context) => MusicCollectionRow(
          title: album.title,
          subtitle: <String>[
            album.albumArtistCredit ?? t.music_artist_unknown,
            ?_releaseYear(album.releaseDate),
            t.music_tracks_count(count: tracks.length),
            if (badge.isNotEmpty) badge,
            if (disc != null && tracks.isEmpty) t.music_disc_not_imported,
          ].join(' · '),
          coverPath: album.coverPath,
          embeddedFromPath: embeddedCoverPath,
          badges: <Widget>[?discBadge],
          onTap: () => onTap(_originOf(context)),
          onLongPress: () => _showAlbumMenuAtCenter(context, ref),
        ),
      );
      return ContextMenuTrigger(
        onInvoke: (Offset position) => _showAlbumMenu(context, ref, position),
        child: line,
      );
    }
    // 方形「唱片」材质卡（材质由网格外的 Scope 给）：封面上不压角标（用户
    // 2026-10-25），光盘规格徽标（CD / DVD / BD）进副行尾部，与视频库原盘卡同位。
    final FushiCoverBlockSize? block = this.block;
    final Widget card = FushiHoverLift(
      scale: kMusicHoverLiftScale,
      builder: (BuildContext context, bool _) => shelfCoverCard(
        onTap: () => onTap(_originOf(context)),
        onLongPress: () => _showAlbumMenuAtCenter(context, ref),
        child: block != null
            ? _block(block, badge, discBadge)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  AspectRatio(
                    aspectRatio: kShelfAlbumAspectRatio,
                    child: ShelfCoverFrame(
                      child: MusicCover(
                        coverPath: album.coverPath,
                        embeddedFromPath: embeddedCoverPath,
                        title: album.title,
                      ),
                    ),
                  ),
                  ShelfCardMeta(
                    key: ValueKey<String>('music-album-meta-${album.albumUid}'),
                    title: album.title,
                    subtitle: subtitle,
                    trailing: discBadge,
                  ),
                ],
              ),
      ),
    );
    // 右键菜单由绑定表决定唤出键（默认右键），右键被别的动作占用时自动让位。
    return ContextMenuTrigger(
      onInvoke: (Offset position) => _showAlbumMenu(context, ref, position),
      child: card,
    );
  }
}

/// 发行日期（`YYYY` / `YYYY-MM` / `YYYY-MM-DD`）里的年份；没有或不是年份开头为
/// null。
String? _releaseYear(String? releaseDate) =>
    releaseDate == null ? null : RegExp(r'^\d{4}').stringMatch(releaseDate);

class _ArtistList extends StatelessWidget {
  const _ArtistList({
    required this.snapshot,
    required this.artists,
    required this.onOpen,
    required this.style,
  });

  /// 取各艺人的专辑（专辑艺人署名与艺人名相同的专辑）：数专辑、拿首张封面当头像。
  final MusicLibrarySnapshot snapshot;
  final List<MusicArtistRow> artists;
  final ValueChanged<MusicArtistRow> onOpen;

  /// 色块 / 单列行（墨水屏恒为原有的分组列表）。
  final MusicViewStyle style;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final EdgeInsets padding = withBottomSafeInset(
      context,
      EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.section,
      ),
    );
    ValueKey<String> keyOf(MusicArtistRow a) =>
        ValueKey<String>('music-artist-${a.artistUid}');
    if (musicViewStyleSwitchable(context)) {
      final Map<String, List<MusicAlbumRow>> albumsByArtist =
          <String, List<MusicAlbumRow>>{};
      for (final MusicAlbumRow album in snapshot.albums) {
        final String? credit = album.albumArtistCredit;
        if (credit == null) continue;
        (albumsByArtist[credit] ??= <MusicAlbumRow>[]).add(album);
      }
      String? countOf(MusicArtistRow a) {
        final int n = albumsByArtist[a.name]?.length ?? 0;
        return n == 0 ? null : t.music_server_album_count(count: n);
      }

      // 艺人没有自己的图：头像取 TA 第一张专辑的封面（没有则人像占位）。
      MusicAlbumRow? coverAlbumOf(MusicArtistRow a) =>
          albumsByArtist[a.name]?.first;
      return MusicStyledCollection(
        style: style,
        itemCount: artists.length,
        padding: padding,
        blockBuilder: (BuildContext context, int i, FushiCoverBlockSize size) {
          final MusicArtistRow a = artists[i];
          final MusicAlbumRow? cover = coverAlbumOf(a);
          return MusicCollectionBlock(
            key: keyOf(a),
            size: size,
            title: a.name,
            subtitle: countOf(a),
            coverPath: cover?.coverPath,
            embeddedFromPath: cover == null
                ? null
                : snapshot.embeddedCoverPathOf(cover),
            circular: true,
            onTap: () => onOpen(a),
          );
        },
        rowBuilder: (BuildContext context, int i) {
          final MusicArtistRow a = artists[i];
          final MusicAlbumRow? cover = coverAlbumOf(a);
          return MusicCollectionRow(
            key: keyOf(a),
            title: a.name,
            subtitle: countOf(a),
            coverPath: cover?.coverPath,
            embeddedFromPath: cover == null
                ? null
                : snapshot.embeddedCoverPathOf(cover),
            circular: true,
            onTap: () => onOpen(a),
          );
        },
      );
    }
    // 墨水屏：原有的分组列表。
    return FushiEntranceScope(
      child: ListView.builder(
        padding: padding,
        itemCount: artists.length,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          final MusicArtistRow artist = artists[i];
          return FushiPressScale(
            child: FushiGroupedListItem(
              key: keyOf(artist),
              index: i,
              count: artists.length,
              onTap: () => onOpen(artist),
              child: FushiListItem(
                leading: const FushiListLeadingIcon(FushiIcons.person),
                title: Text(artist.name),
                trailing: const FushiIcon(FushiIcons.chevronRight),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// 按 uid 打开一个本地歌单（导入后用）；歌单已不在（被删）时不动。
Future<void> _openLocalPlaylistByUid(
  BuildContext context,
  FushiDatabase db,
  String uid,
) async {
  final MusicPlaylistRow? p = await db.getMusicPlaylist(uid);
  if (p == null || !context.mounted) return;
  openMusicLocalPlaylist(context, p);
}

/// 「新建歌单」：问名字建一个空的本地歌单（歌曲在曲目菜单「加入歌单」里加），建好
/// 提示。M3E 色块按钮与 Apple「新建歌单…」行同用这一份。
void _createLocalPlaylist(BuildContext context, AppModel app) {
  if (!app.isDatabaseReady) return;
  unawaited(() async {
    final MusicPlaylistTarget? created = await musicCreatePlaylist(
      context,
      MusicLocalPlaylistEditor(app.database),
    );
    if (created == null) return;
    FushiToast.show(
      msg: t.music_action_playlist_created(name: created.title),
      severity: ToastSeverity.success,
    );
  }());
}

/// 「导入歌单文件」：选一个 `.m3u` / `.m3u8`，条目对曲库后建成本地歌单并打开。M3E
/// 色块按钮与 Apple「导入歌单文件…」行同用这一份。
void _importLocalPlaylist(BuildContext context, AppModel app) {
  if (!app.isDatabaseReady) return;
  final FushiDatabase db = app.database;
  unawaited(() async {
    final String? uid = await musicImportPlaylistFile(
      context: context,
      appModel: app,
      db: db,
    );
    if (uid == null || !context.mounted) return;
    await _openLocalPlaylistByUid(context, db, uid);
  }());
}

/// 本地歌单的「新建歌单」「导入歌单文件」（`.m3u` / `.m3u8`，导入后直接打开）。
class _LocalPlaylistActions extends StatelessWidget {
  const _LocalPlaylistActions();

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: const <Widget>[
        _NewLocalPlaylistButton(),
        _ImportLocalPlaylistButton(),
      ],
    );
  }
}

/// 「导入歌单文件」：选一个 `.m3u` / `.m3u8`，条目对曲库后建成本地歌单并打开。
class _ImportLocalPlaylistButton extends ConsumerWidget {
  const _ImportLocalPlaylistButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) => FushiPressScale(
    child: FushiFilledButton.tonalIcon(
      key: const ValueKey<String>('music_import_local_playlist'),
      onPressed: () => _importLocalPlaylist(context, ref.read(appProvider)),
      icon: const FushiIcon(FushiIcons.folderOpen),
      label: Text(t.music_action_import_playlist),
    ),
  );
}

class _PlaylistList extends StatelessWidget {
  const _PlaylistList({
    required this.playlists,
    required this.counts,
    required this.style,
    this.shrinkWrap = false,
  });

  final List<MusicPlaylistRow> playlists;

  /// 各歌单条目数（歌单 uid → 条数）。
  final Map<String, int> counts;

  /// 色块 / 单列行（墨水屏恒为原有的分组列表）。
  final MusicViewStyle style;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final EdgeInsets padding = shrinkWrap
        ? EdgeInsets.zero
        : withBottomSafeInset(
            context,
            EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.section,
            ),
          );
    ValueKey<String> keyOf(MusicPlaylistRow p) =>
        ValueKey<String>('music-playlist-${p.playlistUid}');
    String countOf(MusicPlaylistRow p) =>
        t.music_tracks_count(count: counts[p.playlistUid] ?? 0);
    // 最前是「新建歌单 / 导入歌单文件」，其后每项一个本地歌单（点开 = 本地歌单页）。
    const Widget actions = Align(
      alignment: AlignmentDirectional.centerStart,
      child: _LocalPlaylistActions(),
    );
    if (musicViewStyleSwitchable(context)) {
      return MusicStyledCollection(
        style: style,
        itemCount: playlists.length,
        padding: padding,
        shrinkWrap: shrinkWrap,
        header: actions,
        headerGap: tokens.spacing.gap,
        blockBuilder: (BuildContext context, int i, FushiCoverBlockSize size) {
          final MusicPlaylistRow p = playlists[i];
          return MusicCollectionBlock(
            key: keyOf(p),
            size: size,
            title: p.name,
            subtitle: countOf(p),
            leadingIcon: FushiIcons.playlist,
            onTap: () => openMusicLocalPlaylist(context, p),
          );
        },
        rowBuilder: (BuildContext context, int i) {
          final MusicPlaylistRow p = playlists[i];
          return MusicCollectionRow(
            key: keyOf(p),
            title: p.name,
            subtitle: countOf(p),
            onTap: () => openMusicLocalPlaylist(context, p),
          );
        },
      );
    }
    // 墨水屏：原有的分组列表。
    return FushiEntranceScope(
      child: ListView.builder(
        shrinkWrap: shrinkWrap,
        primary: shrinkWrap ? false : null,
        physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
        padding: padding,
        itemCount: playlists.length + 1,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          if (i == 0) {
            return Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              child: actions,
            );
          }
          final MusicPlaylistRow p = playlists[i - 1];
          return FushiPressScale(
            child: FushiGroupedListItem(
              key: keyOf(p),
              index: i - 1,
              count: playlists.length,
              onTap: () => openMusicLocalPlaylist(context, p),
              child: FushiListItem(
                leading: const FushiListLeadingIcon(FushiIcons.playlist),
                title: Text(p.name),
                subtitle: Text(countOf(p)),
                trailing: const FushiIcon(FushiIcons.chevronRight),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// 歌单页签的 Apple 版（Apple Music 资料库 › 歌单，iOS 27 / macOS 27）：一张分组
/// 列表。有已登录账号歌单时先列各插件一段（[MusicPluginLibrarySection]，段头是
/// Apple 段头 + 裸字形），再列「本地歌单」一段；只有本地时不画段头（与 Apple Music
/// 一样直接是列表）。本地段首行「新建歌单…」、次行「导入歌单文件…」——两行与歌单行
/// 同几何（行首与封面同尺寸的方块 + 强调色字），空段就只剩这两行，不另叠空态插画与
/// 大按钮。列表自己不留顶部内边距：页头底下那一档间距由大字页头统一给（与曲库其它
/// 分区同一处），段与段之间的分组间距由段头自带。
class _ApplePlaylists extends ConsumerWidget {
  const _ApplePlaylists({
    required this.accounts,
    required this.playlists,
    required this.counts,
    required this.style,
  });

  /// 声明 `library` 能力的插件（各列一段「我的歌单」）。
  final List<MusicPluginManifest> accounts;
  final List<MusicPlaylistRow> playlists;

  /// 各歌单条目数（歌单 uid → 条数）。
  final Map<String, int> counts;

  /// 列表 / 色块（曲库页头的视图切换）。
  final MusicViewStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool blocks = musicCoverBlocksActive(context, style);
    String countOf(MusicPlaylistRow p) =>
        t.music_tracks_count(count: counts[p.playlistUid] ?? 0);
    final List<Widget> head = <Widget>[
      for (final MusicPluginManifest m in accounts)
        MusicPluginLibrarySection(
          key: ValueKey<String>('music-plugin-library-${m.id}'),
          manifest: m,
        ),
      if (accounts.isNotEmpty)
        AppleMusicPlaylistsSectionHeader(title: t.music_playlists_local),
      AppleMusicPlaylistActionRow(
        key: const ValueKey<String>('music_new_local_playlist'),
        icon: FushiIcons.add,
        title: '${t.music_action_new_playlist}…',
        onTap: () => _createLocalPlaylist(context, ref.read(appProvider)),
      ),
      AppleMusicPlaylistActionRow(
        key: const ValueKey<String>('music_import_local_playlist'),
        icon: FushiIcons.folderOpen,
        title: '${t.music_action_import_playlist}…',
        separator: playlists.isNotEmpty && !blocks,
        onTap: () => _importLocalPlaylist(context, ref.read(appProvider)),
      ),
      if (blocks && playlists.isNotEmpty)
        Padding(
          padding: EdgeInsets.only(top: tokens.spacing.gap),
          child: FushiCoverBlocks(
            layout: shellContentLayoutOf(context),
            staggerEntrance: false,
            itemCount: playlists.length,
            itemBuilder:
                (BuildContext context, int i, FushiCoverBlockSize size) {
                  final MusicPlaylistRow p = playlists[i];
                  return MusicCollectionBlock(
                    key: ValueKey<String>('music-playlist-${p.playlistUid}'),
                    size: size,
                    title: p.name,
                    subtitle: countOf(p),
                    leadingIcon: FushiIcons.playlist,
                    onTap: () => openMusicLocalPlaylist(context, p),
                  );
                },
          ),
        ),
    ];
    final int rowCount = blocks ? 0 : playlists.length;
    return FushiEntranceScope(
      child: ListView.builder(
        key: const ValueKey<String>('music-library-playlists-apple'),
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            0,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: head.length + rowCount,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          if (i < head.length) return head[i];
          final int index = i - head.length;
          final MusicPlaylistRow p = playlists[index];
          return AppleMusicEntityRow(
            key: ValueKey<String>('music-playlist-${p.playlistUid}'),
            title: p.name,
            subtitle: countOf(p),
            separator: index < playlists.length - 1,
            onTap: () => openMusicLocalPlaylist(context, p),
          );
        }),
      ),
    );
  }
}

/// 「新建歌单」：问名字建一个空的本地歌单（歌曲在曲目菜单「加入歌单」里加）。
class _NewLocalPlaylistButton extends ConsumerWidget {
  const _NewLocalPlaylistButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) => FushiPressScale(
    child: FushiFilledButton.tonalIcon(
      key: const ValueKey<String>('music_new_local_playlist'),
      onPressed: () => _createLocalPlaylist(context, ref.read(appProvider)),
      icon: const FushiIcon(FushiIcons.add),
      label: Text(t.music_action_new_playlist),
    ),
  );
}

/// 二级搜索页（宽窄屏同一套，曲库页右上角搜索按钮推入）：顶栏是带返回的搜索框（自动聚焦），正文是统一搜索的综合结果，段标题
/// 「全部」再推一层该类型的完整结果。查询词 / 来源过滤只活在本页，返回即丢，曲库页原样。
///
/// 键盘 / 手柄：回车立即提交（[FushiSearchBar.onSubmitted] 跳过防抖）；Esc 先清空，
/// 已空时不消费，交给全局「返回上一级」退出本页。
class _MusicLibrarySearchPage extends StatefulWidget {
  const _MusicLibrarySearchPage({
    required this.inputs,
    required this.localActions,
  });

  /// 曲库页持有的数据（快照 / 混排服务器专辑 / 搜索插件），变化时推过来。
  final ValueListenable<_MusicSearchInputs> inputs;

  /// 本地条目的卡片与跳转（本地专辑卡住在曲库页）。
  final MusicSearchLocalActions Function(MusicLibrarySnapshot snap)
  localActions;

  @override
  State<_MusicLibrarySearchPage> createState() =>
      _MusicLibrarySearchPageState();
}

class _MusicLibrarySearchPageState extends State<_MusicLibrarySearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'music-search-page');
  String _query = '';

  /// 同曲库页：`null` = 全部来源，[kMusicSearchLocalSource] = 只看本地，其余为插件 id。
  String? _sourceFilter;

  /// 综合结果与各页签共用的服务器搜索（一次搜索含全部类型，切页签不重发）。
  final MusicServerSearchCache _serverSearch = MusicServerSearchCache();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 「全部」：推入该类型的完整结果（本地在前、各插件分页接在后面）。
  void _openType(MusicPluginSearchType type) {
    final String query = _query;
    final String? filter = _sourceFilter;
    unawaited(
      Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (BuildContext context) =>
              ValueListenableBuilder<_MusicSearchInputs>(
                valueListenable: widget.inputs,
                builder:
                    (
                      BuildContext context,
                      _MusicSearchInputs inputs,
                      Widget? _,
                    ) {
                      final String? effective = _musicEffectiveSourceFilter(
                        filter,
                        inputs.searchPlugins,
                        inputs.searchServers,
                      );
                      return musicBrowseScaffold(
                        context,
                        title: musicLibrarySectionLabel(switch (type) {
                          MusicPluginSearchType.song =>
                            MusicLibrarySection.songs,
                          MusicPluginSearchType.album =>
                            MusicLibrarySection.albums,
                          MusicPluginSearchType.artist =>
                            MusicLibrarySection.artists,
                          MusicPluginSearchType.playlist =>
                            MusicLibrarySection.playlists,
                        }),
                        body: (BuildContext context) => MusicSearchResultsView(
                          key: ValueKey<String>(
                            'music-search-page-${type.wire}',
                          ),
                          type: type,
                          query: query,
                          sources: _musicFilteredSources(
                            effective,
                            inputs.searchPlugins,
                            type,
                          ),
                          servers: _musicFilteredServers(
                            effective,
                            inputs.searchServers,
                          ),
                          serverSearch: _serverSearch,
                          local: _musicSearchIncludesLocal(effective)
                              ? _musicLocalMatches(
                                  inputs.snapshot,
                                  inputs.serverAlbums,
                                  query,
                                )
                              : MusicSearchLocalItems.none,
                          localActions: widget.localActions(inputs.snapshot),
                        ),
                      );
                    },
              ),
        ),
      ),
    );
  }

  /// 搜索行 + 来源过滤。[masthead]：页头大字形态下作页名下一行（返回键在页头，
  /// 不再带页边与返回键）；否则是整条悬浮页头。
  Widget _header(
    BuildContext context,
    List<MusicPluginManifest> plugins,
    List<MusicServerBrowser> servers, {
    required bool masthead,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool searching = _query.trim().isNotEmpty;
    return Padding(
      padding: masthead
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.gap,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiSearchBar(
            fieldKey: const ValueKey<String>('music-search-page-field'),
            clearButtonKey: const ValueKey<String>('music-search-page-clear'),
            focusId: const FushiFocusId('music-search-page-field'),
            controller: _controller,
            focusNode: _focusNode,
            hintText: t.music_library_search_hint,
            autofocus: true,
            onBack: masthead
                ? null
                : () => unawaited(Navigator.of(context).maybePop()),
            onQueryChanged: (String q) => setState(() => _query = q),
            onSubmitted: (String q) => setState(() => _query = q),
            onClear: () => setState(() => _query = ''),
          ),
          // 来源过滤：同曲库页，只在有搜索词且有在线源时出现。
          if (searching && (plugins.isNotEmpty || servers.isNotEmpty))
            Padding(
              padding: EdgeInsets.only(top: tokens.spacing.gap),
              child: MusicSearchSourceChips(
                key: const ValueKey<String>('music-search-page-sources'),
                sources: plugins,
                servers: servers,
                selected: _musicEffectiveSourceFilter(
                  _sourceFilter,
                  plugins,
                  servers,
                ),
                onSelected: (String? v) => setState(() => _sourceFilter = v),
              ),
            ),
        ],
      ),
    );
  }

  /// 曲库歌词命中（Rust 语料索引的音乐文档），只留仍在曲库里的曲目（语料对账是异步的，
  /// 刚删的曲目可能还在索引里）。
  Future<List<CorpusHit>> _searchLyrics(
    String query,
    MusicLibrarySnapshot snapshot,
  ) async {
    final List<CorpusHit> hits = await LibraryCorpusService.instance.searchText(
      query,
      kind: CorpusSourceKind.music,
    );
    return musicLyricHitsInLibrary(hits, snapshot.tracks);
  }

  Future<void> _openLyricHit(CorpusHit hit) async {
    await playMusicOriginClip(
      app: ProviderScope.containerOf(context, listen: false).read(appProvider),
      trackUid: hit.key,
      positionMs: hit.pos,
    );
  }

  Widget _body(BuildContext context, _MusicSearchInputs inputs) {
    final String query = _query;
    if (query.trim().isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.search,
            message: t.music_library_search_hint,
          ),
        ),
      );
    }
    final String? effective = _musicEffectiveSourceFilter(
      _sourceFilter,
      inputs.searchPlugins,
      inputs.searchServers,
    );
    final bool includesLocal = _musicSearchIncludesLocal(effective);
    return MusicSearchOverview(
      key: const ValueKey<String>('music-search-page-overview'),
      query: query,
      searchLyrics: includesLocal
          ? (String q) => _searchLyrics(q, inputs.snapshot)
          : null,
      onLyricHit: _openLyricHit,
      sources: _musicFilteredSources(effective, inputs.searchPlugins),
      servers: _musicFilteredServers(effective, inputs.searchServers),
      serverSearch: _serverSearch,
      local: _musicSearchIncludesLocal(effective)
          ? _musicLocalMatches(inputs.snapshot, inputs.serverAlbums, query)
          : MusicSearchLocalItems.none,
      localActions: widget.localActions(inputs.snapshot),
      onSeeAll: _openType,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_MusicSearchInputs>(
      valueListenable: widget.inputs,
      builder: (BuildContext context, _MusicSearchInputs inputs, Widget? _) {
        return MusicFloatingBarHost(
          child: FushiPageScaffold(
            masthead: true,
            title: t.music_library_search_hint,
            // 重设计外壳：页头大字（页名 + 返回键），搜索行在页名下一行；墨水屏
            // 照旧整条搜索页头。
            mastheadBottom: _header(
              context,
              inputs.searchPlugins,
              inputs.searchServers,
              masthead: true,
            ),
            header: _header(
              context,
              inputs.searchPlugins,
              inputs.searchServers,
              masthead: false,
            ),
            body: AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.medium),
              // 同上：新旧两态各用自己的主滚动控制器。
              child: KeyedSubtree(
                key: ValueKey<bool>(_query.trim().isEmpty),
                child: SectionPrimaryScrollScope(child: _body(context, inputs)),
              ),
            ),
          ),
        );
      },
    );
  }
}
