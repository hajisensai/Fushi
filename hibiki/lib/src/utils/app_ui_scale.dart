import 'package:flutter/widgets.dart';
import 'package:hibiki/src/utils/spacing.dart';

class HibikiAppUiScale extends StatelessWidget {
  const HibikiAppUiScale({
    required this.scale,
    required this.child,
    super.key,
  });

  static const double minScale = 0.3;
  static const double defaultScale = 1.0;
  static const double maxScale = 3.0;

  final double scale;
  final Widget child;

  static double normalize(double value) {
    if (value.isNaN || !value.isFinite) return defaultScale;
    return value.clamp(minScale, maxScale).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final double effectiveScale = normalize(scale);
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    final TextScaler textScaler = _AppUiTextScaler(
      base: mediaQuery.textScaler,
      scaleFactor: effectiveScale,
    );

    return MediaQuery(
      data: mediaQuery.copyWith(textScaler: textScaler),
      child: Spacing(
        dataBuilder: (_) => SpacingData.generate(10 * effectiveScale),
        child: child,
      ),
    );
  }
}

class _AppUiTextScaler extends TextScaler {
  const _AppUiTextScaler({
    required this.base,
    required this.scaleFactor,
  });

  final TextScaler base;
  final double scaleFactor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * scaleFactor;

  @override
  double get textScaleFactor => base.textScaleFactor * scaleFactor;

  @override
  bool operator ==(Object other) {
    return other is _AppUiTextScaler &&
        other.base == base &&
        other.scaleFactor == scaleFactor;
  }

  @override
  int get hashCode => Object.hash(base, scaleFactor);
}
