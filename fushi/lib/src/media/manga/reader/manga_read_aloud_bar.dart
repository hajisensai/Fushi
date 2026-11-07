/// 漫画朗读时的浮动播放条：状态行 + 纯图标悬浮工具栏（上一句 / 暂停·继续 /
/// 下一句 / 倍速 / 声音 / 停止），倍速展开一行拖动条。
///
/// 工具栏复用共享的 [FushiFloatingToolbar]（MD3 / Apple 两套、48dp 纯图标、
/// tooltip 与 Semantics 齐全、按压缩放）；状态行与倍速行画在 [MangaChromeSurface]
/// 上，展开 / 收起走 [FushiAnimatedSize] + [FushiMotion]。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_speed_slider.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/media/manga/reader/manga_read_aloud_controller.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 拿不到文字的原因 → 现有文案。
String mangaReadAloudTextProblemText(MangaPageTextUnavailableReason reason) =>
    switch (reason) {
      MangaPageTextUnavailableReason.noEngine => t.manga_reader_ocr_unavailable,
      MangaPageTextUnavailableReason.chapterOcrDisabled =>
        t.manga_chapter_not_downloaded,
      MangaPageTextUnavailableReason.lensDeclined ||
      MangaPageTextUnavailableReason.cancelled ||
      MangaPageTextUnavailableReason.failed =>
        t.manga_read_aloud_ocr_unavailable,
    };

/// 播放条状态行：正在读的句子原文，或等待 / 暂停 / 失败 / 读完的说明。
String mangaReadAloudStatusText(MangaReadAloudController c) {
  final String? sentence = c.currentUtterance?.displayText;
  return switch (c.state) {
    MangaReadAloudState.idle => '',
    MangaReadAloudState.preparingText => t.manga_read_aloud_waiting_ocr,
    MangaReadAloudState.synthesizing => sentence ?? t.audiobook_tts_preparing,
    MangaReadAloudState.playing => sentence ?? '',
    MangaReadAloudState.paused =>
      sentence == null ? t.pause : '${t.pause} · $sentence',
    MangaReadAloudState.finished =>
      c.finish == MangaReadAloudFinish.noText
          ? t.manga_read_aloud_no_text
          : t.manga_read_aloud_chapter_end,
    MangaReadAloudState.failed => switch (c.problem) {
      MangaReadAloudTextProblem(:final MangaPageTextUnavailableReason reason) =>
        mangaReadAloudTextProblemText(reason),
      MangaReadAloudSynthesisProblem(:final failure) => ttsFailureText(failure),
      null => t.audiobook_tts_start_failed,
    },
  };
}

class MangaReadAloudBar extends StatefulWidget {
  const MangaReadAloudBar({
    super.key,
    required this.controller,
    required this.onVoice,
  });

  final MangaReadAloudController controller;

  /// 声音快速切换（选中即热切换，「朗读声音」项进设置页）。
  final VoidCallback onVoice;

  @override
  State<MangaReadAloudBar> createState() => _MangaReadAloudBarState();
}

class _MangaReadAloudBarState extends State<MangaReadAloudBar> {
  bool _speedOpen = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final MangaReadAloudController c = widget.controller;
    final MangaChromePalette colors = MangaChromePalette.of(context);
    final ThemeData theme = Theme.of(context);
    final MangaReadAloudState state = c.state;
    final bool running =
        state == MangaReadAloudState.playing ||
        state == MangaReadAloudState.synthesizing ||
        state == MangaReadAloudState.preparingText;
    final bool failed = state == MangaReadAloudState.failed;
    final String status = mangaReadAloudStatusText(c);
    final Duration motion = fushiMotionDuration(context, FushiMotion.short);

    final List<FushiToolbarItem> items = <FushiToolbarItem>[
      FushiToolbarItem(
        key: const ValueKey<String>('manga_read_aloud_previous'),
        icon: FushiIcons.skipPrevious,
        label: t.manga_read_aloud_previous,
        onPressed: c.isActive ? c.previous : null,
      ),
      if (running)
        FushiToolbarItem(
          key: const ValueKey<String>('manga_read_aloud_pause'),
          icon: FushiIcons.pause,
          label: t.pause,
          onPressed: c.pause,
        )
      else if (failed)
        FushiToolbarItem(
          key: const ValueKey<String>('manga_read_aloud_retry'),
          icon: FushiIcons.refresh,
          label: t.retry,
          onPressed: c.resume,
        )
      else
        FushiToolbarItem(
          key: const ValueKey<String>('manga_read_aloud_resume'),
          icon: FushiIcons.play,
          label: t.manga_read_aloud_resume,
          onPressed: state == MangaReadAloudState.paused ? c.resume : null,
        ),
      FushiToolbarItem(
        key: const ValueKey<String>('manga_read_aloud_next'),
        icon: FushiIcons.skipNext,
        label: t.manga_read_aloud_next,
        onPressed: c.isActive ? c.next : null,
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('manga_read_aloud_speed'),
        icon: FushiIcons.speed,
        label: t.playback_speed,
        tooltip: '${t.playback_speed} ${AudiobookSpeedSlider.format(c.speed)}',
        selected: _speedOpen,
        onPressed: () => setState(() => _speedOpen = !_speedOpen),
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('manga_read_aloud_voice'),
        icon: FushiIcons.voice,
        label: t.audiobook_tts_voices_section,
        onPressed: widget.onVoice,
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('manga_read_aloud_stop'),
        icon: FushiIcons.stop,
        label: t.manga_read_aloud_stop,
        onPressed: c.stop,
      ),
    ];

    final TextStyle? statusStyle = theme.textTheme.bodyMedium?.copyWith(
      color: failed ? colors.warning : colors.foreground,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kMangaChromeBottomMaxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiAnimatedSize(
            duration: motion,
            curve: FushiMotion.standard,
            alignment: Alignment.bottomCenter,
            child: status.isEmpty && !_speedOpen
                ? const SizedBox(width: double.infinity)
                : FushiHoverLift(
                    builder: (BuildContext context, bool _) => MangaChromeSurface(
                      radius: 20,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            if (status.isNotEmpty)
                              Semantics(
                                liveRegion: true,
                                child: Text(
                                  status,
                                  key: const ValueKey<String>(
                                    'manga_read_aloud_status',
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: statusStyle,
                                ),
                              ),
                            if (_speedOpen)
                              Row(
                                children: <Widget>[
                                  FushiIcon(
                                    FushiIcons.speed,
                                    size: 20,
                                    color: colors.secondaryForeground,
                                  ),
                                  const SizedBox(width: 6),
                                  SizedBox(
                                    width: 52,
                                    child: Text(
                                      AudiobookSpeedSlider.format(c.speed),
                                      style: theme.textTheme.labelLarge
                                          ?.copyWith(
                                            color: colors.foreground,
                                            fontFeatures: const <FontFeature>[
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                    ),
                                  ),
                                  Expanded(
                                    child: AudiobookSpeedSlider(
                                      key: const ValueKey<String>(
                                        'manga_read_aloud_speed_slider',
                                      ),
                                      speed: c.speed,
                                      onChanged: (double v) => c.setSpeed(v),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          KeyedSubtree(
            key: const ValueKey<String>('manga_read_aloud_bar'),
            child: FushiFloatingToolbar(
              groups: <List<FushiToolbarItem>>[items],
            ),
          ),
        ],
      ),
    );
  }
}
