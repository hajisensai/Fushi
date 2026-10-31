import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';

/// 制卡结果卡片：底部制卡 toast（`FushiToast.showMine`）与视频页左上角制卡 OSD
/// （`_showMineOsd`）共用的唯一长相。
///
/// M3E tonal 胶囊：浅色 container 底 + 深字，左侧强调色图标块（MD3 用 M3E 表现力
/// 形状 cookie9Sided，Apple 设计系统用正圆），第一行状态标题、第二行具体消息
/// （牌组名 / 失败原因），底边一条随停留时长耗尽的倒计时条。颜色与图标见
/// [mineNoticeTone]，标题见 [mineNoticeTitle]。
///
/// 动效：图标块从 -90° / 0.4 倍弹入（M3E spatial 弹簧），倒计时条线性耗尽；墨水屏与
/// 系统「减弱动态效果」下两者都不播（[fushiMotionEnabled]），倒计时条直接不画。
/// 墨水屏另外把三色收成白底黑字黑描边，靠图标形状区分结果。
class FushiMineNoticeCard extends StatefulWidget {
  const FushiMineNoticeCard({
    required this.status,
    required this.message,
    required this.visibleFor,
    this.maxWidth = 440,
    super.key,
  });

  final MineToastStatus status;

  /// 具体消息（调用方已算好的文案，如「卡片已覆盖到『Fushi』。」）。
  final String message;

  /// 这张卡会停留多久：倒计时条按它耗尽，与调用方的自动消失计时同长。
  final Duration visibleFor;

  final double maxWidth;

  @override
  State<FushiMineNoticeCard> createState() => _FushiMineNoticeCardState();
}

class _FushiMineNoticeCardState extends State<FushiMineNoticeCard>
    with TickerProviderStateMixin {
  late final AnimationController _iconIn = AnimationController(
    vsync: this,
    duration: FushiMotion.long,
  );
  late final AnimationController _countdown = AnimationController(
    vsync: this,
    duration: widget.visibleFor,
    value: 1,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (fushiMotionEnabled(context)) {
      _iconIn.forward();
      _countdown.reverse();
    } else {
      _iconIn.value = 1;
    }
  }

  @override
  void dispose() {
    _iconIn.dispose();
    _countdown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context);
    final bool motion = fushiMotionEnabled(context);
    final MineNoticeTone tone = mineNoticeTone(widget.status);
    final Color container = eink ? Colors.white : tone.container;
    final Color onContainer = eink ? Colors.black : tone.onContainer;
    final Color accent = eink ? Colors.black : tone.accent;
    final String? title = mineNoticeTitle(widget.status);
    final TextTheme text = Theme.of(context).textTheme;

    final Animation<double> spring = CurvedAnimation(
      parent: _iconIn,
      curve: FushiMotion.release,
    );
    final Widget iconBlock = AnimatedBuilder(
      animation: spring,
      builder: (BuildContext context, Widget? child) => Transform.rotate(
        angle: (spring.value - 1) * 1.5708,
        child: Transform.scale(scale: 0.4 + 0.6 * spring.value, child: child),
      ),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: accent,
          shape: apple
              ? const CircleBorder()
              : MaterialShapeBorder(shape: MaterialShapes.cookie9Sided),
        ),
        child: FushiIcon(tone.icon, color: Colors.white, size: 22),
      ),
    );

    final Widget texts = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (title != null)
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (text.titleSmall ?? const TextStyle()).copyWith(
              color: onContainer,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
        Text(
          widget.message,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: (text.bodySmall ?? const TextStyle()).copyWith(
            color: onContainer.withValues(alpha: title == null ? 1 : 0.8),
            fontSize: title == null ? 15 : 13,
            fontWeight: title == null ? FontWeight.w600 : FontWeight.w400,
            height: 1.3,
          ),
        ),
      ],
    );

    const BorderRadius radius = BorderRadius.all(Radius.circular(28));
    return Semantics(
      liveRegion: true,
      label: title == null ? widget.message : '$title. ${widget.message}',
      excludeSemantics: true,
      child: Container(
        constraints: BoxConstraints(minHeight: 56, maxWidth: widget.maxWidth),
        decoration: BoxDecoration(
          color: container,
          borderRadius: radius,
          border: eink ? Border.all(color: Colors.black, width: 1.5) : null,
          boxShadow: eink
              ? null
              : const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x59000000),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                  BoxShadow(
                    color: Color(0x4D000000),
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            children: <Widget>[
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 20, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    iconBlock,
                    const SizedBox(width: 12),
                    Flexible(child: texts),
                  ],
                ),
              ),
              if (motion)
                Positioned.fill(
                  child: Align(
                    alignment: AlignmentDirectional.bottomStart,
                    child: AnimatedBuilder(
                      animation: _countdown,
                      builder: (BuildContext context, Widget? _) =>
                          FractionallySizedBox(
                            widthFactor: _countdown.value,
                            child: Container(
                              height: 3,
                              color: accent.withValues(alpha: 0.55),
                            ),
                          ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
