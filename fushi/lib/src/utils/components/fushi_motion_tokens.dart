import 'package:flutter/material.dart';

const Duration hibikiMd3StateDuration = Durations.short4;
const Curve hibikiMd3StateCurve = Easing.standard;

const AnimationStyle hibikiMd3DialogAnimationStyle = AnimationStyle(
  curve: Easing.emphasizedDecelerate,
  duration: Durations.medium2,
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Durations.short4,
);

const AnimationStyle hibikiMd3SheetAnimationStyle = AnimationStyle(
  curve: Easing.emphasizedDecelerate,
  duration: Durations.medium4,
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Durations.medium1,
);

const AnimationStyle hibikiMd3MenuAnimationStyle = AnimationStyle(
  curve: Easing.emphasizedDecelerate,
  duration: Durations.short4,
  reverseCurve: Easing.emphasizedAccelerate,
  reverseDuration: Durations.short2,
);
