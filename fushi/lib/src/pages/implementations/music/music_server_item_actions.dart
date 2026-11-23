// 服务器条目（曲目 / 专辑 / 艺人）的收藏与即时混音动作：曲目菜单、专辑菜单与专辑页按钮共用。
// 只对实现了对应能力的服务器出现（[MusicServerFavoriteEditing] / [MusicServerInstantMix]：
// Jellyfin 家族与 OpenSubsonic），Apple Music / YouTube 不受影响。
part of 'music_server_pages.dart';

/// 这台服务器能不能收藏。
bool musicServerCanFavorite(MusicServerBrowser browser) =>
    browser is MusicServerFavoriteEditing;

/// 这台服务器能不能出即时混音。
bool musicServerCanInstantMix(MusicServerBrowser browser) =>
    browser is MusicServerInstantMix;

/// 心形图标（收藏了画实心）。
IconData musicServerFavoriteIcon(bool favorite) =>
    favorite ? FushiIcons.filled(FushiIcons.favorite) : FushiIcons.favorite;

/// 切换一项的收藏，失败提示（本机显示由 [MusicServerFavoriteStore] 先改、失败还原）。
Future<void> toggleMusicServerFavorite(
  MusicServerBrowser browser,
  MusicServerItemKind kind,
  String id, {
  bool? reported,
}) async {
  final MusicServerFavoriteStore store = MusicServerFavoriteStore.instance;
  final bool next = !store.isFavorite(browser, kind, id, reported: reported);
  try {
    await store.setFavorite(browser, kind, id, favorite: next);
  } on Object catch (e) {
    FushiToast.show(
      msg: t.music_favorite_failed(error: '$e'),
      severity: ToastSeverity.error,
    );
  }
}

/// 以一首 / 一张专辑 / 一位艺人为种子取服务器的即时混音并开播；服务器没给曲目时提示。
Future<void> playMusicServerInstantMix(
  BuildContext context,
  MusicServerBrowser browser,
  MusicServerItemKind kind,
  String id,
) async {
  if (browser is! MusicServerInstantMix) return;
  final AppModel app = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appProvider);
  final List<MusicServerTrack> tracks;
  try {
    tracks = await (browser as MusicServerInstantMix).instantMix(kind, id);
  } on Object catch (e) {
    FushiToast.show(
      msg: t.music_action_failed(error: '$e'),
      severity: ToastSeverity.error,
    );
    return;
  }
  if (tracks.isEmpty) {
    FushiToast.show(msg: t.music_server_instant_mix_empty);
    return;
  }
  final int? limit = musicServerBitrateLimit(
    app.isPreferencesReady ? app.prefsRepo.musicServerMaxBitrate : 0,
  );
  await app.musicSession.engine.playQueue(<MusicPlayItem>[
    for (final MusicServerTrack t in tracks)
      musicServerPlayItem(browser, t, maxBitrateKbps: limit),
  ]);
}

/// 菜单里的「收藏 / 取消收藏」「即时混音」两项（服务器不支持的那项不出现）。
List<MusicMenuAction> musicServerItemActions(
  MusicServerBrowser browser,
  MusicServerItemKind kind,
  String id, {
  bool? reportedFavorite,
}) {
  final bool favorite = MusicServerFavoriteStore.instance.isFavorite(
    browser,
    kind,
    id,
    reported: reportedFavorite,
  );
  return <MusicMenuAction>[
    if (musicServerCanFavorite(browser))
      MusicMenuAction(
        id: 'serverFavorite',
        label: favorite ? t.music_favorite_remove : t.music_favorite_add,
        icon: musicServerFavoriteIcon(favorite),
        run: (_) => toggleMusicServerFavorite(
          browser,
          kind,
          id,
          reported: reportedFavorite,
        ),
      ),
    if (musicServerCanInstantMix(browser))
      MusicMenuAction(
        id: 'serverInstantMix',
        label: t.music_server_instant_mix,
        icon: FushiIcons.cast,
        run: (BuildContext c) =>
            playMusicServerInstantMix(c, browser, kind, id),
      ),
  ];
}

/// 一张服务器专辑的菜单（右键 / 长按专辑卡）：收藏、即时混音（服务器支持时），以及
/// Jellyfin / Subsonic 整张专辑的入库 / 下载动作（给了 [db] 时；打开菜单时取一次曲目与状态）。
/// 一项都没有时回 null。
MusicItemMenu? musicServerAlbumMenu(
  BuildContext context,
  FushiDatabase? db,
  MusicServerBrowser browser,
  MusicServerAlbum album,
) {
  final FushiDatabase? storeDb = musicServerKindStorable(browser.kind)
      ? db
      : null;
  if (storeDb == null &&
      !musicServerCanFavorite(browser) &&
      !musicServerCanInstantMix(browser)) {
    return null;
  }
  return MusicItemMenu(
    buttonKey: ValueKey<String>('music-server-album-menu-${album.id}'),
    open: (MusicMenuAnchor? anchor) => unawaited(() async {
      // 右键坐标只在同步派发期间可读：第一个 await 之前取好。
      final MusicMenuAnchor? at = anchor ?? musicContextMenuAnchor();
      final MusicServerDownloadService? downloads = storeDb == null
          ? null
          : musicServerDownloadServiceOf(context, storeDb, browser);
      final List<MusicMenuAction> actions = musicServerItemActions(
        browser,
        MusicServerItemKind.album,
        album.id,
        reportedFavorite: album.favorite,
      );
      if (storeDb != null) {
        try {
          final List<MusicServerTrack> tracks = await browser.albumTracks(
            album.id,
          );
          final Set<String> inLibrary = await storeDb.musicRemoteLibraryUidsOf(
            musicServerTrackUids(browser, tracks),
          );
          actions.addAll(
            musicServerCollectionActions(
              db: storeDb,
              browser: browser,
              tracks: tracks,
              libraryUids: inLibrary,
              batchTitle: album.title,
              scope: 'album',
              scopeId: album.id,
              downloads: downloads,
              album: album,
              albumTitleOf: (_) => album.title,
            ),
          );
        } on Object catch (e) {
          FushiToast.show(
            msg: t.music_action_failed(error: '$e'),
            severity: ToastSeverity.error,
          );
          if (actions.isEmpty) return;
        }
      }
      if (!context.mounted) return;
      await showMusicActionMenu(
        context,
        anchor: at,
        errorText: (Object e) => t.music_action_failed(error: '$e'),
        actions: actions,
      );
    }()),
  );
}

/// 收藏切换按钮（专辑页 / 艺人页头部）：随 [MusicServerFavoriteStore] 刷新，心形切换带
/// 缩放过渡。服务器不能收藏时不占位。
class MusicServerFavoriteButton extends StatelessWidget {
  const MusicServerFavoriteButton({
    super.key,
    required this.browser,
    required this.kind,
    required this.id,
    this.reported,
  });

  final MusicServerBrowser browser;
  final MusicServerItemKind kind;
  final String id;
  final bool? reported;

  @override
  Widget build(BuildContext context) {
    if (!musicServerCanFavorite(browser)) return const SizedBox.shrink();
    final MusicServerFavoriteStore store = MusicServerFavoriteStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, Widget? _) {
        final bool favorite = store.isFavorite(
          browser,
          kind,
          id,
          reported: reported,
        );
        return AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.short),
          transitionBuilder: (Widget child, Animation<double> a) =>
              ScaleTransition(scale: a, child: child),
          child: FushiIconButton(
            key: ValueKey<String>(
              'music-server-favorite-${kind.name}-$id-$favorite',
            ),
            icon: musicServerFavoriteIcon(favorite),
            tooltip: favorite ? t.music_favorite_remove : t.music_favorite_add,
            padTouchTarget: true,
            onTap: () => unawaited(
              toggleMusicServerFavorite(browser, kind, id, reported: reported),
            ),
          ),
        );
      },
    );
  }
}
