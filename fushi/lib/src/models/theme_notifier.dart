import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:dynamic_color/dynamic_color.dart';
import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder, CupertinoRouteTransitionMixin;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_transitions.dart';
import 'package:fushi/src/utils/adaptive/predictive_back_page_transitions.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/fushi_m3e_misc_themes.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/system_transparency.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/fushi_color_roles.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 钉死色上的文字色：黑 / 白里取 WCAG 对比度更高的那个。
///
/// 以前用 `ThemeData.estimateBrightnessForColor`（相对亮度阈值 0.15）：亮度落在
/// 0.15..0.179 之间的中灰（如 #6E6E6E）会被判「亮」配黑字，对比度只有 ~4.1，
/// 不到 WCAG AA 的 4.5；黑白对比度相等的分界其实是 0.179。直接比对比度，任何
/// 钉死色都至少 4.58:1。
Color _readableOnColor(Color color) {
  final double l = color.computeLuminance();
  final double onBlack = (l + 0.05) / 0.05;
  final double onWhite = 1.05 / (l + 0.05);
  return onWhite >= onBlack ? Colors.white : Colors.black;
}

Color _deriveContainer(Color role, Brightness brightness) {
  final Color target =
      brightness == Brightness.dark ? Colors.black : Colors.white;
  return Color.lerp(role, target, brightness == Brightness.dark ? 0.7 : 0.85)!;
}

/// Resolve the `system-theme` [ColorScheme] from whatever the OS actually
/// exposed.
///
/// `DynamicColorPlugin.getCorePalette()` only returns a non-null [palette] on
/// Android (it reads `@android:color/system_*`). On Windows / macOS / Linux it
/// is always null, and the OS theme color is instead exposed through
/// `getAccentColor()`. The canonical dynamic_color path (see its own
/// `DynamicColorBuilder`) is therefore: prefer the full [palette]; otherwise
/// seed from the OS [accent]; and only when the OS exposes neither, fall back
/// to [fallbackSeed]. Missing this [accent] branch is exactly why `system-theme`
/// never followed the Windows accent color at startup (BUG-090).
ColorScheme buildSystemThemeColorScheme({
  required Brightness brightness,
  required Color fallbackSeed,
  CorePalette? palette,
  Color? accent,
}) {
  if (palette != null) {
    return palette.toColorScheme(brightness: brightness);
  }
  final Color seed = accent ?? fallbackSeed;
  return ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    // 灰色系统强调色（Windows「自动」灰 / 石墨）没有可信色相，vibrant 会把量化色相
    // 拉成鲜蓝；这类 seed 维持 tonalSpot 的低彩度结果。
    dynamicSchemeVariant: isAchromaticSeed(seed)
        ? DynamicSchemeVariant.tonalSpot
        : kFushiDefaultSchemeVariant,
  );
}

/// M3 Expressive 的默认方案变体：vibrant。
///
/// M3E 要「饱和的 container 色块」：tonalSpot 的 primary 彩度只有 36、容器偏灰，
/// vibrant 把 primary 调色板彩度拉满（同色相，品牌色不跑偏），secondary / tertiary
/// 容器也更鲜明；expressive 变体会把 primary 色相整体旋转（青色 seed 出紫粉主色），
/// 预设之间的色相区分与品牌色都会丢，所以不用作默认。角色色调（tone）与 tonalSpot
/// 同一套，on-色对比度由 DynamicScheme 保证（见 theme_contrast_test.dart）。
/// 中性灰预设仍用 neutral，无彩度 seed 仍走 monochrome，墨水屏不受影响。
const DynamicSchemeVariant kFushiDefaultSchemeVariant =
    DynamicSchemeVariant.vibrant;

/// [buildFushiColorScheme] 的纯函数 memo：`ColorScheme.fromSeed` 走 HCT 色调板
/// 生成、单次非平凡；阅读设置抽屉的主题选择器每次 rebuild 会对每张色卡各调一次
/// （系统 + 预设 7 + 自定义 N），拖字号 slider 时每个 tick 全表 setState 就是
/// 每 tick 一场 HCT 风暴（BUG-969）。入参→结果是纯映射，按参数键缓存即可整体
/// 消除。有界防自定义主题编辑时无限膨胀（编辑逐色微调会产生大量一次性键）。
typedef _FushiSchemeKey = (
  int seed,
  Brightness brightness,
  DynamicSchemeVariant variant,
  int? primary,
  int? secondary,
  int? tertiary,
  int? primaryContainer,
  int? surface,
  bool neutralDerived,
  bool pureBlack,
);
final Map<_FushiSchemeKey, ColorScheme> _hibikiSchemeCache =
    <_FushiSchemeKey, ColorScheme>{};
const int _hibikiSchemeCacheLimit = 64;

/// [surface]：用户钉死的界面底色（页面 / 卡片 / 菜单）。给了就用
/// [deriveSurfaceRolesFrom] 从它推出整套中性角色（容器梯度、文字、描边、反色），
/// 不再从 seed 的中性调色板取——那套永远带主题色相（tonalSpot neutral chroma 6），
/// 用户想要纯白 / 纯黑底色时没有别的路。
///
/// [pureBlack]：深色下表面走 [applyFushiPureBlackSurfaceLadder]（页面底真黑），
/// 内置「纯黑」预设用；亮色下不起作用。
ColorScheme buildFushiColorScheme({
  required Color seedColor,
  required Brightness brightness,
  DynamicSchemeVariant variant = kFushiDefaultSchemeVariant,
  Color? primary,
  Color? secondary,
  Color? tertiary,
  Color? primaryContainer,
  Color? surface,
  bool neutralDerived = false,
  bool pureBlack = false,
}) {
  final _FushiSchemeKey key = (
    seedColor.toARGB32(),
    brightness,
    variant,
    primary?.toARGB32(),
    secondary?.toARGB32(),
    tertiary?.toARGB32(),
    primaryContainer?.toARGB32(),
    surface?.toARGB32(),
    neutralDerived,
    pureBlack,
  );
  final ColorScheme? cached = _hibikiSchemeCache[key];
  if (cached != null) return cached;
  // 中性派生：标签 / 选中项 / 菜单 / 表面这些「派生色」一律灰阶，只留主题色本身
  // 作强调（Windows 亮色主题那种观感）。两种情况走这条路：用户显式开了
  // [neutralDerived]；或 seed 本身无彩度（白 / 灰 / 黑，HCT chroma 极小）——这种
  // seed 在 HCT 里仍有一个随机色相（纯白 ≈ 209°，偏蓝），tonalSpot 又强制给中性色
  // 6 的彩度，结果「选了白色，界面却发蓝」。无彩度的 seed 没有任何色相可言，派生
  // 出带色相的界面只能算 bug。
  final bool neutral = neutralDerived || isAchromaticSeed(seedColor);
  final ColorScheme base = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
    dynamicSchemeVariant: neutral ? DynamicSchemeVariant.monochrome : variant,
  );
  // 中性派生下主色相关角色仍要来自 seed 自己的色调板（monochrome 会把 primary
  // 也压成灰）：没钉死主色时取 tonalSpot 的 primary / primaryContainer；钉死了主色
  // 但没钉控件底色时，控件底色从钉死的主色推。
  final ColorScheme? accentBase =
      neutral && (primary == null || primaryContainer == null)
          ? ColorScheme.fromSeed(
              seedColor: seedColor,
              brightness: brightness,
              // 无彩度 seed（白 / 灰 / 黑）只有 HCT 量化出的随机色相：vibrant 会把它
              // 拉成满彩度的蓝，选白色主题却得到鲜蓝强调色。这类 seed 的强调色沿用
              // tonalSpot 的低彩度版本（与 M3E 前一致）。
              dynamicSchemeVariant: isAchromaticSeed(seedColor) &&
                      variant == DynamicSchemeVariant.vibrant
                  ? DynamicSchemeVariant.tonalSpot
                  : variant,
            )
          : null;
  final Color? accent = neutral ? (primary ?? accentBase!.primary) : primary;
  final Color? accentContainer = neutral
      ? (primaryContainer ??
          (primary != null
              ? _deriveContainer(primary, brightness)
              : accentBase!.primaryContainer))
      : primaryContainer;
  final Color? secContainer =
      secondary != null ? _deriveContainer(secondary, brightness) : null;
  final Color? terContainer =
      tertiary != null ? _deriveContainer(tertiary, brightness) : null;
  if (_hibikiSchemeCache.length >= _hibikiSchemeCacheLimit) {
    _hibikiSchemeCache.remove(_hibikiSchemeCache.keys.first);
  }
  final SurfaceRoles? surfaceRoles =
      surface != null ? deriveSurfaceRolesFrom(surface) : null;
  final ColorScheme withRoles = base.copyWith(
    primary: accent ?? base.primary,
    onPrimary: accent != null ? _readableOnColor(accent) : base.onPrimary,
    // 钉死主色后，从主色派生的两个角色也必须跟着走：inversePrimary 是视频播放器
    // 浅色主题的控件强调色（video_chrome_colors.dart），surfaceTint 决定 M3 表面
    // 上叠的主题色——否则用户改了主题色，播放器仍是 seed 派生的旧色。
    inversePrimary: accent != null
        ? _inversePrimaryFor(accent, brightness)
        : base.inversePrimary,
    // 中性派生下表面不再被主题色叠层染回。
    surfaceTint: neutral ? Colors.transparent : (accent ?? base.surfaceTint),
    secondary: secondary ?? base.secondary,
    onSecondary:
        secondary != null ? _readableOnColor(secondary) : base.onSecondary,
    secondaryContainer: secContainer ?? base.secondaryContainer,
    onSecondaryContainer: secContainer != null
        ? _readableOnColor(secContainer)
        : base.onSecondaryContainer,
    tertiary: tertiary ?? base.tertiary,
    onTertiary: tertiary != null ? _readableOnColor(tertiary) : base.onTertiary,
    tertiaryContainer: terContainer ?? base.tertiaryContainer,
    onTertiaryContainer: terContainer != null
        ? _readableOnColor(terContainer)
        : base.onTertiaryContainer,
    primaryContainer: accentContainer ?? base.primaryContainer,
    onPrimaryContainer: accentContainer != null
        ? _readableOnColor(accentContainer)
        : base.onPrimaryContainer,
  );
  if (surfaceRoles == null) {
    return _hibikiSchemeCache[key] = pureBlack
        ? applyFushiPureBlackSurfaceLadder(withRoles)
        : applyFushiSurfaceLadder(withRoles);
  }
  return _hibikiSchemeCache[key] = withRoles.copyWith(
    surface: surfaceRoles.surface,
    surfaceDim: surfaceRoles.surfaceDim,
    surfaceBright: surfaceRoles.surfaceBright,
    surfaceContainerLowest: surfaceRoles.surfaceContainerLowest,
    surfaceContainerLow: surfaceRoles.surfaceContainerLow,
    surfaceContainer: surfaceRoles.surfaceContainer,
    surfaceContainerHigh: surfaceRoles.surfaceContainerHigh,
    surfaceContainerHighest: surfaceRoles.surfaceContainerHighest,
    onSurface: surfaceRoles.onSurface,
    onSurfaceVariant: surfaceRoles.onSurfaceVariant,
    outline: surfaceRoles.outline,
    outlineVariant: surfaceRoles.outlineVariant,
    inverseSurface: surfaceRoles.inverseSurface,
    onInverseSurface: surfaceRoles.onInverseSurface,
    // 用户钉了底色就不该再被 M3 的主题色叠层染回去。
    surfaceTint: Colors.transparent,
  );
}

/// seed 是否无彩度（白 / 灰 / 黑）：HCT chroma < 4。这种 seed 的「色相」只是浮点
/// 噪声，派生界面必须走中性灰阶。
bool isAchromaticSeed(Color seed) => Hct.fromInt(seed.toARGB32()).chroma < 4;

/// 钉死主色的反色主色：同色相/彩度，色调换到另一明暗档（M3 primary 亮 40 / 暗 80）。
Color _inversePrimaryFor(Color primary, Brightness brightness) {
  final Hct hct = Hct.fromInt(primary.toARGB32());
  final double tone = brightness == Brightness.dark ? 40 : 80;
  return Color(Hct.from(hct.hue, hct.chroma, tone).toInt());
}

/// 从一个用户指定的底色推出的整套中性角色（界面背景可钉死）。
typedef SurfaceRoles = ({
  Color surface,
  Color surfaceDim,
  Color surfaceBright,
  Color surfaceContainerLowest,
  Color surfaceContainerLow,
  Color surfaceContainer,
  Color surfaceContainerHigh,
  Color surfaceContainerHighest,
  Color onSurface,
  Color onSurfaceVariant,
  Color outline,
  Color outlineVariant,
  Color inverseSurface,
  Color onInverseSurface,
});

/// Hibiki 的表面层级 tone 表（顺序：containerLowest / surface / containerLow /
/// container / containerHigh / containerHighest）。
///
/// M3 baseline 的六级容器色在亮色下是 tone 100/98/96/94/92/90——相邻只差 2
/// tone，折合 WCAG 对比度约 **1.05**，远低于大面积色块的可辨阈值。M3 本来指望
/// elevation 阴影与 surfaceTint 叠层承担层次，色差只作辅助；但 Hibiki 是
/// 「扁平 + 描边」的视觉语言，全局 `elevation: 0` 且 surfaceTint 一律
/// [Colors.transparent]，阴影和叠层都不存在——层次就只剩这 1.05 的色差。
///
/// 更糟的是 [FushiSurfaceColors] 的映射恰好落在阶梯最挤的一段：
/// page=surface(98) / group=surfaceContainerLow(96) / card=surfaceContainer(94)，
/// 这三层是设置页、书架、媒体库里最常同屏出现的组合，总跨度却只有 1.11；而
/// 间距最大的 High / Highest 反倒给了搜索框和菜单这些小面积控件。结果就是页面
/// 底、导航窗格、卡片糊成一片，既不像分层也不像扁平。
///
/// 这里把六级重新排布：相邻层 ≥ 1.07、页面↔卡片 1.16（原 1.11），并把深色下
/// baseline 本身就不均匀的阶梯（1.079 / 1.045 / 1.147 / 1.167）拉齐。**只改
/// tone，色相与彩度沿用原方案**，所以每个主题的性格不变，只是层级看得见了。
///
/// 亮色下探到 93.5 就打住，是因为 tone 90 是 `secondaryContainer` 等
/// `*Container` 角色的地盘：卡片再往下压就会贴上选中态的明度，列表选中项反而
/// 糊掉（压到 92.5 时实测 secondaryContainer↔卡片从 1.109 掉到 1.069）。深色
/// 没有这个约束——那边 `secondaryContainer` 在 tone 30，离得远。
const List<double> _lightSurfaceTones =
    <double>[100, 99.5, 96.5, 93.5, 90.5, 87];
const List<double> _darkSurfaceTones = <double>[3, 5, 9.5, 14, 19, 24];

/// 把 [scheme] 的六级表面按 [_lightSurfaceTones] / [_darkSurfaceTones] 重算。
///
/// 三条主题路径（系统取色 / 内置预设 / 自定义 seed）出口都过这一道，所以层级
/// 关系是全应用、全平台唯一的：Android 的 `CorePalette.toColorScheme()`（来自
/// 系统壁纸）与桌面的 `fromSeed(accent)` 原本会推出**间距不同**的两套阶梯，
/// 同一个「系统」主题在手机和桌面观感并不一致，收口后两端一致。
///
/// 两种情况不覆盖：墨水屏由 [buildEinkColorScheme] 全塌成纯黑白（层次改由描边
/// 承担），用户钉死底色则走 [deriveSurfaceRolesFrom] 从钉死的那个色推同比例
/// 阶梯——都在各自出口保持语义。
ColorScheme applyFushiSurfaceLadder(ColorScheme scheme) {
  final bool light = scheme.brightness == Brightness.light;
  final List<double> tones = light ? _lightSurfaceTones : _darkSurfaceTones;
  // 锚定原方案的中性色相 / 彩度：tonalSpot 给中性色 chroma 6、monochrome 给 0，
  // 取 surfaceContainer 的 HCT 就能原样继承，不必区分 variant。
  final Hct anchor = Hct.fromInt(scheme.surfaceContainer.toARGB32());
  Color at(double tone) => hctToneKeepingHue(anchor.hue, anchor.chroma, tone);
  return scheme.copyWith(
    surfaceContainerLowest: at(tones[0]),
    surface: at(tones[1]),
    surfaceContainerLow: at(tones[2]),
    surfaceContainer: at(tones[3]),
    surfaceContainerHigh: at(tones[4]),
    surfaceContainerHighest: at(tones[5]),
    // dim / bright 是页面底自己的暗 / 亮变体，必须跟着走：亮色把 highest 压到
    // tone 87 之后，baseline 的 dim(亮 87 / 暗 6) 不再比 highest 暗，语义就倒了。
    surfaceBright: at(light ? tones[1] : 26),
    surfaceDim: at(light ? 85 : 4),
  );
}

/// 深色「纯黑」阶梯（OLED 省电 / 纯黑阅读）：页面底与最低层都是真黑 #000，
/// 其余四级沿用与 [_darkSurfaceTones] 同样的间距往上推，卡片、菜单仍看得出层次。
const List<double> _pureBlackSurfaceTones = <double>[0, 0, 4.5, 9, 14, 19];

/// 深色下把 [scheme] 的表面换成 [_pureBlackSurfaceTones]；亮色原样走
/// [applyFushiSurfaceLadder]——纯黑只是深色的一个变体，用户把全局明暗切到浅色时
/// 这个预设就是一套普通的浅色方案。
ColorScheme applyFushiPureBlackSurfaceLadder(ColorScheme scheme) {
  if (scheme.brightness == Brightness.light) {
    return applyFushiSurfaceLadder(scheme);
  }
  const List<double> tones = _pureBlackSurfaceTones;
  final Hct anchor = Hct.fromInt(scheme.surfaceContainer.toARGB32());
  Color at(double tone) => hctToneKeepingHue(anchor.hue, anchor.chroma, tone);
  return scheme.copyWith(
    surfaceContainerLowest: at(tones[0]),
    surface: at(tones[1]),
    surfaceContainerLow: at(tones[2]),
    surfaceContainer: at(tones[3]),
    surfaceContainerHigh: at(tones[4]),
    surfaceContainerHighest: at(tones[5]),
    surfaceBright: at(24),
    surfaceDim: at(0),
  );
}

/// 按 [hue] / [chroma] / [tone] 取色，但**不许色相漂移**。
///
/// HCT 在极亮 / 极暗端能容纳的彩度很小，请求的彩度超出色域时求解器会连色相一起
/// 漂走：米黄主题（色相 74°）在 tone 99.5 解出的是偏紫的 `#fffdff`（色相 252°），
/// 暖色主题的页面底成了冷白。这里逐级降彩度直到解出的色相落回 [hue] 附近；解出
/// 的彩度不再高于同 tone 纯灰时就退回纯灰。
///
/// 基准是「同 tone 纯灰在 HCT 里读出的彩度」而不是 0：HCT 在极亮端连纯灰都读出
/// 彩度 ~2.8，中性 / monochrome 方案的锚点彩度就落在这一带——它本来就是灰，没有
/// 色相可守，原样取解；否则往更低彩度试反而会解出 #fbfeff 这类更偏的颜色。
Color hctToneKeepingHue(double hue, double chroma, double tone) {
  final int gray = Hct.from(hue, 0, tone).toInt();
  final double grayChroma = Hct.fromInt(gray).chroma;
  if (chroma <= grayChroma + 0.5) {
    return Color(Hct.from(hue, chroma, tone).toInt());
  }
  double c = chroma;
  while (c > grayChroma) {
    final int argb = Hct.from(hue, c, tone).toInt();
    final Hct back = Hct.fromInt(argb);
    final double d = (back.hue - hue).abs() % 360;
    final double hueDistance = d > 180 ? 360 - d : d;
    if (hueDistance <= 10 && back.chroma <= chroma + 1.5) return Color(argb);
    c /= 2;
  }
  return Color(gray);
}

/// 以 [surface] 为页面底色，向对比端（底色偏亮 → 暗，偏暗 → 亮）逐级推出分组 /
/// 卡片 / 搜索框 / 菜单四级底色与文字、描边、反色。
///
/// 层级走 HCT **tone 增量**，间距与 [applyFushiSurfaceLadder] 同源，用户钉底色
/// 前后层次不会一跳。原先是按固定比例向黑 / 白 `Color.lerp`，有两个毛病：比例
/// 照抄 M3 baseline，比新阶梯挤将近一半；而且 sRGB 混色不是感知均匀的——同样
/// 4% 的比例，纯白底下推出的层次清晰可辨，纯黑底下只有 1.06 的对比度（gamma
/// 在暗端压得厉害），钉死纯黑的自定义主题层级基本是看不见的。
///
/// 编辑页预览与词典弹窗都复用它，保证所见即所得。
SurfaceRoles deriveSurfaceRolesFrom(Color surface) {
  final bool dark =
      ThemeData.estimateBrightnessForColor(surface) == Brightness.dark;
  final Color contrast = dark ? Colors.white : Colors.black;
  Color step(double t) => Color.lerp(surface, contrast, t)!;
  // 钉死的底色自己在 HCT 里的位置就是阶梯起点，其余各级按 tone 增量往对比端
  // 走；夹到 [0,100] 是为了钉纯白 / 纯黑这两个端点仍有层次可推。
  final Hct anchor = Hct.fromInt(surface.toARGB32());
  Color tone(double delta) {
    final double t =
        (anchor.tone + (dark ? delta : -delta)).clamp(0, 100).toDouble();
    return Color(Hct.from(anchor.hue, anchor.chroma, t).toInt());
  }

  return (
    surface: surface,
    surfaceDim: dark ? tone(-1) : tone(14.5),
    surfaceBright: surface,
    surfaceContainerLowest: surface,
    surfaceContainerLow: tone(dark ? 4.5 : 3),
    surfaceContainer: tone(dark ? 9 : 6),
    surfaceContainerHigh: tone(dark ? 14 : 9),
    surfaceContainerHighest: tone(dark ? 19 : 12.5),
    onSurface: dark ? const Color(0xDEFFFFFF) : const Color(0xDE000000),
    onSurfaceVariant: dark ? const Color(0x99FFFFFF) : const Color(0x99000000),
    outline: step(0.5),
    outlineVariant: step(0.2),
    inverseSurface: step(0.85),
    onInverseSurface: surface,
  );
}

/// 自定义主题条目 [entry] 的配色——活跃主题、设置色卡与编辑草稿预览的**唯一**
/// 解析链（BUG-2988）。系统取色 / 纯黑 / 墨水屏这三样全局状态显式传入，
/// 调用方（[ThemeNotifier.buildCustomThemeColorScheme]、`AppModel` 的同名门面）
/// 各自取自己那份真值，算法只有这一份。
ColorScheme buildCustomThemeEntryColorScheme(
  CustomThemeEntry entry,
  Brightness brightness, {
  required bool einkMode,
  required bool pureBlack,
  required Color? systemPrimaryColor,
}) {
  if (einkMode) return buildEinkColorScheme(brightness);
  Color? role(int? value) => value == null ? null : Color(value);
  // 开了「跟随系统取色」且系统真有色时用系统色。
  final Color? systemAccent =
      entry.followSystemAccent ? systemPrimaryColor : null;
  return buildFushiColorScheme(
    seedColor: systemAccent ?? Color(entry.seed),
    brightness: brightness,
    primary: entry.primaryColor == null
        ? null
        : (systemAccent ?? Color(entry.primaryColor!)),
    secondary: role(entry.secondaryColor),
    tertiary: role(entry.tertiaryColor),
    primaryContainer: role(entry.containerColor),
    surface: role(entry.surfaceColor),
    neutralDerived: entry.neutralDerived,
    pureBlack: pureBlack,
  );
}

/// E-ink mode (墨水屏模式): a pure black-and-white [ColorScheme] built by hand
/// instead of `fromSeed` (any seed would leak hue into the neutral palette).
/// Light = black text on white; dark = white text on black. Every surface
/// container collapses to the background and every accent role collapses to
/// the foreground, so nothing renders as a mid-gray that an e-ink panel would
/// dither. Contrast between surfaces is re-introduced with explicit outlines
/// in `_buildThemeData` (cards/switch tracks get 1px borders when eink is on).
ColorScheme buildEinkColorScheme(Brightness brightness) {
  final Color bg = brightness == Brightness.light ? Colors.white : Colors.black;
  final Color fg = brightness == Brightness.light ? Colors.black : Colors.white;
  return ColorScheme(
    brightness: brightness,
    primary: fg,
    onPrimary: bg,
    primaryContainer: bg,
    onPrimaryContainer: fg,
    secondary: fg,
    onSecondary: bg,
    secondaryContainer: bg,
    onSecondaryContainer: fg,
    tertiary: fg,
    onTertiary: bg,
    tertiaryContainer: bg,
    onTertiaryContainer: fg,
    error: fg,
    onError: bg,
    errorContainer: bg,
    onErrorContainer: fg,
    surface: bg,
    onSurface: fg,
    onSurfaceVariant: fg,
    surfaceDim: bg,
    surfaceBright: bg,
    surfaceContainerLowest: bg,
    surfaceContainerLow: bg,
    surfaceContainer: bg,
    surfaceContainerHigh: bg,
    surfaceContainerHighest: bg,
    outline: fg,
    outlineVariant: fg,
    shadow: Colors.transparent,
    scrim: Colors.black,
    inverseSurface: fg,
    onInverseSurface: bg,
    inversePrimary: bg,
    surfaceTint: Colors.transparent,
  );
}

/// Zero-motion route transition for e-ink displays: pushing/popping a page
/// swaps content in a single frame instead of animating, so the panel does a
/// single refresh rather than smearing through a fade/slide.
class EinkNoPageTransitionsBuilder extends PageTransitionsBuilder {
  const EinkNoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

/// E-ink route transition for the platforms whose *only* way back out of a
/// pushed page is the Cupertino edge-swipe gesture (iOS has no system back
/// button, and `isCupertinoPlatform` is false under the default `auto` design
/// system, so every page there is a plain [MaterialPageRoute] whose gesture
/// comes solely from this [PageTransitionsTheme] entry).
///
/// [EinkNoPageTransitionsBuilder] returns `child` verbatim, which never
/// installs Flutter's back-gesture detector — turning on e-ink mode therefore
/// used to strip swipe-back from the whole app on iOS/macOS, stranding users on
/// any page whose chrome is hidden. This builder keeps the detector by
/// delegating to [CupertinoRouteTransitionMixin.buildPageTransitions], and
/// still refreshes the panel exactly once by feeding it settled animations
/// whenever no drag is in flight: pages swap in a single frame as before, and
/// only a real finger drag gets the live, finger-following animation.
class EinkCupertinoPageTransitionsBuilder extends PageTransitionsBuilder {
  const EinkCupertinoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final bool dragging = route.popGestureInProgress;
    return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
      route,
      context,
      dragging ? animation : kAlwaysCompleteAnimation,
      dragging ? secondaryAnimation : kAlwaysDismissedAnimation,
      child,
    );
  }
}

/// 一个内置主题预设：只有种子色 [seed] + M3 方案变体 [variant]。
///
/// 2026-10-06 用户：「切换主题的时候如果我是深色就要继续保持深色」——预设**只决定
/// 种子色，不决定明暗**：选任何预设都不改写 `brightness_mode`、不强制亮 / 暗，
/// app 与阅读器始终按当前明暗设置（亮 / 暗 / 跟随系统）从种子派生。旧预设带的
/// 「纯黑」语义改为明暗旁的独立开关（[ThemeNotifier.pureBlackDark]）。
typedef ThemePreset = ({
  Color seed,
  DynamicSchemeVariant variant,
});

/// 2026-10 精简前的内置预设（已删）：只为存量 `app_theme_key` 的只读映射保留
/// 种子与语义——[neutral] = 中性灰变体、[dark] = 当年选中时写入的明暗（仅在
/// `brightness_mode` 从未写过时作只读兜底）、[pureBlack] = 纯黑底。
typedef LegacyThemePreset = ({
  Color seed,
  bool neutral,
  bool dark,
  bool pureBlack,
});

/// Default seed for a brand-new / unconfigured custom theme. Matches the legacy
/// `custom_theme_seed` default (the Hibiki brand teal); used by migration to
/// decide whether a legacy custom theme was ever actually configured.
const int kCustomThemeDefaultSeed = 0xFF1F4959;

/// 品牌默认种子色（默认预设 / 自定义主题默认值 / 兜底主题共用）。
const Color kFushiDefaultSeed = Color(kCustomThemeDefaultSeed);

/// One self-contained custom theme. Replaces the old flat single-set
/// `custom_theme_*` prefs with a value type so the notifier can hold a list of
/// them (TODO-930). `null` on a role color means "not enabled" (the old flat
/// prefs used the `0 == null` sentinel; inside an entry we use real `null`).
class CustomThemeEntry {
  const CustomThemeEntry({
    required this.id,
    required this.name,
    required this.seed,
    this.fontColor,
    this.bgColor,
    this.selectionColor,
    this.primaryColor,
    this.secondaryColor,
    this.tertiaryColor,
    this.containerColor,
    this.sentenceAudioHighlightColor,
    this.linkColor,
    this.surfaceColor,
    this.followSystemAccent = false,
    this.neutralDerived = false,
  });

  final String id;
  final String name;
  final int seed;
  final int? fontColor;
  final int? bgColor;
  final int? selectionColor;
  final int? primaryColor;
  final int? secondaryColor;
  final int? tertiaryColor;
  final int? containerColor;
  final int? sentenceAudioHighlightColor;
  final int? linkColor;

  /// 界面底色（页面 / 卡片 / 菜单），null = 由 seed 派生。见 [deriveSurfaceRolesFrom]。
  final int? surfaceColor;

  /// 主题色跟随系统取色（Android 壁纸 Material You / 桌面 OS 强调色）：为 true 时
  /// seed 与钉死的主色都取 [ThemeNotifier.systemPrimaryColor]，[seed] /
  /// [primaryColor] 只作系统不提供时的兜底。
  final bool followSystemAccent;

  /// 派生色中性灰：标签 / 选中项 / 菜单 / 表面不带主题色相，只留主题色作强调。
  final bool neutralDerived;

  CustomThemeEntry copyWith({String? id, String? name, int? seed}) {
    return CustomThemeEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      seed: seed ?? this.seed,
      fontColor: fontColor,
      bgColor: bgColor,
      selectionColor: selectionColor,
      primaryColor: primaryColor,
      secondaryColor: secondaryColor,
      tertiaryColor: tertiaryColor,
      containerColor: containerColor,
      sentenceAudioHighlightColor: sentenceAudioHighlightColor,
      linkColor: linkColor,
      surfaceColor: surfaceColor,
      followSystemAccent: followSystemAccent,
      neutralDerived: neutralDerived,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'seed': seed,
        if (fontColor != null) 'fontColor': fontColor,
        if (bgColor != null) 'bgColor': bgColor,
        if (selectionColor != null) 'selectionColor': selectionColor,
        if (primaryColor != null) 'primaryColor': primaryColor,
        if (secondaryColor != null) 'secondaryColor': secondaryColor,
        if (tertiaryColor != null) 'tertiaryColor': tertiaryColor,
        if (containerColor != null) 'containerColor': containerColor,
        // JSON 键与字段同名；历史键 'sasayakiColor'（custom_themes 旧行）已由
        // v71 Drift 迁移一次性改写。分享码不含此键（用 'sk' 段），不受影响。
        if (sentenceAudioHighlightColor != null)
          'sentenceAudioHighlightColor': sentenceAudioHighlightColor,
        if (linkColor != null) 'linkColor': linkColor,
        if (surfaceColor != null) 'surfaceColor': surfaceColor,
        if (followSystemAccent) 'followSystemAccent': true,
        if (neutralDerived) 'neutralDerived': true,
      };

  factory CustomThemeEntry.fromJson(Map<String, dynamic> json) {
    int? asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
    return CustomThemeEntry(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      seed: asInt(json['seed']) ?? kCustomThemeDefaultSeed,
      fontColor: asInt(json['fontColor']),
      bgColor: asInt(json['bgColor']),
      selectionColor: asInt(json['selectionColor']),
      primaryColor: asInt(json['primaryColor']),
      secondaryColor: asInt(json['secondaryColor']),
      tertiaryColor: asInt(json['tertiaryColor']),
      containerColor: asInt(json['containerColor']),
      sentenceAudioHighlightColor: asInt(json['sentenceAudioHighlightColor']),
      linkColor: asInt(json['linkColor']),
      surfaceColor: asInt(json['surfaceColor']),
      followSystemAccent: json['followSystemAccent'] == true,
      neutralDerived: json['neutralDerived'] == true,
    );
  }
}

/// Result of [migrateLegacyCustomTheme]. [shouldWrite] is false when nothing
/// needs persisting (already migrated, or a brand-new user with no legacy data).
class LegacyCustomThemeMigration {
  const LegacyCustomThemeMigration({
    required this.entries,
    required this.selectedId,
    required this.shouldWrite,
  });

  final List<CustomThemeEntry> entries;
  final String? selectedId;
  final bool shouldWrite;
}

/// Idempotent, pure migration of the legacy flat single-set custom theme into
/// the new list model (TODO-930).
///
/// - If [existing] (the `custom_themes` list) is already non-empty: parse and
///   return it, [shouldWrite] = false (idempotent — re-running is a no-op).
/// - Otherwise, if any legacy flat key is "configured" (seed differs from the
///   default, or any role color is non-zero): build exactly one entry from the
///   legacy values (id generated once, empty name → UI shows a default name) and
///   request a write of `custom_themes=[entry]` + `selected_custom_theme_id=id`.
/// - Otherwise (brand-new user, no legacy data): empty list, [shouldWrite] =
///   false.
///
/// Legacy role colors use the `0 == null` sentinel; this maps `0` back to null
/// inside the entry. The legacy flat keys are NOT deleted (kept as read-only
/// fallback, same as TODO-928's handling of custom_theme_dark).
LegacyCustomThemeMigration migrateLegacyCustomTheme({
  required List<String> existing,
  required int legacySeed,
  required int legacyFontColor,
  required int legacyBgColor,
  required int legacySelectionColor,
  required int legacyPrimaryColor,
  required int legacySecondaryColor,
  required int legacyTertiaryColor,
  required int legacyContainerColor,
  required int legacySentenceAudioHighlightColor,
  required int legacyLinkColor,
  required String Function() idGenerator,
}) {
  if (existing.isNotEmpty) {
    final List<CustomThemeEntry> parsed = <CustomThemeEntry>[];
    for (final String s in existing) {
      try {
        final dynamic decoded = jsonDecode(s);
        if (decoded is Map) {
          parsed.add(CustomThemeEntry.fromJson(
              decoded.map((k, v) => MapEntry(k.toString(), v))));
        }
      } catch (_) {
        // Skip malformed rows.
      }
    }
    return LegacyCustomThemeMigration(
      entries: parsed,
      selectedId: parsed.isEmpty ? null : parsed.first.id,
      shouldWrite: false,
    );
  }

  final bool configured = legacySeed != kCustomThemeDefaultSeed ||
      legacyFontColor != 0 ||
      legacyBgColor != 0 ||
      legacySelectionColor != 0 ||
      legacyPrimaryColor != 0 ||
      legacySecondaryColor != 0 ||
      legacyTertiaryColor != 0 ||
      legacyContainerColor != 0 ||
      legacySentenceAudioHighlightColor != 0 ||
      legacyLinkColor != 0;

  if (!configured) {
    return const LegacyCustomThemeMigration(
      entries: <CustomThemeEntry>[],
      selectedId: null,
      shouldWrite: false,
    );
  }

  int? nz(int v) => v == 0 ? null : v;
  final CustomThemeEntry entry = CustomThemeEntry(
    id: idGenerator(),
    name: '',
    seed: legacySeed,
    fontColor: nz(legacyFontColor),
    bgColor: nz(legacyBgColor),
    selectionColor: nz(legacySelectionColor),
    primaryColor: nz(legacyPrimaryColor),
    secondaryColor: nz(legacySecondaryColor),
    tertiaryColor: nz(legacyTertiaryColor),
    containerColor: nz(legacyContainerColor),
    sentenceAudioHighlightColor: nz(legacySentenceAudioHighlightColor),
    linkColor: nz(legacyLinkColor),
  );
  return LegacyCustomThemeMigration(
    entries: <CustomThemeEntry>[entry],
    selectedId: entry.id,
    shouldWrite: true,
  );
}

typedef _DesignSystemPreferenceMigration = ({
  String expectedRaw,
  String normalizedRaw,
});

class ThemeNotifier extends ChangeNotifier {
  ThemeNotifier(
    this._db,
    this._textThemeBuilder, {
    String Function()? customThemeIdGenerator,
  }) : _customThemeIdGenerator =
            customThemeIdGenerator ?? _defaultCustomThemeIdGenerator {
    // 系统「降低透明度」切换时玻璃要立刻回退 / 恢复：重建主题即可。
    SystemTransparency.reduceTransparency.addListener(notifyListeners);
  }

  @override
  void dispose() {
    SystemTransparency.reduceTransparency.removeListener(notifyListeners);
    super.dispose();
  }

  // Stable, testable id source. Defaults to epoch-millis + a monotonic counter
  // so two entries created in the same millisecond never collide. Tests can
  // inject a deterministic generator. (TODO-930)
  final String Function() _customThemeIdGenerator;
  static int _customThemeIdCounter = 0;
  static String _defaultCustomThemeIdGenerator() {
    final int n = _customThemeIdCounter++;
    return 'ct-${DateTime.now().millisecondsSinceEpoch}-$n';
  }

  static const String appUiScaleModeAuto = 'auto';
  static const String appUiScaleModeCustom = 'custom';

  final FushiDatabase _db;
  final TextTheme Function() _textThemeBuilder;
  final Map<String, String> _prefs = {};
  int _preferenceWriteRevision = 0;
  final Map<String, int> _publishedPreferenceWriteRevisions = {};
  // Invalidates an async migration reload whenever a newer local write or
  // full preference snapshot has taken ownership of the in-memory value.
  int _designSystemPreferenceRevision = 0;
  double _autoAppUiScale = FushiAppUiScale.defaultScale;

  CorePalette? _systemPalette;
  String? _systemPaletteIdentity;
  // OS accent color, the only system-color signal Windows / macOS / Linux
  // expose (getCorePalette is Android-only there). Used to seed `system-theme`
  // when [_systemPalette] is null (BUG-090).
  Color? _systemAccentColor;

  Color? get systemPrimaryColor {
    if (_systemPalette != null) return Color(_systemPalette!.primary.get(40));
    return _systemAccentColor;
  }

  /// 两种明暗的 Android 壁纸方案是否同源；只作镜像缓存身份，不是可派生种子。
  /// 墨水屏覆盖了壁纸方案，切换时也必须淘汰另一明暗留下的彩色镜像。
  String? get activeSystemPaletteIdentity {
    final String? identity = _systemPaletteIdentity;
    if (appThemeKey != 'system-theme' || identity == null) return null;
    return einkMode ? '$identity:eink' : identity;
  }

  Future<void> refreshSystemPalette() async {
    CorePalette? palette;
    try {
      palette = await DynamicColorPlugin.getCorePalette();
    } catch (_) {
      palette = null;
    }
    // Android yields a full palette; elsewhere it is null, so fall back to the
    // OS accent color (the canonical dynamic_color path).
    Color? accent;
    if (palette == null) {
      try {
        accent = await DynamicColorPlugin.getAccentColor();
      } catch (_) {
        accent = null;
      }
    }
    // 值没变就不广播（BUG-2010）。本方法挂在 `AppLifecycleState.resumed` 上，而
    // 桌面端每次窗口激活都会走一遍 resumed，于是「无条件 notifyListeners」＝
    // 「每把 Fushi 拉到前台一次就让整棵树重建一次」。重建本身无害，但它会引爆
    // 任何把 FutureBuilder 的 future 写在 build 里的页面——那种页面会退回
    // waiting、内容整块消失一帧（用户报的「一拉到前台就闪」）。系统调色板本就
    // 极少变，这里只在真变了时才通知；订阅方少一次无谓重建，闪的放大器就没了。
    final bool unchanged =
        palette == _systemPalette && accent == _systemAccentColor;
    _systemPalette = palette;
    _systemAccentColor = accent;
    if (unchanged) return;
    // 固定宽度 ARGB 编码 + SHA-256：跨进程稳定，不能用对象 hashCode。
    // 只在系统颜色真变化时计算，重复 resumed 不重算、不额外广播。
    if (palette == null) {
      _systemPaletteIdentity = null;
    } else {
      final String colors = palette.asList().map((int argb) {
        return (argb & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
      }).join();
      _systemPaletteIdentity = 'android-v1:${sha256.convert(utf8.encode(colors))}';
    }
    // 自定义主题也可以显式跟随系统强调色，与系统主题消费同一份取色结果。
    if (appThemeKey == 'system-theme' ||
        (activeCustomThemeEntry?.followSystemAccent ?? false)) {
      notifyListeners();
    }
  }

  void loadFromPrefsSnapshot(Map<String, String> snapshot) {
    _prefs
      ..clear()
      ..addAll(snapshot);
    _designSystemPreferenceRevision++;
    final _DesignSystemPreferenceMigration? migration =
        _normalizeHiddenDesignSystemInMemory();
    if (migration != null) {
      // Initial snapshot loading is deliberately synchronous. The best-effort
      // migration owns all of its async errors so this fire-and-forget boundary
      // can never surface an unhandled Future during app startup.
      unawaited(
        _persistHiddenDesignSystemMigration(
          migration,
          notifyOnReload: true,
        ),
      );
    }
  }

  Future<void> refreshFromDb() async {
    final all = await _db.getAllPrefs();
    _prefs
      ..clear()
      ..addAll(all);
    _designSystemPreferenceRevision++;
    final _DesignSystemPreferenceMigration? migration =
        _normalizeHiddenDesignSystemInMemory();
    if (migration != null) {
      await _persistHiddenDesignSystemMigration(
        migration,
        notifyOnReload: false,
      );
    }
    notifyListeners();
  }

  Future<void> _persistHiddenDesignSystemMigration(
    _DesignSystemPreferenceMigration migration, {
    required bool notifyOnReload,
  }) async {
    try {
      final bool migrated = await _db.compareAndSetPref(
        'design_system',
        expectedValue: migration.expectedRaw,
        newValue: migration.normalizedRaw,
      );
      if (!migrated) {
        await _reloadDesignSystemPreferenceAfterMigrationRace(
          migration,
          notifyOnChange: notifyOnReload,
        );
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[ThemeNotifier] design_system migration write failed: $error\n'
        '$stackTrace',
      );
      await _reloadDesignSystemPreferenceAfterMigrationRace(
        migration,
        notifyOnChange: notifyOnReload,
      );
    }
  }

  Future<void> _reloadDesignSystemPreferenceAfterMigrationRace(
    _DesignSystemPreferenceMigration migration, {
    required bool notifyOnChange,
  }) async {
    try {
      final int revisionBeforeReload = _designSystemPreferenceRevision;
      final String designSystemBeforeReload = designSystem;
      final String? currentRaw = await _db.getPref('design_system');
      if (_designSystemPreferenceRevision != revisionBeforeReload ||
          _prefs['design_system'] != migration.normalizedRaw) {
        return;
      }
      if (currentRaw == null) {
        _prefs.remove('design_system');
      } else {
        _prefs['design_system'] = currentRaw;
      }
      _designSystemPreferenceRevision++;
      if (notifyOnChange &&
          designSystemBeforeReload != designSystem &&
          hasListeners) {
        notifyListeners();
      }
    } catch (error, stackTrace) {
      // Migration is compatibility cleanup, not a prerequisite for rendering.
      // Keep the already-normalized in-memory auto value and report the failed
      // reload without letting snapshot startup leak an unhandled Future.
      debugPrint(
        '[ThemeNotifier] design_system migration reload failed: $error\n'
        '$stackTrace',
      );
    }
  }

  // Pure read. Theme getters (theme/darkTheme/themeMode) run inside
  // MaterialApp.build(); previously an absent key triggered a fire-and-forget
  // DB write (_set) from the getter, a side effect on every first build
  // (HBK-AUDIT-022). Defaults are returned without persisting; writes happen
  // only at explicit setter or load/refresh migration boundaries, never here.
  dynamic _get(String key, {dynamic defaultValue}) {
    final raw = _prefs[key];
    if (raw == null) return defaultValue;
    return PrefCodec.decode(raw, defaultValue);
  }

  Future<void> _set(String key, dynamic value) async {
    final String strVal = PrefCodec.encode(value);
    _publishPreferenceWrite(key, strVal, ++_preferenceWriteRevision);
    if (key == 'design_system') {
      _designSystemPreferenceRevision++;
    }
    await _db.setPref(key, strVal);
  }

  // A committed theme batch must not overwrite a newer immediate UI setting
  // (brightness / pure black) while its transaction was pending. Track only
  // published writes: a later pending theme that fails must not suppress an
  // earlier successful commit. Single-key setters keep their existing timing.
  void _publishPreferenceWrite(String key, String value, int revision) {
    if ((_publishedPreferenceWriteRevisions[key] ?? 0) > revision) return;
    _prefs[key] = value;
    _publishedPreferenceWriteRevisions[key] = revision;
  }

  // ── Theme presets ──────────────────────────────────────────────────

  // 2026-10-06 用户「预设只留 M3E 谷歌经典配色」：Material Theme Builder 的经典
  // 种子（M3 基线紫 + Google 经典色板），一律由种子经 DynamicScheme 生成整套 tonal
  // 方案（M3E 默认 vibrant 变体，中性灰用 neutral），不手写任何槽位。顺序按色相。
  // 「跟随系统取色」（system-theme）、自定义主题、墨水屏开关不在此表，照旧保留。
  static const Map<String, ThemePreset> themePresets = {
    'm3-baseline': (
      seed: Color(0xFF6750A4),
      variant: kFushiDefaultSchemeVariant,
    ),
    'm3-indigo': (
      seed: Color(0xFF3F51B5),
      variant: kFushiDefaultSchemeVariant,
    ),
    'm3-blue': (
      seed: Color(0xFF0B57D0),
      variant: kFushiDefaultSchemeVariant,
    ),
    'm3-teal': (
      seed: Color(0xFF00796B),
      variant: kFushiDefaultSchemeVariant,
    ),
    'm3-green': (
      seed: Color(0xFF146C2E),
      variant: kFushiDefaultSchemeVariant,
    ),
    'm3-yellow': (
      seed: Color(0xFFFBBC04),
      variant: kFushiDefaultSchemeVariant,
    ),
    'm3-orange': (
      seed: Color(0xFFFF6D00),
      variant: kFushiDefaultSchemeVariant,
    ),
    'm3-red': (
      seed: Color(0xFFB3261E),
      variant: kFushiDefaultSchemeVariant,
    ),
    'm3-pink': (
      seed: Color(0xFFE91E63),
      variant: kFushiDefaultSchemeVariant,
    ),
    'm3-neutral': (
      seed: Color(0xFF5F6368),
      variant: DynamicSchemeVariant.neutral,
    ),
  };

  /// 中性灰预设 id（无彩度 / neutral 变体的旧预设映射到它）。
  static const String neutralPresetKey = 'm3-neutral';

  /// 已删除的旧预设（id 冻结在存量偏好 / 备份 / Profile 快照 / 阅读器设置里）。
  /// 读取时经 [legacyPresetReplacement] 映射到最接近的保留预设，**不改写偏好**；
  /// 阅读器的手调纸色（羊皮纸 / 水蓝 / 护眼 / 灰 / 深色 / 纯黑）仍按存量 id 生效
  /// （见 [storedAppThemeKey]），本次不动。
  static const Map<String, LegacyThemePreset> legacyThemePresets = {
    'light-theme': (
      seed: Color(0xFF1F4959),
      neutral: false,
      dark: false,
      pureBlack: false,
    ),
    'ecru-theme': (
      seed: Color(0xFF8B7355),
      neutral: false,
      dark: false,
      pureBlack: false,
    ),
    'water-theme': (
      seed: Color(0xFF3A6EA5),
      neutral: false,
      dark: false,
      pureBlack: false,
    ),
    'eyecare-theme': (
      seed: Color(0xFF5E8C63),
      neutral: false,
      dark: false,
      pureBlack: false,
    ),
    'gray-theme': (
      seed: Color(0xFF5C6B73),
      neutral: true,
      dark: true,
      pureBlack: false,
    ),
    'dark-theme': (
      seed: Color(0xFF1F4959),
      neutral: false,
      dark: true,
      pureBlack: false,
    ),
    'black-theme': (
      seed: Color(0xFF3F51B5),
      neutral: false,
      dark: true,
      pureBlack: true,
    ),
  };

  static final Map<String, String> _legacyReplacementCache =
      <String, String>{};

  /// 旧预设 [key] 的替代预设：中性 → [neutralPresetKey]；其余按种子 HCT 色相
  /// 环形距离最近的彩色预设。非旧预设 id 返回 null。
  static String? legacyPresetReplacement(String key) {
    final LegacyThemePreset? legacy = legacyThemePresets[key];
    if (legacy == null) return null;
    return _legacyReplacementCache.putIfAbsent(key, () {
      if (legacy.neutral || isAchromaticSeed(legacy.seed)) {
        return neutralPresetKey;
      }
      return nearestPresetForSeed(legacy.seed);
    });
  }

  /// 与 [seed] 色相最近的彩色预设（不含中性灰）。
  static String nearestPresetForSeed(Color seed) {
    final double hue = Hct.fromInt(seed.toARGB32()).hue;
    String best = 'm3-baseline';
    double bestDistance = double.infinity;
    for (final MapEntry<String, ThemePreset> entry in themePresets.entries) {
      if (entry.value.variant == DynamicSchemeVariant.neutral) continue;
      final double h = Hct.fromInt(entry.value.seed.toARGB32()).hue;
      final double d = (hue - h).abs() % 360;
      final double distance = d > 180 ? 360 - d : d;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = entry.key;
      }
    }
    return best;
  }

  /// 预设 [preset] 在 [brightness] 下的 ColorScheme——设置页色卡与生效主题同源。
  static ColorScheme buildPresetColorScheme(
    ThemePreset preset,
    Brightness brightness, {
    bool pureBlack = false,
  }) {
    return buildFushiColorScheme(
      seedColor: preset.seed,
      brightness: brightness,
      variant: preset.variant,
      pureBlack: pureBlack,
    );
  }

  /// 主题名（设置页色卡下的名称）；旧预设 id 显示其替代预设的名字。
  static String themeLabel(String key) {
    switch (legacyPresetReplacement(key) ?? key) {
      case 'system-theme':
        return t.theme_preset_system;
      case 'm3-baseline':
        return t.theme_preset_baseline;
      case 'm3-indigo':
        return t.theme_preset_indigo;
      case 'm3-blue':
        return t.theme_preset_blue;
      case 'm3-teal':
        return t.theme_preset_teal;
      case 'm3-green':
        return t.theme_preset_green;
      case 'm3-yellow':
        return t.theme_preset_yellow;
      case 'm3-orange':
        return t.theme_preset_orange;
      case 'm3-red':
        return t.theme_preset_red;
      case 'm3-pink':
        return t.theme_preset_pink;
      case 'm3-neutral':
        return t.theme_preset_neutral;
      default:
        return key;
    }
  }

  // ── Theme getters ────────────────────────────────────────────────

  /// Prefix marking the active app theme as a custom theme. The stored value is
  /// either bare `'custom-theme'` (= whichever custom theme is currently
  /// selected, backward-compatible with the legacy single-set users) or
  /// `'custom-theme:<id>'` to pin a specific entry (TODO-930).
  static const String customThemeKeyPrefix = 'custom-theme';

  /// True when [key] selects a custom theme in either form.
  static bool isCustomThemeKey(String key) =>
      key == customThemeKeyPrefix || key.startsWith('$customThemeKeyPrefix:');

  /// The custom-theme id embedded in [key] (`custom-theme:<id>`), or null for
  /// the bare `custom-theme` form / non-custom keys.
  static String? customThemeIdFromKey(String key) {
    const String prefix = '$customThemeKeyPrefix:';
    if (key.startsWith(prefix)) return key.substring(prefix.length);
    return null;
  }

  /// 偏好里存的原始主题键（校验过：未知值 → `system-theme`），**可能是已删的
  /// 旧预设 id**。只给阅读器纸色（按存量 id 生效）与只读兜底用；其余一律读
  /// [appThemeKey]。
  String get storedAppThemeKey {
    final String key = _get('app_theme_key', defaultValue: '');
    if (key.isEmpty ||
        (!themePresets.containsKey(key) &&
            !legacyThemePresets.containsKey(key) &&
            !isCustomThemeKey(key) &&
            key != 'system-theme')) {
      return 'system-theme';
    }
    return key;
  }

  /// 生效的主题键：已删的旧预设 id 只读映射到最接近的保留预设
  /// （[legacyPresetReplacement]），偏好原值不改写。
  String get appThemeKey {
    final String key = storedAppThemeKey;
    return legacyPresetReplacement(key) ?? key;
  }

  /// 「纯黑深色背景」：深色下页面底为真黑（OLED）。与预设 / 明暗正交的独立开关；
  /// 从没写过时，存量选了旧「纯黑」预设的用户默认开（保持原观感，不改写偏好）。
  bool get pureBlackDark => _get(
        'pure_black_dark',
        defaultValue:
            legacyThemePresets[storedAppThemeKey]?.pureBlack ?? false,
      ) as bool;

  Future<void> setPureBlackDark(bool value) async {
    await _set('pure_black_dark', value);
    notifyListeners();
    _persistSplashColor();
  }

  /// Resolve the [CustomThemeEntry] the current [appThemeKey] points at, applying
  /// the documented fallback chain when the key is custom:
  /// explicit `custom-theme:<id>` → that id if it exists → otherwise
  /// [selectedCustomThemeId] → otherwise the first entry in the list. Returns
  /// null only when no custom theme is active or the list is empty (the caller
  /// then falls back to the legacy flat getters, keeping migrate-time behavior
  /// identical).
  CustomThemeEntry? get activeCustomThemeEntry {
    final String key = appThemeKey;
    if (!isCustomThemeKey(key)) return null;
    final List<CustomThemeEntry> list = customThemes;
    if (list.isEmpty) return null;
    final String? pinnedId = customThemeIdFromKey(key);
    if (pinnedId != null) {
      final CustomThemeEntry? byId = customThemeById(pinnedId);
      if (byId != null) return byId;
    }
    final String? selId = selectedCustomThemeId;
    if (selId != null) {
      final CustomThemeEntry? sel = customThemeById(selId);
      if (sel != null) return sel;
    }
    return list.first;
  }

  /// E-ink mode (墨水屏模式). A single app-global switch (excluded from the
  /// per-profile snapshot in ProfileKeys — it describes the physical display,
  /// not a reading preference) that overlays the active theme with a pure
  /// black-and-white scheme and disables page-transition animations. The
  /// user's chosen theme key / brightness mode are left untouched, so turning
  /// the switch off restores the previous colors exactly. Default OFF; getPref
  /// returns the default only when the key was never written.
  bool get einkMode => _get('eink_mode', defaultValue: false) as bool;

  Future<void> setEinkMode(bool value) async {
    await _set('eink_mode', value);
    notifyListeners();
  }

  /// 功能层表面材质（与颜色主题正交）。随 Profile 走，与主题键一致；墨水屏 /
  /// 增强对比度下的回退在消费端 [glassMaterialOf] 判，这里只存用户的选择。
  /// 生效的玻璃材质：只有设计系统选「玻璃」时才非 off；当前固定毛玻璃
  /// （见 [glassMaterialTier]），液态档暂时关闭。
  FushiGlassMaterial get glassMaterial {
    if (designSystem != 'glass') return FushiGlassMaterial.off;
    // 系统开了「降低透明度 / 关闭透明效果」：整套玻璃回退实心（主题层半透明
    // 色阶与 BackdropFilter 一起关），窗口材质也随之关闭。
    if (SystemTransparency.reduceTransparency.value) {
      return FushiGlassMaterial.off;
    }
    return glassMaterialTier;
  }

  /// 玻璃设计系统下的材质档位（不看设计系统，供设置页显示选中项）。
  ///
  /// 2026-10-06 用户拍板：Apple 设计系统固定毛玻璃，液态玻璃先关——这里恒为
  /// frosted，**不读也不改写** `glass_material` 偏好：已存 `liquid` 的用户读取时
  /// 直接降级为毛玻璃，存储值原样保留（入口在设置页同步隐藏，见
  /// settings_schema_appearance.dart 的 `appearance.glass_material`）。恢复液态
  /// 档时还原为：偏好 == frosted ? frosted : liquid（缺省 liquid）。
  FushiGlassMaterial get glassMaterialTier => FushiGlassMaterial.frosted;

  Future<void> setGlassMaterial(FushiGlassMaterial value) async {
    await _set('glass_material', value.name);
    notifyListeners();
  }

  String get brightnessMode {
    final String mode = _get('brightness_mode', defaultValue: '');
    if (mode.isNotEmpty) return mode;
    final key = appThemeKey;
    if (key == 'system-theme') return 'system';
    if (isCustomThemeKey(key)) return customThemeDark ? 'dark' : 'light';
    // 只读兜底：老用户选旧预设时当年会顺带写 brightness_mode；万一没写过，按旧
    // 预设的明暗语义读出，不改写。新预设不带明暗 → 跟随系统。
    final LegacyThemePreset? legacy = legacyThemePresets[storedAppThemeKey];
    if (legacy != null) return legacy.dark ? 'dark' : 'light';
    return 'system';
  }

  // ── Design system override ────────────────────────────────────────

  /// 对外开放的设计系统值：auto / material（MD3）/ glass（玻璃）。玻璃是 MD3
  /// 组件之上的一层材质皮肤，渲染器仍走 Material（见 [designSystemTheme]）。
  static String normalizeDesignSystemPreference(Object? value) {
    if (value == 'material' || value == 'glass') return value! as String;
    return 'auto';
  }

  _DesignSystemPreferenceMigration? _normalizeHiddenDesignSystemInMemory() {
    final String? expectedRaw = _prefs['design_system'];
    if (expectedRaw == null) return null;
    final Object? decoded = PrefCodec.decodeUntyped(expectedRaw);
    final String normalized = normalizeDesignSystemPreference(decoded);
    if (decoded == normalized) return null;
    final String normalizedRaw = PrefCodec.encode(normalized);
    _prefs['design_system'] = normalizedRaw;
    return (expectedRaw: expectedRaw, normalizedRaw: normalizedRaw);
  }

  String get designSystem => normalizeDesignSystemPreference(
        _get('design_system', defaultValue: 'auto'),
      );

  Future<void> setDesignSystem(String value) async {
    await _set('design_system', normalizeDesignSystemPreference(value));
    notifyListeners();
  }

  FushiDesignSystem get designSystemTheme {
    switch (designSystem) {
      case 'material':
      case 'glass':
        return FushiDesignSystem.material;
      case 'cupertino':
        return FushiDesignSystem.cupertino;
      case 'macos':
        return FushiDesignSystem.macos;
      default:
        return FushiDesignSystem.auto;
    }
  }

  static String normalizeAppUiScaleMode(String value) {
    return value == appUiScaleModeCustom
        ? appUiScaleModeCustom
        : appUiScaleModeAuto;
  }

  // TODO-374: 界面大小不再有「自动/自定义」模式开关，只有一个用户可拖的具体百分比
  // （持久值 `app_ui_scale`）。
  //
  // 「是否已经把合适值落盘」的判据是 [_isAppUiScaleSeeded]：只要存在一个非旧 auto
  // 模式下的 `app_ui_scale` 持久值，就认定用户面对的是一个具体可调数值，永不再自动
  // 改写它。首启（或旧 auto 用户首次进入）则由 [resolveAppUiScaleForViewport] 用当时
  // 视口算出的合适值落盘成 `app_ui_scale`，等价于他们原本看到的 auto 效果，不突变。
  //
  // 向后兼容（Never break userspace）：
  // - 旧 custom 用户（`app_ui_scale_mode='custom'` 或 legacy 只存过 `app_ui_scale`）：
  //   持久值就是他们手动选的值，保持不变、不重新种子。
  // - 旧 auto 用户（`app_ui_scale_mode='auto'`）：当时 auto 忽略任何 `app_ui_scale`
  //   旧值、按视口实时算；首次进入按当时屏幕算出合适值落盘成具体数值，覆盖那个被
  //   忽略的陈旧值（这才等价于他们原本看到的 auto 效果）。
  bool get _isAppUiScaleSeeded {
    if (!_prefs.containsKey('app_ui_scale')) return false;
    // 旧 auto 用户的 app_ui_scale 是被忽略的陈旧值，视为「未种子」，首次进入重算落盘。
    final Object? mode = _get('app_ui_scale_mode');
    if (mode is String && normalizeAppUiScaleMode(mode) == appUiScaleModeAuto) {
      return false;
    }
    return true;
  }

  /// 当前持久化的界面大小（首启种子完成后此即唯一权威值）。
  double get customAppUiScale {
    final Object value = _get(
      'app_ui_scale',
      defaultValue: FushiAppUiScale.defaultScale,
    );
    if (value is num) return FushiAppUiScale.normalize(value.toDouble());
    return FushiAppUiScale.defaultScale;
  }

  /// 最近一次按视口算出的「合适」自动值，仅用作首启种子与种子前的临时显示，不再是
  /// 用户可见的独立模式。
  double get autoAppUiScale => _autoAppUiScale;

  double get appUiScale {
    if (_isAppUiScaleSeeded) return customAppUiScale;
    // 种子前（首启 / 旧 auto 用户尚未拿到视口）：先按已算出的自动值显示，
    // resolveAppUiScaleForViewport 拿到真实视口后会把它落盘成具体数值。
    return autoAppUiScale;
  }

  /// 在拥有真实视口的渲染层调用：算出当时屏幕的「合适」缩放；若界面大小尚未种子
  /// （首启或旧 auto 用户），把该合适值落盘成具体可调的 `app_ui_scale`，此后界面大小
  /// 永远是一个用户可拖的数值。返回当前应生效的 [appUiScale]。
  double resolveAppUiScaleForViewport({
    required Size viewport,
    required TargetPlatform platform,
  }) {
    _autoAppUiScale = FushiAppUiScale.automaticScaleForViewport(
      viewport: viewport,
      platform: platform,
    );
    if (!_isAppUiScaleSeeded) {
      // 首启种子：把当时屏幕算出的合适值落盘成具体百分比并清掉旧模式键，转为纯具体值。
      // 先同步置内存 _prefs（见 _seedAppUiScale），使本帧 appUiScale 立刻返回种子值。
      unawaited(_seedAppUiScale(_autoAppUiScale));
      return _autoAppUiScale;
    }
    return appUiScale;
  }

  Future<void> _seedAppUiScale(double value) async {
    final double normalized = FushiAppUiScale.normalize(value);
    // 立刻更新内存值，使同帧 _isAppUiScaleSeeded / appUiScale 反映已种子（_db 写是
    // async，先同步置内存避免本帧/下一帧重复种子）。
    _prefs['app_ui_scale'] = PrefCodec.encode(normalized);
    _prefs.remove('app_ui_scale_mode');
    await _db.setPref('app_ui_scale', PrefCodec.encode(normalized));
    // 清掉旧 auto 模式键，避免下次启动又被判为未种子（旧 auto 用户路径）。
    await _db.deletePref('app_ui_scale_mode');
    notifyListeners();
  }

  Future<void> setAppUiScale(double value) async {
    await _set('app_ui_scale', FushiAppUiScale.normalize(value));
    // 用户显式拖动即落具体值；清掉任何残留旧模式键，确保此后判为已种子。
    _prefs.remove('app_ui_scale_mode');
    await _db.deletePref('app_ui_scale_mode');
    notifyListeners();
  }

  bool get isDarkMode {
    switch (brightnessMode) {
      case 'light':
        return false;
      case 'dark':
        return true;
      default:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    }
  }

  ThemeMode get themeMode {
    switch (brightnessMode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Color get _seedColor {
    if (isCustomThemeKey(appThemeKey)) {
      final CustomThemeEntry? entry = activeCustomThemeEntry;
      if (entry != null) {
        return _followedSystemAccent(entry) ?? Color(entry.seed);
      }
      // No list entry yet (pre-migration race): fall back to the legacy flat
      // pref so behavior is identical to before TODO-930.
      return customThemeSeed;
    }
    return themePresets[appThemeKey]?.seed ?? kFushiDefaultSeed;
  }

  // The M3 scheme variant for the active preset. Presets differ here so the
  // three dark presets (gray/dark/black) stay visually distinct (TODO-100);
  // custom / system fall back to the M3E default variant (their own seed/role
  // overrides / OS palette already differentiate them).
  DynamicSchemeVariant get _variant {
    return themePresets[appThemeKey]?.variant ?? kFushiDefaultSchemeVariant;
  }

  /// 当前主题**实际生成方案所用**的种子色（浏览器扩展「跟随 Fushi」按同一种子派生另一明暗用）。
  ///
  /// HBK-AUDIT-030：系统取色（system-theme）与 [buildSystemThemeColorScheme] 同口径——桌面用
  /// 系统强调色、取不到才用兜底种子；Android 壁纸调色板（[_systemPalette]）不是由单个种子生成的，
  /// 返回 null（扩展收不到种子就不按种子派生）。以前这里恒为 [_seedColor]，系统取色下落成
  /// 默认种子，扩展派生的另一明暗与 app 实际配色对不上。
  Color? get activeSeedColor {
    if (appThemeKey == 'system-theme') {
      if (_systemPalette != null) return null;
      return _systemAccentColor ?? _seedColor;
    }
    return _seedColor;
  }

  /// 当前主题的 M3 方案变体（同上）。系统取色与 [buildSystemThemeColorScheme] 同口径：
  /// 无彩度强调色用 tonalSpot，其余用默认变体。
  DynamicSchemeVariant get activeSchemeVariant {
    if (appThemeKey == 'system-theme') {
      final Color? seed = activeSeedColor;
      return seed != null && isAchromaticSeed(seed)
          ? DynamicSchemeVariant.tonalSpot
          : kFushiDefaultSchemeVariant;
    }
    return _variant;
  }

  ThemeData get theme => _buildThemeData(Brightness.light);
  ThemeData get darkTheme => _buildThemeData(Brightness.dark);

  ColorScheme buildColorScheme(Brightness brightness) {
    // E-ink overlays every theme path (system / preset / custom) with pure
    // black-and-white; the stored theme key is untouched so switching the
    // toggle off restores the previous colors without any migration.
    if (einkMode) {
      return buildEinkColorScheme(brightness);
    }
    if (appThemeKey == 'system-theme') {
      // 系统取色的中性阶梯有两个来源（Android 壁纸调色板 / 桌面 accent seed），
      // 间距各不相同；同预设与自定义主题一样收口到统一阶梯。
      final ColorScheme system = buildSystemThemeColorScheme(
        brightness: brightness,
        palette: _systemPalette,
        accent: _systemAccentColor,
        fallbackSeed: _seedColor,
      );
      return pureBlackDark
          ? applyFushiPureBlackSurfaceLadder(system)
          : applyFushiSurfaceLadder(system);
    }
    final CustomThemeEntry? custom = activeCustomThemeEntry;
    if (custom != null) return buildCustomThemeColorScheme(custom, brightness);
    return buildFushiColorScheme(
      seedColor: _seedColor,
      brightness: brightness,
      variant: _variant,
      primary: activeCustomThemePrimaryColor,
      secondary: _activeCustomRole(
        (CustomThemeEntry e) => e.secondaryColor,
        () => customThemeSecondaryColor,
      ),
      tertiary: _activeCustomRole(
        (CustomThemeEntry e) => e.tertiaryColor,
        () => customThemeTertiaryColor,
      ),
      primaryContainer: _activeCustomRole(
        (CustomThemeEntry e) => e.containerColor,
        () => customThemeContainerColor,
      ),
      surface: activeCustomThemeSurfaceColor,
      neutralDerived: activeCustomThemeNeutralDerived,
      pureBlack: pureBlackDark,
    );
  }

  /// 自定义条目在当前系统取色 / 纯黑 / 墨水屏设置下的配色。
  /// 活跃主题、设置色卡与编辑草稿共用此入口，不要求条目已经保存或选中。
  ColorScheme buildCustomThemeColorScheme(
    CustomThemeEntry entry,
    Brightness brightness,
  ) =>
      buildCustomThemeEntryColorScheme(
        entry,
        brightness,
        einkMode: einkMode,
        pureBlack: pureBlackDark,
        systemPrimaryColor: systemPrimaryColor,
      );

  /// 当前生效自定义主题是否要求派生色中性灰。
  bool get activeCustomThemeNeutralDerived {
    if (!isCustomThemeKey(appThemeKey)) return false;
    return activeCustomThemeEntry?.neutralDerived ?? false;
  }

  /// [entry] 开了「跟随系统取色」且系统真有色时返回系统色，否则 null。
  Color? _followedSystemAccent(CustomThemeEntry entry) {
    if (!entry.followSystemAccent) return null;
    return systemPrimaryColor;
  }

  /// BUG-2187：「当前生效的自定义主题」里某个角色色的**唯一**解析链——
  /// 非自定义 key → null；自定义 key 且能解析到条目 → 条目字段（null = 跟随主题）；
  /// 自定义 key 但列表还没条目（迁移前竞态）→ 旧扁平偏好。
  ///
  /// 以前只有 [buildColorScheme] 走这条链，阅读器 chrome 直接读
  /// `customThemeFontColor` 等旧扁平 getter 并用 `== 'custom-theme'` 严格比较 key：
  /// TODO-930 之后编辑页写的是 `custom-theme:<id>`、且再也没人写扁平偏好，于是
  /// 正文/背景/选区/链接四色在阅读器里永远不生效。现在所有消费者都走这一个函数。
  Color? _activeCustomRole(
    int? Function(CustomThemeEntry entry) pick,
    Color? Function() legacy,
  ) {
    if (!isCustomThemeKey(appThemeKey)) return null;
    final CustomThemeEntry? entry = activeCustomThemeEntry;
    if (entry != null) {
      final int? value = pick(entry);
      return value == null ? null : Color(value);
    }
    return legacy();
  }

  /// 当前生效自定义主题钉死的主色（null = 由 seed 派生，即「按明暗自动调整色调」）。
  /// 跟随系统取色时，钉死的值换成系统色；是否钉死仍由 `primaryColor != null` 决定。
  Color? get activeCustomThemePrimaryColor {
    final Color? pinned = _activeCustomRole(
      (CustomThemeEntry e) => e.primaryColor,
      () => customThemePrimaryColor,
    );
    if (pinned == null) return null;
    final CustomThemeEntry? entry = activeCustomThemeEntry;
    if (entry == null) return pinned;
    return _followedSystemAccent(entry) ?? pinned;
  }

  /// 当前生效自定义主题钉死的界面底色（null = 由 seed 派生）。
  Color? get activeCustomThemeSurfaceColor =>
      _activeCustomRole((CustomThemeEntry e) => e.surfaceColor, () => null);

  /// 当前生效自定义主题的阅读器正文字色（null = 跟随主题）。
  Color? get activeCustomThemeFontColor => _activeCustomRole(
        (CustomThemeEntry e) => e.fontColor,
        () => customThemeFontColor,
      );

  /// 当前生效自定义主题的阅读器页面背景色（null = 跟随主题）。
  Color? get activeCustomThemeBackgroundColor => _activeCustomRole(
        (CustomThemeEntry e) => e.bgColor,
        () => customThemeBackgroundColor,
      );

  /// 当前生效自定义主题的查词选区高亮色（null = 跟随主题）。
  Color? get activeCustomThemeSelectionColor => _activeCustomRole(
        (CustomThemeEntry e) => e.selectionColor,
        () => customThemeSelectionColor,
      );

  /// 当前生效自定义主题的书内链接色（null = 跟随主题）。
  Color? get activeCustomThemeLinkColor => _activeCustomRole(
        (CustomThemeEntry e) => e.linkColor,
        () => customThemeLinkColor,
      );

  ThemeData _buildThemeData(Brightness brightness) =>
      buildThemeDataFor(buildColorScheme(brightness));

  /// 用当前主题的字体 / 墨水屏 / 设计系统，把任意 [scheme] 装成完整 ThemeData
  /// （[theme] / [darkTheme] 的唯一实现；工厂本体是 [buildFushiThemeData]）。
  ThemeData buildThemeDataFor(ColorScheme scheme) => buildFushiThemeData(
        scheme: scheme,
        textTheme: _textThemeBuilder(),
        eink: einkMode,
        designSystem: designSystemTheme,
        glass: glassMaterial,
        glassDesign: designSystem == 'glass',
        // 默认主题（系统取色）在玻璃设计系统下是单色：白底黑字 / 黑底白字。
        monochromeAccent: appThemeKey == 'system-theme',
      );

  // ── Custom theme prefs ─────────────────────────────────────────────

  Color get customThemeSeed {
    final int v =
        _get('custom_theme_seed', defaultValue: kCustomThemeDefaultSeed);
    return Color(v);
  }

  Future<void> setCustomThemeSeed(Color color) async {
    await _set('custom_theme_seed', color.toARGB32());
  }

  bool get customThemeDark =>
      _get('custom_theme_dark', defaultValue: false) as bool;

  Future<void> setCustomThemeDark(bool dark) async {
    await _set('custom_theme_dark', dark);
  }

  Color? get customThemeFontColor => _colorPref('custom_theme_font_color');
  Future<void> setCustomThemeFontColor(Color? c) =>
      _setColorPref('custom_theme_font_color', c);

  Color? get customThemeBackgroundColor => _colorPref('custom_theme_bg_color');
  Future<void> setCustomThemeBackgroundColor(Color? c) =>
      _setColorPref('custom_theme_bg_color', c);

  Color? get customThemeSelectionColor =>
      _colorPref('custom_theme_selection_color');
  Future<void> setCustomThemeSelectionColor(Color? c) =>
      _setColorPref('custom_theme_selection_color', c);

  Color? get customThemePrimaryColor =>
      _colorPref('custom_theme_primary_color');
  Future<void> setCustomThemePrimaryColor(Color? c) =>
      _setColorPref('custom_theme_primary_color', c);

  Color? get customThemeSecondaryColor =>
      _colorPref('custom_theme_secondary_color');
  Future<void> setCustomThemeSecondaryColor(Color? c) =>
      _setColorPref('custom_theme_secondary_color', c);

  Color? get customThemeTertiaryColor =>
      _colorPref('custom_theme_tertiary_color');
  Future<void> setCustomThemeTertiaryColor(Color? c) =>
      _setColorPref('custom_theme_tertiary_color', c);

  Color? get customThemeContainerColor =>
      _colorPref('custom_theme_container_color');
  Future<void> setCustomThemeContainerColor(Color? c) =>
      _setColorPref('custom_theme_container_color', c);

  // 历史键 'custom_theme_sasayaki_color'（Drift preferences 表）已由 v71
  // Drift 迁移搬到本键。
  Color? get customThemeSentenceAudioHighlightColor =>
      _colorPref('custom_theme_sentence_audio_color');
  Future<void> setCustomThemeSentenceAudioHighlightColor(Color? c) =>
      _setColorPref('custom_theme_sentence_audio_color', c);

  Color? get customThemeLinkColor => _colorPref('custom_theme_link_color');
  Future<void> setCustomThemeLinkColor(Color? c) =>
      _setColorPref('custom_theme_link_color', c);

  /// TODO-977: 音频高亮（原 sasayaki 跟随高亮）颜色，**全局、与阅读器主题解耦**。
  ///
  /// 旧设计把该色绑死在 custom-theme 主题条目里（`customThemeSasayakiColor`），
  /// 非自定义主题时阅读器音频高亮恒用主题 primary（reader_fushi_page.dart:300），
  /// 用户无处改色——「一直用主色」。本偏好是单值全局色，置非空时由
  /// `resolveReaderThemeColors` 覆盖所有主题分支的 sasayaki 角色色；为 null 时
  /// 沿用旧的随主题取色行为（向后兼容，老用户不受影响）。
  static const String audioHighlightColorPrefKey = 'audio_highlight_color';
  Color? get audioHighlightColor => _colorPref(audioHighlightColorPrefKey);
  Future<void> setAudioHighlightColor(Color? c) =>
      _setColorPref(audioHighlightColorPrefKey, c);

  Color? _colorPref(String key) {
    final int v = _get(key, defaultValue: 0);
    if (v == 0) return null;
    return Color(v);
  }

  Future<void> _setColorPref(String key, Color? color) async {
    await _set(key, color?.toARGB32() ?? 0);
  }

  // ── Multi custom theme list (TODO-930) ────────────────────────────
  //
  // Storage: the new `custom_themes` pref holds a List<String>, each element a
  // JSON-encoded [CustomThemeEntry]; `selected_custom_theme_id` holds the
  // currently-selected entry id. Both are per-Profile (NOT in
  // ProfileKeys._excludedPrefKeys) so the existing snapshot/apply/prune machinery
  // carries them, exactly like the legacy flat custom_theme_* keys.
  //
  // The legacy flat 11-key custom theme is migrated into a single list entry on
  // first read (idempotent). The flat keys are kept as read-only fallback and
  // never written again (same approach as TODO-928 stopping custom_theme_dark).
  static const String customThemesPrefKey = 'custom_themes';
  static const String selectedCustomThemeIdPrefKey = 'selected_custom_theme_id';

  bool _legacyCustomThemeMigrated = false;

  List<String> _rawCustomThemes() {
    final Object value =
        _get(customThemesPrefKey, defaultValue: const <String>[]);
    if (value is List) return value.map((dynamic e) => e.toString()).toList();
    return const <String>[];
  }

  List<CustomThemeEntry> _decodeCustomThemes(List<String> raw) {
    final List<CustomThemeEntry> out = <CustomThemeEntry>[];
    for (final String s in raw) {
      try {
        final dynamic decoded = jsonDecode(s);
        if (decoded is Map<String, dynamic>) {
          out.add(CustomThemeEntry.fromJson(decoded));
        } else if (decoded is Map) {
          out.add(CustomThemeEntry.fromJson(
              decoded.map((k, v) => MapEntry(k.toString(), v))));
        }
      } catch (_) {
        // Skip a malformed row rather than aborting the whole read.
      }
    }
    return out;
  }

  /// All custom themes. First read performs the idempotent legacy migration so
  /// pre-TODO-930 users transparently get a one-entry list pointing at their old
  /// flat custom theme.
  List<CustomThemeEntry> get customThemes {
    _ensureLegacyCustomThemeMigrated();
    return _decodeCustomThemes(_rawCustomThemes());
  }

  CustomThemeEntry? customThemeById(String id) {
    for (final CustomThemeEntry e in customThemes) {
      if (e.id == id) return e;
    }
    return null;
  }

  String? get selectedCustomThemeId {
    _ensureLegacyCustomThemeMigrated();
    final String v =
        _get(selectedCustomThemeIdPrefKey, defaultValue: '') as String;
    return v.isEmpty ? null : v;
  }

  Future<void> _writeCustomThemes(List<CustomThemeEntry> entries) async {
    await _set(
      customThemesPrefKey,
      entries.map((CustomThemeEntry e) => jsonEncode(e.toJson())).toList(),
    );
  }

  Future<void> _writeSelectedCustomThemeId(String? id) async {
    await _set(selectedCustomThemeIdPrefKey, id ?? '');
  }

  /// Insert a new entry (and select it) or replace an existing one by id.
  Future<void> upsertCustomTheme(CustomThemeEntry entry) async {
    final List<CustomThemeEntry> list =
        List<CustomThemeEntry>.from(customThemes);
    final int idx = list.indexWhere((CustomThemeEntry e) => e.id == entry.id);
    if (idx >= 0) {
      list[idx] = entry;
      await _writeCustomThemes(list);
    } else {
      list.add(entry);
      await _writeCustomThemes(list);
      await _writeSelectedCustomThemeId(entry.id);
    }
    notifyListeners();
  }

  /// Remove the entry with [id]. If it was selected, selection falls back to the
  /// first remaining entry (or clears when the list becomes empty).
  Future<void> deleteCustomTheme(String id) async {
    final List<CustomThemeEntry> list =
        customThemes.where((CustomThemeEntry e) => e.id != id).toList();
    await _writeCustomThemes(list);
    if (selectedCustomThemeId == id) {
      await _writeSelectedCustomThemeId(list.isEmpty ? null : list.first.id);
    }
    notifyListeners();
  }

  /// Make [id] the selected custom theme (no-op for an unknown id).
  Future<void> selectCustomTheme(String id) async {
    if (customThemeById(id) == null) return;
    await _writeSelectedCustomThemeId(id);
    notifyListeners();
  }

  void _ensureLegacyCustomThemeMigrated() {
    if (_legacyCustomThemeMigrated) return;
    _legacyCustomThemeMigrated = true;
    final LegacyCustomThemeMigration result = migrateLegacyCustomTheme(
      existing: _rawCustomThemes(),
      legacySeed:
          _get('custom_theme_seed', defaultValue: kCustomThemeDefaultSeed)
              as int,
      legacyFontColor: _get('custom_theme_font_color', defaultValue: 0) as int,
      legacyBgColor: _get('custom_theme_bg_color', defaultValue: 0) as int,
      legacySelectionColor:
          _get('custom_theme_selection_color', defaultValue: 0) as int,
      legacyPrimaryColor:
          _get('custom_theme_primary_color', defaultValue: 0) as int,
      legacySecondaryColor:
          _get('custom_theme_secondary_color', defaultValue: 0) as int,
      legacyTertiaryColor:
          _get('custom_theme_tertiary_color', defaultValue: 0) as int,
      legacyContainerColor:
          _get('custom_theme_container_color', defaultValue: 0) as int,
      legacySentenceAudioHighlightColor:
          _get('custom_theme_sentence_audio_color', defaultValue: 0) as int,
      legacyLinkColor: _get('custom_theme_link_color', defaultValue: 0) as int,
      idGenerator: _customThemeIdGenerator,
    );
    if (!result.shouldWrite) return;
    // Persist synchronously into _prefs so the very same read returns migrated
    // data, then flush to DB (fire-and-forget like other seed paths).
    final List<String> encoded = result.entries
        .map((CustomThemeEntry e) => jsonEncode(e.toJson()))
        .toList();
    _prefs[customThemesPrefKey] = PrefCodec.encode(encoded);
    _prefs[selectedCustomThemeIdPrefKey] =
        PrefCodec.encode(result.selectedId ?? '');
    unawaited(_db.setPref(customThemesPrefKey, PrefCodec.encode(encoded)));
    unawaited(_db.setPref(selectedCustomThemeIdPrefKey,
        PrefCodec.encode(result.selectedId ?? '')));
  }

  // ── Setters ───────────────────────────────────────────────────────

  /// 切主题只换配色：**不改写 `brightness_mode`、不强制亮 / 暗**（2026-10-06 用户
  /// 「切换主题的时候如果我是深色就要继续保持深色」）。此前选 `system-theme` 会把
  /// 明暗写成 system、选预设会写成该预设自带的 light / dark。
  Future<void> setAppThemeKey(String key) async {
    await _setAppThemeKeyKeepingEffective(key);
    notifyListeners();
    _persistSplashColor();
  }

  /// HBK-AUDIT-035：换主题键前，把**只靠旧主题键兜底读出**、从没独立存过的明暗
  /// （[brightnessMode] 对旧预设 / `custom_theme_dark` 的回退）与纯黑（[pureBlackDark]
  /// 对旧「纯黑」预设的回退）按换键前的有效值补写成独立偏好，与新主题键同一批落库。
  /// 换掉主题键后那些兜底就读不到了：旧 black-theme 用户改个种子色纯黑消失、旧自定义深色
  /// 用户换预设变成跟随系统。已显式存过的键不动。
  Future<void> _setAppThemeKeyKeepingEffective(String key) async {
    final Map<String, String> writes = <String, String>{};
    if (_get('brightness_mode', defaultValue: '').isEmpty) {
      writes['brightness_mode'] = PrefCodec.encode(brightnessMode);
    }
    if (_prefs['pure_black_dark'] == null) {
      writes['pure_black_dark'] = PrefCodec.encode(pureBlackDark);
    }
    writes['app_theme_key'] = PrefCodec.encode(key);
    final int revision = ++_preferenceWriteRevision;
    await _db.setPrefs(writes);
    for (final MapEntry<String, String> write in writes.entries) {
      _publishPreferenceWrite(write.key, write.value, revision);
    }
  }

  Future<void> setBrightnessMode(String mode) async {
    await _set('brightness_mode', mode);
    notifyListeners();
    _persistSplashColor();
  }

  // TODO-928: 自定义主题不再拥有自己的明暗真值。删掉 `brightnessMode` 参数后，
  // applyCustomTheme 只落 seed + 角色色 + `app_theme_key='custom-theme'`，**不再写**
  // `custom_theme_dark`、**不再写** `brightness_mode`。切到自定义主题保留用户当前的
  // 全局明暗（浅色态切自定义=浅色，深色态=深色），明暗变体由
  // buildFushiColorScheme(seed, brightness) 在 light/dark 各自从 seed 派生。
  // 想改明暗用全局的 brightness 选择器，自带/自定义一视同仁。
  //
  // 向后兼容（Never break userspace）：老用户历史一直双写过 `brightness_mode`，故其
  // 全局明暗持久值仍在、不回归；`customThemeDark` getter + brightnessMode 的 custom
  // 回退（:260）保留为纯只读兜底，只是不再产生新值。
  Future<void> applyCustomTheme({
    required Color seed,
    Color? fontColor,
    Color? backgroundColor,
    Color? selectionColor,
    Color? primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
    Color? containerColor,
    Color? sentenceAudioHighlightColor,
    Color? linkColor,
  }) async {
    // TODO-930: write the same values into the new list model so the share-code
    // import path keeps working: replace the currently-selected entry, or create
    // one when the list is empty. The legacy flat keys are still written so
    // pre-migration fallback and any code still reading them stays consistent.
    await setCustomThemeSeed(seed);
    await setCustomThemeFontColor(fontColor);
    await setCustomThemeBackgroundColor(backgroundColor);
    await setCustomThemeSelectionColor(selectionColor);
    await setCustomThemePrimaryColor(primaryColor);
    await setCustomThemeSecondaryColor(secondaryColor);
    await setCustomThemeTertiaryColor(tertiaryColor);
    await setCustomThemeContainerColor(containerColor);
    await setCustomThemeSentenceAudioHighlightColor(
        sentenceAudioHighlightColor);
    await setCustomThemeLinkColor(linkColor);

    int? argb(Color? c) => c?.toARGB32();
    final CustomThemeEntry? current = activeCustomThemeEntry;
    final CustomThemeEntry entry = CustomThemeEntry(
      id: current?.id ?? _customThemeIdGenerator(),
      name: current?.name ?? '',
      seed: seed.toARGB32(),
      fontColor: argb(fontColor),
      bgColor: argb(backgroundColor),
      selectionColor: argb(selectionColor),
      primaryColor: argb(primaryColor),
      secondaryColor: argb(secondaryColor),
      tertiaryColor: argb(tertiaryColor),
      containerColor: argb(containerColor),
      sentenceAudioHighlightColor: argb(sentenceAudioHighlightColor),
      linkColor: argb(linkColor),
    );
    await upsertCustomTheme(entry);

    await _setAppThemeKeyKeepingEffective('custom-theme');
    notifyListeners();
    _persistSplashColor();
  }

  // ── Splash ────────────────────────────────────────────────────────

  static const _splashChannel = FushiChannels.splash;

  void _persistSplashColor() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final brightness = isDarkMode ? Brightness.dark : Brightness.light;
    final surface = buildColorScheme(brightness).surface;
    _splashChannel.invokeMethod('setSplashColor', {
      'color': surface.toARGB32(),
      'isDark': isDarkMode,
    }).catchError((Object e) {
      debugPrint('[theme] setSplashColor failed: $e');
    });
  }
}

final themeProvider = ChangeNotifierProvider<ThemeNotifier>((ref) {
  final appModel = ref.watch(appProvider);
  return appModel.themeNotifier;
});

/// 全局输入框主题（用户 2026-10-04：「所有输入框都很丑」的根因层）。
///
/// 凡是没经 `fushiMd3FieldDecoration` / `FushiTextFieldControl` 包装的输入
/// （裸 TextField、DropdownMenu、调用点手写 `OutlineInputBorder()` 的装饰——
/// 主题的 enabledBorder 会顶掉它们的 border）都落到这里，所以这里与
/// `fushiMd3FieldDecoration` 同口径：
/// - MD3：surfaceContainerHigh 柔和填充、圆角 12、静止无描边，聚焦 2px
///   primary，错误 error；
/// - Apple：tertiaryFill 实色、圆角 10、无描边（iOS roundedRect 文本框），
///   聚焦一圈半透明强调色（键盘 / 手柄导航落到框上时的焦点指示）；
/// - 墨水屏：保留描边方框——填充色在墨水屏上是抖动灰噪点，边界只能靠描边。
InputDecorationTheme _fushiInputDecorationTheme(
  ColorScheme cs, {
  required bool eink,
  required FushiAppleColors? apple,
}) {
  if (eink) {
    return InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: FushiBorderRadius.control,
        borderSide: BorderSide(color: cs.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: FushiBorderRadius.control,
        borderSide: BorderSide(color: cs.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: FushiBorderRadius.control,
        borderSide: BorderSide(color: cs.primary, width: 2),
      ),
    );
  }
  final BorderRadius radius = BorderRadius.circular(apple != null ? 10 : 12);
  OutlineInputBorder outline([Color? color, double width = 0]) =>
      OutlineInputBorder(
        borderRadius: radius,
        borderSide: color == null
            ? BorderSide.none
            : BorderSide(color: color, width: width),
      );
  final Color focus = apple == null
      ? cs.primary
      : apple.accent.withValues(alpha: 0.5);
  final Color error = apple?.destructive ?? cs.error;
  return InputDecorationTheme(
    filled: true,
    fillColor: apple?.tertiaryFill ?? cs.surfaceContainerHigh,
    hoverColor: Colors.transparent,
    hintStyle: TextStyle(color: apple?.secondaryLabel ?? cs.onSurfaceVariant),
    prefixIconColor: apple?.secondaryLabel ?? cs.onSurfaceVariant,
    suffixIconColor: apple?.secondaryLabel ?? cs.onSurfaceVariant,
    border: outline(),
    enabledBorder: outline(),
    disabledBorder: outline(),
    focusedBorder: outline(focus, 2),
    errorBorder: outline(error, 1.5),
    focusedErrorBorder: outline(error, 2),
  );
}

/// 全应用唯一的「ColorScheme → ThemeData」工厂。
///
/// 主 app（[ThemeNotifier.theme] / [ThemeNotifier.darkTheme]）、书内查词弹窗
/// （`resolveDictionaryPopupTheme`）与数据库就绪前的兜底界面
/// （[buildFushiFallbackTheme]）都从这里取组件主题；新代码不得再手写
/// `ThemeData(`（守卫 `test/models/theme_single_factory_guard_test.dart`）。
ThemeData buildFushiThemeData({
  required ColorScheme scheme,
  required TextTheme textTheme,
  bool eink = false,
  FushiDesignSystem designSystem = FushiDesignSystem.auto,
  FushiGlassMaterial glass = FushiGlassMaterial.off,
  bool glassDesign = false,
  bool monochromeAccent = false,
}) {
  // 玻璃设计系统 = Apple 26 设计语言：表面 / 文字 / 描边换成 Apple 系统色，
  // 强调色取主题色相按 iOS 系统色重建（见 fushi_apple_palette.dart）。MD3 不受影响。
  final bool appleDesign = glassDesign && !eink;
  final ColorScheme cs = appleDesign
      ? appleColorScheme(scheme, monochrome: monochromeAccent)
      : scheme;
  // 字阶先解析到与 Theme.of(context).textTheme 同一基底（Typography 2021 颜色档
  // + 几何档，inherit: false）：下面组件主题里的文字样式与框架默认样式、以及切换
  // 主题 / 明暗 / 设计系统时 AnimatedTheme 的插值都在同一基底上做 TextStyle.lerp，
  // 不再撞 inherit 不一致的断言（见 fushiResolveTextTheme）。
  final TextTheme tt = fushiResolveTextTheme(
    appleDesign ? appleTextTheme(textTheme) : textTheme,
    scheme: cs,
  );
  final FushiAppleColors? appleColors = appleDesign
      ? FushiAppleColors.of(cs.brightness, cs.primary)
      : null;
  // 玻璃设计系统：Flutter 自己构建 Material 的那些表面（对话框、菜单、下拉、
  // 提示条、tooltip、卡片、抽屉、裸 showModalBottomSheet、AppBar）在主题层统一
  // 染成半透明，全平台、全调用点一次生效。能挂 BackdropFilter 的表面（导航、
  // adaptiveModalSheet、FushiDialogFrame、悬浮按钮）由 FushiGlassSurface 另外加
  // 模糊；对话框背后的模糊由 showAppDialog 统一铺。墨水屏下恒实心。
  final bool glassy = glass != FushiGlassMaterial.off && !eink;
  Color? glassTint(Color color, double Function(Brightness) opacity) =>
      glassy ? color.withValues(alpha: opacity(cs.brightness)) : null;
  final Color? glassMenuColor = glassTint(
    cs.surfaceContainer,
    fushiGlassOverlayOpacity,
  );
  // MD3 菜单面板（2026-10-04 菜单统一）：surfaceContainer、圆角 12、轻阴影
  // （elevation 3）、无 tint；面板四周内缩 6，菜单行的圆角高亮块因此离面板
  // 边缘 6px。毛玻璃下面板半透明（glassMenuColor）。墨水屏补实描边。Apple
  // 设计系统的 MenuAnchor / 下拉由 fushi_glass_overlays.dart 自绘，覆盖这些值。
  final MenuStyle menuPanelStyle = MenuStyle(
    backgroundColor: WidgetStatePropertyAll<Color>(
      glassMenuColor ?? cs.surfaceContainer,
    ),
    surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    elevation: const WidgetStatePropertyAll<double>(3),
    shadowColor: WidgetStatePropertyAll<Color>(cs.shadow),
    padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
      EdgeInsets.all(6),
    ),
    shape: WidgetStatePropertyAll<OutlinedBorder>(
      RoundedRectangleBorder(
        borderRadius: FushiBorderRadius.menu,
        side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
      ),
    ),
  );
  // MD3 菜单行（MenuItemButton）：行高 44、左右 12、14 号 onSurface 字、
  // 20 号 onSurfaceVariant 图标；悬停 / 焦点 = secondaryContainer 圆角（8）块。
  final ButtonStyle menuRowStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll<Size>(Size(188, 44)),
    padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
      EdgeInsets.symmetric(horizontal: 12),
    ),
    shape: const WidgetStatePropertyAll<OutlinedBorder>(
      RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
    ),
    backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      if (states.contains(WidgetState.disabled)) return Colors.transparent;
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused) ||
          states.contains(WidgetState.pressed)) {
        return cs.secondaryContainer;
      }
      return Colors.transparent;
    }),
    foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      if (states.contains(WidgetState.disabled)) {
        return cs.disabledContent;
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused) ||
          states.contains(WidgetState.pressed)) {
        return cs.onSecondaryContainer;
      }
      return cs.onSurface;
    }),
    iconColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      if (states.contains(WidgetState.disabled)) {
        return cs.disabledContent;
      }
      return cs.onSurfaceVariant;
    }),
    iconSize: const WidgetStatePropertyAll<double>(20),
    overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    textStyle: WidgetStatePropertyAll<TextStyle?>(
      tt.bodyMedium?.copyWith(fontSize: 14),
    ),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    textTheme: tt,
    primaryTextTheme: tt.apply(
      bodyColor: cs.onPrimary,
      displayColor: cs.onPrimary,
    ),
    // M3E 语义图标（FushiIcons，Material Symbols 可变字体）的全局轴默认：opsz 24
    // 对应常规 24dp 图标（框架兜底是 48，24dp 下笔画发细）；深色主题 GRAD -25 抵消
    // 浅色图标的光晕。颜色沿用框架默认（black87 / white），旧 MaterialIcons 与
    // CupertinoIcons 不是可变字体，这些轴对它们无效、像素不变。
    iconTheme: IconThemeData(
      color: cs.brightness == Brightness.dark
          ? kDefaultIconLightColor
          : kDefaultIconDarkColor,
      opticalSize: 24,
      grade: fushiSymbolGrade(cs.brightness),
    ),
    // E-ink: swap pages in one frame (single panel refresh, no smearing) and
    // drop ink ripples — a spreading translucent overlay is exactly the kind
    // of repeated partial refresh slow panels render worst.
    pageTransitionsTheme: eink
        ? const PageTransitionsTheme(
            builders: <TargetPlatform, PageTransitionsBuilder>{
              TargetPlatform.android: EinkNoPageTransitionsBuilder(),
              // iOS/macOS 不能用零转场：它们的返回手势由这份 builder 装载，
              // 直接 `return child` 等于把侧滑返回从整个 app 拆掉（iOS 又没有
              // 系统返回键），隐藏顶栏的页面就此退不出去。
              TargetPlatform.iOS: EinkCupertinoPageTransitionsBuilder(),
              TargetPlatform.macOS: EinkCupertinoPageTransitionsBuilder(),
              TargetPlatform.windows: EinkNoPageTransitionsBuilder(),
              TargetPlatform.linux: EinkNoPageTransitionsBuilder(),
              TargetPlatform.fuchsia: EinkNoPageTransitionsBuilder(),
            },
          )
        // Android 侧滑返回改走自带手势记账的转场：Flutter 自带实现把平台事件直接
        // 转成 navigator 的手势计数增减，平台重发起始事件 / 手势中途路由被 pop 都
        // 会让计数失配，而计数一旦卡住，每层路由都被 IgnorePointer——画面正常但整个
        // app 点不动（见 FushiPredictiveBackPageTransitionsBuilder 类注释）。
        // 其余平台必须逐个列出：PageTransitionsTheme 的 builders 是全量替换，漏一个
        // 平台它就回落到 ZoomPageTransitionsBuilder（iOS/macOS 会因此丢掉 Cupertino
        // 的边缘滑动返回）。
        : const PageTransitionsTheme(
            builders: <TargetPlatform, PageTransitionsBuilder>{
              TargetPlatform.android:
                  FushiPredictiveBackPageTransitionsBuilder(),
              TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
              TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
              // 桌面：原地淡入、不位移（2026-10 动效重做）。Zoom 的整窗缩放位移
              // 随窗口尺寸线性增长，大屏上很重，见该 builder 类注释。
              TargetPlatform.windows: FushiSharedAxisPageTransitionsBuilder(),
              TargetPlatform.linux: FushiSharedAxisPageTransitionsBuilder(),
              TargetPlatform.fuchsia: FushiSharedAxisPageTransitionsBuilder(),
            },
          ),
    // Apple 设计系统同样不要水波：iOS / macOS 的按压反馈是整块变暗 / 变淡，
    // 不是从触点扩散的墨水圈。一处主题改动把页面里残留的 InkWell（自绘卡片、
    // 行）一起收掉；按下的 highlight 改成极淡的 Apple 中性填充（tertiaryFill
    // 的一半），不再是 MD3 的 12% 前景色叠层。
    splashFactory: eink || appleDesign ? NoSplash.splashFactory : null,
    // E-ink：NoSplash 只去掉扩散水波，InkWell 的 hover（4% alpha）/ 按下
    // highlight（12% alpha）叠层照画——都是墨水屏上的抖动灰，且每次 hover
    // 进出都是一次局部刷新。按下反馈交给各组件自己的反色/描边，这里归零。
    // focusColor 不动：焦点环由 FushiFocusTarget 自绘。
    hoverColor: eink ? Colors.transparent : null,
    highlightColor: eink
        ? Colors.transparent
        : appleColors?.tertiaryFill.withValues(
            alpha: appleColors.tertiaryFill.a / 2,
          ),
    extensions: <ThemeExtension<dynamic>>[
      FushiDesignSystemTheme(designSystem),
      FushiEinkTheme(eink),
      FushiGlassTheme(glass, glassDesign: glassDesign && !eink),
      if (appleColors != null) appleColors,
    ],
    // 玻璃下顶栏透明：透出外壳的系统窗口材质（Windows 11 Mica / macOS
    // vibrancy）或页面底色，不再自带一条实心色带。
    // MD3（2026-10 顶栏统一，M3 Expressive）：静止时透明（alpha 0 的
    // surface——状态栏图标明暗仍按 surface 估算，不会被纯透明色判成深色），
    // 内容滚到栏下面后换成 surfaceContainer 色块；不画阴影线、不叠 tint。
    // 标题 titleLarge（22 w400）onSurface，返回 / 抽屉图标 24 onSurface，
    // actions 图标 24 onSurfaceVariant。墨水屏 surfaceContainer 塌成页面底色，
    // 滚动前后观感不变。Apple 设计系统的顶栏由 FushiAppBar 自己给参数，这里
    // 的字阶 / 图标色不套给它。
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: glassy
          ? Colors.transparent
          : WidgetStateColor.resolveWith(
              (Set<WidgetState> states) =>
                  states.contains(WidgetState.scrolledUnder)
                  ? cs.surfaceContainer
                  : cs.surface.withValues(alpha: 0),
            ),
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      // 不在主题里钉 titleTextStyle：M3 默认就是 titleLarge / onSurface，而主题级
      // titleTextStyle 会同时盖掉 SliverAppBar.medium / .large 展开态的
      // headlineSmall / headlineMedium 大标题（Flutter 展开态取
      // `titleTextStyle ?? appBarTheme.titleTextStyle ?? 大标题默认`），
      // 大标题顶栏只剩一行 22 号小字压在 152 高的空带底部（BUG-3039：Android
      // MD3 设置页「设置」上方大片空白）。
      titleTextStyle: null,
      iconTheme: appleDesign
          ? null
          : IconThemeData(color: cs.onSurface, size: 24),
      actionsIconTheme: appleDesign
          ? null
          : IconThemeData(color: cs.onSurfaceVariant, size: 24),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: glassTint(
        cs.surfaceContainerLow,
        fushiGlassOverlayOpacity,
      ),
    ),
    // MD3 Expressive rail（自绘 rail 已按此画；这里给仍用框架
    // NavigationRail 的地方同一套）：全圆角 secondaryContainer 药丸、
    // 24 图标、12 号 w500 标签；墨水屏反色药丸。
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: glassTint(cs.surface, fushiGlassFillOpacity),
      indicatorColor: eink ? cs.onSurface : cs.secondaryContainer,
      indicatorShape: const StadiumBorder(),
      selectedIconTheme: IconThemeData(
        color: eink ? cs.surface : cs.onSecondaryContainer,
        size: 24,
      ),
      unselectedIconTheme: IconThemeData(color: cs.onSurfaceVariant, size: 24),
      selectedLabelTextStyle: tt.labelMedium?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
      ),
      unselectedLabelTextStyle: tt.labelMedium?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: cs.onSurfaceVariant,
      ),
    ),
    menuTheme: MenuThemeData(style: menuPanelStyle),
    menuButtonTheme: MenuButtonThemeData(style: menuRowStyle),
    menuBarTheme: MenuBarThemeData(
      style: glassMenuColor == null
          ? null
          : MenuStyle(
              backgroundColor: WidgetStatePropertyAll<Color>(glassMenuColor),
              surfaceTintColor: const WidgetStatePropertyAll<Color>(
                Colors.transparent,
              ),
            ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(menuStyle: menuPanelStyle),
    // 滑块 / 轨道配色交回 M3 默认（选中：轨道 primary、滑块 onPrimary、勾
    // onPrimaryContainer；未选中：轨道 surfaceContainerHighest、滑块 outline）。
    // 以前覆写成「轨道 primaryContainer + 滑块 primary」是 M2 的配法，而 M3 的
    // 勾图标仍按 onPrimaryContainer 着色——亮色下深色勾压在 primary 滑块上几乎
    // 看不见。墨水屏下 primary=前景、onPrimary=底色，默认配色同样黑白分明。
    // 勾显式着 primary：M3 默认的 onPrimaryContainer 只在原生色阶里与 onPrimary
    // 明暗相反；自定义主题钉了主色时 onPrimary 与 onPrimaryContainer 是各自另算
    // 的可读色，可能同黑同白（深色模式钉深主色 / 亮色模式钉亮主色），勾就与
    // 滑块撞色消失。primary 与 onPrimary 的对比度由构造保证。
    switchTheme: SwitchThemeData(
      thumbIcon: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? Icon(Icons.check, size: 14, color: cs.primary)
            : null;
      }),
      trackOutlineColor: WidgetStateColor.resolveWith((states) {
        // E-ink: keep a solid outline on both states so the switch body
        // never depends on a fill the panel may dither.
        if (eink) return cs.outline;
        // 2026-10 开关统一：未选中也不描灰边——M3 默认那圈 outline 让关态开关
        // 像个空心输入框；轨道 surfaceContainerHighest + 滑块 outline（M3 默认
        // 角色色）已足够表达关态。
        return Colors.transparent;
      }),
      // 悬停 / 按下 / 焦点状态层压淡：M3 默认 8%–10% 的整圆状态层在成片的设置
      // 列表里一路扫过去很跳。墨水屏交回默认（与以前一致）。
      overlayColor: eink ? null : _fushiSoftStateLayer(cs),
    ),
    // 2026-10 复选 / 单选统一（与开关同一套柔和状态层）：复选框 18 见方、圆角 4
    // （M3 默认 2 太方）；未选中 2px onSurfaceVariant 边、选中 primary 底 +
    // onPrimary 勾都是 M3 默认角色色，不覆写。单选 20（外环 2px），选中圆点
    // 10（默认 9 在外环里显得空）。墨水屏全部交回默认（与以前一致）。
    checkboxTheme: eink
        ? null
        : CheckboxThemeData(
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(4)),
            ),
            overlayColor: _fushiSoftStateLayer(cs),
          ),
    radioTheme: eink
        ? null
        : RadioThemeData(
            innerRadius: const WidgetStatePropertyAll<double?>(5),
            overlayColor: _fushiSoftStateLayer(cs),
          ),
    // MD3 Expressive 导航栏（与自绘底栏同一套）：64 高、全圆角药丸、
    // 12 号 w500 标签（选中加粗一档、onSurface，未选中 onSurfaceVariant）。
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      height: 64,
      indicatorColor: eink ? cs.onSurface : cs.secondaryContainer,
      indicatorShape: const StadiumBorder(),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (Set<WidgetState> states) => tt.labelMedium?.copyWith(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? cs.onSurface
              : cs.onSurfaceVariant,
        ),
      ),
      backgroundColor: glassTint(cs.surfaceContainer, fushiGlassFillOpacity),
    ),
    // MD3 弹出菜单：与 MenuAnchor 同一块面板（surfaceContainer、圆角 12、
    // elevation 3、无 tint、上下 6），14 号 onSurface 文字。
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: FushiBorderRadius.menu,
        side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
      ),
      color: glassMenuColor ?? cs.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shadowColor: cs.shadow,
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      labelTextStyle: WidgetStateProperty.resolveWith((
        Set<WidgetState> states,
      ) {
        return tt.bodyMedium?.copyWith(
          fontSize: 14,
          color: states.contains(WidgetState.disabled)
              ? cs.disabledContent
              : cs.onSurface,
        );
      }),
    ),
    // MD3 对话框（2026-10-04 对话框统一）：surfaceContainerHigh 面板、圆角 28、
    // 无 tint 无阴影；标题 22 w600 onSurface、正文 14/1.5 onSurfaceVariant、
    // 动作区 24 内边距右对齐。墨水屏补实描边。毛玻璃下本体半透明，背后由
    // showAppDialog 铺整屏模糊。Apple 设计系统的对话框不走 Material
    // 表面（fushi_glass_overlays.dart 自绘），文字样式留空交给它自己。
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: FushiBorderRadius.dialog,
        side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
      ),
      backgroundColor:
          glassTint(cs.surfaceContainerHigh, fushiGlassFillOpacity) ??
          cs.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      iconColor: appleDesign ? null : cs.secondary,
      titleTextStyle: appleDesign
          ? null
          : (tt.headlineSmall ?? const TextStyle()).copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              height: 1.27,
              color: cs.onSurface,
            ),
      contentTextStyle: appleDesign
          ? null
          : (tt.bodyMedium ?? const TextStyle()).copyWith(
              fontSize: 14,
              height: 1.5,
              color: cs.onSurfaceVariant,
            ),
      actionsPadding: appleDesign
          ? null
          : const EdgeInsets.fromLTRB(24, 0, 24, 24),
    ),
    // MD3 列表行（2026-10-04 卡片 / 列表统一）：左右 16；悬停 / 按下状态层与
    // 选中底都是 12 圆角块（FushiListTileControl 再把行左右内缩 4，不顶到容器
    // 边），选中 = secondaryContainer 底 + onSecondaryContainer 前景（不再是
    // primary 彩字）。标题 bodyLarge onSurface、副标题 bodyMedium
    // onSurfaceVariant、行首图标 onSurfaceVariant 都是 M3 默认，不覆写。Apple
    // 设计系统的行自己画（_GlassListTileHost）；墨水屏 secondaryContainer 塌缩成
    // 背景色、选中底不可见，交回默认（与以前一致）。
    listTileTheme: appleDesign || eink
        ? const ListTileThemeData()
        : ListTileThemeData(
            contentPadding: const EdgeInsetsDirectional.symmetric(
              horizontal: 16,
            ),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            selectedColor: cs.onSecondaryContainer,
            selectedTileColor: cs.secondaryContainer,
          ),
    inputDecorationTheme: _fushiInputDecorationTheme(
      cs,
      eink: eink,
      apple: appleColors,
    ),
    // BUG-1997：两个亮度用同一个粗细。原来深色是 `null`（退回 Material 默认 8），
    // 而全局 `thumbVisibility: true` + 桌面端自动包 Scrollbar 意味着那 8+2px 是
    // **常驻**覆盖在每个列表右侧的，压住并吞掉最右一列的操作按钮。仓库里 9 处
    // RawScrollbar 都硬写 3，说明 3 才是设计意图，深色只是漏钉。
    // M3E：粗细不变、全圆头 + onSurfaceVariant 状态递进拇指（fushi_m3e_misc_themes）。
    scrollbarTheme: fushiM3eScrollbarTheme(cs: cs, eink: eink),
    // 2026-10：M3 2024 版滑块（16 粗轨道 + 竖条拇指 + 拇指两侧留缝 + 尾端停止
    // 点），与下面的 2024 版进度条同一代视觉；RangeSlider 吃同一份主题。墨水屏
    // 保留 2023 版细轨圆钮与原配色（缝与停止点在低分辨率面板上会糊成灰点）。
    // 自带 SliderTheme 覆写 thumbShape / trackShape 的紧凑滑块（视频音量浮层、
    // 有声书面板）照旧用它们自己的形状。
    sliderTheme: eink
        ? SliderThemeData(
            thumbColor: cs.primary,
            activeTrackColor: cs.primary,
            inactiveTrackColor: cs.outlineVariant,
          )
        : SliderThemeData(
            // year2023 被标为 deprecated 只是为了提示「将来默认 false」；显式传
            // false 正是官方给的启用方式。
            // ignore: deprecated_member_use
            year2023: false,
            // 离散刻度（停止点）克制：默认是 onPrimary / onSecondaryContainer
            // 实色点，分格多时像一串珠子，压成半透明。
            activeTickMarkColor: cs.onPrimary.withValues(alpha: 0.6),
            inactiveTickMarkColor: cs.onSecondaryContainer.withValues(
              alpha: 0.38,
            ),
            // 数值气泡：M3 圆角矩形（2024 版默认就是它，钉住免得默认再变）。
            valueIndicatorShape: const RoundedRectSliderValueIndicatorShape(),
            rangeValueIndicatorShape:
                const RoundedRectRangeSliderValueIndicatorShape(),
            valueIndicatorColor: cs.inverseSurface,
            valueIndicatorTextStyle: tt.labelMedium?.copyWith(
              color: cs.onInverseSurface,
            ),
          ),
    // M3 Expressive 其余组件（2026-10-05 用户「所有组件都是 m3e」）：提示条 /
    // tooltip / 徽标 / 日期时间选择器 / 轮播的主题统一在 fushi_m3e_misc_themes.dart，
    // 这里只调用。提示条与 toast、plain tooltip 同一套「反色浮层」语言。
    snackBarTheme: fushiM3eSnackBarTheme(
      cs: cs,
      tt: tt,
      eink: eink,
      glassDesign: glassDesign,
      glassBackground: glassTint(cs.inverseSurface, fushiGlassOverlayOpacity),
    ),
    tooltipTheme: fushiM3eTooltipTheme(
      cs: cs,
      tt: tt,
      eink: eink,
      glassBackground: glassTint(cs.inverseSurface, fushiGlassOverlayOpacity),
    ),
    badgeTheme: fushiM3eBadgeTheme(cs: cs, tt: tt, eink: eink),
    datePickerTheme: fushiM3eDatePickerTheme(
      cs: cs,
      tt: tt,
      eink: eink,
      appleDesign: appleDesign,
    ),
    timePickerTheme: fushiM3eTimePickerTheme(
      cs: cs,
      tt: tt,
      eink: eink,
      appleDesign: appleDesign,
    ),
    carouselViewTheme: fushiM3eCarouselTheme(cs: cs, eink: eink),
    // 2026-10：M3 2024 版进度条——圆头、轨道与指示器之间留缝、确定态尾端有
    // 停止点，读数比 2023 版的一整条色带清楚。墨水屏保留 2023 版（缝与停止点在
    // 低分辨率面板上会糊成灰点）。
    // 2026-10 进度统一：Fushi*ProgressIndicator 包装在 MD3 下画 Material 3
    // Expressive 的波浪进度（自绘，见 fushi_expressive_progress.dart），尺寸 /
    // 线宽 / 缝 / 配色都从这里读；绕过包装的原生控件吃 2024 版（圆头、缝、
    // 停止点）。两者同一套参数：线宽 4、缝 4、轨道 secondaryContainer、已填段
    // primary。墨水屏保留 2023 版（缝与停止点在低分辨率面板上会糊成灰点，包装
    // 在墨水屏下也退回原控件）。
    progressIndicatorTheme: ProgressIndicatorThemeData(
      // year2023 被标为 deprecated 只是为了提示「将来默认 false」；显式传 false
      // 正是官方给的启用方式。
      // ignore: deprecated_member_use
      year2023: eink,
      linearTrackColor: eink ? null : cs.secondaryContainer,
      linearMinHeight: eink ? null : 4,
      trackGap: eink ? null : 4,
      borderRadius: const BorderRadius.all(Radius.circular(4)),
    ),
    // MD3 卡片（2026-10-04 卡片 / 列表统一）：surfaceContainerLow 填充分层、
    // 16 圆角、无阴影无 surface tint（elevation 0 之外再钉死两色，调用点传了
    // elevation 也不会冒出灰影 / 粉调）。
    cardTheme: CardThemeData(
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      color: glassTint(cs.surfaceContainerLow, fushiGlassContainerOpacity) ??
          cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        // E-ink: surfaceContainerLow == the page background, so cards need a
        // solid outline to keep their boundary readable in pure black/white.
        side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
      ),
    ),
    // 裸 showModalBottomSheet 的底色；adaptiveModalSheet 自己挂玻璃表面、底色
    // 透明，不吃这里。没有模糊，所以用浮层档的不透明度。
    // MD3 底部弹层（2026-10-04 弹层统一）：surfaceContainerLow、上两角 28、
    // 拖动条 32×4 onSurfaceVariant@0.4、无 tint、遮罩 scrim@0.32；宽屏居中、
    // 最宽 640（MD3 规范）。墨水屏补实描边、遮罩不透明度交回默认。
    bottomSheetTheme: BottomSheetThemeData(
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
      ),
      dragHandleColor: cs.onSurfaceVariant.withValues(alpha: 0.4),
      dragHandleSize: const Size(32, 4),
      constraints: const BoxConstraints(maxWidth: 640),
      modalBarrierColor: eink ? null : cs.modalScrim,
      surfaceTintColor: Colors.transparent,
      backgroundColor: glassTint(
        cs.surfaceContainerLow,
        fushiGlassOverlayOpacity,
      ),
      modalBackgroundColor: glassTint(
        cs.surfaceContainerLow,
        fushiGlassOverlayOpacity,
      ),
    ),
    // 玻璃下悬浮按钮底色让位给外包的 FushiGlassFab（液态档折射、毛玻璃档模糊）。
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 0,
      highlightElevation: 0,
      // Apple（iOS 26）：悬浮按钮是中性玻璃胶囊 / 圆钮 + 强调色图标，不是 MD3
      // 的 primaryContainer 圆角方块；降低透明度时回落二级分组实色底。
      backgroundColor: glassy
          ? Colors.transparent
          : appleDesign
              ? cs.surfaceContainerHigh
              : cs.primaryContainer,
      foregroundColor: appleDesign ? cs.primary : cs.onPrimaryContainer,
      shape: appleDesign
          ? const StadiumBorder()
          : RoundedRectangleBorder(
              borderRadius: FushiBorderRadius.control,
              // E-ink：primaryContainer == 页面底色、阴影又是透明的，FAB 只剩一枚
              // 悬空图标（首页后台刮削任务按钮）；描边把按钮体画回来。
              side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
            ),
    ),
    // E-ink：M3 只用 `secondaryContainer` 填充表达选中段，而墨水屏方案把它
    // 塌缩成了页面底色——选中段与相邻段逐像素相同，全仓调用点又一律
    // `showSelectedIcon: false`，连勾选形状这条兜底都没有。`side` 由整条按钮
    // 的 states 解析（Flutter 的 `segmentStyleFor` 不把 side 下发到分段），
    // 做不出按段差异；反色填充是剩下唯一的通道，也是上游 HSA 的做法——它的
    // eink scheme 直接把 `secondaryContainer` 定义成前景色。失效态返回 null
    // 交回 M3 默认，不动既有的失效观感。填充/前景都不改几何，不影响分段条
    // 的宽度估算与 overflow 守卫。
    segmentedButtonTheme: eink
        ? SegmentedButtonThemeData(
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith<Color?>((
                Set<WidgetState> states,
              ) {
                if (states.contains(WidgetState.disabled)) return null;
                return states.contains(WidgetState.selected)
                    ? cs.onSurface
                    : cs.surface;
              }),
              foregroundColor: WidgetStateProperty.resolveWith<Color?>((
                Set<WidgetState> states,
              ) {
                if (states.contains(WidgetState.disabled)) return null;
                return states.contains(WidgetState.selected)
                    ? cs.surface
                    : cs.onSurface;
              }),
              iconColor: WidgetStateProperty.resolveWith<Color?>((
                Set<WidgetState> states,
              ) {
                if (states.contains(WidgetState.disabled)) return null;
                return states.contains(WidgetState.selected)
                    ? cs.surface
                    : cs.onSurface;
              }),
            ),
          )
        : const SegmentedButtonThemeData(),
    // chip 统一（2026-10-04）：与全胶囊按钮、填充输入框同一语言——全胶囊、
    // 未选中 surfaceContainerHigh 柔和填充、无描边（以前是 r6 + outlineVariant
    // 描边，在胶囊按钮旁边又方又旧）。墨水屏填充色是抖动灰，保留描边表达边界。
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: eink ? BorderSide(color: cs.outlineVariant) : BorderSide.none,
      backgroundColor: eink ? null : cs.surfaceContainerHigh,
      // E-ink：同一个塌缩——`secondaryContainer` 等于页面底色，`showCheckmark`
      // 又关掉了 M3 唯一的形状信号，选中与未选中的 chip 逐像素相同（字体库那
      // 排「用途」FilterChip 就栽在这）。反色填充 + 配对 label 色补回信号；
      // labelStyle 必须从 `labelLarge` 派生，直接给裸 TextStyle 会把 chip 的
      // 字号字族一起替换掉。
      selectedColor: eink ? cs.onSurface : cs.secondaryContainer,
      labelStyle: eink
          ? (tt.labelLarge ?? const TextStyle()).copyWith(
              color: WidgetStateColor.resolveWith(
                (Set<WidgetState> states) =>
                    states.contains(WidgetState.selected)
                        ? cs.surface
                        : cs.onSurface,
              ),
            )
          // MD3：14 号 w500，未选中 onSurfaceVariant、选中
          // onSecondaryContainer（与选中底 secondaryContainer 配对）。
          : (tt.labelLarge ?? const TextStyle()).copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: WidgetStateColor.resolveWith(
                (Set<WidgetState> states) =>
                    states.contains(WidgetState.selected)
                        ? cs.onSecondaryContainer
                        : cs.onSurfaceVariant,
              ),
            ),
      checkmarkColor: eink ? null : cs.onSecondaryContainer,
      deleteIconColor: eink ? null : cs.onSurfaceVariant,
      // 全局不画对勾：ChoiceChip 是单选、靠填充表达选中；多选的 FilterChip
      // 由 FushiFilterChip 包装显式打开对勾（MD3 filter chip 规范）。
      showCheckmark: false,
    ),
    // 按钮统一（用户 2026-10-04：「按钮也很丑，统一优化」）：全族同高 40、
    // 全胶囊、左右 20 留白、14 号 semibold、18 号图标；描边按钮用更柔和的
    // outlineVariant。墨水屏保留原有的描边补偿。
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 40),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        textStyle: tt.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        iconSize: 18,
        elevation: 0,
        // E-ink：`FilledButton.tonal*` 的填充是 secondaryContainer == 页面底色，
        // 没有边就退化成一行裸文字、与旁边的 TextButton 无法区分；描边补回
        // 按钮体。实心 FilledButton 的填充本就是前景色，多一圈同色边无害。
        side: eink ? BorderSide(color: cs.outline) : null,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 40),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        textStyle: tt.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        iconSize: 18,
        foregroundColor: eink ? null : cs.onSurface,
        side: BorderSide(color: eink ? cs.outline : cs.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: const StadiumBorder(),
        minimumSize: const Size(48, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        textStyle: tt.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        iconSize: 18,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 40),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        textStyle: tt.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        iconSize: 18,
        elevation: 0,
        backgroundColor: eink ? null : cs.surfaceContainerHigh,
      ),
    ),
    // Apple 文本选区（用户 2026-10-04：黑白主题下选中文字被黑色选区盖住）：
    // 单色强调色不能直接当选区色；改用 macOS 默认的蓝灰选区，彩色强调色取淡色。
    textSelectionTheme: appleDesign
        ? TextSelectionThemeData(
            cursorColor: cs.primary,
            selectionColor: monochromeAccent
                ? (cs.brightness == Brightness.dark
                      ? const Color(0xFF3F638B)
                      : const Color(0xFFB4D5FE))
                : cs.primary.withValues(alpha: 0.28),
            selectionHandleColor: monochromeAccent
                ? const Color(0xFF0A84FF)
                : cs.primary,
          )
        : null,
    dividerTheme: DividerThemeData(
      color: cs.outlineVariant,
      // E-ink panels can't render a crisp half-pixel hairline; use a full
      // pixel so dividers stay solid black/white lines.
      // M3 / M3E 分隔线规格 1dp outlineVariant（此前 0.5 的发丝线在 1x 屏上
      // 被抗锯齿成半透明灰，与 M3E 色块分层的力度不匹配）。
      thickness: 1,
    ),
  );
}

/// 把已成型的 [base] 换成 [scheme] 重走一遍工厂：组件主题（菜单 / 对话框 / 弹层
/// / 提示条 / 滑条……的底色与前景）全按新 scheme 重算，字阶、设计系统、玻璃材质、
/// 墨水屏、平台沿用 [base]；[base] 上的其它主题扩展原样保留（新工厂产物同类型
/// 的扩展优先）。
///
/// 为什么不能 `base.copyWith(colorScheme: scheme)`：工厂把 scheme 颜色**烤进**了
/// 各组件主题（popupMenuTheme.color = surfaceContainer 等），只换 colorScheme
/// 时那些组件仍是旧色——歌词模式按封面取色后，⋯ 菜单仍是全局主题的深蓝表面。
ThemeData rethemeFushiWithScheme(ThemeData base, ColorScheme scheme) {
  final FushiGlassTheme? glass = base.extension<FushiGlassTheme>();
  final ThemeData rebuilt = buildFushiThemeData(
    scheme: scheme,
    textTheme: base.textTheme,
    eink: base.extension<FushiEinkTheme>()?.einkMode ?? false,
    designSystem: base.extension<FushiDesignSystemTheme>()?.designSystem ??
        FushiDesignSystem.auto,
    glass: glass?.material ?? FushiGlassMaterial.off,
    glassDesign: glass?.glassDesign ?? false,
  );
  return rebuilt.copyWith(
    platform: base.platform,
    // 不写显式类型实参：`<ThemeExtension<dynamic>>[]` 在 CFE 里会按 F-有界
    // 实参推成 ThemeExtension<ThemeExtension<dynamic>>，spread 编译不过。
    extensions: [...base.extensions.values, ...rebuilt.extensions.values],
  );
}

/// 数据库就绪前（启动加载 / 初始化报错 / 降级拦截 / 数据目录迁移）与弹窗冷启动
/// 占位用的主题：读不到用户偏好，取默认种子色与系统默认字体，但组件主题与字号
/// 阶梯与主 app 同源（字号 / 圆角 / 组件形状一致；用户字体要等偏好加载后才有）。
ThemeData buildFushiFallbackTheme(Brightness brightness) => buildFushiThemeData(
      scheme: buildFushiColorScheme(
        seedColor: kFushiDefaultSeed,
        brightness: brightness,
      ),
      textTheme: FushiTypeScale.buildTextTheme(const TextStyle()),
    );

/// 选择类控件（开关 / 复选 / 单选）的柔和状态层：M3 默认 8%–10% 的整圆状态层
/// 在成片的设置列表里一路扫过去很跳，悬停压到 5%，按下 / 焦点保留 10%（焦点
/// 环另由 FushiFocusTarget 画）。选中态用 primary、未选中用 onSurface，与 M3
/// 同角色。
WidgetStateProperty<Color?> _fushiSoftStateLayer(ColorScheme cs) {
  return WidgetStateProperty.resolveWith((Set<WidgetState> states) {
    final Color base =
        states.contains(WidgetState.selected) ? cs.primary : cs.onSurface;
    final double opacity = FushiStateLayer.opacityFor(states, soft: true);
    return opacity == 0 ? null : base.withValues(alpha: opacity);
  });
}
