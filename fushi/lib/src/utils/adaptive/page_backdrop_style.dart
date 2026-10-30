import 'dart:io';

import 'package:flutter/foundation.dart';

/// 页面背景（路由层 `FushiPageBackdrop` 垫在每一页下面的那层）的可切换样式。
///
/// 2026-10-30 用户拍板：在 10-25 定版的「角落三块 M3E 形状」之外扩成一组预设，
/// 并支持用户上传自定义图片、从图片取色。设计稿见
/// `fushi/build/library_material_design/backdrop_presets.html`（本地，不入库）。
///
/// 持久化值（[wire]）冻结，改名等于数据迁移。
enum PageBackdropPreset {
  /// 角落三块形状（10-25 定版，默认）。
  corner('corner'),

  /// 纯色：只有页面底色，不画装饰。
  plain('plain'),

  /// 十几块小号 M3E 形状散在整页。
  confetti('confetti'),

  /// 三团柔和的径向渐变色斑。
  mesh('mesh'),

  /// 右上巨大圆弧 + 同心细环 + 左下 sunny 形状。
  arc('arc'),

  /// 底部三层错开的波浪色带。
  wave('wave'),

  /// 右下一块只露一半的巨大 sunny 形状，开动效时极慢自转。
  sunny('sunny'),

  /// 用户上传的图片。
  custom('custom');

  const PageBackdropPreset(this.wire);

  final String wire;

  static PageBackdropPreset fromWire(Object? raw) {
    for (final PageBackdropPreset preset in values) {
      if (preset.wire == raw) return preset;
    }
    return PageBackdropPreset.corner;
  }
}

/// 形状类预设的浓淡（乘在各形状的不透明度上）。
enum PageBackdropStrength {
  subtle('subtle', 0.6),
  standard('standard', 1),
  strong('strong', 1.45);

  const PageBackdropStrength(this.wire, this.factor);

  final String wire;
  final double factor;

  static PageBackdropStrength fromWire(Object? raw) {
    for (final PageBackdropStrength strength in values) {
      if (strength.wire == raw) return strength;
    }
    return PageBackdropStrength.standard;
  }
}

/// 自定义图片的模糊档（逻辑像素 sigma）。
enum PageBackdropBlur {
  none('none', 0),
  light('light', 6),
  heavy('heavy', 16);

  const PageBackdropBlur(this.wire, this.sigma);

  final String wire;
  final double sigma;

  static PageBackdropBlur fromWire(Object? raw) {
    for (final PageBackdropBlur blur in values) {
      if (blur.wire == raw) return blur;
    }
    return PageBackdropBlur.none;
  }
}

/// 自定义图片遮罩浓度的取值范围（盖在图上的页面底色不透明度）。
const double kPageBackdropScrimMin = 0;
const double kPageBackdropScrimMax = 0.85;
const double kPageBackdropScrimDefault = 0.5;

/// 从图片取出的候选种子色最多几个（设置页让用户挑）。
const int kPageBackdropSeedCandidates = 4;

/// 偏好键。样式类随 Profile 走（与主题同族）；图片路径与取色缓存是**设备本地**
/// 文件，登记在 `SyncRepository.deviceLocalPrefKeys` 与 `ProfileKeys` 排除表里。
const String kPageBackdropPresetPrefKey = 'page_backdrop_preset';
const String kPageBackdropStrengthPrefKey = 'page_backdrop_strength';
const String kPageBackdropMotionPrefKey = 'page_backdrop_motion';
const String kPageBackdropImageBlurPrefKey = 'page_backdrop_image_blur';
const String kPageBackdropImageScrimPrefKey = 'page_backdrop_image_scrim';
const String kPageBackdropFollowImageAccentPrefKey =
    'page_backdrop_follow_image_accent';
const String kPageBackdropAccentIndexPrefKey = 'page_backdrop_accent_index';
const String kPageBackdropLandscapeImagePrefKey =
    'page_backdrop_image_landscape';
const String kPageBackdropPortraitImagePrefKey = 'page_backdrop_image_portrait';
const String kPageBackdropSeedCachePrefKey = 'page_backdrop_seed_cache';

/// 设备本地的那几个键（图片文件路径 + 取色缓存）。
const List<String> kPageBackdropDeviceLocalPrefKeys = <String>[
  kPageBackdropLandscapeImagePrefKey,
  kPageBackdropPortraitImagePrefKey,
  kPageBackdropSeedCachePrefKey,
];

/// 当前生效的页面背景设置（不可变快照）。
@immutable
class PageBackdropSettings {
  const PageBackdropSettings({
    this.preset = PageBackdropPreset.corner,
    this.strength = PageBackdropStrength.standard,
    this.motion = false,
    this.landscapeImagePath,
    this.portraitImagePath,
    this.blur = PageBackdropBlur.none,
    this.scrim = kPageBackdropScrimDefault,
  });

  final PageBackdropPreset preset;
  final PageBackdropStrength strength;

  /// 缓慢漂移 / 自转（系统「减弱动态效果」与墨水屏下不动）。
  final bool motion;

  /// 横屏（以及没单独设竖屏图时的竖屏）用的图片文件。
  final String? landscapeImagePath;

  /// 竖屏单独用的图片文件；null = 与横屏共用。
  final String? portraitImagePath;

  final PageBackdropBlur blur;
  final double scrim;

  /// 是否真有一张可用的自定义图片（预设是 custom 且横屏图存在）。
  bool get hasCustomImage =>
      preset == PageBackdropPreset.custom && landscapeImagePath != null;

  /// 按视口朝向挑图：竖屏且单独设了竖屏图时用竖屏图。
  String? imagePathFor({required bool portrait}) {
    if (!hasCustomImage) return null;
    if (portrait && portraitImagePath != null) return portraitImagePath;
    return landscapeImagePath;
  }

  /// 实际要画的样式：选了自定义但图片不在（换了设备、文件被删）时回落到默认形状。
  PageBackdropPreset get effectivePreset =>
      preset == PageBackdropPreset.custom && !hasCustomImage
      ? PageBackdropPreset.corner
      : preset;

  PageBackdropSettings copyWith({
    PageBackdropPreset? preset,
    PageBackdropStrength? strength,
    bool? motion,
    String? Function()? landscapeImagePath,
    String? Function()? portraitImagePath,
    PageBackdropBlur? blur,
    double? scrim,
  }) => PageBackdropSettings(
    preset: preset ?? this.preset,
    strength: strength ?? this.strength,
    motion: motion ?? this.motion,
    landscapeImagePath: landscapeImagePath != null
        ? landscapeImagePath()
        : this.landscapeImagePath,
    portraitImagePath: portraitImagePath != null
        ? portraitImagePath()
        : this.portraitImagePath,
    blur: blur ?? this.blur,
    scrim: scrim ?? this.scrim,
  );

  @override
  bool operator ==(Object other) =>
      other is PageBackdropSettings &&
      other.preset == preset &&
      other.strength == strength &&
      other.motion == motion &&
      other.landscapeImagePath == landscapeImagePath &&
      other.portraitImagePath == portraitImagePath &&
      other.blur == blur &&
      other.scrim == scrim;

  @override
  int get hashCode => Object.hash(
    preset,
    strength,
    motion,
    landscapeImagePath,
    portraitImagePath,
    blur,
    scrim,
  );
}

/// 遮罩浓度夹到合法区间；读到非数字回默认值。
double clampPageBackdropScrim(Object? raw) {
  if (raw is! num) return kPageBackdropScrimDefault;
  return raw
      .toDouble()
      .clamp(kPageBackdropScrimMin, kPageBackdropScrimMax)
      .toDouble();
}

/// 偏好里存的图片路径：空串 / 非字符串 / 文件不存在一律视为没有。
String? existingPageBackdropImagePath(
  Object? raw, {
  bool Function(String path)? exists,
}) {
  if (raw is! String || raw.isEmpty) return null;
  final bool present = (exists ?? (String p) => File(p).existsSync())(raw);
  return present ? raw : null;
}

/// 全局发布点：`ThemeNotifier` 在偏好加载 / 修改后写入，路由层背景与设置页预览
/// 监听它（与 `currentAppIconSelection` 同一做法——背景挂在每个路由上，不经
/// Riverpod）。
final ValueNotifier<PageBackdropSettings> pageBackdropSettings =
    ValueNotifier<PageBackdropSettings>(const PageBackdropSettings());
