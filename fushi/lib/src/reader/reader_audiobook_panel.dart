/// 有声书侧板内容（2026-10 重设计，用户：「有声书的侧边栏那块也优化一下」）。
///
/// 页头（图标 / 标题 / 当前章 / 关闭）由外壳 [ReaderSideSheet] 画；本组件是 body：
///  * 「正在播放」卡：M3E primaryContainer 饱和色块（Apple 分组卡）——封面、当前句
///    （交叉淡入）、可拖动的全书进度（章节刻度 + 随播放波动的波浪）、大号时间、
///    传输行（中间是形状变形的播放 FAB）、倍速滑块（与歌词模式同款）与跟随键；
///  * 页签「句子 / 章节 / 设置」：句子页列当前章的句子，当前句高亮并自动滚到视野
///    里（手动滚动后 5 秒不抢），点句跳过去；低频的资源（对齐 / 转录 / 导入）收进
///    设置页底部的次级分组。
/// 设置页内容由调用方经 [settingsBuilder] 提供（音量 / 延迟等行的写路径在设置 sheet）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_play_bar.dart'
    show AudiobookFollowAudioButton, AudiobookPlayFab;
import 'package:fushi/src/media/audiobook/audiobook_speed_slider.dart';
import 'package:fushi/src/pages/implementations/reader_fushi/reader_panel_kit.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/reader/ttu_toc_flatten.dart'
    show resolveCurrentTocEntry;
import 'package:fushi/utils.dart';

/// 「信息卡固定 + tab 内容独立滚动」形态所需的最小可用高度（dp）。
///
/// 固定部分在**挂了控制器**时（封面 + 当前句 + 进度条 + 大号时间 + 五颗传输键含
/// 80 的播放 FAB + 倍速 chip 组 + 倍速滑块行 + 标签栏 + 间距）约 520dp；再留
/// ≥128dp 给 tab 视口，才够看见几行章节。低于此高度就得整块面板一起滚——见
/// [readerAudiobookPanelPinsHero]。曾是 440（按没有控制器的空状态卡估的），挂上
/// 真实控制器后 400×460 底部溢出 108px（HBK039）。
const double kReaderAudiobookPanelPinnedMinHeight = 660.0;

/// 给定可用高度下，面板是否还能把信息卡钉住、只让 tab 内容滚。
///
/// 为什么需要这道判据：面板原先恒为「Column(min) + Flexible(tab 滚动区)」。
/// `Flexible` 在高度不够时**不会溢出报错，而是被压到 ~0**——手机横屏（如
/// 768×348dp，bottom sheet 只有 0.9×348≈313dp）下实测 tab 视口只剩 1.2px，
/// `maxScrollExtent` 也近乎 0：标签栏以下的资源 / 章节 / 设置既看不见、也**滚不
/// 出来**，且因为没有 overflow 报错而在测试里毫无痕迹。
bool readerAudiobookPanelPinsHero(double availableHeight) =>
    availableHeight.isFinite &&
    availableHeight >= kReaderAudiobookPanelPinnedMinHeight;

/// 标签页顺序（也是 [ReaderAudiobookPanel.initialTab] 的取值域）。
const List<String> kReaderAudiobookPanelTabs = <String>['chapters', 'settings'];

class ReaderAudiobookPanel extends StatefulWidget {
  const ReaderAudiobookPanel({
    super.key,
    required this.controller,
    required this.toc,
    required this.currentSection,
    this.currentCharOffset,
    required this.onJumpSection,
    required this.title,
    required this.chapterLabel,
    required this.coverPath,
    required this.settingsBuilder,
    this.onAudioImport,
    this.onPickAlignment,
    this.onTranscribe,
    this.cueStudyOffset,
    this.initialTab = 'chapters',
    this.tick = const Duration(seconds: 1),
  });

  final AudiobookPlayerController? controller;
  final List<TtuTocEntry> toc;

  /// 阅读器当前章（用于「当前章节」标注）。
  final int? currentSection;

  /// 当前章内字符偏移（与 [TtuTocEntry.anchorCharOffset] 同尺），未知 null；
  /// 同一 spine 章下靠锚点分节的目录项靠它分清当前是哪一条。
  final int? currentCharOffset;
  final Future<void> Function(int sectionIndex, String? fragment) onJumpSection;
  final String title;
  final String? chapterLabel;

  /// 书籍封面文件路径；null 不显示。
  final String? coverPath;

  /// 「设置」tab 的内容（音量 / 速度 / 延迟 / 播放条开关…）。
  final WidgetBuilder settingsBuilder;

  final VoidCallback? onAudioImport;
  final VoidCallback? onPickAlignment;
  final VoidCallback? onTranscribe;

  /// cue 音频坐标（[SubtitleRematchFragment.normCharStart]）→ 章内学习单位偏移
  /// （与 [TtuTocEntry.anchorCharOffset] 同尺）。阅读器页给出；null / 映射不出时
  /// 退回 cue 自身的 normCharStart。用于「同一 spine 内按锚点分节」的目录项把
  /// 音频定位到锚点处的那句，而不是整个 spine 的首句（HBK040）。
  final int? Function(SubtitleRematchFragment fragment)? cueStudyOffset;

  /// chapters / settings（见 [kReaderAudiobookPanelTabs]）。
  final String initialTab;

  /// 进度条刷新周期（控制器只在 cue 切换 / 播放暂停时 notify，拖动条需要秒级 tick）。
  final Duration tick;

  @override
  State<ReaderAudiobookPanel> createState() => _ReaderAudiobookPanelState();
}

class _ReaderAudiobookPanelState extends State<ReaderAudiobookPanel> {
  late String _tab = kReaderAudiobookPanelTabs.contains(widget.initialTab)
      ? widget.initialTab
      : kReaderAudiobookPanelTabs.first;
  Timer? _ticker;

  /// 拖动整书进度条期间 / 跨文件 seek 落定前本地保留的目标位置（毫秒），避免松手
  /// 后拇指先跳回旧位置再追上。位置追上（±1.5s）或超过 2s 自动放手。
  int? _scrubTargetMs;
  DateTime? _scrubSetAt;

  int? _effectiveScrubMs(Duration livePos) {
    final int? target = _scrubTargetMs;
    final DateTime? at = _scrubSetAt;
    if (target == null || at == null) return null;
    final bool stale = DateTime.now().difference(at).inMilliseconds > 2000;
    final bool caughtUp = (livePos.inMilliseconds - target).abs() < 1500;
    if (stale || caughtUp) {
      _scrubTargetMs = null;
      _scrubSetAt = null;
      return null;
    }
    return target;
  }

  /// 页签切换方向（shared-axis X 的进出方向）：true = 往右边的页签走。
  bool _tabForward = true;

  /// 页签每切一次 +1：AnimatedSwitcher 里同时存活的进/出子树各有独立身份。
  /// 「章节→设置→章节」快速反切时，退出中的章节页与新进的章节页曾共用同一个
  /// tab key、同一个 GlobalKey 和 ScrollController → Duplicate GlobalKey
  /// （HBK045）。现在每次进入都是新的 [_AudiobookChapterList] 实例，滚动与当前
  /// 章 key 都归实例自己持有。
  int _tabSerial = 0;

  /// 侧板路由的进场动画是否已落定。错峰进场在它落定之后才开窗：之前进场窗口从
  /// 面板挂载起算（600ms），恰好和侧板自己的滑入（约 300–400ms）重叠，各卡的
  /// 淡入上移全被「整块滑进来」盖掉，看起来就是静态的（10-06 用户「没有动画」）。
  bool _routeSettled = true;
  Animation<double>? _routeAnimation;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(widget.tick, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Animation<double>? anim = ModalRoute.of(context)?.animation;
    if (identical(anim, _routeAnimation)) return;
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _routeAnimation = anim;
    final bool animating =
        anim != null &&
        anim.status == AnimationStatus.forward &&
        fushiMotionEnabled(context);
    _routeSettled = !animating;
    if (animating) anim.addStatusListener(_onRouteStatus);
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.forward) return;
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    if (mounted && !_routeSettled) {
      setState(() {
        _routeSettled = true;
        // 内容重挂载（进场窗口此刻才开）：章节列表是新实例，会重新把当前章
        // 滚进视野。
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    super.dispose();
  }

  static String _formatDuration(Duration d) => FushiTimeFormat.clockPadded(d);

  /// 目录项 → 音频起点 cue 的记忆（按 cue 列表与目录的身份失效）：带锚点的条目
  /// 要按锚点逐句换算偏移，面板每秒 tick 重建，不能每次重算。
  final Map<int, AudioCue?> _entryCueMemo = <int, AudioCue?>{};
  Object? _entryCueMemoCues;
  Object? _entryCueMemoToc;

  /// 目录第 [i] 项在音频里的起点 cue：无锚点（或锚在章首）= 该 spine 首句；
  /// 有锚点 = 该 spine 里锚点处及之后的第一句（HBK040）。
  AudioCue? _entryStartCue(AudiobookPlayerController ctrl, int i) {
    final List<AudioCue> cues = ctrl.allBookCuesSnapshot;
    if (!identical(cues, _entryCueMemoCues) ||
        !identical(widget.toc, _entryCueMemoToc)) {
      _entryCueMemo.clear();
      _entryCueMemoCues = cues;
      _entryCueMemoToc = widget.toc;
    }
    return _entryCueMemo.putIfAbsent(i, () {
      final TtuTocEntry e = widget.toc[i];
      return ctrl.sectionCueFrom(
        e.index,
        e.charOffsetInChapter,
        offsetOf: widget.cueStudyOffset,
      );
    });
  }

  int? _entryStartMs(AudiobookPlayerController ctrl, int i) {
    final AudioCue? cue = _entryStartCue(ctrl, i);
    return cue == null ? null : ctrl.globalMsOfCue(cue);
  }

  static String _formatMsValue(double ms) =>
      _formatDuration(Duration(milliseconds: ms.round()));

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AudiobookPlayerController? ctrl = widget.controller;
    final Widget tabContent = switch (_tab) {
      'settings' => _buildSettingsTab(theme, ctrl),
      _ => _buildChaptersTab(theme, ctrl),
    };
    final List<Widget> head = <Widget>[
      readerPanelStagger(0, _buildHero(theme, ctrl)),
      const SizedBox(height: 4),
      readerPanelStagger(
        1,
        ReaderPanelTabs<String>(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
          tabs: <ReaderPanelTab<String>>[
            ReaderPanelTab<String>(
              value: 'chapters',
              label: t.reader_audiobook_tab_chapters,
              icon: Icons.format_list_bulleted,
              key: const ValueKey<String>(
                'fushi_audiobook_tab_button_chapters',
              ),
            ),
            ReaderPanelTab<String>(
              value: 'settings',
              label: t.settings,
              icon: Icons.tune_outlined,
              key: const ValueKey<String>(
                'fushi_audiobook_tab_button_settings',
              ),
            ),
          ],
          selected: _tab,
          onChanged: (String id) => setState(() {
            _tabForward =
                kReaderAudiobookPanelTabs.indexOf(id) >=
                kReaderAudiobookPanelTabs.indexOf(_tab);
            if (id != _tab) _tabSerial++;
            _tab = id;
          }),
        ),
      ),
    ];
    final ValueKey<String> tabKey = ValueKey<String>(
      'fushi_audiobook_tab_${_tab}_$_tabSerial',
    );
    // M3E shared-axis X：新页签从前进方向滑入淡入，旧页签朝反方向滑出淡出。
    // 每个页签内容自带一个进场窗口（新挂载的 scope），切过去也有一轮错峰进场——
    // 之前整块共用面板挂载时的那一个窗口，切页签时窗口早已关了，行瞬间出现。
    final Widget body = AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      transitionBuilder: (Widget child, Animation<double> a) {
        final double dir = _tabForward ? 1 : -1;
        final bool incoming = child.key == tabKey;
        return FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset((incoming ? 0.08 : -0.08) * dir, 0),
              end: Offset.zero,
            ).animate(a),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(
        key: tabKey,
        child: FushiEntranceScope(child: tabContent),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 高度够 → 「正在播放」卡钉住、只有页签内容滚；不够 → 整块面板一起滚
          // （手机横屏），否则 Expanded 被压到 ~0，页签以下滚不出来。
          final bool pinned = readerAudiobookPanelPinsHero(
            constraints.maxHeight,
          );
          Widget gate(Widget child) => _routeSettled
              ? KeyedSubtree(
                  key: const ValueKey<String>('fushi_audiobook_settled'),
                  child: child,
                )
              : IgnorePointer(child: Opacity(opacity: 0, child: child));
          if (pinned) {
            return gate(
              FushiEntranceScope(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    ...head,
                    Expanded(child: body),
                  ],
                ),
              ),
            );
          }
          final Widget column = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ...head,
              SizedBox(
                height: math.max(320, constraints.maxHeight * 0.8),
                child: body,
              ),
            ],
          );
          if (!constraints.maxHeight.isFinite) return gate(column);
          return SingleChildScrollView(
            key: ValueKey<String>('fushi_audiobook_scroll_$_tab'),
            primary: false,
            child: gate(FushiEntranceScope(child: column)),
          );
        },
      ),
    );
  }

  /// 「正在播放」卡：M3E primaryContainer 饱和色块（Apple 分组卡）——封面 + 当前句
  /// + 全书进度（可拖动，章节刻度）+ 大号时间 + 传输行（形状变形播放 FAB）+ 倍速与
  /// 跟随。没挂控制器时只给导入入口。
  Widget _buildHero(ThemeData theme, AudiobookPlayerController? ctrl) {
    const ReaderPanelCardTone tone = ReaderPanelCardTone.emphasis;
    final Color fg = ReaderPanelCard.foregroundFor(context, tone);
    final String? coverPath = widget.coverPath;
    if (ctrl == null) {
      return ReaderPanelCard(
        tone: tone,
        child: ReaderPanelEmpty(
          icon: FushiIcons.audiobook,
          message: widget.title.isEmpty
              ? t.reader_audiobook_empty_hint
              : '${widget.title}\n${t.reader_audiobook_empty_hint}',
          actionLabel: widget.onAudioImport == null ? null : t.audio_import,
          onAction: widget.onAudioImport == null
              ? null
              : () {
                  Navigator.of(context).pop();
                  widget.onAudioImport!();
                },
        ),
      );
    }
    final String cueText = ctrl.currentCue?.text.trim() ?? '';
    return ReaderPanelCard(
      key: const ValueKey<String>('fushi_audiobook_now_playing'),
      tone: tone,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (coverPath != null) ...<Widget>[
                // M3E 大封面：大圆角 + 两层投影把它从色块里托起来；Apple 小圆角。
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(
                      Radius.circular(isGlassDesign(context) ? 10 : 20),
                    ),
                    boxShadow: isGlassDesign(context)
                        ? const <BoxShadow>[]
                        : <BoxShadow>[
                            BoxShadow(
                              color: theme.colorScheme.shadow.withValues(
                                alpha: 0.28,
                              ),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.all(
                      Radius.circular(isGlassDesign(context) ? 10 : 20),
                    ),
                    child: Image.file(
                      File(coverPath),
                      key: const ValueKey<String>('fushi_audiobook_cover'),
                      width: 92,
                      height: 128,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const SizedBox(width: 92, height: 128),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      t.reader_audiobook_now_playing,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: fg.withValues(alpha: 0.75),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if ((widget.chapterLabel ?? '').trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          widget.chapterLabel!.trim(),
                          key: const ValueKey<String>(
                            'fushi_audiobook_hero_chapter',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: fg.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    const SizedBox(height: 4),
                    AnimatedSwitcher(
                      duration: fushiMotionDuration(context, FushiMotion.short),
                      switchInCurve: FushiMotion.enter,
                      switchOutCurve: FushiMotion.exit,
                      layoutBuilder: (Widget? current, List<Widget> previous) =>
                          Stack(
                            alignment: AlignmentDirectional.topStart,
                            children: <Widget>[
                              ...previous,
                              if (current != null) current,
                            ],
                          ),
                      child: Text(
                        cueText.isEmpty ? widget.title : cueText,
                        key: ValueKey<String>('fushi_audiobook_cue_$cueText'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildTransport(theme, ctrl, fg),
        ],
      ),
    );
  }

  /// **全书**进度条（[AudiobookPlayerController.globalPosition] /
  /// [AudiobookPlayerController.totalDuration]，拖动经 `seekGlobalMs` 跨文件定位，
  /// 松手才 seek）+ 大号当前时间 / 总时长 + 「-10s / 上一句 / 播放 / 下一句 / +10s」
  /// + 倍速 / 跟随。
  Widget _buildTransport(
    ThemeData theme,
    AudiobookPlayerController ctrl,
    Color fg,
  ) {
    final bool glass = isGlassDesign(context);
    final Duration livePos = ctrl.globalPosition;
    final Duration dur = ctrl.totalDuration;
    final int durMs = dur.inMilliseconds;
    final int? scrub = _effectiveScrubMs(livePos);
    final Duration pos = scrub == null
        ? livePos
        : Duration(milliseconds: scrub);
    final double value = durMs > 0
        ? (pos.inMilliseconds / durMs).clamp(0.0, 1.0)
        : 0.0;
    final List<double> ticks = <double>[
      if (durMs > 0)
        for (int i = 0; i < widget.toc.length; i++)
          if (_entryStartMs(ctrl, i) case final int ms
              when ms > 0 && ms < durMs)
            ms / durMs,
    ];
    final ButtonStyle flat = IconButton.styleFrom(foregroundColor: fg);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // M3E：粗轨道滑块（S 档 24，竖条把手、按下变窄、拖动时时间气泡），章节刻度
        // 画在同一条轨道上；Apple 保持细轨道 iOS 滑块。
        Builder(
          builder: (BuildContext context) {
            final SliderThemeData base = SliderTheme.of(context);
            final SliderThemeData data = glass
                ? base.copyWith(
                    trackHeight: 3,
                    trackShape: ReaderAudiobookChapterTrackShape(
                      fractions: ticks,
                      tickColor: fg.withValues(alpha: 0.55),
                    ),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                  )
                : fushiSliderSizeTheme(
                    base.copyWith(
                      activeTrackColor: fg,
                      inactiveTrackColor: fg.withValues(alpha: 0.22),
                      thumbColor: fg,
                      valueIndicatorColor: theme.colorScheme.inverseSurface,
                      trackShape: ReaderAudiobookChapterTrackShape(
                        fractions: ticks,
                        tickColor: theme.colorScheme.primaryContainer
                            .withValues(alpha: 0.9),
                        inner: const GappedSliderTrackShape(),
                      ),
                      thumbShape: const HandleThumbShape(),
                      showValueIndicator: ShowValueIndicator.onDrag,
                    ),
                    FushiSliderSize.s,
                  );
            return SliderTheme(
              data: data,
              child: FushiSlider(
                key: const ValueKey<String>('fushi_audiobook_panel_slider'),
                value: value,
                ticks: ticks,
                year2023: glass ? null : false,
                label: _formatDuration(pos),
                onChangeStart: durMs > 0
                    ? (double v) => setState(() {
                        _scrubTargetMs = (v * durMs).round();
                        _scrubSetAt = DateTime.now();
                      })
                    : null,
                onChanged: durMs > 0
                    ? (double v) => setState(() {
                        _scrubTargetMs = (v * durMs).round();
                        _scrubSetAt = DateTime.now();
                      })
                    : null,
                onChangeEnd: durMs > 0
                    ? (double v) {
                        final int target = (v * durMs).round();
                        setState(() {
                          _scrubTargetMs = target;
                          _scrubSetAt = DateTime.now();
                        });
                        unawaited(ctrl.seekGlobalMs(target));
                      }
                    : null,
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              // 窄面板（320）里大号时间按比例缩小，不把右侧剩余时间挤出去（HBK039）。
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.bottomStart,
                  child: ReaderStatNumber(
                    key: const ValueKey<String>('fushi_audiobook_time'),
                    value: _formatDuration(pos),
                    color: fg,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 右端：剩余（-m:ss，按原速）在上、总时长在下。
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _RollingText(
                    key: const ValueKey<String>('fushi_audiobook_remaining'),
                    text:
                        '-${_formatDuration(dur > pos ? dur - pos : Duration.zero)}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                  Text(
                    _formatDuration(dur),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: fg.withValues(alpha: 0.7),
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // 五颗传输键（含 80 的播放 FAB）自然宽约 300：窄面板里整排等比缩小，
        // 不溢出、不丢键（HBK039）。
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIconButtonControl(
                tooltip: '-10s',
                style: flat,
                icon: const FushiIcon(Icons.replay_10_rounded),
                onPressed: () => unawaited(ctrl.seekRelative(-10)),
              ),
              FushiIconButtonControl(
                tooltip: t.prev_sentence,
                style: flat,
                iconSize: 36,
                icon: const FushiIcon(Icons.skip_previous_rounded),
                onPressed: () => unawaited(ctrl.skipToPrevCue()),
              ),
              const SizedBox(width: 6),
              KeyedSubtree(
                key: const ValueKey<String>('fushi_audiobook_panel_play'),
                child: FushiPressScale(
                  scale: 0.92,
                  child: AudiobookPlayFab(controller: ctrl, size: 80),
                ),
              ),
              const SizedBox(width: 6),
              FushiIconButtonControl(
                tooltip: t.next_sentence,
                style: flat,
                iconSize: 36,
                icon: const FushiIcon(Icons.skip_next_rounded),
                onPressed: () => unawaited(ctrl.skipToNextCue()),
              ),
              FushiIconButtonControl(
                tooltip: '+10s',
                style: flat,
                icon: const FushiIcon(Icons.forward_10_rounded),
                onPressed: () => unawaited(ctrl.seekRelative(10)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // 倍速预设 chip 组（M3E），下面一行是同款自定义拖动条；睡眠定时 chip。
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            for (final double v in kReaderAudiobookSpeedPresets)
              FushiPressScale(
                child: FushiChoiceChip(
                  key: ValueKey<String>('fushi_audiobook_speed_$v'),
                  label: Text(AudiobookSpeedSlider.format(v)),
                  selected: (ctrl.speed - v).abs() < 0.01,
                  showCheckmark: false,
                  onSelected: (_) {
                    unawaited(ctrl.setSpeed(v));
                    setState(() {});
                  },
                ),
              ),
            FushiPressScale(child: _SleepTimerChip(controller: ctrl)),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            FushiIcon(Icons.speed_rounded, color: fg, size: 20),
            const SizedBox(width: 6),
            SizedBox(
              width: 52,
              child: Text(
                AudiobookSpeedSlider.format(ctrl.speed),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
            Expanded(
              child: AudiobookSpeedSlider(
                key: const ValueKey<String>('fushi_audiobook_panel_speed'),
                speed: ctrl.speed,
                onChanged: (double v) {
                  unawaited(ctrl.setSpeed(v));
                  setState(() {});
                },
              ),
            ),
            AudiobookFollowAudioButton(controller: ctrl, foregroundColor: fg),
          ],
        ),
      ],
    );
  }

  /// 「设置」页：音量 / 速度 / 延迟等（调用方提供），底部次级分组收低频的资源操作
  /// （音频文件、对齐文件、转录、导入音频）。
  Widget _buildSettingsTab(ThemeData theme, AudiobookPlayerController? ctrl) {
    return ListView(
      key: const ValueKey<String>('fushi_audiobook_settings_list'),
      primary: false,
      children: <Widget>[widget.settingsBuilder(context)],
    );
  }

  /// 「对齐与转录」卡：对齐文件（当前文件名 / 未选）+ 音频文件数，下面一排 tonal
  /// 按钮是低频的资源操作（重新选对齐文件 / 设备转录 / 导入音频），多文件时再列出
  /// 各文件名。只读控制器已有的数据，操作都是调用方原有的回调。
  Widget _buildSourceCard(ThemeData theme, AudiobookPlayerController? ctrl) {
    final List<File> files = ctrl?.audioFiles ?? const <File>[];
    final String? alignmentPath = ctrl?.audiobook?.alignmentPath;
    final String? alignmentName = alignmentPath == null || alignmentPath.isEmpty
        ? null
        : p.basename(alignmentPath);
    void closeThen(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    final Color fg = ReaderPanelCard.foregroundFor(
      context,
      ReaderPanelCardTone.neutral,
    );
    final List<Widget> actions = <Widget>[
      if (widget.onPickAlignment != null)
        FushiFilledButton.tonalIcon(
          key: const ValueKey<String>('fushi_audiobook_panel_alignment'),
          size: FushiButtonSize.xs,
          onPressed: () => closeThen(widget.onPickAlignment!),
          icon: const FushiIcon(FushiIcons.alignLeft, size: 18),
          label: Text(t.audiobook_pick_alignment),
        ),
      if (widget.onTranscribe != null)
        FushiFilledButton.tonalIcon(
          key: const ValueKey<String>('fushi_audiobook_panel_transcribe'),
          size: FushiButtonSize.xs,
          onPressed: () => closeThen(widget.onTranscribe!),
          icon: const FushiIcon(FushiIcons.voice, size: 18),
          label: Text(t.audiobook_transcribe_action),
        ),
      if (widget.onAudioImport != null)
        FushiFilledButton.tonalIcon(
          key: const ValueKey<String>('fushi_audiobook_panel_import'),
          size: FushiButtonSize.xs,
          onPressed: () => closeThen(widget.onAudioImport!),
          icon: const FushiIcon(FushiIcons.importFile, size: 18),
          label: Text(t.audio_import),
        ),
    ];
    return ReaderPanelCard(
      key: const ValueKey<String>('fushi_audiobook_source_card'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const ReaderPanelIconBadge(icon: FushiIcons.audio),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      alignmentName ?? t.reader_audiobook_source_no_alignment,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (files.isNotEmpty)
                      Text(
                        t.reader_audiobook_source_audio_files(n: files.length),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: fg.withValues(alpha: 0.7),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (files.length > 1) ...<Widget>[
            const SizedBox(height: 10),
            for (int i = 0; i < files.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 28,
                      child: Text(
                        '${i + 1}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: fg.withValues(alpha: 0.6),
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        p.basename(files[i].path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: fg),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }

  /// 「收听概览」卡：已听百分比 / 按当前倍速的剩余时长 / 本章剩余，并排的大号
  /// 数字（窄于 360 时两列换行）。全部由控制器的全书位置、总时长、倍速与各章
  /// 起点推出来，不新增数据。
  Widget _buildOverviewCard(
    ThemeData theme,
    AudiobookPlayerController ctrl, {
    required int? chapterEndMs,
  }) {
    final int posMs = ctrl.globalPosition.inMilliseconds;
    final int durMs = ctrl.totalDuration.inMilliseconds;
    final double speed = ctrl.speed > 0 ? ctrl.speed : 1.0;
    final int leftMs = durMs > posMs ? ((durMs - posMs) / speed).round() : 0;
    final int? chapterLeftMs = chapterEndMs != null && chapterEndMs > posMs
        ? ((chapterEndMs - posMs) / speed).round()
        : null;
    final List<Widget> stats = <Widget>[
      _OverviewStat(
        key: const ValueKey<String>('fushi_audiobook_overview_listened'),
        icon: FushiIcons.history,
        target: durMs > 0 ? (posMs / durMs * 100).clamp(0, 100).toDouble() : 0,
        format: (double v) => durMs > 0 ? '${v.toStringAsFixed(1)}%' : '—',
        label: t.reader_audiobook_overview_listened,
      ),
      _OverviewStat(
        key: const ValueKey<String>('fushi_audiobook_overview_left'),
        icon: FushiIcons.timer,
        target: leftMs.toDouble(),
        format: _formatMsValue,
        label:
            '${t.reader_audiobook_overview_left} · '
            '${AudiobookSpeedSlider.format(speed)}',
      ),
      if (chapterLeftMs != null)
        _OverviewStat(
          key: const ValueKey<String>('fushi_audiobook_overview_chapter_left'),
          icon: FushiIcons.bulletList,
          target: chapterLeftMs.toDouble(),
          format: _formatMsValue,
          label: t.reader_audiobook_overview_chapter_left,
        ),
    ];
    return ReaderPanelCard(
      key: const ValueKey<String>('fushi_audiobook_overview_card'),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth >= 360) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final Widget w in stats) Expanded(child: w),
              ],
            );
          }
          final double cell = (constraints.maxWidth - 8) / 2;
          return Wrap(
            spacing: 8,
            runSpacing: 14,
            children: <Widget>[
              for (final Widget w in stats) SizedBox(width: cell, child: w),
            ],
          );
        },
      ),
    );
  }

  /// 「章节」页：目录 + 该章首句在全书音频时间轴上的起点；当前章高亮。点击先跳
  /// 阅读器到该章，再把音频定位到该章首句（无 cue 的章只跳文字）。
  Widget _buildChaptersTab(ThemeData theme, AudiobookPlayerController? ctrl) {
    final int currentEntry =
        resolveCurrentTocEntry(
          widget.toc,
          widget.currentSection,
          widget.currentCharOffset,
        ) ??
        -1;
    final int totalMs = ctrl?.totalDuration.inMilliseconds ?? 0;
    final List<int?> starts = <int?>[
      for (int i = 0; i < widget.toc.length; i++)
        if (ctrl == null) null else _entryStartMs(ctrl, i),
    ];
    int? durationFor(int i) {
      final int? start = starts[i];
      if (start == null) return null;
      for (int j = i + 1; j < starts.length; j++) {
        final int? next = starts[j];
        if (next != null && next > start) return next - start;
      }
      return totalMs > start ? totalMs - start : null;
    }

    // 当前章的音频终点（下一章起点 / 全书末）：概览卡的「本章剩余」。
    final int? currentStart = currentEntry >= 0 && currentEntry < starts.length
        ? starts[currentEntry]
        : null;
    final int? currentDur = currentStart == null
        ? null
        : durationFor(currentEntry);
    final int? chapterEndMs = currentStart == null || currentDur == null
        ? null
        : currentStart + currentDur;
    // 章节列表之前是「收听概览」与「音频来源」两张卡（句子列表砍掉后面板显空，
    // 2026-10-06 用户）。它们和章节在同一条滚动里，钉住的只有「正在播放」卡。
    final List<Widget> lead = <Widget>[
      if (ctrl != null) ...<Widget>[
        ReaderPanelSectionLabel(
          t.reader_audiobook_section_overview,
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        ),
        _buildOverviewCard(theme, ctrl, chapterEndMs: chapterEndMs),
      ],
      if (ctrl != null ||
          widget.onPickAlignment != null ||
          widget.onTranscribe != null ||
          widget.onAudioImport != null) ...<Widget>[
        ReaderPanelSectionLabel(t.reader_audiobook_section_tools),
        _buildSourceCard(theme, ctrl),
      ],
      if (widget.toc.isNotEmpty)
        ReaderPanelSectionLabel(
          t.reader_audiobook_tab_chapters,
          trailing: Text(
            '${widget.toc.length}',
            style: theme.textTheme.labelMedium,
          ),
        ),
    ];
    return _AudiobookChapterList(
      currentEntry: currentEntry,
      leadCount: lead.length,
      itemCount: lead.length + widget.toc.length,
      builder:
          (
            BuildContext context,
            ScrollController scroll,
            GlobalKey currentRowKey,
          ) => ListView.builder(
            key: const ValueKey<String>('fushi_audiobook_chapters'),
            controller: scroll,
            itemCount: lead.length + widget.toc.length,
            itemBuilder: fushiStaggeredItemBuilder((
              BuildContext context,
              int index,
            ) {
              if (index < lead.length) return lead[index];
              final int i = index - lead.length;
              final TtuTocEntry entry = widget.toc[i];
              final int? startMs = starts[i];
              final int? dms = durationFor(i);
              final String? subtitle = <String>[
                if (i == currentEntry) t.reader_audiobook_current_chapter,
                if (dms != null) _formatDuration(Duration(milliseconds: dms)),
              ].join(' · ').let((String s) => s.isEmpty ? null : s);
              return ReaderPanelListItem(
                key: i == currentEntry ? currentRowKey : null,
                title: entry.label,
                subtitle: subtitle,
                current: i == currentEntry,
                trailing: Text(
                  startMs == null
                      ? '—'
                      : _formatDuration(Duration(milliseconds: startMs)),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  await widget.onJumpSection(entry.index, entry.fragment);
                  final AudioCue? first = ctrl == null
                      ? null
                      : _entryStartCue(ctrl, i);
                  if (ctrl != null && first != null) {
                    await ctrl.skipToCue(first);
                  }
                },
              );
            }),
          ),
    );
  }
}

/// 章节页的列表：自己持有滚动控制器与当前章行的 GlobalKey，并负责把当前章滚进
/// 视野（偏上 1/3）。每个挂载实例独立，页签切换动画里新旧两份同时存活也不会
/// 共享 GlobalKey / ScrollController（HBK045）。
class _AudiobookChapterList extends StatefulWidget {
  const _AudiobookChapterList({
    required this.currentEntry,
    required this.leadCount,
    required this.itemCount,
    required this.builder,
  });

  /// 当前章在目录里的下标（-1 = 无）。
  final int currentEntry;

  /// 目录行之前的非目录项个数（概览卡等）。
  final int leadCount;

  /// 列表总项数（lead + 目录）。
  final int itemCount;

  final Widget Function(
    BuildContext context,
    ScrollController scroll,
    GlobalKey currentRowKey,
  )
  builder;

  @override
  State<_AudiobookChapterList> createState() => _AudiobookChapterListState();
}

class _AudiobookChapterListState extends State<_AudiobookChapterList> {
  /// 目标行没被懒构建时最多迭代估算几轮；每轮一帧，收敛不了就放手（不无界重试）。
  static const int _maxRevealAttempts = 12;

  final ScrollController _scroll = ScrollController();
  final GlobalKey _currentRowKey = GlobalKey();

  /// 已确实滚进视野的章（-1 = 还没有）。只在目标行真被构建并对齐后才写入，
  /// 估算跳转没找到行时不写（HBK046：之前估算一次就标记完成，长标题 / 大字下
  /// 行高远大于最小行高，跳过去仍差几千像素，之后再也不纠正）。
  int _scrolledEntry = -1;

  /// 正在定位的章；定位进行中 ticker 重建不重复调度。
  int _revealingEntry = -1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scheduleReveal() {
    final int entry = widget.currentEntry;
    if (entry < 0 || entry == _scrolledEntry || entry == _revealingEntry) {
      return;
    }
    _revealingEntry = entry;
    _revealStep(entry, 0);
  }

  void _revealStep(int entry, int attempt) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (entry != widget.currentEntry) {
        // 当前章在定位途中变了：放弃这一轮，交给新章的定位。
        if (_revealingEntry == entry) _revealingEntry = -1;
        _scheduleReveal();
        return;
      }
      final BuildContext? row = _currentRowKey.currentContext;
      if (row != null) {
        _scrolledEntry = entry;
        _revealingEntry = -1;
        unawaited(
          FushiFocusScroll.ensureVisible(
            row,
            alignment: 0.3,
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.standard,
          ),
        );
        return;
      }
      if (attempt >= _maxRevealAttempts || !_scroll.hasClients) {
        _scrolledEntry = entry;
        _revealingEntry = -1;
        return;
      }
      final ScrollPosition pos = _scroll.position;
      final int index = widget.leadCount + entry;
      // 首轮还没有实测行高：按最小行高估（最贴近 lead 卡之后的真实布局下界）。
      // 之后用列表自己的平均项高（maxScrollExtent 是 SliverList 按已布局子项的
      // 平均高度外推的，跳过去后真实行参与平均，逐轮收敛）。
      final int itemCount = widget.itemCount;
      final double average = itemCount <= 0
          ? 0
          : (pos.maxScrollExtent + pos.viewportDimension) / itemCount;
      final double estimate = attempt == 0
          ? widget.leadCount * 120.0 + entry * readerPanelRowMinHeight(context)
          : index * average - pos.viewportDimension * 0.3;
      final double target = estimate.clamp(
        pos.minScrollExtent,
        pos.maxScrollExtent,
      );
      if (attempt > 0 && (target - pos.pixels).abs() < 1) {
        // 估算原地不动却仍看不到目标：再跳也一样，放手。
        _scrolledEntry = entry;
        _revealingEntry = -1;
        return;
      }
      _scroll.jumpTo(target);
      _revealStep(entry, attempt + 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleReveal();
    return widget.builder(context, _scroll, _currentRowKey);
  }
}

/// 全书进度条的轨道：先画默认圆角轨道，再在**同一个 trackRect** 上画章节刻度
/// （每章首句在全书时间轴上的位置）。
///
/// 刻度曾是 slider 下方单独一条 `CustomPaint`，左右硬写 24px 内缩；而 slider 的
/// 轨道内缩是 `max(overlay, thumb) / 2`（本面板 overlayRadius 12 → 12px），两者
/// 对不上，刻度整体被往中间压、离两端越远偏得越多，拇指走到章首时和刻度错开。
/// 非离散 slider 的拇指中心就是 `trackRect.left + value * trackRect.width`，刻度
/// 用同一公式即与进度恒对齐。
class ReaderAudiobookChapterTrackShape extends SliderTrackShape {
  const ReaderAudiobookChapterTrackShape({
    required this.fractions,
    required this.tickColor,
    this.inner = const RoundedRectSliderTrackShape(),
  });

  /// 章首在全书时间轴上的位置（0~1，已去掉两端）。
  final List<double> fractions;
  final Color tickColor;
  final SliderTrackShape inner;

  /// 刻度 x 坐标：与非离散 slider 的拇指中心同一公式。
  static double tickX(Rect trackRect, double fraction, TextDirection dir) {
    final double f = dir == TextDirection.rtl ? 1 - fraction : fraction;
    return trackRect.left + f * trackRect.width;
  }

  @override
  bool get isRounded => inner.isRounded;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) => inner.getPreferredRect(
    parentBox: parentBox,
    offset: offset,
    sliderTheme: sliderTheme,
    isEnabled: isEnabled,
    isDiscrete: isDiscrete,
  );

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    inner.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
      textDirection: textDirection,
    );
    if (fractions.isEmpty) return;
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final double half = trackRect.height / 2 + 3;
    final Paint paint = Paint()
      ..color = tickColor
      ..strokeWidth = 1.5;
    for (final double f in fractions) {
      final double x = tickX(trackRect, f, textDirection);
      context.canvas.drawLine(
        Offset(x, trackRect.center.dy - half),
        Offset(x, trackRect.center.dy + half),
        paint,
      );
    }
  }
}

/// 概览卡里的一格：小图标 + 大号等宽数字（放不下时缩小）+ 说明文字。
class _OverviewStat extends StatelessWidget {
  const _OverviewStat({
    super.key,
    required this.icon,
    required this.target,
    required this.format,
    required this.label,
  });

  final IconData icon;

  /// 数值目标；首次出现从 0 计数到它（count-up），之后变化从当前值补间过去。
  final double target;
  final String Function(double) format;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color fg = ReaderPanelCard.foregroundFor(
      context,
      ReaderPanelCardTone.neutral,
    );
    final Color accent = isGlassDesign(context)
        ? appleColorsOf(context).secondaryLabel
        : theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(icon, size: 18, color: accent),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: target),
              duration: fushiMotionDuration(context, FushiMotion.long * 2),
              curve: FushiMotion.standard,
              builder: (BuildContext context, double v, Widget? _) => Text(
                format(v),
                maxLines: 1,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: fg.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

/// 数字变化时新值自下滚入、旧值向上滚出（剩余时间的「滚动数字」）。减弱动态 /
/// 墨水屏下时长归零，直接换字。
class _RollingText extends StatelessWidget {
  const _RollingText({super.key, required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSwitcher(
        duration: fushiMotionDuration(context, FushiMotion.short),
        switchInCurve: FushiMotion.enter,
        switchOutCurve: FushiMotion.exit,
        layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
          alignment: AlignmentDirectional.centerEnd,
          children: <Widget>[...previous, if (current != null) current],
        ),
        transitionBuilder: (Widget child, Animation<double> a) {
          final bool incoming = child.key == ValueKey<String>(text);
          return FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset(0, incoming ? 0.6 : -0.6),
                end: Offset.zero,
              ).animate(a),
              child: child,
            ),
          );
        },
        child: Text(text, key: ValueKey<String>(text), style: style),
      ),
    );
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

/// 倍速预设（chip 组）。
const List<double> kReaderAudiobookSpeedPresets = <double>[
  0.75,
  1.0,
  1.25,
  1.5,
  2.0,
];

/// 有声书睡眠定时：到点暂停。计时器挂在控制器上（[Expando]），关掉侧板照样走；
/// 换书（换控制器）自然失效。
///
/// 是 [Listenable]：开 / 关 / 到点，以及运行中剩余分钟每跨一分钟都通知一次。
/// 歌词覆盖层只随控制器通知重建，暂停时控制器不再通知，之前睡眠按钮的剩余分钟
/// 提示就停在开定时那一刻；暂停中到点时 `pause()` 也不会再通知，按钮一直亮着
/// 「剩余 1 分钟」。现在覆盖层同时监听它。
class AudiobookSleepTimer extends ChangeNotifier {
  AudiobookSleepTimer._(this._onExpire);

  /// 测试用：不挂控制器，到点只回调 [onExpire]。
  @visibleForTesting
  AudiobookSleepTimer.forTesting({required VoidCallback onExpire})
    : _onExpire = onExpire;

  static final Expando<AudiobookSleepTimer> _byController =
      Expando<AudiobookSleepTimer>('audiobookSleepTimer');

  static AudiobookSleepTimer of(AudiobookPlayerController controller) =>
      _byController[controller] ??= AudiobookSleepTimer._(
        () => unawaited(controller.pause()),
      );

  /// 当前时刻（测试注入假时钟）。
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  final VoidCallback _onExpire;
  Timer? _timer;
  Timer? _minuteTick;
  DateTime? _endsAt;

  /// 剩余分钟（向上取整，至少 1）；没开定时 = null。
  int? get remainingMinutes {
    final int? ms = _remainingMs;
    return ms == null ? null : (ms / 60000).ceil();
  }

  int? get _remainingMs {
    final DateTime? end = _endsAt;
    if (end == null) return null;
    final int ms = end.difference(now()).inMilliseconds;
    return ms <= 0 ? null : ms;
  }

  /// 开 [minutes] 分钟定时；null = 关闭。
  void start(int? minutes) {
    _cancel();
    if (minutes != null && minutes > 0) {
      final Duration d = Duration(minutes: minutes);
      _endsAt = now().add(d);
      _timer = Timer(d, () {
        _cancel();
        _onExpire();
        notifyListeners();
      });
      _scheduleMinuteTick();
    }
    notifyListeners();
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _minuteTick?.cancel();
    _minuteTick = null;
    _endsAt = null;
  }

  /// 在剩余分钟（向上取整）下一次变小的那一刻通知。
  void _scheduleMinuteTick() {
    _minuteTick?.cancel();
    final int? ms = _remainingMs;
    if (ms == null) return;
    final int intoMinute = ms % 60000;
    // 恰在整分上：再过一整分钟读数才变；否则过完这一分钟的零头就变。
    final int delay = (intoMinute == 0 ? 60000 : intoMinute) + 1;
    if (delay >= ms) return; // 最后一分钟交给到点回调。
    _minuteTick = Timer(Duration(milliseconds: delay), () {
      _minuteTick = null;
      notifyListeners();
      _scheduleMinuteTick();
    });
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }
}

/// 睡眠定时 chip：点开选 关闭 / 15 / 30 / 45 / 60 分钟；开着时显示剩余分钟。
class _SleepTimerChip extends StatelessWidget {
  const _SleepTimerChip({required this.controller});

  final AudiobookPlayerController controller;

  static const List<int> _options = <int>[15, 30, 45, 60];

  @override
  Widget build(BuildContext context) {
    final AudiobookSleepTimer timer = AudiobookSleepTimer.of(controller);
    final int? remaining = timer.remainingMinutes;
    return Builder(
      builder: (BuildContext anchor) => FushiChoiceChip(
        key: const ValueKey<String>('fushi_audiobook_sleep_timer'),
        avatar: const FushiIcon(Icons.bedtime_outlined, size: 18),
        label: Text(
          remaining == null
              ? t.reader_audiobook_sleep_timer
              : t.reader_audiobook_sleep_remaining(n: remaining),
        ),
        selected: remaining != null,
        showCheckmark: false,
        onSelected: (_) async {
          final RenderObject? box = anchor.findRenderObject();
          final RenderObject? overlay = Overlay.of(
            anchor,
          ).context.findRenderObject();
          if (box is! RenderBox || overlay is! RenderBox) return;
          final Offset at = box.localToGlobal(Offset.zero, ancestor: overlay);
          final int? choice = await showFushiMenu<int>(
            context: anchor,
            position: RelativeRect.fromRect(
              at & box.size,
              Offset.zero & overlay.size,
            ),
            items: <PopupMenuEntry<int>>[
              PopupMenuItem<int>(
                value: 0,
                child: Text(t.reader_audiobook_sleep_off),
              ),
              for (final int m in _options)
                PopupMenuItem<int>(
                  value: m,
                  child: Text(t.stat_format_minutes(n: m)),
                ),
            ],
          );
          if (choice == null) return;
          timer.start(choice == 0 ? null : choice);
          // 面板每秒 tick 重建，chip 读数随之刷新。
        },
      ),
    );
  }
}
