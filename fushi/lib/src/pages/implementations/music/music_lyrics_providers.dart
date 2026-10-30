/// 设置 › 音乐 › 歌词来源（docs/specs/2026-10-30-lyrics-plugins.md §6）：
/// LRCLIB 固定第一（内置、无开关、不可移除 / 重排），其后是已装歌词插件的可排序、可启停列表。
library;

import 'dart:async';

import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/lyrics_provider_list.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_settings.dart';
import 'package:fushi/src/settings/settings_kit.dart' show SettingsEmptyState;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

class MusicLyricsProvidersBody extends StatefulWidget {
  const MusicLyricsProvidersBody({super.key, required this.appModel});

  final AppModel appModel;

  @override
  State<MusicLyricsProvidersBody> createState() =>
      _MusicLyricsProvidersBodyState();
}

class _MusicLyricsProvidersBodyState extends State<MusicLyricsProvidersBody> {
  MusicPluginManager get _manager => widget.appModel.musicPluginManager;

  /// null = 还在加载。
  List<LyricsProviderEntry>? _entries;
  Map<String, InstalledMusicPlugin> _byId =
      const <String, InstalledMusicPlugin>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final List<InstalledMusicPlugin> plugins = <InstalledMusicPlugin>[
      for (final InstalledMusicPlugin p in await _manager.list())
        if (p.isLyricsSource) p,
    ];
    if (!mounted) return;
    setState(() {
      _byId = <String, InstalledMusicPlugin>{
        for (final InstalledMusicPlugin p in plugins) p.id: p,
      };
      _entries = mergeLyricsProviders(
        parseLyricsProviders(widget.appModel.prefsRepo.musicLyricsProvidersRaw),
        plugins.map((InstalledMusicPlugin p) => p.id),
      );
    });
  }

  Future<void> _commit(List<LyricsProviderEntry> next) async {
    setState(() => _entries = next);
    await widget.appModel.prefsRepo.setMusicLyricsProvidersRaw(
      serializeLyricsProviders(next),
    );
  }

  void _move(int from, int to) {
    final List<LyricsProviderEntry>? entries = _entries;
    if (entries == null) return;
    unawaited(_commit(reorderLyricsProviders(entries, from, to)));
  }

  void _toggle(String id, bool on) {
    final List<LyricsProviderEntry>? entries = _entries;
    if (entries == null) return;
    unawaited(_commit(toggleLyricsProvider(entries, id, on)));
  }

  Future<void> _install() async {
    if (await pickAndInstallMusicPlugin(context, _manager)) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<LyricsProviderEntry>? entries = _entries;
    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            t.music_lyrics_providers_hint,
            style: context.fushiType.bodySmall,
          ),
          FushiStaggeredEntrance(
            index: 0,
            child: AdaptiveSettingsRow(
              key: const ValueKey<String>('music-lyrics-provider-lrclib'),
              icon: FushiIcons.lyrics,
              showIcon: true,
              title: 'LRCLIB',
              subtitle: t.music_lyrics_providers_builtin_note,
              trailing: const FushiIcon(FushiIcons.lock, size: 20),
            ),
          ),
          if (entries == null)
            const FushiLinearProgressIndicator()
          else if (entries.isEmpty)
            FushiStaggeredEntrance(
              index: 1,
              child: SettingsEmptyState(
                icon: FushiIcons.browserExtension,
                title: t.music_lyrics_providers_empty,
                message: t.music_lyrics_providers_empty_hint,
                action: FushiPressScale(
                  child: FushiFilledButton.icon(
                    key: const ValueKey<String>(
                      'music_lyrics_provider_install',
                    ),
                    onPressed: () => unawaited(_install()),
                    icon: const FushiIcon(FushiIcons.importFile),
                    label: Text(t.music_lyrics_providers_install_action),
                  ),
                ),
              ),
            )
          else
            FushiReorderableColumn(
              itemCount: entries.length,
              spacing: tokens.spacing.gap,
              keyForIndex: (int i) =>
                  ValueKey<String>('music-lyrics-provider-${entries[i].id}'),
              onReorder: _move,
              itemBuilder: (BuildContext context, int i) =>
                  FushiStaggeredEntrance(
                    index: i + 1,
                    child: _ProviderRow(
                      entry: entries[i],
                      plugin: _byId[entries[i].id],
                      onToggle: (bool v) => _toggle(entries[i].id, v),
                      onMoveUp: i > 0 ? () => _move(i, i - 1) : null,
                      onMoveDown: i < entries.length - 1
                          ? () => _move(i, i + 1)
                          : null,
                    ),
                  ),
            ),
        ],
      ),
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    required this.entry,
    required this.plugin,
    required this.onToggle,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final LyricsProviderEntry entry;
  final InstalledMusicPlugin? plugin;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    final MusicPluginManifest? m = plugin?.info?.manifest;
    return Row(
      children: <Widget>[
        const FushiIcon(FushiIcons.dragHandle, size: 20),
        Expanded(
          child: AdaptiveSettingsSwitchRow(
            icon: FushiIcons.browserExtension,
            showIcon: true,
            title: m?.name ?? entry.id,
            subtitle: m == null
                ? entry.id
                : <String>[
                    t.music_plugins_version(version: m.version),
                    m.id,
                  ].join(' · '),
            value: entry.enabled,
            onChanged: onToggle,
          ),
        ),
        FushiIconButton(
          key: ValueKey<String>('music-lyrics-provider-up-${entry.id}'),
          icon: FushiIcons.expandLess,
          tooltip: t.music_lyrics_providers_move_up,
          padTouchTarget: true,
          enabled: onMoveUp != null,
          onTap: onMoveUp,
        ),
        FushiIconButton(
          key: ValueKey<String>('music-lyrics-provider-down-${entry.id}'),
          icon: FushiIcons.expandMore,
          tooltip: t.music_lyrics_providers_move_down,
          padTouchTarget: true,
          enabled: onMoveDown != null,
          onTap: onMoveDown,
        ),
      ],
    );
  }
}
