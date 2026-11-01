/// 音乐「来源」页（曲库页右上角入口，设计稿 fushi/build/music_design/music_sources.html ①）：
///
/// - **音源**：本地文件夹 + 在线来源（插件音源、Jellyfin / Emby、OpenSubsonic、Apple Music）
///   一张可排序、可开关的表；顺序与开关决定它们在「推荐」来源 chip 与统一搜索里的出现顺序
///   （偏好 `music_online_sources`）。Apple Music 的开关就是它的启用开关，开着时下面跟地区选择。
/// - **歌词**：歌词来源（与 设置 › 音乐 › 歌词来源 同一份）。
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
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_library_page.dart'
    show showMusicSourcesDialog;
import 'package:fushi/src/pages/implementations/music/music_lyrics_providers.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_pages.dart'
    show openMusicPluginManagement;
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_server_settings.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 推入「来源」页；返回后调用方重读来源（开关 / 顺序 / 新加的服务器都可能变了）。
Future<void> openMusicSourcesPage(BuildContext context) =>
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => const MusicSourcesPage(),
      ),
    );

/// 读齐本机全部在线来源（插件音源 + 服务器），未排序。合规门没过的平台没有插件。
Future<List<MusicOnlineSource>> loadMusicOnlineSources(AppModel app) async {
  final List<MusicOnlineSource> out = <MusicOnlineSource>[];
  if (isMusicPluginSourcesAvailable) {
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

/// 「来源」页里 Apple Music 关着时的占位行（关着就没有浏览器实例）。
final class _AppleMusicOffSource extends MusicOnlineSource {
  const _AppleMusicOffSource();

  @override
  String get key => kAppleMusicSourceKey;

  @override
  String get name => 'Apple Music';
}

enum _SourcesTab { music, lyrics }

class MusicSourcesPage extends ConsumerStatefulWidget {
  const MusicSourcesPage({super.key});

  @override
  ConsumerState<MusicSourcesPage> createState() => _MusicSourcesPageState();
}

class _MusicSourcesPageState extends ConsumerState<MusicSourcesPage> {
  _SourcesTab _tab = _SourcesTab.music;

  /// null = 还在加载。
  List<MusicOrderedSource>? _rows;
  final GlobalKey _addAnchor = GlobalKey(debugLabel: 'music-sources-add');

  AppModel get _app => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final List<MusicOnlineSource> sources = await loadMusicOnlineSources(_app);
    if (!sources.any((MusicOnlineSource s) => s.key == kAppleMusicSourceKey)) {
      sources.add(const _AppleMusicOffSource());
    }
    final List<MusicOrderedSource> rows = orderMusicOnlineSources(
      sources,
      parseLyricsProviders(_app.prefsRepo.musicOnlineSourcesRaw),
    );
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  Future<void> _commit(List<MusicOrderedSource> rows) async {
    setState(() => _rows = rows);
    await _app.prefsRepo.setMusicOnlineSourcesRaw(
      serializeLyricsProviders(<LyricsProviderEntry>[
        for (final MusicOrderedSource r in rows)
          LyricsProviderEntry(id: r.source.key, enabled: r.enabled),
      ]),
    );
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
      await _app.prefsRepo.setMusicAppleMusicEnabled(on);
      await _load();
      return;
    }
    await _commit(<MusicOrderedSource>[
      for (final MusicOrderedSource r in rows)
        identical(r, row) ? (source: r.source, enabled: on) : r,
    ]);
  }

  bool _isOn(MusicOrderedSource row) => row.source.key == kAppleMusicSourceKey
      ? _app.prefsRepo.musicAppleMusicEnabled
      : row.enabled;

  Future<void> _setStorefront(String sf) async {
    await _app.prefsRepo.setMusicAppleMusicStorefront(sf);
    await _load();
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
                () => openMusicPluginManagement(context, appModel: _app),
              ),
            item(
              'music_sources_add_server',
              FushiIcons.server,
              t.music_sources_add_server,
              _openServerSettings,
            ),
            item(
              'music_sources_add_local',
              FushiIcons.folderOpen,
              t.music_sources_local,
              () => showMusicSourcesDialog(context),
            ),
          ],
        );
    if (action == null || !mounted) return;
    await action();
    await _load();
  }

  Future<void> _openServerSettings() => Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (BuildContext context) => musicBrowseScaffold(
        context,
        title: t.music_servers_title,
        body: Builder(
          builder: (BuildContext context) => SingleChildScrollView(
            padding: musicBrowsePagePadding(context),
            child: MusicServerSettingsBody(appModel: _app),
          ),
        ),
      ),
    ),
  );

  String _subtitleOf(MusicOnlineSource s) => switch (s) {
    MusicServerOnlineSource(:final MusicServerBrowser browser) =>
      switch (browser.kind) {
        MusicServerKind.jellyfin => 'Jellyfin / Emby',
        MusicServerKind.subsonic => 'OpenSubsonic',
        MusicServerKind.appleMusic => t.music_server_apple_music_subtitle,
      },
    _AppleMusicOffSource() => t.music_server_apple_music_subtitle,
    _ => t.music_sources_plugin_subtitle,
  };

  IconData _iconOf(MusicOnlineSource s) => switch (s) {
    MusicPluginOnlineSource() => FushiIcons.browserExtension,
    _ when s.key == kAppleMusicSourceKey => FushiIcons.globe,
    _ => FushiIcons.server,
  };

  Widget _musicTab(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<MusicOrderedSource>? rows = _rows;
    final String storefront = _app.prefsRepo.musicAppleMusicStorefront;
    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          FushiStaggeredEntrance(
            index: 0,
            child: AdaptiveSettingsRow(
              key: const ValueKey<String>('music-sources-local'),
              icon: FushiIcons.folderOpen,
              showIcon: true,
              title: t.music_sources_local,
              subtitle: t.music_sources_local_hint,
              trailing: const FushiIcon(FushiIcons.chevronRight, size: 20),
              onTap: () => unawaited(showMusicSourcesDialog(context)),
            ),
          ),
          Text(t.music_sources_online_hint, style: context.fushiType.bodySmall),
          if (rows == null)
            const FushiLinearProgressIndicator()
          else
            FushiReorderableColumn(
              itemCount: rows.length,
              spacing: tokens.spacing.gap,
              keyForIndex: (int i) =>
                  ValueKey<String>('music-source-${rows[i].source.key}'),
              onReorder: _move,
              itemBuilder: (BuildContext context, int i) {
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
                              key: ValueKey<String>(
                                'music-source-toggle-${r.source.key}',
                              ),
                              icon: _iconOf(r.source),
                              showIcon: true,
                              title: am ? 'Apple Music' : r.source.name,
                              subtitle: _subtitleOf(r.source),
                              value: on,
                              onChanged: (bool v) => unawaited(_toggle(r, v)),
                            ),
                          ),
                          FushiIconButton(
                            key: ValueKey<String>(
                              'music-source-up-${r.source.key}',
                            ),
                            icon: FushiIcons.expandLess,
                            tooltip: t.music_lyrics_providers_move_up,
                            padTouchTarget: true,
                            enabled: i > 0,
                            onTap: () => _move(i, i - 1),
                          ),
                          FushiIconButton(
                            key: ValueKey<String>(
                              'music-source-down-${r.source.key}',
                            ),
                            icon: FushiIcons.expandMore,
                            tooltip: t.music_lyrics_providers_move_down,
                            padTouchTarget: true,
                            enabled: i < rows.length - 1,
                            onTap: () => _move(i, i + 1),
                          ),
                        ],
                      ),
                      AnimatedSize(
                        duration: fushiMotionDuration(
                          context,
                          FushiMotion.short,
                        ),
                        alignment: Alignment.topCenter,
                        child: am && on
                            ? Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  start: 20,
                                ),
                                child: AdaptiveSettingsPickerRow<String>(
                                  key: const ValueKey<String>(
                                    'music-sources-apple-music-region',
                                  ),
                                  title: t.music_sources_region,
                                  subtitle: t.music_apple_music_storefront_hint,
                                  options:
                                      <AdaptiveSettingsPickerOption<String>>[
                                        for (final String sf
                                            in kAppleMusicStorefrontChoices)
                                          AdaptiveSettingsPickerOption<String>(
                                            value: sf,
                                            label: sf.toUpperCase(),
                                          ),
                                      ],
                                  selected:
                                      kAppleMusicStorefrontChoices.contains(
                                        storefront,
                                      )
                                      ? storefront
                                      : kAppleMusicStorefrontChoices.first,
                                  onChanged: (String v) =>
                                      unawaited(_setStorefront(v)),
                                ),
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                    ],
                  ),
                );
              },
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
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return musicBrowseScaffold(
      context,
      title: t.music_sources_title,
      body: Builder(
        builder: (BuildContext context) => SingleChildScrollView(
          padding: musicBrowsePagePadding(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: tokens.spacing.gap,
            children: <Widget>[
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: adaptiveSegmentedButton<_SourcesTab>(
                  context: context,
                  segments: <ButtonSegment<_SourcesTab>>[
                    ButtonSegment<_SourcesTab>(
                      value: _SourcesTab.music,
                      label: Text(t.music_sources_tab_music),
                    ),
                    ButtonSegment<_SourcesTab>(
                      value: _SourcesTab.lyrics,
                      label: Text(t.music_sources_tab_lyrics),
                    ),
                  ],
                  selected: <_SourcesTab>{_tab},
                  onSelectionChanged: (Set<_SourcesTab> v) =>
                      setState(() => _tab = v.first),
                ),
              ),
              AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.medium),
                child: KeyedSubtree(
                  key: ValueKey<_SourcesTab>(_tab),
                  child: switch (_tab) {
                    _SourcesTab.music => _musicTab(context),
                    _SourcesTab.lyrics => MusicLyricsProvidersBody(
                      appModel: _app,
                    ),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
