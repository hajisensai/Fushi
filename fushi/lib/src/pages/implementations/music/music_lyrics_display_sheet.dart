/// 歌词显示快切：翻译（双语 / 单语）、罗马音、注音三个副行开关。
///
/// 渲染层（[KaraokeLyricsAppearance]）早就支持三者分开显示，这里补上入口：播放页顶栏
/// 「歌词显示」打开，设置 › 音乐里也有同样三项。开关是设备本地观感偏好（[AppModel]
/// `musicLyricsShow*`），改了歌词页 / MV 页即时生效。当前这首歌词没有某一类数据（例如
/// LRC 没翻译、源没带注音轨）时那一项置灰并说明原因——注音只来自歌词源自带的 ruby
/// （QRC 注音轨 / ASS / TTML），不在这里现算。
library;

import 'dart:async';

import 'package:fushi_music/fushi_music.dart'
    show LyricLine, LyricSyllable, LyricTimeline;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_floating_panel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 一首歌词实际带了哪些副行数据（决定开关是否可用）。
@immutable
class MusicLyricsExtras {
  const MusicLyricsExtras({
    required this.translation,
    required this.romanization,
    required this.ruby,
  });

  /// 扫一遍时间轴：任一行有翻译 / 罗马音、任一音节有注音即算有。
  factory MusicLyricsExtras.of(LyricTimeline? timeline) {
    bool translation = false;
    bool romanization = false;
    bool ruby = false;
    for (final LyricLine l in timeline?.lines ?? const <LyricLine>[]) {
      translation |= (l.primaryTranslation ?? '').trim().isNotEmpty;
      romanization |= (l.romanization ?? '').trim().isNotEmpty;
      if (!ruby) {
        ruby = l.syllables.any(
          (LyricSyllable s) => (s.ruby ?? '').trim().isNotEmpty,
        );
      }
      if (translation && romanization && ruby) break;
    }
    return MusicLyricsExtras(
      translation: translation,
      romanization: romanization,
      ruby: ruby,
    );
  }

  final bool translation;
  final bool romanization;
  final bool ruby;
}

/// 打开歌词显示快切。
Future<void> showMusicLyricsDisplaySheet(
  BuildContext context, {
  required AppModel appModel,
  required MusicLyricsExtras extras,
}) => showMusicFloatingPanel(
  context: context,
  maxWidth: 480,
  builder: (BuildContext _) =>
      MusicLyricsDisplaySheet(appModel: appModel, extras: extras),
);

class MusicLyricsDisplaySheet extends StatefulWidget {
  const MusicLyricsDisplaySheet({
    required this.appModel,
    required this.extras,
    super.key,
  });

  final AppModel appModel;
  final MusicLyricsExtras extras;

  @override
  State<MusicLyricsDisplaySheet> createState() =>
      _MusicLyricsDisplaySheetState();
}

class _MusicLyricsDisplaySheetState extends State<MusicLyricsDisplaySheet> {
  Future<void> _set(Future<void> Function(bool) setter, bool value) async {
    await setter(value);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppModel app = widget.appModel;
    final MusicLyricsExtras extras = widget.extras;
    final List<Widget> blocks = <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: Text(
              t.music_lyrics_display_title,
              style: context.fushiType.titleLarge.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          FushiIconButtonControl(
            key: const ValueKey<String>('music_lyrics_display_close'),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            icon: const FushiIcon(FushiIcons.close),
            onPressed: () => unawaited(Navigator.of(context).maybePop()),
          ),
        ],
      ),
      _DisplayToggleRow(
        key: const ValueKey<String>('music_lyrics_display_translation'),
        icon: FushiIcons.language,
        title: t.music_lyrics_show_translation_title,
        hint: extras.translation
            ? t.music_lyrics_show_translation_hint
            : t.music_lyrics_show_translation_missing,
        available: extras.translation,
        value: app.musicLyricsShowTranslation,
        onChanged: (bool v) =>
            unawaited(_set(app.setMusicLyricsShowTranslation, v)),
      ),
      _DisplayToggleRow(
        key: const ValueKey<String>('music_lyrics_display_romanization'),
        icon: FushiIcons.textFields,
        title: t.music_lyrics_show_romanization_title,
        hint: extras.romanization
            ? t.music_lyrics_show_romanization_hint
            : t.music_lyrics_show_romanization_missing,
        available: extras.romanization,
        value: app.musicLyricsShowRomanization,
        onChanged: (bool v) =>
            unawaited(_set(app.setMusicLyricsShowRomanization, v)),
      ),
      _DisplayToggleRow(
        key: const ValueKey<String>('music_lyrics_display_ruby'),
        icon: FushiIcons.title,
        title: t.music_lyrics_show_ruby_title,
        hint: extras.ruby
            ? t.music_lyrics_show_ruby_hint
            : t.music_lyrics_show_ruby_missing,
        available: extras.ruby,
        value: app.musicLyricsShowRuby,
        onChanged: (bool v) => unawaited(_set(app.setMusicLyricsShowRuby, v)),
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

/// 图标 + 标题 / 说明 + 开关。当前歌词没有这类数据时整行置灰、开关不可点。
class _DisplayToggleRow extends StatelessWidget {
  const _DisplayToggleRow({
    required this.icon,
    required this.title,
    required this.hint,
    required this.available,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final IconData icon;
  final String title;
  final String hint;
  final bool available;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Opacity(
      opacity: available ? 1 : 0.55,
      child: Row(
        children: <Widget>[
          FushiIcon(icon, color: tokens.surfaces.onVariant),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: context.fushiType.labelLarge),
                Text(
                  hint,
                  style: context.fushiType.bodySmall.copyWith(
                    color: tokens.surfaces.onVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          adaptiveSwitch(
            context: context,
            value: value,
            onChanged: available ? onChanged : null,
          ),
        ],
      ),
    );
  }
}
