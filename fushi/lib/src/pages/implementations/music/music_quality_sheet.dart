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
import 'package:fushi/src/pages/implementations/music/music_signal_path_panel.dart'
    show musicSourceLabel;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
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
    adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext _) => MusicQualitySheet(appModel: appModel),
    );

/// 播放器信息行里的音质胶囊：显示这首当前按哪一档取流，点开 [showMusicQualitySheet]。
/// 不是插件曲目时不占位。
class MusicQualityChip extends StatelessWidget {
  const MusicQualityChip({
    required this.appModel,
    required this.item,
    super.key,
  });

  final AppModel appModel;
  final MusicPlayItem? item;

  @override
  Widget build(BuildContext context) {
    final MusicPlayItem? it = item;
    if (it == null || !musicItemQualitySelectable(it)) {
      return const SizedBox.shrink();
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String label = musicPluginQualityLabel(
      appModel.musicPluginQualityFor(it.path),
    );
    return Semantics(
      button: true,
      label: t.music_quality_chip_semantics(quality: label),
      excludeSemantics: true,
      child: FushiPressScale(
        child: Material(
          key: const ValueKey<String>('music_quality_chip'),
          color: cs.secondaryContainer,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => unawaited(showMusicQualitySheet(context, appModel)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32, minWidth: 48),
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      label,
                      style: context.fushiType.labelLarge.copyWith(
                        color: cs.onSecondaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Icon(
                      FushiIcons.expandMore,
                      size: 18,
                      color: cs.onSecondaryContainer,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
    final List<Widget> rows = <Widget>[
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(24, 4, 24, 4),
        child: Text(
          t.music_quality_title,
          style: context.fushiType.titleLarge.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      for (final MusicPluginQuality q in MusicPluginQuality.values)
        FushiListTileControl(
          key: ValueKey<String>('music_quality_${q.wire}'),
          selected: q == selected,
          enabled: path != null,
          leading: Icon(
            q == selected ? FushiIcons.check : FushiIcons.radioUnchecked,
          ),
          title: Text(musicPluginQualityLabel(q)),
          subtitle: Text(musicPluginQualityHint(q)),
          onTap: path == null || q == selected
              ? null
              : () => unawaited(_pick(path, q)),
        ),
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(24, 12, 24, 0),
        child: Text(
          t.music_quality_current_stream,
          style: context.fushiType.labelLarge.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(24, 4, 24, 8),
        child: Text(
          stream,
          key: const ValueKey<String>('music_quality_stream'),
          style: context.fushiType.bodyLarge,
        ),
      ),
      FushiListTileControl(
        key: const ValueKey<String>('music_quality_set_default'),
        title: Text(t.music_quality_set_default),
        subtitle: Text(t.music_quality_set_default_hint),
        trailing: adaptiveSwitch(
          context: context,
          value: _setDefault,
          onChanged: (bool v) => setState(() => _setDefault = v),
        ),
        onTap: () => setState(() => _setDefault = !_setDefault),
      ),
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(24, 4, 24, 16),
        child: Text(
          t.music_quality_note,
          style: context.fushiType.bodySmall.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ),
    ];
    return SafeArea(
      child: SingleChildScrollView(
        child: FushiEntranceScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < rows.length; i++)
                FushiStaggeredEntrance(index: i, child: rows[i]),
            ],
          ),
        ),
      ),
    );
  }
}
