import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/src/media/video/video_orientation_policy.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;

/// 竖屏学习版式下半屏的页签（拍板台 P9AS-fvjJh 设计图 B）。
enum VideoPortraitTab { subtitles, episodes, chapters, chat }

/// 页签描述：页面层按当前视频有没有选集 / 章节决定给哪几个。
class VideoPortraitTabSpec {
  const VideoPortraitTabSpec({
    required this.tab,
    required this.icon,
    required this.label,
    required this.builder,
  });

  final VideoPortraitTab tab;
  final IconData icon;
  final String label;

  /// 页签内容。[insets] 是内容要让出的边距（顶部安全区 / 底部浮动工具栏 + 底部安全区），
  /// 列表类内容应把它当作滚动区的内边距，让最后一行能滚到工具栏上方。
  final Widget Function(BuildContext context, EdgeInsets insets) builder;
}

/// 竖屏学习版式（拍板台 P9AS-fvjJh 设计图 A / B，平板分栏见第 6 点）。
///
/// * [VideoPortraitLayoutKind.stacked]（手机）：视频按比例贴顶（控件只盖在这一条上），
///   下面是当前句大字、页签面板，底部一条纯图标浮动工具栏。
/// * [VideoPortraitLayoutKind.split]（平板竖屏，宽 ≥ 600dp）：左边视频 + 当前句 + 工具栏，
///   右边页签面板。
///
/// 只管几何与进场动效；内容全由页面层传入（视频 / 当前句 / 页签 / 工具栏），这里不碰
/// 播放器。视频条高度与页面层算查词卡停靠位置用同一个 [videoPortraitVideoBottom]。
class VideoPortraitLayout extends StatelessWidget {
  const VideoPortraitLayout({
    required this.kind,
    required this.video,
    required this.currentCue,
    required this.pane,
    required this.toolbar,
    this.videoAspectRatio,
    super.key,
  }) : assert(kind != VideoPortraitLayoutKind.none);

  final VideoPortraitLayoutKind kind;
  final Widget video;
  final double? videoAspectRatio;

  /// 当前句大字（[VideoPortraitCurrentCue]）。
  final Widget currentCue;

  /// 页签面板（[VideoPortraitPane]），收到的边距由本组件决定。
  final Widget Function(EdgeInsets insets) pane;

  /// 底部浮动工具栏。
  final Widget toolbar;

  /// 浮动工具栏占的高度（含上下留白），页签内容据此让位。
  static const double toolbarReserve = 76;

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final EdgeInsets padding = MediaQuery.paddingOf(context);
    final double videoBottom = videoPortraitVideoBottom(
      kind: kind,
      screen: screen,
      topInset: padding.top,
      videoAspectRatio: videoAspectRatio,
    );
    final Widget strip = ColoredBox(
      key: const ValueKey<String>('video-portrait-strip'),
      color: Colors.black,
      child: Padding(
        padding: EdgeInsets.only(top: padding.top),
        child: SizedBox(
          height: videoBottom - padding.top,
          width: double.infinity,
          child: video,
        ),
      ),
    );
    final Widget floatingToolbar = Padding(
      padding: EdgeInsets.only(bottom: padding.bottom + 12),
      child: Center(child: toolbar),
    );
    final Color surface = Theme.of(context).colorScheme.surface;
    return FushiEntranceScope(
      child: ColoredBox(
        color: surface,
        child: switch (kind) {
          VideoPortraitLayoutKind.split => Row(
            key: const ValueKey<String>('video-portrait-split'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    strip,
                    Expanded(
                      child: FushiStaggeredEntrance(
                        index: 0,
                        child: SingleChildScrollView(child: currentCue),
                      ),
                    ),
                    FushiStaggeredEntrance(index: 2, child: floatingToolbar),
                  ],
                ),
              ),
              SizedBox(
                width: videoPortraitSplitPaneWidth(screen.width),
                child: FushiStaggeredEntrance(
                  index: 1,
                  child: pane(
                    EdgeInsets.only(top: padding.top, bottom: padding.bottom),
                  ),
                ),
              ),
            ],
          ),
          _ => Column(
            key: const ValueKey<String>('video-portrait-stacked'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              strip,
              FushiStaggeredEntrance(index: 0, child: currentCue),
              Expanded(
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: FushiStaggeredEntrance(
                        index: 1,
                        child: pane(
                          EdgeInsets.only(
                            bottom: padding.bottom + toolbarReserve,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: FushiStaggeredEntrance(
                        index: 2,
                        child: floatingToolbar,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        },
      ),
    );
  }
}

/// 当前句大字（设计图 A）：跟着播放走，点字从该字起查词（与字幕列表行同一套逐字命中
/// [SubtitleTranscriptText]），点空白跳回本句开头。没有当前句时显示 [emptyHint]。
class VideoPortraitCurrentCue extends StatelessWidget {
  const VideoPortraitCurrentCue({
    required this.listenable,
    required this.currentCue,
    required this.onLookup,
    required this.onTapCue,
    required this.emptyHint,
    this.fontFamily,
    this.fontSize = 22,
    super.key,
  });

  /// 当前句变化时通知（页面层传播放器）。
  final Listenable listenable;
  final AudioCue? Function() currentCue;
  final void Function(AudioCue cue, int graphemeIndex, Rect anchor) onLookup;
  final void Function(AudioCue cue) onTapCue;
  final String emptyHint;
  final String? fontFamily;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: listenable,
      builder: (BuildContext context, Widget? _) {
        final AudioCue? cue = currentCue();
        final String text = cue?.text.trim() ?? '';
        final AudioCue? shown = text.isEmpty ? null : cue;
        final Key contentKey = shown == null
            ? const ValueKey<String>('video-portrait-cue-empty')
            : ValueKey<String>('video-portrait-cue-${shown.startMs}');
        final Widget content = shown == null
            ? Text(
                emptyHint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : SubtitleTranscriptText(
                text: text,
                style: TextStyle(
                  fontSize: fontSize,
                  height: 1.45,
                  fontFamily: fontFamily,
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
                onLookup: (int index, Rect anchor) =>
                    onLookup(shown, index, anchor),
                onBackgroundTap: () => onTapCue(shown),
              );
        return Padding(
          key: const ValueKey<String>('video-portrait-current-cue'),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: FushiAnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.short),
              switchInCurve: FushiMotion.enter,
              switchOutCurve: FushiMotion.exit,
              layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
                alignment: Alignment.topLeft,
                children: <Widget>[...previous, if (current != null) current],
              ),
              child: Align(
                key: contentKey,
                alignment: Alignment.topLeft,
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 页签面板（设计图 B）：顶上一排分段页签（[adaptiveSegmentedButton]，M3E 胶囊 / Apple
/// 分段同源）+ 可选的尾部动作，下面是当前页签内容，切换时交叉淡入。
class VideoPortraitPane extends StatelessWidget {
  const VideoPortraitPane({
    required this.tabs,
    required this.selected,
    required this.onSelect,
    required this.insets,
    this.trailing = const <Widget>[],
    super.key,
  });

  final List<VideoPortraitTabSpec> tabs;
  final ValueListenable<VideoPortraitTab> selected;
  final ValueChanged<VideoPortraitTab> onSelect;
  final EdgeInsets insets;

  /// 页签行尾部的动作（如待制卡列表入口）。
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPortraitTab>(
      valueListenable: selected,
      builder: (BuildContext context, VideoPortraitTab value, Widget? _) {
        final VideoPortraitTabSpec spec = tabs.firstWhere(
          (VideoPortraitTabSpec s) => s.tab == value,
          orElse: () => tabs.first,
        );
        return Padding(
          padding: EdgeInsets.only(top: insets.top),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (tabs.length > 1 || trailing.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Row(
                    children: <Widget>[
                      if (tabs.length > 1)
                        Expanded(
                          child: adaptiveSegmentedButton<VideoPortraitTab>(
                            context: context,
                            segments: <ButtonSegment<VideoPortraitTab>>[
                              for (final VideoPortraitTabSpec s in tabs)
                                ButtonSegment<VideoPortraitTab>(
                                  value: s.tab,
                                  icon: Icon(s.icon),
                                  label: Text(
                                    s.label,
                                    key: ValueKey<String>(
                                      'video-portrait-tab-${s.tab.name}',
                                    ),
                                  ),
                                ),
                            ],
                            selected: <VideoPortraitTab>{spec.tab},
                            onSelectionChanged: (Set<VideoPortraitTab> next) {
                              if (next.isNotEmpty) onSelect(next.first);
                            },
                          ),
                        )
                      else
                        const Spacer(),
                      ...trailing,
                    ],
                  ),
                ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: fushiMotionDuration(context, FushiMotion.medium),
                  switchInCurve: FushiMotion.enter,
                  switchOutCurve: FushiMotion.exit,
                  child: KeyedSubtree(
                    key: ValueKey<String>(
                      'video-portrait-pane-${spec.tab.name}',
                    ),
                    child: spec.builder(
                      context,
                      EdgeInsets.only(bottom: insets.bottom),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 竖屏学习版式底部的纯图标浮动工具栏（设计图 A）：文字只进 tooltip 与 Semantics，
/// 命中区由 [FushiFloatingToolbar] 保证 ≥ 48dp。
Widget videoPortraitToolbar({required List<FushiToolbarItem> items}) {
  return FushiFloatingToolbar(
    key: const ValueKey<String>('video-portrait-toolbar'),
    groups: <List<FushiToolbarItem>>[items],
  );
}
