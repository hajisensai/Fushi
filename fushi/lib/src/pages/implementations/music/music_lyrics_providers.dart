/// 设置 › 音乐 › 歌词来源（docs/specs/2026-10-30-lyrics-plugins.md §6）：内置的 LRCLIB 与已装
/// 歌词插件同在一份可排序、可启停的列表里（LRCLIB 不可卸载），列表顺序即查询顺序。
library;

import 'dart:async';

import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/lyrics_provider_list.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_settings.dart';
import 'package:fushi/src/settings/settings_kit_core.dart'
    show SettingsEmptyState;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

class MusicLyricsProvidersBody extends StatefulWidget {
  const MusicLyricsProvidersBody({
    super.key,
    required this.appModel,
    this.canInstall = true,
  });

  final AppModel appModel;

  /// 本机能装插件（[isMusicPluginSourcesAvailable]）。经互联中继用 host 插件的设备（iOS）
  /// 只能启停 / 排序，不出安装入口。
  final bool canInstall;

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

  /// 歌词插件可能由本页按钮装上，也可能由外层页面的拖放落点（[MusicPluginDropTarget]）
  /// 装上：一律经 [MusicPluginManager.changes] 刷新。
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = _manager.changes.listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
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
      _entries = mergeLyricsSourceList(
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
    await pickAndInstallMusicPlugin(context, _manager);
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
          if (entries == null)
            const FushiLinearProgressIndicator()
          else
            FushiReorderableColumn(
              itemCount: entries.length,
              spacing: tokens.spacing.gap,
              keyForIndex: (int i) =>
                  ValueKey<String>('music-lyrics-provider-${entries[i].id}'),
              onReorder: _move,
              itemBuilder: (BuildContext context, int i) =>
                  FushiStaggeredEntrance(
                    index: i,
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
          // 列表里只有内置的 LRCLIB：空态说明 + 安装入口。
          if (entries != null && !_hasPlugins(entries))
            FushiStaggeredEntrance(
              index: entries.length,
              child: SettingsEmptyState(
                icon: FushiIcons.browserExtension,
                title: t.music_lyrics_providers_empty,
                message: t.music_lyrics_providers_empty_hint,
                action: !widget.canInstall
                    ? null
                    : FushiPressScale(
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
            ),
          // 已有插件时也能再装：与空态同一条安装流程。
          if (widget.canInstall && entries != null && _hasPlugins(entries))
            FushiStaggeredEntrance(
              index: entries.length,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FushiPressScale(
                  child: FushiOutlinedButton.icon(
                    key: const ValueKey<String>(
                      'music_lyrics_provider_install_more',
                    ),
                    onPressed: () => unawaited(_install()),
                    icon: const FushiIcon(FushiIcons.importFile),
                    label: Text(t.music_lyrics_providers_install_action),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 列表里除内置 LRCLIB 外还有没有歌词插件。
bool _hasPlugins(List<LyricsProviderEntry> entries) =>
    entries.any((LyricsProviderEntry e) => e.id != MusicLyricsSource.lrclib);

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
    final bool builtIn = entry.id == MusicLyricsSource.lrclib;
    return Row(
      children: <Widget>[
        const FushiIcon(FushiIcons.dragHandle, size: 20),
        Expanded(
          child: AdaptiveSettingsSwitchRow(
            icon: builtIn ? FushiIcons.lyrics : FushiIcons.browserExtension,
            showIcon: true,
            title: builtIn ? 'LRCLIB' : m?.name ?? entry.id,
            subtitle: builtIn
                ? t.music_lyrics_providers_builtin_note
                : m == null
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
