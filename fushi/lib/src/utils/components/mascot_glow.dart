/// 吉祥物光晕：在吉祥物轮廓外圈画一层主题色的呼吸光晕（偏好 `theme_mascot_glow`，
/// 默认关）。
///
/// 光晕是吉祥物图本身的剪影：把同一张图按 srcIn 染成光晕色、高斯模糊后垫在原图
/// 下面，白色的吉祥物盖住中间，只在轮廓外露出一圈光。空闲时缓慢呼吸；有后台同步
/// 任务在跑时更亮、呼吸快一倍，看一眼就知道 Fushi 在忙。
///
/// 墨水屏不画；系统「减弱动态效果」下只画一圈静止的光晕。开关关着时直接返回原图，
/// 不建 ticker、不多一层合成。
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/sync/background_tasks_indicator.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 「吉祥物光晕」开关的运行时真值。持久化在 [ThemeNotifier]（`setMascotGlow`），
/// 由它在加载 / 改动偏好时发布到这里；画吉祥物的组件拿不到 AppModel，统一监听它。
final ValueNotifier<bool> mascotGlowEnabled = ValueNotifier<bool>(false);

/// 光晕层的 key（测试用）。
const ValueKey<String> kMascotGlowHaloKey = ValueKey<String>(
  'fushi_mascot_glow_halo',
);

/// 一档光晕的强度：透明度在 [low]..[high] 间呼吸，模糊半径 [sigma]。
@immutable
class MascotGlowLevel {
  const MascotGlowLevel({
    required this.low,
    required this.high,
    required this.sigma,
  });

  final double low;
  final double high;
  final double sigma;

  /// 减弱动态效果时用的静止透明度。
  double get still => (low + high) / 2;
}

/// 空闲档：若隐若现。
const MascotGlowLevel kMascotGlowIdle = MascotGlowLevel(
  low: 0.25,
  high: 0.6,
  sigma: 3,
);

/// 忙碌档（后台同步在跑）：更亮、更外扩。
const MascotGlowLevel kMascotGlowBusy = MascotGlowLevel(
  low: 0.5,
  high: 1,
  sigma: 4.5,
);

/// 给 [child]（一张透明底的吉祥物图）加呼吸光晕。
///
/// [busyListenable] / [isBusy] 决定「在忙」；不传时看后台同步任务
/// （[syncBackgroundTasksListenable] / [hasActiveSyncTasks]）。
class MascotGlow extends StatefulWidget {
  const MascotGlow({
    super.key,
    required this.child,
    this.color,
    this.busyListenable,
    this.isBusy,
  });

  final Widget child;

  /// 光晕色；null = 当前主题的 primary。
  final Color? color;

  final Listenable? busyListenable;
  final bool Function()? isBusy;

  @override
  State<MascotGlow> createState() => _MascotGlowState();
}

class _MascotGlowState extends State<MascotGlow> with TickerProviderStateMixin {
  AnimationController? _breath;

  /// 当前 [_breath] 按哪一档节奏在跑（档位变了要换时长重开）。
  bool? _breathBusy;

  Listenable get _busyListenable =>
      widget.busyListenable ?? syncBackgroundTasksListenable;

  bool _busy() => (widget.isBusy ?? hasActiveSyncTasks)();

  @override
  void initState() {
    super.initState();
    mascotGlowEnabled.addListener(_onChanged);
    _busyListenable.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(MascotGlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Listenable old =
        oldWidget.busyListenable ?? syncBackgroundTasksListenable;
    if (!identical(old, _busyListenable)) {
      old.removeListener(_onChanged);
      _busyListenable.addListener(_onChanged);
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    mascotGlowEnabled.removeListener(_onChanged);
    _busyListenable.removeListener(_onChanged);
    _breath?.dispose();
    super.dispose();
  }

  /// 需要呼吸时按档位起 / 换节奏；不需要时收掉 ticker。
  AnimationController? _syncBreath({
    required bool animate,
    required bool busy,
  }) {
    if (!animate) {
      _breath?.dispose();
      _breath = null;
      _breathBusy = null;
      return null;
    }
    final AnimationController controller = _breath ??= AnimationController(
      vsync: this,
    );
    if (_breathBusy != busy || !controller.isAnimating) {
      _breathBusy = busy;
      controller.repeat(
        reverse: true,
        period: busy
            ? FushiMotion.ambientBreathBusy
            : FushiMotion.ambientBreath,
      );
    }
    return controller;
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = mascotGlowEnabled.value && !isEinkTheme(context);
    final bool animate = enabled && fushiMotionEnabled(context);
    final bool busy = enabled && _busy();
    final AnimationController? breath = _syncBreath(
      animate: animate,
      busy: busy,
    );
    if (!enabled) return widget.child;

    final MascotGlowLevel level = busy ? kMascotGlowBusy : kMascotGlowIdle;
    final Color color = widget.color ?? Theme.of(context).colorScheme.primary;
    final Widget silhouette = ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: level.sigma,
        sigmaY: level.sigma,
        tileMode: TileMode.decal,
      ),
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        child: widget.child,
      ),
    );
    final Widget halo = breath == null
        ? Opacity(opacity: level.still, child: silhouette)
        : FadeTransition(
            opacity: breath.drive(
              Tween<double>(
                begin: level.low,
                end: level.high,
              ).chain(CurveTween(curve: FushiMotion.ambient)),
            ),
            child: silhouette,
          );
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: KeyedSubtree(key: kMascotGlowHaloKey, child: halo),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}
