import 'package:flutter/material.dart';

const Duration fushiMd3StateDuration = Durations.short4;
const Curve fushiMd3StateCurve = Easing.standard;

const AnimationStyle fushiMd3DialogAnimationStyle = AnimationStyle(
  curve: Easing.emphasizedDecelerate,
  duration: Durations.medium2,
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Durations.short4,
);

const AnimationStyle fushiMd3SheetAnimationStyle = AnimationStyle(
  curve: Easing.emphasizedDecelerate,
  duration: Durations.medium4,
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Durations.medium1,
);

const AnimationStyle fushiMd3MenuAnimationStyle = AnimationStyle(
  curve: Easing.emphasizedDecelerate,
  duration: Durations.short4,
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Durations.short2,
);
