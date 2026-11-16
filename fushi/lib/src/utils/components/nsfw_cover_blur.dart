/// NSFW 封面模糊的纯 UI 部分（不认识数据库 / 偏好）：[NsfwCoverBlur] 打模糊，
/// [ShelfCoverNsfw] 把「这张卡的封面要模糊」从卡壳广播给卡内的 `ShelfCoverFrame`。
/// 判定（哪部作品是 NSFW、全局开关）在 `media/nsfw/media_nsfw_cover.dart`。
library;

import 'dart:ui' as ui;

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 「这张卡的封面要模糊」的广播层（[MediaNsfwCoverScope] 写，`ShelfCoverFrame` 读）。
class ShelfCoverNsfw extends InheritedWidget {
  const ShelfCoverNsfw({required this.blur, required super.child, super.key});

  final bool blur;

  /// 子树没有这一层时为 false（不模糊）。
  static bool blurOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShelfCoverNsfw>()?.blur ??
      false;

  @override
  bool updateShouldNotify(ShelfCoverNsfw oldWidget) => oldWidget.blur != blur;
}

/// 封面模糊的高斯 sigma（逻辑像素）。够大到认不出画面，又保留主色调让书架不突兀。
const double kNsfwCoverBlurSigma = 18;

/// 把 [child]（一张封面）按 [blur] 打模糊，中间压一枚「已隐藏」图标。模糊强度随
/// 开关做一段短过渡（MD3 / Apple 共用 [FushiMotion] 时长；减弱动态时直接跳）。
/// 树结构恒定（不按 blur 增删层），开关切换不重建封面图。
class NsfwCoverBlur extends StatelessWidget {
  const NsfwCoverBlur({
    required this.blur,
    required this.child,
    this.showIcon = true,
    super.key,
  });

  final bool blur;
  final Widget child;

  /// 小缩略图（列表行 40 宽那种）不压图标，避免喧宾夺主。
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: blur ? 1 : 0),
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      child: child,
      builder: (BuildContext context, double t, Widget? cover) {
        final double sigma = kNsfwCoverBlurSigma * t;
        return Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            ClipRect(
              child: ImageFiltered(
                key: const ValueKey<String>('nsfw-cover-blur'),
                enabled: sigma > 0.01,
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: sigma,
                  sigmaY: sigma,
                  tileMode: TileMode.decal,
                ),
                child: cover,
              ),
            ),
            if (showIcon)
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: t,
                    child: Center(
                      child: FushiIcon(
                        FushiIcons.visibilityOff,
                        size: 28,
                        color: Colors.white.withValues(alpha: 0.9),
                        shadows: const <Shadow>[
                          Shadow(color: Colors.black54, blurRadius: 8),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
