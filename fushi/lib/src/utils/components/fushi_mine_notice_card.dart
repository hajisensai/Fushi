import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';

/// 制卡结果卡片上的一颗动作按钮（反馈 JNyykxvuY9：成功提示上的「撤销」）。
@immutable
class MineNoticeAction {
  const MineNoticeAction({required this.label, required this.onPressed});

  final String label;

  /// 点下后调用；宿主（toast / 视频 OSD）同时立即收起这张卡。
  final VoidCallback onPressed;
}

/// 带动作按钮的结果卡停留多久：普通结果卡只停 2.4 秒，来不及去点按钮；
/// 6 秒又挡视线太久（用户反馈），取 4 秒。
const Duration kMineNoticeActionVisibleFor = Duration(seconds: 4);

/// 制卡结果卡片：底部制卡 toast（`FushiToast.showMine`）与视频页左上角制卡 OSD
/// （`_showMineOsd`）共用的唯一长相。
///
/// M3E tonal 胶囊：浅色 container 底 + 深字，左侧强调色图标块（MD3 用 M3E 表现力
/// 形状 cookie9Sided，Apple 设计系统用正圆），一行具体消息（牌组名 / 失败原因），
/// 底边一条随停留时长耗尽的倒计时条。尺寸与普通提示胶囊一致（48 高、图标块 32）。
/// 颜色与图标见 [mineNoticeTone]；状态标题 [mineNoticeTitle] 只进读屏 label。
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
    this.action,
    this.compact = false,
    super.key,
  });

  /// 卡片右侧的动作按钮（如「撤销」）；为 null 时不画。小号卡同样画在消息右侧。
  /// 按钮视觉 32 高；触控平台（主题 tapTargetSize 为 padded）命中区撑到 48dp，
  /// 默认卡带按钮仍是 48 高，小号卡（不带按钮 40 高）带按钮时随命中区长到 48；
  /// 桌面精确指针命中区即视觉尺寸（[FushiTouchTargetPadding] 的约定）。
  final MineNoticeAction? action;

  /// 角落小号：图标块 28、40 高、消息至多两行，给歌词模式这类「正文铺满全屏」
  /// 的页面用——默认卡会压住正文。
  final bool compact;

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
    // 字阶走设计令牌（context.fushiType），不写裸字号。
    final FushiTypography type = context.fushiType;

    final Animation<double> spring = CurvedAnimation(
      parent: _iconIn,
      curve: FushiMotion.release,
    );
    final bool compact = widget.compact;
    final double iconBox = compact ? 28 : 32;
    final bool hasAction = widget.action != null;
    final double verticalPad = compact ? 6 : 8;
    final double cardMinHeight = compact ? 40 : 48;
    final Widget iconBlock = AnimatedBuilder(
      animation: spring,
      builder: (BuildContext context, Widget? child) => Transform.rotate(
        angle: (spring.value - 1) * 1.5708,
        child: Transform.scale(scale: 0.4 + 0.6 * spring.value, child: child),
      ),
      child: Container(
        width: iconBox,
        height: iconBox,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: accent,
          shape: apple
              ? const CircleBorder()
              : MaterialShapeBorder(shape: MaterialShapes.cookie9Sided),
        ),
        child: FushiIcon(
          tone.icon,
          color: Colors.white,
          size: compact ? 16 : 20,
        ),
      ),
    );

    // 默认卡与普通提示胶囊（FushiToastCapsule）同一副尺寸：单行 48 高、图标块
    // 32、字阶 labelLarge；状态标题不再单占一行（仍进读屏 label），颜色与图标
    // 已经说明结果。消息过长时折行。
    final Widget texts = Text(
      widget.message,
      // 小卡两行：「卡片已导出到『<卡组名>』」里较长的卡组名一行放不下。
      maxLines: compact ? 2 : 3,
      overflow: TextOverflow.ellipsis,
      style: type.labelLarge.copyWith(color: onContainer),
    );

    final BorderRadius radius = BorderRadius.all(
      Radius.circular(compact ? 20 : 24),
    );
    return Semantics(
      liveRegion: true,
      label: title == null ? widget.message : '$title. ${widget.message}',
      // 有动作按钮时不能吞掉子树语义，否则读屏 / 键盘用户够不到「撤销」。
      excludeSemantics: widget.action == null,
      child: Container(
        constraints: BoxConstraints(
          minHeight: cardMinHeight,
          maxWidth: widget.maxWidth,
        ),
        decoration: BoxDecoration(
          color: container,
          borderRadius: radius,
          border: eink ? Border.all(color: Colors.black, width: 1.5) : null,
          boxShadow: eink
              ? null
              : compact
              ? const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ]
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
                // 只留横向留白；带按钮时尾端收窄：文字按钮自带内边距。上下
                // 留白只加在消息上、不加在整行上：触控平台按钮的 48dp 命中区
                // 要能占满行高（命中测试出不了卡片边界），默认卡带按钮因此
                // 仍是 48 高；行高下限 = 卡片下限，图标块 / 按钮在行内居中。
                padding: EdgeInsetsDirectional.only(
                  start: compact ? 6 : 8,
                  end: hasAction ? (compact ? 6 : 8) : (compact ? 14 : 24),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: cardMinHeight),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      iconBlock,
                      SizedBox(width: compact ? 8 : 12),
                      Flexible(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: verticalPad),
                          child: texts,
                        ),
                      ),
                      if (widget.action
                          case final MineNoticeAction action) ...<Widget>[
                        const SizedBox(width: 8),
                        // 触控平台把命中区撑到 48dp（MD3 与 Apple 两套按钮都
                        // 经这一层，Apple 玻璃按钮不认 tapTargetSize）；桌面
                        // 精确指针保持视觉尺寸，与设计系统其它紧凑控件一致。
                        FushiTouchTargetPadding(
                          child: FushiTextButton(
                            key: const ValueKey<String>('mine-notice-action'),
                            onPressed: action.onPressed,
                            // 紧凑小按钮：默认 40 高 + labelLarge 在两行卡片里
                            // 比正文还抢眼，视觉收成 32 高、正文同级字号。
                            // shrinkWrap：命中区交给外层 FushiTouchTargetPadding，
                            // 不叠 VisualDensity.compact（会把 32 再压到 24）。
                            style: TextButton.styleFrom(
                              foregroundColor: accent,
                              textStyle: type.labelMedium,
                              minimumSize: const Size(0, 32),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(action.label),
                          ),
                        ),
                      ],
                    ],
                  ),
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
                              height: compact ? 2 : 3,
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
