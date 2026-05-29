import 'package:flutter/widgets.dart';
import 'package:gap/gap.dart';

class SizeSet<T> {
  const SizeSet({
    required this.extraSmall,
    required this.small,
    required this.semiSmall,
    required this.normal,
    required this.semiBig,
    required this.big,
    required this.extraBig,
  });

  final T extraSmall;
  final T small;
  final T semiSmall;
  final T normal;
  final T semiBig;
  final T big;
  final T extraBig;
}

class SpacingInsetsData {
  const SpacingInsetsData({
    required this.all,
    required this.horizontal,
    required this.vertical,
    required this.onlyRight,
    required this.onlyTop,
    required this.onlyBottom,
    required this.onlyLeft,
    required this.exceptLeft,
    required this.exceptRight,
    required this.exceptTop,
    required this.exceptBottom,
  });

  factory SpacingInsetsData.fromSpaces(SizeSet<double> s) {
    SizeSet<EdgeInsets> apply(EdgeInsets Function(double) fn) => SizeSet(
          extraSmall: fn(s.extraSmall),
          small: fn(s.small),
          semiSmall: fn(s.semiSmall),
          normal: fn(s.normal),
          semiBig: fn(s.semiBig),
          big: fn(s.big),
          // HBK-AUDIT-152: fix copy-paste bug — extraBig was mapped to s.big.
          extraBig: fn(s.extraBig),
        );

    return SpacingInsetsData(
      all: apply(EdgeInsets.all),
      horizontal: apply((v) => EdgeInsets.symmetric(horizontal: v)),
      vertical: apply((v) => EdgeInsets.symmetric(vertical: v)),
      onlyRight: apply((v) => EdgeInsets.only(right: v)),
      onlyLeft: apply((v) => EdgeInsets.only(left: v)),
      onlyTop: apply((v) => EdgeInsets.only(top: v)),
      onlyBottom: apply((v) => EdgeInsets.only(bottom: v)),
      exceptBottom: apply((v) => EdgeInsets.fromLTRB(v, v, v, 0)),
      exceptLeft: apply((v) => EdgeInsets.fromLTRB(0, v, v, v)),
      exceptRight: apply((v) => EdgeInsets.fromLTRB(v, v, 0, v)),
      exceptTop: apply((v) => EdgeInsets.fromLTRB(v, 0, v, v)),
    );
  }

  final SizeSet<EdgeInsets> all;
  final SizeSet<EdgeInsets> horizontal;
  final SizeSet<EdgeInsets> vertical;
  final SizeSet<EdgeInsets> onlyRight;
  final SizeSet<EdgeInsets> onlyTop;
  final SizeSet<EdgeInsets> onlyBottom;
  final SizeSet<EdgeInsets> onlyLeft;
  final SizeSet<EdgeInsets> exceptLeft;
  final SizeSet<EdgeInsets> exceptRight;
  final SizeSet<EdgeInsets> exceptTop;
  final SizeSet<EdgeInsets> exceptBottom;
}

class SpacingData {
  const SpacingData({required this.spaces, required this.insets});

  factory SpacingData.generate(double normal) {
    final spaces = SizeSet<double>(
      extraSmall: normal * 0.2,
      small: normal * 0.4,
      semiSmall: normal * 0.6,
      normal: normal,
      semiBig: normal * 1.5,
      big: normal * 2.5,
      extraBig: normal * 5.0,
    );
    return SpacingData(
      spaces: spaces,
      insets: SpacingInsetsData.fromSpaces(spaces),
    );
  }

  final SizeSet<double> spaces;
  final SpacingInsetsData insets;
}

enum SpaceSize {
  extraSmall,
  small,
  semiSmall,
  normal,
  semiBig,
  big,
  extraBig;

  double toPoints(BuildContext context) {
    final s = Spacing.of(context).spaces;
    return switch (this) {
      SpaceSize.extraSmall => s.extraSmall,
      SpaceSize.small => s.small,
      SpaceSize.semiSmall => s.semiSmall,
      SpaceSize.normal => s.normal,
      SpaceSize.semiBig => s.semiBig,
      SpaceSize.big => s.big,
      SpaceSize.extraBig => s.extraBig,
    };
  }
}

class Spacing extends StatelessWidget {
  const Spacing({
    super.key,
    required this.dataBuilder,
    required this.child,
  });

  final SpacingData Function(BuildContext context) dataBuilder;
  final Widget child;

  static SpacingData of(BuildContext context) {
    final provider =
        context.dependOnInheritedWidgetOfExactType<_SpacingProvider>();
    assert(provider != null, 'No Spacing in widget tree.');
    return provider!.data;
  }

  @override
  Widget build(BuildContext context) {
    return _SpacingProvider(data: dataBuilder(context), child: child);
  }
}

class _SpacingProvider extends InheritedWidget {
  const _SpacingProvider({required this.data, required super.child});
  final SpacingData data;

  @override
  bool updateShouldNotify(_SpacingProvider old) => data != old.data;
}

class Space extends StatelessWidget {
  const Space({super.key, required double mainAxisExtent})
      : _extent = mainAxisExtent,
        _size = null;

  const Space.extraSmall({super.key})
      : _size = SpaceSize.extraSmall,
        _extent = null;
  const Space.small({super.key})
      : _size = SpaceSize.small,
        _extent = null;
  const Space.semiSmall({super.key})
      : _size = SpaceSize.semiSmall,
        _extent = null;
  const Space.normal({super.key})
      : _size = SpaceSize.normal,
        _extent = null;
  const Space.semiBig({super.key})
      : _size = SpaceSize.semiBig,
        _extent = null;
  const Space.big({super.key})
      : _size = SpaceSize.big,
        _extent = null;
  const Space.extraBig({super.key})
      : _size = SpaceSize.extraBig,
        _extent = null;

  final double? _extent;
  final SpaceSize? _size;

  @override
  Widget build(BuildContext context) {
    final v = _extent ?? (_size ?? SpaceSize.normal).toPoints(context);
    return Gap(v);
  }
}
