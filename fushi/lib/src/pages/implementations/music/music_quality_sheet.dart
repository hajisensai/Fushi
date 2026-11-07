/// 播放器里的音质快切（在线插件曲目）：四档（标准 / 高品 / 无损 / Hi-Res）+ 当前流实际规格
/// + 「设为默认音质」。选了就按新档原位重取（[AppModel.setMusicPluginQuality] /
/// [AppModel.setMusicPluginQualityOverride] → [MusicPlayerEngine.reopenCurrent]），进度与
/// 暂停态不变。插件拿不到所选档时由它给出能提供的最高档，「当前流」一行以 mpv 实际解出的
/// 规格为准（[musicSourceLabel]），不信插件自报。
///
/// 媒体服务器（Jellyfin / Subsonic）的转码码率不在这里：它是服务器凭据旁的设置
/// （设置 › 媒体服务器），与插件音质各管各的。
library;

import 'dart:async';

import 'package:fushi_music/fushi_music.dart' show MusicPluginQuality;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_floating_panel.dart';
import 'package:fushi/src/pages/implementations/music/music_signal_path_panel.dart'
    show musicSourceLabel;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 档位显示名（`Hi-Res` 是通行写法，各语言不译，仍走 i18n 便于个别语言调整）。
String musicPluginQualityLabel(MusicPluginQuality q) => switch (q) {
  MusicPluginQuality.standard => t.music_quality_standard,
  MusicPluginQuality.high => t.music_quality_high,
  MusicPluginQuality.lossless => t.music_quality_lossless,
  MusicPluginQuality.hires => t.music_quality_hires,
};

/// 档位说明一行。
String musicPluginQualityHint(MusicPluginQuality q) => switch (q) {
  MusicPluginQuality.standard => t.music_quality_standard_hint,
  MusicPluginQuality.high => t.music_quality_high_hint,
  MusicPluginQuality.lossless => t.music_quality_lossless_hint,
  MusicPluginQuality.hires => t.music_quality_hires_hint,
};

/// 这一项能在播放器里换音质：在线插件曲目，且插件取流已装配（iOS 商店合规门没过时不装）。
bool musicItemQualitySelectable(MusicPlayItem? item) =>
    item != null &&
    musicPluginPlaybackHost != null &&
    parseMusicPluginTrackPath(item.path) != null;

/// 打开音质快切。
Future<void> showMusicQualitySheet(BuildContext context, AppModel appModel) =>
    showMusicFloatingPanel(
      context: context,
      maxWidth: 640,
      builder: (BuildContext _) => MusicQualitySheet(appModel: appModel),
    );

class MusicQualitySheet extends StatefulWidget {
  const MusicQualitySheet({required this.appModel, super.key});

  final AppModel appModel;

  @override
  State<MusicQualitySheet> createState() => _MusicQualitySheetState();
}

class _MusicQualitySheetState extends State<MusicQualitySheet> {
  MusicSignalPathSnapshot? _snapshot;
  Timer? _refresh;
  bool _setDefault = true;

  MusicPlayerEngine get _engine => widget.appModel.musicSession.engine;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onEngine);
    unawaited(_read());
    // 换档后重取要一会儿：开着时每秒重读一次实际规格。
    _refresh = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_read()),
    );
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _engine.removeListener(_onEngine);
    super.dispose();
  }

  void _onEngine() {
    if (mounted) setState(() {});
  }

  Future<void> _read() async {
    final MusicSignalPathSnapshot? s = await _engine.readSignalPath();
    if (mounted) setState(() => _snapshot = s);
  }

  Future<void> _pick(String path, MusicPluginQuality q) async {
    final AppModel app = widget.appModel;
    if (_setDefault) {
      await app.setMusicPluginQuality(q);
    } else {
      await app.setMusicPluginQualityOverride(path, q);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final MusicPlayItem? item = _engine.current;
    final String? path = musicItemQualitySelectable(item) ? item!.path : null;
    final MusicPluginQuality selected = path == null
        ? widget.appModel.musicPluginQuality
        : widget.appModel.musicPluginQualityFor(path);
    final MusicSignalPathSnapshot? s = _snapshot;
    final String stream = _engine.resolving
        ? t.music_quality_fetching
        : (s == null ? '—' : musicSourceLabel(s));
    final List<Widget> blocks = <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: Text(
              t.music_quality_title,
              style: context.fushiType.titleLarge.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          FushiIconButtonControl(
            key: const ValueKey<String>('music_quality_close'),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            icon: const FushiIcon(FushiIcons.close),
            onPressed: () => unawaited(Navigator.of(context).maybePop()),
          ),
        ],
      ),
      // 四档并排的选择卡：档名 + 一行规格，选中的填色。
      LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final int cols = c.maxWidth >= 480 ? 4 : 2;
          const double gap = 8;
          final double w = (c.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (final MusicPluginQuality q in MusicPluginQuality.values)
                SizedBox(
                  width: w,
                  child: _TierCard(
                    key: ValueKey<String>('music_quality_${q.wire}'),
                    label: musicPluginQualityLabel(q),
                    hint: musicPluginQualityHint(q),
                    selected: q == selected,
                    onTap: path == null || q == selected
                        ? null
                        : () => unawaited(_pick(path, q)),
                  ),
                ),
            ],
          );
        },
      ),
      // 当前流：mpv 实际解出的规格。
      DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: <Widget>[
              Text(
                t.music_quality_current_stream,
                style: context.fushiType.labelMedium.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  stream,
                  key: const ValueKey<String>('music_quality_stream'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: context.fushiType.labelLarge.copyWith(
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      Row(
        key: const ValueKey<String>('music_quality_set_default'),
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.music_quality_set_default,
                  style: context.fushiType.labelLarge,
                ),
                Text(
                  t.music_quality_set_default_hint,
                  style: context.fushiType.bodySmall.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          adaptiveSwitch(
            context: context,
            value: _setDefault,
            onChanged: (bool v) => setState(() => _setDefault = v),
          ),
        ],
      ),
      Text(
        t.music_quality_note,
        style: context.fushiType.bodySmall.copyWith(color: cs.onSurfaceVariant),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 16, 20),
      child: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: <Widget>[
            for (int i = 0; i < blocks.length; i++)
              FushiStaggeredEntrance(index: i, child: blocks[i]),
          ],
        ),
      ),
    );
  }
}

/// 一档：档名（选中带勾）+ 规格，选中填 primaryContainer。
class _TierCard extends StatelessWidget {
  const _TierCard({
    required this.label,
    required this.hint,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final String hint;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color fg = selected ? cs.onPrimaryContainer : cs.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      child: FushiPressScale(
        enabled: onTap != null,
        child: Material(
          color: selected
              ? cs.primaryContainer
              : cs.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.fushiType.titleSmall.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (selected)
                        FushiIcon(FushiIcons.check, size: 18, color: fg),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hint,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.bodySmall.copyWith(
                      color: selected
                          ? cs.onPrimaryContainer
                          : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
