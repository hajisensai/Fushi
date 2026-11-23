import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/src/media/video/video_live_chat_replay.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart'
    show VideoSubtitleJumpPanel, formatCueTimestamp;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/media/video/youtube_live_chat_replay.dart';
import 'package:material_ui/material_ui.dart';

/// 播放头之前这么久以内发出的消息算「当前时刻」，整行高亮。
const int kVideoLiveChatCurrentWindowMs = 5000;

/// 列表离底部（最新消息）超过这么远就算用户在往回翻：停止跟随、冻结列表。
const double _kFollowBreakPx = 48;

/// 命中聊天栏某条消息的某个字符（查词浮层 dismiss barrier 用，同字幕列表 BUG-874）。
typedef LiveChatHit = ({
  YoutubeChatMessage message,
  int graphemeIndex,
  Rect charRect,
  Rect anchorRect,
});

/// 给上层（查词浮层 dismiss barrier / 悬停查词）按全局坐标反查「点到的是聊天栏哪条
/// 消息哪个字符」的句柄，与 `VideoSubtitleListHitTester` 同范式：面板 build 时绑定，
/// 卸载时解绑。
class VideoLiveChatHitTester {
  LiveChatHit? Function(Offset globalPos, {bool exactOnly})? _impl;

  void bindHitTest(
    LiveChatHit? Function(Offset globalPos, {bool exactOnly}) impl,
  ) => _impl = impl;

  /// 面板卸载时解绑——只解自己绑的那份（横屏侧栏收起动画期间竖屏页签可能已经绑上）。
  void unbind(LiveChatHit? Function(Offset globalPos, {bool exactOnly}) impl) {
    if (_impl == impl) _impl = null;
  }

  /// [exactOnly]：只在点落在字形盒内才命中（barrier 判定「点空白想关浮层」用）。
  LiveChatHit? hitTest(Offset globalPos, {bool exactOnly = false}) =>
      _impl?.call(globalPos, exactOnly: exactOnly);
}

/// 列表此刻显示到哪：跟随时 = 播放头；用户往回翻时冻结在翻之前的那一刻（新消息先不
/// 往列表里插——倒序列表在顶端插行会把正在看的内容顶走）。往回拖播放头时取更早的那个。
int videoLiveChatShownUntilMs({
  required int positionMs,
  required bool following,
  required int? frozenAtMs,
}) {
  if (following || frozenAtMs == null) return positionMs;
  return math.min(positionMs, frozenAtMs);
}

/// [message] 是否落在「当前时刻」高亮窗口里。
bool videoLiveChatIsCurrent(YoutubeChatMessage message, int positionMs) =>
    message.offsetMs <= positionMs &&
    message.offsetMs > positionMs - kVideoLiveChatCurrentWindowMs;

/// YouTube 直播回放的聊天回放栏（拍板台 zTedU_pOQF，方案 b）：跟随播放的聊天列表。
///
/// - 只列出「播放到此刻已经发出」的消息，最新的在最下面，当前时刻那几条整行高亮；
/// - 点消息里的字直接查词（不必暂停，列表是静止文字），查词 / 制卡走页面传进来的
///   [onLookup]（与字幕列表同一条链路）；
/// - 手动往上翻就停止跟随、列表冻结，底部浮出「回到当前」；点它回到底部继续跟随。
///
/// 横屏是画面右侧的推挤式侧栏（与字幕列表同一套），竖屏学习版式里是下半屏的一个页签；
/// 两处都用这一个组件。
class VideoLiveChatPanel extends StatefulWidget {
  const VideoLiveChatPanel({
    required this.chat,
    required this.onLookup,
    required this.colorScheme,
    required this.width,
    this.safeAreaInsets = EdgeInsets.zero,
    this.showAuthor = true,
    this.onClose,
    this.hitTester,
    this.lookupHighlightOf,
    this.fontSize = 14,
    this.fontFamily,
    super.key,
  });

  final VideoLiveChatReplay chat;

  /// 点消息第 [graphemeIndex] 个字位查词；[charRect] 是被点字符的全局矩形。
  final void Function(
    YoutubeChatMessage message,
    int graphemeIndex,
    Rect charRect,
  )
  onLookup;

  final ColorScheme colorScheme;
  final double width;

  /// 贴边侧栏铺进系统安全区时，内容要让出的那一截（同字幕列表）。
  final EdgeInsets safeAreaInsets;

  /// 是否显示发送者名字（设置「聊天栏显示用户名」）。
  final bool showAuthor;

  /// 头部关闭钮；null = 不出（竖屏页签里常驻）。
  final VoidCallback? onClose;

  final VideoLiveChatHitTester? hitTester;

  /// 这条消息上正在查的词（主题色底色带），null = 不高亮。
  final SubtitleTranscriptHighlightRange? Function(YoutubeChatMessage message)?
  lookupHighlightOf;

  final double fontSize;
  final String? fontFamily;

  @override
  State<VideoLiveChatPanel> createState() => _VideoLiveChatPanelState();
}

class _VideoLiveChatPanelState extends State<VideoLiveChatPanel> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _textKeys = <String, GlobalKey>{};
  final Map<String, YoutubeChatMessage> _keyedMessages =
      <String, YoutubeChatMessage>{};

  bool _following = true;
  int? _frozenAtMs;

  /// 上次 build 用的「显示条数 / 高亮起点」：位置每 tick 都推，只在它们变了才重建。
  int _lastShownCount = -1;
  int _lastCurrentStart = -1;

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_onChatChanged);
    widget.chat.position.addListener(_onPosition);
    widget.chat.attachViewer();
    widget.hitTester?.bindHitTest(_hitTest);
  }

  @override
  void didUpdateWidget(VideoLiveChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.chat, widget.chat)) {
      oldWidget.chat.removeListener(_onChatChanged);
      oldWidget.chat.position.removeListener(_onPosition);
      oldWidget.chat.detachViewer();
      widget.chat.addListener(_onChatChanged);
      widget.chat.position.addListener(_onPosition);
      widget.chat.attachViewer();
      _resetFollow();
    }
    if (!identical(oldWidget.hitTester, widget.hitTester)) {
      oldWidget.hitTester?.unbind(_hitTest);
      widget.hitTester?.bindHitTest(_hitTest);
    }
  }

  @override
  void dispose() {
    widget.chat.removeListener(_onChatChanged);
    widget.chat.position.removeListener(_onPosition);
    widget.chat.detachViewer();
    widget.hitTester?.unbind(_hitTest);
    _scroll.dispose();
    super.dispose();
  }

  void _resetFollow() {
    _following = true;
    _frozenAtMs = null;
    _textKeys.clear();
    _keyedMessages.clear();
  }

  void _onChatChanged() {
    if (!mounted) return;
    // 会话跳转换了窗口（列表清空）：之前冻结的位置已不在新窗口里，回到跟随。
    if (widget.chat.messages.isEmpty) {
      _resetFollow();
    } else {
      _pruneTextKeys();
    }
    setState(() {});
  }

  /// 会话窗口裁掉 / 跳走的消息不再保留字符命中用的 [GlobalKey]：长直播的消息可达十万条，
  /// 不裁的话两张表随观看时长无限增长，[_hitTest] 每次悬停都要把历史上见过的每一条扫一遍。
  /// 只留当前窗口里的（上限 = 会话的 maxMessages）。
  void _pruneTextKeys() {
    if (_textKeys.isEmpty) return;
    final Set<String> live = <String>{
      for (final YoutubeChatMessage m in widget.chat.messages) m.id,
    };
    _textKeys.removeWhere((String id, GlobalKey _) => !live.contains(id));
    _keyedMessages.removeWhere(
      (String id, YoutubeChatMessage _) => !live.contains(id),
    );
  }

  void _onPosition() {
    if (!mounted) return;
    final ({int shown, int currentStart}) next = _layoutKey();
    if (next.shown == _lastShownCount &&
        next.currentStart == _lastCurrentStart) {
      return;
    }
    setState(() {});
  }

  int get _shownUntilMs => videoLiveChatShownUntilMs(
    positionMs: widget.chat.positionMs,
    following: _following,
    frozenAtMs: _frozenAtMs,
  );

  ({int shown, int currentStart}) _layoutKey() {
    final List<YoutubeChatMessage> messages = widget.chat.messages;
    final int pos = widget.chat.positionMs;
    return (
      shown: youtubeChatVisibleCount(messages, _shownUntilMs),
      currentStart: youtubeChatVisibleCount(
        messages,
        pos - kVideoLiveChatCurrentWindowMs,
      ),
    );
  }

  bool _onScroll(ScrollNotification n) {
    // 只认用户手势带来的滚动（拖动 / 甩动 / 滚轮），列表内容变化引起的不算。
    final bool userDriven =
        (n is ScrollUpdateNotification && n.dragDetails != null) ||
        n is UserScrollNotification;
    if (!userDriven) return false;
    final double pixels = n.metrics.pixels;
    if (_following && pixels > _kFollowBreakPx) {
      setState(() {
        _following = false;
        _frozenAtMs = widget.chat.positionMs;
      });
    } else if (!_following && pixels <= 1) {
      setState(() {
        _following = true;
        _frozenAtMs = null;
      });
    }
    return false;
  }

  void _jumpToNow() {
    setState(() {
      _following = true;
      _frozenAtMs = null;
    });
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.standard,
      );
    }
  }

  LiveChatHit? _hitTest(Offset globalPos, {bool exactOnly = false}) {
    for (final MapEntry<String, GlobalKey> entry in _textKeys.entries) {
      final YoutubeChatMessage? message = _keyedMessages[entry.key];
      if (message == null) continue;
      final RenderObject? ro = entry.value.currentContext?.findRenderObject();
      if (ro is! RenderParagraph || !ro.attached) continue;
      final Offset local = ro.globalToLocal(globalPos);
      if (!(Offset.zero & ro.size).contains(local)) continue;
      final SubtitleListCharHit? hit = subtitleListCharHitFromParagraph(
        ro,
        message.text,
        localPosition: local,
        globalPosition: globalPos,
        exactOnly: exactOnly,
      );
      if (hit == null) continue;
      return (
        message: message,
        graphemeIndex: hit.graphemeIndex,
        charRect: hit.charRect,
        anchorRect: hit.anchorRect,
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = widget.colorScheme;
    final List<YoutubeChatMessage> messages = widget.chat.messages;
    final ({int shown, int currentStart}) key = _layoutKey();
    _lastShownCount = key.shown;
    _lastCurrentStart = key.currentStart;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: widget.width + widget.safeAreaInsets.right,
        padding: EdgeInsets.only(
          top: widget.safeAreaInsets.top,
          right: widget.safeAreaInsets.right,
        ),
        color: VideoSubtitleJumpPanel.columnSurfaceColor(
          context,
          colorScheme: cs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(context, cs),
            const FushiDividerControl(height: 1),
            Expanded(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: _buildBody(context, cs, messages, key.shown),
                  ),
                  _buildJumpToNow(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ColorScheme cs) {
    final VoidCallback? onClose = widget.onClose;
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4, top: 4, bottom: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              t.video_live_chat_title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: widget.fontSize + 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // 方案 b：Apple 风格是文字「完成」，MD3 是 ×。
          if (onClose != null)
            if (isGlassDesign(context))
              FushiTextButton(
                key: const ValueKey<String>('video-live-chat-close'),
                onPressed: onClose,
                child: Text(t.video_live_chat_done),
              )
            else
              FushiIconButtonControl(
                key: const ValueKey<String>('video-live-chat-close'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                icon: FushiIcon(FushiIcons.close, size: widget.fontSize + 4),
                color: cs.onSurfaceVariant,
                onPressed: onClose,
                visualDensity: VisualDensity.compact,
              ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ColorScheme cs,
    List<YoutubeChatMessage> messages,
    int shown,
  ) {
    final YoutubeChatReplayStatus status = widget.chat.status;
    if (status == YoutubeChatReplayStatus.failed && shown == 0) {
      return _buildFailed(cs);
    }
    if (shown == 0) {
      final bool loading =
          status == YoutubeChatReplayStatus.loading ||
          status == YoutubeChatReplayStatus.idle;
      return _buildHint(
        cs,
        loading ? t.video_live_chat_loading : t.video_live_chat_empty,
        loading: loading,
      );
    }
    final int pos = widget.chat.positionMs;
    final TextStyle textStyle = TextStyle(
      color: cs.onSurface,
      fontSize: widget.fontSize,
      fontFamily: widget.fontFamily,
      height: 1.35,
    );
    final Widget list = NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: FushiEntranceScope(
        replayKey: widget.chat.videoId,
        child: ListView.builder(
          key: const ValueKey<String>('video-live-chat-list'),
          controller: _scroll,
          // 最新的在最下面：倒序列表的 0 号是最新一条，「停在底部」就是 offset 0。
          reverse: true,
          padding: EdgeInsets.only(bottom: widget.safeAreaInsets.bottom),
          itemCount: shown,
          itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
            final YoutubeChatMessage m = messages[shown - 1 - i];
            return _buildRow(
              context,
              cs,
              m,
              textStyle,
              current: videoLiveChatIsCurrent(m, pos),
            );
          }),
        ),
      ),
    );
    if (status != YoutubeChatReplayStatus.failed) return list;
    // 已有消息但后续页取失败：列表照常显示，顶上给一条可重试的提示。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildFailedBanner(cs),
        Expanded(child: list),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context,
    ColorScheme cs,
    YoutubeChatMessage m,
    TextStyle baseStyle, {
    required bool current,
  }) {
    final GlobalKey textKey = _textKeys.putIfAbsent(m.id, GlobalKey.new);
    _keyedMessages[m.id] = m;
    final Color textColor = SubtitleTranscriptRow.textColorOf(
      context,
      cs,
      selected: current,
    );
    final Color secondary = SubtitleTranscriptRow.secondaryColorOf(
      context,
      cs,
      selected: current,
    );
    final String? amount = m.paidAmount;
    final bool showMeta =
        (widget.showAuthor && m.author.isNotEmpty) || amount != null;
    return KeyedSubtree(
      key: ValueKey<String>('video-live-chat-row-${m.id}'),
      child: SubtitleTranscriptRow(
        colorScheme: cs,
        selected: current,
        leading: Text(
          formatCueTimestamp(m.offsetMs),
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: secondary,
            fontSize: widget.fontSize - 2,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        text: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (showMeta)
              Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    if (widget.showAuthor && m.author.isNotEmpty)
                      TextSpan(text: m.author),
                    if (widget.showAuthor &&
                        m.author.isNotEmpty &&
                        amount != null)
                      const TextSpan(text: '  '),
                    if (amount != null)
                      TextSpan(
                        text: amount,
                        style: TextStyle(
                          color: cs.tertiary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: secondary,
                  fontSize: widget.fontSize - 2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (m.text.isNotEmpty)
              SubtitleTranscriptText(
                text: m.text,
                style: baseStyle.copyWith(color: textColor),
                textKey: textKey,
                lookupHighlight: widget.lookupHighlightOf?.call(m),
                onLookup: (int index, Rect rect) =>
                    widget.onLookup(m, index, rect),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildJumpToNow(BuildContext context) {
    final bool show = !_following;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 12 + widget.safeAreaInsets.bottom,
      child: IgnorePointer(
        ignoring: !show,
        child: AnimatedSlide(
          offset: show ? Offset.zero : const Offset(0, 0.6),
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.enter,
          child: AnimatedOpacity(
            opacity: show ? 1 : 0,
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            child: Center(
              child: FushiPressScale(
                child: FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('video-live-chat-jump-to-now'),
                  onPressed: _jumpToNow,
                  icon: const FushiIcon(FushiIcons.arrowDown),
                  label: Text(t.video_live_chat_jump_to_now),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHint(ColorScheme cs, String text, {required bool loading}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (loading) ...<Widget>[
              const FushiCircularProgressIndicator(),
              const SizedBox(height: 16),
            ],
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: widget.fontSize,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFailed(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              t.video_live_chat_failed,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: widget.fontSize,
              ),
            ),
            const SizedBox(height: 12),
            FushiPressScale(
              child: FushiFilledButton.tonal(
                key: const ValueKey<String>('video-live-chat-retry'),
                onPressed: widget.chat.retry,
                child: Text(t.retry),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFailedBanner(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              t.video_live_chat_failed,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: widget.fontSize - 1,
              ),
            ),
          ),
          FushiTextButton(
            key: const ValueKey<String>('video-live-chat-retry'),
            onPressed: widget.chat.retry,
            child: Text(t.retry),
          ),
        ],
      ),
    );
  }
}
