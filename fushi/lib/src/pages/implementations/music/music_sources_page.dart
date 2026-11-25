/// 音乐「在线」组的两个视图（与书 / 漫画 / 视频库「在线」组的「来源」「扩展」同构，
/// 拍板台 4GBgF6TrNr：音乐的来源 / 插件入口并进「在线」，不再是曲库页「⋯」里单独推出
/// 的一页）：
///
/// - [MusicOnlineSourcesView]「来源」：
///   - **音源**：在线来源（插件音源、Jellyfin / Emby、OpenSubsonic、Apple Music、YouTube）
///     一张可排序、可开关的表；顺序与开关决定它们在「推荐」来源 chip 与统一搜索里的出现
///     顺序（偏好 `music_online_sources`）。Apple Music 的开关就是它的启用开关，开着时
///     下面跟地区选择。
///   - **歌词来源**（与 设置 › 音乐 › 歌词来源 同一份）。
/// - [MusicPluginsView]「插件」：插件安装 / 启停 / 登录（对应其它库页的「扩展」）。
///
/// 本地文件夹不在这里：它是「把音乐放进库里」，住导入视图的常驻来源区（与书 / 视频 /
/// 漫画一样，导入管本地、在线管在线）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart'
    show kAppleMusicStorefrontChoices;
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/lyrics_provider_list.dart';
import 'package:fushi/src/media/music/music_online_sources.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_gate.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/media/music/server/youtube_music_gate.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_providers.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_settings.dart'
    show MusicPluginDropTarget, MusicPluginSettingsBody;
import 'package:fushi/src/pages/implementations/music/music_plugin_pages.dart'
    show openMusicPluginManagement;
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_services.dart'
    show buildMusicServersDestination;
import 'package:fushi/src/pages/implementations/music/apple/apple_music_sources_layout.dart';
import 'package:fushi/src/pages/implementations/music/apple/apple_music_list_layout.dart'
    show appleMusicListPagePadding;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isGlassDesign;
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// 读齐本机全部在线来源（插件音源 + 服务器），未排序。插件含本机装的与经互联中继的
/// （[isMusicPluginSourcesUsable]）；两者都没有的平台没有插件。
Future<List<MusicOnlineSource>> loadMusicOnlineSources(AppModel app) async {
  final List<MusicOnlineSource> out = <MusicOnlineSource>[];
  if (isMusicPluginSourcesUsable) {
    for (final InstalledMusicPlugin p in await app.musicPluginManager.list()) {
      if (p.isMusicSource) out.add(MusicPluginOnlineSource(p.info!.manifest));
    }
  }
  for (final MusicServerBrowser b in await loadMusicServerBrowsers(app)) {
    out.add(MusicServerOnlineSource(b));
  }
  return out;
}

/// 读来源并按偏好排序。
Future<List<MusicOrderedSource>> loadOrderedMusicOnlineSources(
  AppModel app,
) async {
  final List<MusicOnlineSource> sources = await loadMusicOnlineSources(app);
  return orderMusicOnlineSources(
    sources,
    app.isPreferencesReady
        ? parseLyricsProviders(app.prefsRepo.musicOnlineSourcesRaw)
        : const <LyricsProviderEntry>[],
  );
}

/// 「来源」页里 Apple Music 关着时的占位行：关着就没有浏览器实例，但这一行的开关正是
/// 打开它的地方，所以必须有一行可点。顺序的保留不靠它（写回走
/// [applyMusicOnlineSourceEdits]，不在场的来源一律原样保留）。
final class _AppleMusicOffSource extends MusicOnlineSource {
  const _AppleMusicOffSource();

  @override
  String get key => kAppleMusicSourceKey;

  @override
  String get name => 'Apple Music';
}

/// 「来源」页里 YouTube 内置音源关着时的占位行（同 [_AppleMusicOffSource]：这一行的开关就是
/// 启用开关）。合规门没过（iOS）时不出这一行。
final class _YoutubeOffSource extends MusicOnlineSource {
  const _YoutubeOffSource();

  @override
  String get key => kYoutubeMusicSourceKey;

  @override
  String get name => 'YouTube';
}

/// 音乐「在线 › 来源」：音源的排序 / 开关（+ Apple Music 地区）与歌词来源，一页滚完。
///
/// 嵌在曲库页的「在线」组里（与书 / 漫画 / 视频库的「来源」视图同位），不另推页面。
/// 页面体收 `.fushiplug` 拖放（BUG-4712；歌词来源的 [MusicLyricsProvidersBody] 自己不挂
/// 落点，免得同一次拖放装两遍）。
class MusicOnlineSourcesView extends ConsumerStatefulWidget {
  const MusicOnlineSourcesView({super.key, this.onChanged, this.onOpenPlugins});

  /// 音源的顺序 / 开关 / 启用 / 新加的服务器变了：宿主（曲库页）据此重读「推荐」与搜索
  /// 用的来源。
  final VoidCallback? onChanged;

  /// 「添加来源 › 音源插件」：宿主就地切到「在线 › 插件」（与其它库页「来源」空态去
  /// 「扩展」同一做法）；null 时推插件管理页，不留死按钮。
  final VoidCallback? onOpenPlugins;

  @override
  ConsumerState<MusicOnlineSourcesView> createState() =>
      _MusicOnlineSourcesViewState();
}

class _MusicOnlineSourcesViewState
    extends ConsumerState<MusicOnlineSourcesView> {
  /// null = 还在加载。
  List<MusicOrderedSource>? _rows;
  final GlobalKey _addAnchor = GlobalKey(debugLabel: 'music-sources-add');

  /// initState 里取一次：await 之后页面可能已 dispose，不再经过 ref。
  late final AppModel _app = ref.read(appProvider);

  /// 插件装 / 卸 / 启停都会改变「来源」列表：本页的拖放落点装上的插件要立刻出现。
  StreamSubscription<void>? _pluginChanges;

  @override
  void initState() {
    super.initState();
    _pluginChanges = _app.musicPluginManager.changes.listen(
      (_) => unawaited(_load()),
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_pluginChanges?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final List<MusicOnlineSource> sources = await loadMusicOnlineSources(_app);
    if (!sources.any((MusicOnlineSource s) => s.key == kAppleMusicSourceKey)) {
      sources.add(const _AppleMusicOffSource());
    }
    if (isYoutubeMusicSourceAvailable &&
        !sources.any(
          (MusicOnlineSource s) => s.key == kYoutubeMusicSourceKey,
        )) {
      sources.add(const _YoutubeOffSource());
    }
    final List<MusicOrderedSource> rows = orderMusicOnlineSources(
      sources,
      parseLyricsProviders(_app.prefsRepo.musicOnlineSourcesRaw),
    );
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  /// 可见行的新顺序与开关合并回已存的完整列表：这次没加载到的来源（插件 / 服务器被停用）
  /// 的顺序与开关原样保留，不因在这里排了一次序就被删掉。
  ///
  /// 写偏好期间用户可能已切走（本视图嵌在曲库页的「在线」组里，切页签就 dispose）：
  /// 宿主回调在动手前同步取好，写完照样通知宿主（宿主比本视图活得久，自己判
  /// mounted），不经已卸载的本 State 取 `widget`，也不因本视图没了就漏通知。
  Future<void> _commit(List<MusicOrderedSource> rows) async {
    final VoidCallback? notify = widget.onChanged;
    setState(() => _rows = rows);
    await _app.prefsRepo.setMusicOnlineSourcesRaw(
      serializeLyricsProviders(
        applyMusicOnlineSourceEdits(
          parseLyricsProviders(_app.prefsRepo.musicOnlineSourcesRaw),
          <LyricsProviderEntry>[
            for (final MusicOrderedSource r in rows)
              LyricsProviderEntry(id: r.source.key, enabled: r.enabled),
          ],
        ),
      ),
    );
    notify?.call();
  }

  void _move(int from, int to) {
    final List<MusicOrderedSource>? rows = _rows;
    if (rows == null || to < 0 || to >= rows.length) return;
    final List<MusicOrderedSource> next = List<MusicOrderedSource>.of(rows);
    next.insert(to, next.removeAt(from));
    unawaited(_commit(next));
  }

  Future<void> _toggle(MusicOrderedSource row, bool on) async {
    final List<MusicOrderedSource>? rows = _rows;
    if (rows == null) return;
    if (row.source.key == kAppleMusicSourceKey) {
      // Apple Music 的开关就是启用开关：关着时没有浏览器实例，条目本身恒为显示。
      await _persistThenReload(
        () => _app.prefsRepo.setMusicAppleMusicEnabled(on),
      );
      return;
    }
    if (row.source.key == kYoutubeMusicSourceKey) {
      // 同上：YouTube 内置音源的开关就是启用开关。
      await _persistThenReload(() => _app.prefsRepo.setMusicYoutubeEnabled(on));
      return;
    }
    await _commit(<MusicOrderedSource>[
      for (final MusicOrderedSource r in rows)
        identical(r, row) ? (source: r.source, enabled: on) : r,
    ]);
  }

  /// 来源集合本身变了（启用开关 / 地区 / 新加服务器）：先做 [change]（写偏好 / 推
  /// 添加页），再重读本页并告诉宿主。宿主回调在 [change] 之前同步取好：[change]
  /// 期间用户切走、本视图已 dispose 时，本页不再重读，但宿主照样收到通知（推荐与
  /// 统一搜索的来源、混排的服务器专辑由宿主重读，不能因本视图没了就停在旧配置上）。
  Future<void> _persistThenReload(Future<void> Function() change) async {
    final VoidCallback? notify = widget.onChanged;
    await change();
    if (mounted) await _load();
    notify?.call();
  }

  bool _isOn(MusicOrderedSource row) => switch (row.source.key) {
    kAppleMusicSourceKey => _app.prefsRepo.musicAppleMusicEnabled,
    kYoutubeMusicSourceKey => _app.prefsRepo.musicYoutubeEnabled,
    _ => row.enabled,
  };

  Future<void> _setStorefront(String sf) =>
      _persistThenReload(() => _app.prefsRepo.setMusicAppleMusicStorefront(sf));

  Future<void> _openPlugins() async {
    final VoidCallback? select = widget.onOpenPlugins;
    if (select != null) {
      select();
      return;
    }
    await openMusicPluginManagement(context, appModel: _app);
  }

  Future<void> _openAddMenu() async {
    final RenderObject? overlay = Overlay.of(
      context,
    ).context.findRenderObject();
    final RenderObject? button = _addAnchor.currentContext?.findRenderObject();
    if (overlay is! RenderBox || button is! RenderBox) return;
    final Offset anchor = overlay.globalToLocal(
      button.localToGlobal(button.size.bottomLeft(Offset.zero)),
    );
    PopupMenuItem<Future<void> Function()> item(
      String key,
      IconData icon,
      String label,
      Future<void> Function() action,
    ) => FushiPopupMenuItem<Future<void> Function()>(
      key: ValueKey<String>(key),
      value: action,
      icon: icon,
      label: label,
    );
    final Future<void> Function()? action =
        await showFushiMenu<Future<void> Function()>(
          context: context,
          position: RelativeRect.fromRect(
            Rect.fromPoints(anchor, anchor),
            Offset.zero & overlay.size,
          ),
          items: <PopupMenuEntry<Future<void> Function()>>[
            if (isMusicPluginSourcesAvailable)
              item(
                'music_sources_add_plugin',
                FushiIcons.browserExtension,
                t.music_sources_add_plugin,
                _openPlugins,
              ),
            item(
              'music_sources_add_server',
              FushiIcons.server,
              t.music_sources_add_server,
              _openServerSettings,
            ),
          ],
        );
    if (action == null || !mounted) return;
    await _persistThenReload(action);
  }

  /// 「添加 › 服务器」：推设置 › 在线服务 › 媒体服务器里那一页（同一棵
  /// [buildMusicServersDestination]，同壳、同正文、同串流音质行），不在模块页另拼一份。
  /// 与视频的「去设置添加服务器」（`openMediaServerSettings`）同走根导航器。
  Future<void> _openServerSettings() =>
      Navigator.of(context, rootNavigator: true).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) =>
              const SettingsDetailPage.subPage(buildMusicServersDestination),
        ),
      );

  String _subtitleOf(MusicOnlineSource s) => switch (s) {
    MusicServerOnlineSource(:final MusicServerBrowser browser) =>
      switch (browser.kind) {
        MusicServerKind.jellyfin => 'Jellyfin / Emby',
        MusicServerKind.subsonic => 'OpenSubsonic',
        MusicServerKind.appleMusic ||
        MusicServerKind.youtube ||
        MusicServerKind.fushiHost => musicServerSubtitle(browser),
      },
    _AppleMusicOffSource() => t.music_server_apple_music_subtitle,
    _YoutubeOffSource() => t.music_server_youtube_subtitle,
    _ => t.music_sources_plugin_subtitle,
  };

  IconData _iconOf(MusicOnlineSource s) => switch (s) {
    MusicPluginOnlineSource() => FushiIcons.browserExtension,
    _ when s.key == kAppleMusicSourceKey => FushiIcons.globe,
    _ when s.key == kYoutubeMusicSourceKey => FushiIcons.globe,
    _ => FushiIcons.server,
  };

  Widget _sourceRow(
    BuildContext context,
    List<MusicOrderedSource> rows,
    int i,
    String storefront,
  ) {
    final MusicOrderedSource r = rows[i];
    final bool am = r.source.key == kAppleMusicSourceKey;
    final bool on = _isOn(r);
    return FushiStaggeredEntrance(
      index: i + 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const FushiIcon(FushiIcons.dragHandle, size: 20),
              Expanded(
                child: AdaptiveSettingsSwitchRow(
                  key: ValueKey<String>('music-source-toggle-${r.source.key}'),
                  icon: _iconOf(r.source),
                  showIcon: true,
                  title: am ? 'Apple Music' : r.source.name,
                  subtitle: _subtitleOf(r.source),
                  value: on,
                  onChanged: (bool v) => unawaited(_toggle(r, v)),
                ),
              ),
              FushiIconButton(
                key: ValueKey<String>('music-source-up-${r.source.key}'),
                icon: FushiIcons.expandLess,
                tooltip: t.music_lyrics_providers_move_up,
                padTouchTarget: true,
                enabled: i > 0,
                onTap: () => _move(i, i - 1),
              ),
              FushiIconButton(
                key: ValueKey<String>('music-source-down-${r.source.key}'),
                icon: FushiIcons.expandMore,
                tooltip: t.music_lyrics_providers_move_down,
                padTouchTarget: true,
                enabled: i < rows.length - 1,
                onTap: () => _move(i, i + 1),
              ),
            ],
          ),
          FushiAnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            alignment: Alignment.topCenter,
            child: am && on
                ? Padding(
                    padding: const EdgeInsetsDirectional.only(start: 20),
                    child: AdaptiveSettingsPickerRow<String>(
                      key: const ValueKey<String>(
                        'music-sources-apple-music-region',
                      ),
                      title: t.music_sources_region,
                      subtitle: t.music_apple_music_storefront_hint,
                      options: <AdaptiveSettingsPickerOption<String>>[
                        for (final String sf in kAppleMusicStorefrontChoices)
                          AdaptiveSettingsPickerOption<String>(
                            value: sf,
                            label: sf.toUpperCase(),
                          ),
                      ],
                      selected:
                          kAppleMusicStorefrontChoices.contains(storefront)
                          ? storefront
                          : kAppleMusicStorefrontChoices.first,
                      onChanged: (String v) => unawaited(_setStorefront(v)),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  /// Cupertino：与曲库「歌单」同一套 Apple Music 资料库式分组列表
  /// （[AppleMusicSourcesLayout]）；状态、写回、添加菜单与 M3E 同一份。
  Widget _buildApple(
    BuildContext context,
    List<MusicOrderedSource>? rows,
    String storefront,
  ) => AppleMusicSourcesLayout(
    rows: rows == null
        ? null
        : <AppleMusicSourceRowData>[
            for (final MusicOrderedSource r in rows)
              (
                key: r.source.key,
                title: r.source.key == kAppleMusicSourceKey
                    ? 'Apple Music'
                    : r.source.name,
                subtitle: _subtitleOf(r.source),
                icon: _iconOf(r.source),
                on: _isOn(r),
                appleMusic: r.source.key == kAppleMusicSourceKey,
              ),
          ],
    storefront: storefront,
    storefronts: kAppleMusicStorefrontChoices,
    onToggle: (int i, bool on) {
      final List<MusicOrderedSource>? current = _rows;
      if (current == null || i >= current.length) return;
      unawaited(_toggle(current[i], on));
    },
    onReorder: _move,
    onStorefront: (String v) => unawaited(_setStorefront(v)),
    addKey: _addAnchor,
    onAdd: () => unawaited(_openAddMenu()),
    // 曲库「在线 › 来源」排在大字页头下面：页头已给让位 + 一档间距，不再叠
    // musicBrowsePagePadding 的顶距（那是给滚到大字底下的推荐页用的）。
    padding: appleMusicListPagePadding(context),
    lyrics: isMusicPluginSourcesUsable
        ? MusicLyricsProvidersBody(
            appModel: _app,
            canInstall: isMusicPluginSourcesAvailable,
            sectionTitle: t.music_lyrics_providers_title,
          )
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<MusicOrderedSource>? rows = _rows;
    final String storefront = _app.prefsRepo.musicAppleMusicStorefront;
    final Widget body = isGlassDesign(context)
        ? _buildApple(context, rows, storefront)
        : SingleChildScrollView(
            key: const ValueKey<String>('music-online-sources-view'),
            padding: musicBrowsePagePadding(context),
            child: FushiEntranceScope(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  FushiStaggeredEntrance(
                    index: 0,
                    child: Text(
                      t.music_sources_online_hint,
                      style: context.fushiType.bodySmall,
                    ),
                  ),
                  if (rows == null)
                    const FushiLinearProgressIndicator()
                  else
                    FushiReorderableColumn(
                      itemCount: rows.length,
                      spacing: tokens.spacing.gap,
                      keyForIndex: (int i) => ValueKey<String>(
                        'music-source-${rows[i].source.key}',
                      ),
                      onReorder: _move,
                      itemBuilder: (BuildContext context, int i) =>
                          _sourceRow(context, rows, i, storefront),
                    ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FushiPressScale(
                      child: FushiOutlinedButton.icon(
                        key: _addAnchor,
                        onPressed: () => unawaited(_openAddMenu()),
                        icon: const FushiIcon(FushiIcons.add),
                        label: Text(t.music_sources_add),
                      ),
                    ),
                  ),
                  // 歌词来源是歌词插件（与 设置 › 音乐 › 歌词来源 同一份、同一道门）。
                  if (isMusicPluginSourcesUsable) ...<Widget>[
                    SettingsSectionHeader(
                      t.music_lyrics_providers_title,
                      key: const ValueKey<String>(
                        'music-sources-lyrics-header',
                      ),
                    ),
                    MusicLyricsProvidersBody(
                      appModel: _app,
                      canInstall: isMusicPluginSourcesAvailable,
                    ),
                  ],
                ],
              ),
            ),
          );
    if (!isMusicPluginSourcesAvailable) return body;
    return MusicPluginDropTarget(manager: _app.musicPluginManager, child: body);
  }
}

/// 音乐「在线 › 插件」：插件的安装（含 `.fushiplug` 拖放，BUG-4712）/ 启停 / 登录，
/// 与其它库页「在线 › 扩展」同位。只在本机能跑插件时出现
/// （[isMusicPluginSourcesAvailable]）。
class MusicPluginsView extends ConsumerWidget {
  const MusicPluginsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel app = ref.read(appProvider);
    return MusicPluginDropTarget(
      manager: app.musicPluginManager,
      child: SingleChildScrollView(
        key: const ValueKey<String>('music-plugins-view'),
        // Apple：排在大字页头下面，页头已给顶部间距，列表不再叠一份（与歌单 / 来源
        // 同一处 [appleMusicListPagePadding]）。M3E 照旧。
        padding: isGlassDesign(context)
            ? appleMusicListPagePadding(context)
            : musicBrowsePagePadding(context),
        child: FushiEntranceScope(
          child: FushiStaggeredEntrance(
            index: 0,
            child: MusicPluginSettingsBody(appModel: app),
          ),
        ),
      ),
    );
  }
}
