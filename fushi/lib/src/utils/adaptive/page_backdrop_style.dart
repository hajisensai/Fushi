import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart' show PrefCodec;
import 'package:path/path.dart' as p;

import 'package:fushi/src/models/home_tab.dart';

/// 页面背景（路由层 `FushiPageBackdrop` 垫在每一页下面的那层）的可切换样式。
///
/// 2026-10-30 用户拍板：在 10-25 定版的「角落三块 M3E 形状」之外扩成一组预设，
/// 并支持用户上传自定义图片、从图片取色。设计稿见
/// `fushi/build/library_material_design/backdrop_presets.html`（本地，不入库）。
///
/// 持久化值（[wire]）冻结，改名等于数据迁移。
///
/// 2026-11-15 所有者拍板：删掉「角落形状」（旧 wire `corner`），默认改为
/// [mesh]（柔光晕染）。存量偏好 / Profile / 同步 / 备份里的 `corner` 不改写，
/// 读取侧经 [fromWire] / [decodePageBackdropModulePresets] 解析为 [mesh]。
enum PageBackdropPreset {
  /// 纯色：只有页面底色，不画装饰。
  plain('plain'),

  /// 十几块小号 M3E 形状散在整页。
  confetti('confetti'),

  /// 三团柔和的径向渐变色斑（柔光晕染，默认）。
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

  /// 新装 / 恢复默认 / 认不出的旧值都落到这里。
  static const PageBackdropPreset defaultPreset = PageBackdropPreset.mesh;

  static PageBackdropPreset fromWire(Object? raw) =>
      _presetFromWireOrNull(raw) ?? defaultPreset;
}

/// 已删除的「角落形状」预设的旧 wire：存量数据里仍可能出现，读取时解析为默认。
const String kPageBackdropLegacyCornerWire = 'corner';

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

/// 按模块单独设的背景预设（反馈 DYI1IOZxSM）：JSON 对象 `{模块 wire: 预设 wire}`，
/// 没出现的模块跟随全局。样式类，随 Profile 走。
const String kPageBackdropModulePresetsPrefKey = 'page_backdrop_module_presets';

/// 按模块单独设的背景图片：JSON 对象
/// `{模块 wire: {"landscape": 路径, "portrait": 路径}}`。文件只在这台设备上，设备本地。
const String kPageBackdropModuleImagesPrefKey = 'page_backdrop_module_images';

/// 设备本地的那几个键（图片文件 + 取色缓存）。
///
/// BUG-5370：图片键（含模块 JSON 与各配置的停放值）存的是背景图目录
/// （`<support>/page_backdrop`）里的**文件名**，读时按当前目录拼成绝对路径
/// （[resolvePageBackdropImagePath]）。以前存绝对路径，iOS 每次安装 / 更新都换容器
/// UUID、桌面换数据根也换 support 根，旧路径悬空，背景图静默回落默认样式。存量绝对
/// 路径由 `ThemeNotifier` 载入时按文件名改写一次（[healPageBackdropImageRef]）。取色
/// 缓存里的路径同样只按文件名比对。这几个键在 `kPathRebasePrefs` 里登记为非路径，守卫
/// `path_rebase_coverage_guard_test.dart` 盯着这份清单。
const List<String> kPageBackdropDeviceLocalPrefKeys = <String>[
  kPageBackdropLandscapeImagePrefKey,
  kPageBackdropPortraitImagePrefKey,
  kPageBackdropSeedCachePrefKey,
  kPageBackdropModuleImagesPrefKey,
];

/// 背景图片按配置记、只留在本机：live 键 → 停放键前缀（后缀 = profile uid）。
///
/// 样式（预设 / 强度 / 模糊…）随 Profile 快照走，图片路径却是设备本地的——两者拆开后切配置
/// 只换样式不换图。这里把图片键接进 `ProfileRepository.perProfileDeviceLocalPrefs`：切走时
/// live 值停放到这份配置名下，切入时换回；没停放过的配置沿用切换前的图（现有全局图就是每份
/// 配置的初始值，不需要迁移）。停放键与 live 键同样设备本地
/// （`PrefRedactionPolicy.deviceLocalKeyPrefixes`）：不进 Profile 快照 / 分享 / 备份 / 设置同步。
/// 取色缓存跟着图走，一并停放，切回来不用重取。
const Map<String, String> kPageBackdropProfileParkedPrefKeyPrefixes =
    <String, String>{
      kPageBackdropLandscapeImagePrefKey: 'page_backdrop_image_landscape::',
      kPageBackdropPortraitImagePrefKey: 'page_backdrop_image_portrait::',
      kPageBackdropModuleImagesPrefKey: 'page_backdrop_module_images::',
      kPageBackdropSeedCachePrefKey: 'page_backdrop_seed_cache::',
    };

/// [prefs]（偏好表原始编码值）里仍在引用的全部背景图（存的原值：文件名或存量绝对
/// 路径，调用方按 [pageBackdropImageFileName] 比对）：live 键与各配置停放的值，
/// 全局两张 + 各模块的。[skipParkedUid] 的停放值不算——激活配置的停放值是它上次切走时
/// 的旧值，live 键才是它现在的图（下次切走会被覆盖），算进去只会让换掉的旧图多留一阵。
Set<String> pageBackdropReferencedImagePaths(
  Map<String, String> prefs, {
  String? skipParkedUid,
}) {
  final Set<String> out = <String>{};
  void addPath(Object? value) {
    if (value is String && value.isNotEmpty) out.add(value);
  }

  void addModuleImages(Object? value) {
    for (final PageBackdropModuleImages images
        in decodePageBackdropModuleImages(value).values) {
      addPath(images.landscape);
      addPath(images.portrait);
    }
  }

  prefs.forEach((String key, String raw) {
    for (final MapEntry<String, String> e
        in kPageBackdropProfileParkedPrefKeyPrefixes.entries) {
      if (e.key == kPageBackdropSeedCachePrefKey) continue;
      final bool live = key == e.key;
      final bool parked =
          key.startsWith(e.value) &&
          (skipParkedUid == null || key != '${e.value}$skipParkedUid');
      if (!live && !parked) continue;
      // 停放值是 live 原始编码值的原样拷贝；空串 = 那份配置没设图。
      if (raw.isEmpty) return;
      final Object? value = PrefCodec.decodeUntyped(raw);
      if (e.key == kPageBackdropModuleImagesPrefKey) {
        addModuleImages(value);
      } else {
        addPath(value);
      }
      return;
    }
  });
  return out;
}

/// 当前生效的页面背景设置（不可变快照）。
@immutable
class PageBackdropSettings {
  const PageBackdropSettings({
    this.preset = PageBackdropPreset.defaultPreset,
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

  /// 实际要画的样式：选了自定义但图片不在（换了设备、文件被删）时回落到默认样式。
  PageBackdropPreset get effectivePreset =>
      preset == PageBackdropPreset.custom && !hasCustomImage
      ? PageBackdropPreset.defaultPreset
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

/// [path]（文件名或存量绝对路径，`/` 与 `\` 两种分隔符都认）的文件名部分。
String pageBackdropImageFileName(String path) {
  final int cut = path.lastIndexOf(RegExp(r'[\\/]'));
  return cut < 0 ? path : path.substring(cut + 1);
}

/// 偏好里的图片值（文件名，或 BUG-5370 之前写下的绝对路径）→ 本机绝对路径。
///
/// 文件名按 [directory]（当前背景图目录）拼；[directory] 还没解析出来时返回 null
/// （当作暂时没有图，目录解析后会重发布）。存量绝对路径原样返回（载入时能按文件名
/// 找回的已被 [healPageBackdropImageRef] 改写成文件名，剩下的是真不在本机的）。
String? resolvePageBackdropImagePath(
  Object? raw, {
  required String? directory,
}) {
  if (raw is! String || raw.isEmpty) return null;
  if (pageBackdropImageFileName(raw) != raw) return raw;
  if (directory == null) return null;
  return p.join(directory, raw);
}

/// 存量绝对路径值的迁移：文件名在当前背景图目录里（[inDirectory] 判）就返回该文件名，
/// 否则（已是文件名 / 空值 / 文件不在目录里）返回 null = 不改写。
String? healPageBackdropImageRef(
  Object? raw, {
  required bool Function(String name) inDirectory,
}) {
  if (raw is! String || raw.isEmpty) return null;
  final String name = pageBackdropImageFileName(raw);
  if (name == raw || name.isEmpty) return null;
  return inDirectory(name) ? name : null;
}

/// [kPageBackdropModuleImagesPrefKey] 值（解码后的 JSON 串）里的存量绝对路径按
/// [healPageBackdropImageRef] 改写；没有要改的返回 null。
String? healPageBackdropModuleImagesValue(
  Object? raw, {
  required bool Function(String name) inDirectory,
}) {
  final Map<HomeTab, PageBackdropModuleImages> images =
      decodePageBackdropModuleImages(raw);
  bool changed = false;
  String? heal(String? path) {
    final String? healed = healPageBackdropImageRef(
      path,
      inDirectory: inDirectory,
    );
    if (healed == null) return path;
    changed = true;
    return healed;
  }

  final Map<HomeTab, PageBackdropModuleImages> out =
      <HomeTab, PageBackdropModuleImages>{
        for (final MapEntry<HomeTab, PageBackdropModuleImages> e
            in images.entries)
          e.key: (
            landscape: heal(e.value.landscape),
            portrait: heal(e.value.portrait),
          ),
      };
  return changed ? encodePageBackdropModuleImages(out) : null;
}

/// 偏好里存的图片路径：空串 / 非字符串 / [exists] 判为不存在的一律视为没有。
///
/// [exists] 由调用方给（`ThemeNotifier` 传异步核对过的结果）：快照在 UI isolate
/// 上频繁重读，这里刻意不做同步文件 IO。
String? existingPageBackdropImagePath(
  Object? raw, {
  required bool Function(String path) exists,
}) {
  if (raw is! String || raw.isEmpty) return null;
  final bool present = exists(raw);
  return present ? raw : null;
}

/// 全局发布点：`ThemeNotifier` 在偏好加载 / 修改后写入，路由层背景与设置页预览
/// 监听它（与 `currentAppIconSelection` 同一做法——背景挂在每个路由上，不经
/// Riverpod）。
final ValueNotifier<PageBackdropSettings> pageBackdropSettings =
    ValueNotifier<PageBackdropSettings>(const PageBackdropSettings());

// ── 按模块单独设置（反馈 DYI1IOZxSM，2026-11-04）─────────────────────────────
//
// 「模块」= 主导航顶层 tab（[HomeTab]）。某个模块单独设了预设（可以是自定义图片）
// 就用它，没设的模块用全局背景。只覆盖「画什么」（预设 + 图片）：强度 / 模糊 /
// 遮罩 / 漂移动效沿用全局；**应用配色只取全局背景图**（用户要求主题配色全局统一，
// 不随模块切换变色），所以模块图片不参与取色。

/// 模块在偏好里的 wire（冻结：改了等于数据迁移）。不直接用 `HomeTab.name`，
/// 免得枚举改名悄悄丢掉用户的设置。
String pageBackdropModuleWire(HomeTab tab) => switch (tab) {
  HomeTab.home => 'home',
  HomeTab.books => 'books',
  HomeTab.manga => 'manga',
  HomeTab.video => 'video',
  HomeTab.music => 'music',
  HomeTab.browse => 'browse',
  HomeTab.dictionaries => 'dictionaries',
  HomeTab.srs => 'srs',
  HomeTab.games => 'games',
  HomeTab.web => 'web',
  HomeTab.settings => 'settings',
};

/// [pageBackdropModuleWire] 的反向；认不出的返回 null（旧版本 / 别的设备写的）。
HomeTab? pageBackdropModuleFromWire(Object? raw) {
  for (final HomeTab tab in HomeTab.values) {
    if (pageBackdropModuleWire(tab) == raw) return tab;
  }
  return null;
}

/// 某个模块单独设的背景（不可变）。
@immutable
class PageBackdropModuleOverride {
  const PageBackdropModuleOverride({
    required this.preset,
    this.landscapeImagePath,
    this.portraitImagePath,
  });

  final PageBackdropPreset preset;

  /// 本模块的横屏图（以及没单独设竖屏图时的竖屏图）；已核对过存在。
  final String? landscapeImagePath;

  /// 本模块竖屏单独用的图；null = 与本模块横屏图共用。
  final String? portraitImagePath;

  /// 选了自定义图片却没有可用的图（换了设备 / 文件被删）时，这个模块退回全局。
  bool get usable =>
      preset != PageBackdropPreset.custom || landscapeImagePath != null;

  @override
  bool operator ==(Object other) =>
      other is PageBackdropModuleOverride &&
      other.preset == preset &&
      other.landscapeImagePath == landscapeImagePath &&
      other.portraitImagePath == portraitImagePath;

  @override
  int get hashCode =>
      Object.hash(preset, landscapeImagePath, portraitImagePath);
}

/// 把模块单独的设置叠到全局设置上：没设 / 不可用时原样返回全局。
PageBackdropSettings resolvePageBackdropSettings(
  PageBackdropSettings global,
  PageBackdropModuleOverride? override,
) {
  if (override == null || !override.usable) return global;
  return global.copyWith(
    preset: override.preset,
    landscapeImagePath: () => override.landscapeImagePath,
    portraitImagePath: () => override.portraitImagePath,
  );
}

/// 解析 [kPageBackdropModulePresetsPrefKey] 的值：坏 JSON / 认不出的模块或预设
/// 一律跳过（等于那个模块跟随全局）；已删除的「角落形状」旧值解析为默认预设。
Map<HomeTab, PageBackdropPreset> decodePageBackdropModulePresets(Object? raw) {
  final Map<String, Object?> json = _decodeJsonObject(raw);
  final Map<HomeTab, PageBackdropPreset> out = <HomeTab, PageBackdropPreset>{};
  json.forEach((String key, Object? value) {
    final HomeTab? tab = pageBackdropModuleFromWire(key);
    if (tab == null || value is! String) return;
    final PageBackdropPreset? preset = _presetFromWireOrNull(value);
    if (preset != null) out[tab] = preset;
  });
  return out;
}

String encodePageBackdropModulePresets(Map<HomeTab, PageBackdropPreset> map) =>
    jsonEncode(<String, String>{
      for (final MapEntry<HomeTab, PageBackdropPreset> e in map.entries)
        pageBackdropModuleWire(e.key): e.value.wire,
    });

/// 某个模块的两张图片路径（未核对存在与否）。
typedef PageBackdropModuleImages = ({String? landscape, String? portrait});

/// 解析 [kPageBackdropModuleImagesPrefKey] 的值；空串路径视为没有。
Map<HomeTab, PageBackdropModuleImages> decodePageBackdropModuleImages(
  Object? raw,
) {
  final Map<String, Object?> json = _decodeJsonObject(raw);
  final Map<HomeTab, PageBackdropModuleImages> out =
      <HomeTab, PageBackdropModuleImages>{};
  json.forEach((String key, Object? value) {
    final HomeTab? tab = pageBackdropModuleFromWire(key);
    if (tab == null || value is! Map) return;
    String? path(Object? v) => v is String && v.isNotEmpty ? v : null;
    final PageBackdropModuleImages images = (
      landscape: path(value['landscape']),
      portrait: path(value['portrait']),
    );
    if (images.landscape != null || images.portrait != null) {
      out[tab] = images;
    }
  });
  return out;
}

String encodePageBackdropModuleImages(
  Map<HomeTab, PageBackdropModuleImages> map,
) => jsonEncode(<String, Object>{
  for (final MapEntry<HomeTab, PageBackdropModuleImages> e in map.entries)
    if (e.value.landscape != null || e.value.portrait != null)
      pageBackdropModuleWire(e.key): <String, String>{
        if (e.value.landscape case final String l) 'landscape': l,
        if (e.value.portrait case final String p) 'portrait': p,
      },
});

/// 偏好值不是 JSON 对象（缺键、空串、坏数据）时按「没有任何模块单独设置」处理。
Map<String, Object?> _decodeJsonObject(Object? raw) {
  if (raw is! String || raw.isEmpty) return const <String, Object?>{};
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <String, Object?>{};
  }
  return decoded is Map<String, Object?> ? decoded : const <String, Object?>{};
}

PageBackdropPreset? _presetFromWireOrNull(Object? raw) {
  if (raw == kPageBackdropLegacyCornerWire) {
    return PageBackdropPreset.defaultPreset;
  }
  for (final PageBackdropPreset preset in PageBackdropPreset.values) {
    if (preset.wire == raw) return preset;
  }
  return null;
}

/// 全局发布点：各模块单独设的背景（只含有设置的模块）。`ThemeNotifier` 写入，
/// 路由层背景与设置页监听。
final ValueNotifier<Map<HomeTab, PageBackdropModuleOverride>>
pageBackdropModuleOverrides =
    ValueNotifier<Map<HomeTab, PageBackdropModuleOverride>>(
      const <HomeTab, PageBackdropModuleOverride>{},
    );

/// [module] 实际生效的背景设置（null = 不属于任何模块，用全局）。
PageBackdropSettings pageBackdropSettingsFor(HomeTab? module) =>
    resolvePageBackdropSettings(
      pageBackdropSettings.value,
      module == null ? null : pageBackdropModuleOverrides.value[module],
    );
