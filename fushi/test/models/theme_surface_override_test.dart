import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// 自定义主题「界面背景」钉死 + 钉死主色带动 inversePrimary / surfaceTint。
///
/// - `buildFushiColorScheme(surface: 纯白)` → 页面纯白、容器逐级变深、文字深色、
///   surfaceTint 透明（不被主题色染回）；纯黑反向。
/// - `deriveSurfaceRolesFrom` 是编辑页预览 / ColorScheme / 词典弹窗共用的单一梯度。
/// - 钉死 primary 后 inversePrimary（视频播放器浅色主题控件色）与 surfaceTint
///   跟主色走，不再从 seed 派生。
/// - memo key 含 surface：同 seed 不同 surface 不能命中同一缓存。
void main() {
  const Color seed = Color(0xFF1F4959);

  double lum(Color c) => c.computeLuminance();

  group('deriveSurfaceRolesFrom', () {
    test('纯白：页面 == 白，容器逐级变深，文字深色', () {
      final SurfaceRoles r = deriveSurfaceRolesFrom(Colors.white);
      expect(r.surface, Colors.white);
      expect(r.surfaceContainerLowest, Colors.white);
      expect(lum(r.surfaceContainerLow), lessThan(lum(r.surface)));
      expect(lum(r.surfaceContainer), lessThan(lum(r.surfaceContainerLow)));
      expect(lum(r.surfaceContainerHigh), lessThan(lum(r.surfaceContainer)));
      expect(
        lum(r.surfaceContainerHighest),
        lessThan(lum(r.surfaceContainerHigh)),
      );
      // 卡片只是极浅灰（层次仍在但不抢戏）。
      expect(lum(r.surfaceContainer), greaterThan(0.85));
      expect(r.onSurface, const Color(0xDE000000));
      expect(lum(r.outline), lessThan(lum(r.outlineVariant)));
    });

    test('纯黑：反向（容器逐级变亮，文字浅色）', () {
      final SurfaceRoles r = deriveSurfaceRolesFrom(Colors.black);
      expect(r.surface, Colors.black);
      expect(lum(r.surfaceContainerLow), greaterThan(lum(r.surface)));
      expect(
        lum(r.surfaceContainerHighest),
        greaterThan(lum(r.surfaceContainer)),
      );
      expect(r.onSurface, const Color(0xDEFFFFFF));
      expect(lum(r.inverseSurface), greaterThan(0.5));
      expect(r.onInverseSurface, Colors.black);
    });
  });

  group('buildFushiColorScheme · surface 钉死', () {
    test('亮色方案 + 纯白底：整套中性角色来自 deriveSurfaceRolesFrom', () {
      final ColorScheme cs = buildFushiColorScheme(
        seedColor: seed,
        brightness: Brightness.light,
        surface: Colors.white,
      );
      final SurfaceRoles r = deriveSurfaceRolesFrom(Colors.white);
      expect(cs.surface, Colors.white);
      expect(cs.surfaceContainerLow, r.surfaceContainerLow);
      expect(cs.surfaceContainer, r.surfaceContainer);
      expect(cs.surfaceContainerHighest, r.surfaceContainerHighest);
      expect(cs.onSurface, r.onSurface);
      expect(cs.outlineVariant, r.outlineVariant);
      expect(cs.surfaceTint, Colors.transparent);
      // 主题色相关角色不受影响。
      expect(
        cs.primary,
        buildFushiColorScheme(
          seedColor: seed,
          brightness: Brightness.light,
        ).primary,
      );
    });

    test('不给 surface：与旧输出完全一致（零变化）', () {
      final ColorScheme a = buildFushiColorScheme(
        seedColor: seed,
        brightness: Brightness.light,
      );
      final ColorScheme b = ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.light,
      );
      expect(a.surface, b.surface);
      expect(a.surfaceContainer, b.surfaceContainer);
      expect(a.surfaceTint, b.surfaceTint);
      expect(a.inversePrimary, b.inversePrimary);
    });

    test('memo key 区分 surface', () {
      final ColorScheme a = buildFushiColorScheme(
        seedColor: seed,
        brightness: Brightness.light,
      );
      final ColorScheme b = buildFushiColorScheme(
        seedColor: seed,
        brightness: Brightness.light,
        surface: Colors.white,
      );
      expect(identical(a, b), isFalse);
      expect(a.surface, isNot(b.surface));
    });
  });

  group('buildFushiColorScheme · 钉死 primary 带动派生角色', () {
    test('surfaceTint == primary；inversePrimary 同色相换色调', () {
      const Color pinned = Color(0xFFB3261E);
      final ColorScheme light = buildFushiColorScheme(
        seedColor: seed,
        brightness: Brightness.light,
        primary: pinned,
      );
      expect(light.surfaceTint, pinned);
      expect(light.inversePrimary, isNot(pinned));
      // 亮色方案的 inversePrimary 是暗色方案用的浅色调：比 pinned 亮得多。
      expect(lum(light.inversePrimary), greaterThan(lum(pinned)));
      final ColorScheme dark = buildFushiColorScheme(
        seedColor: seed,
        brightness: Brightness.dark,
        primary: pinned,
      );
      expect(lum(dark.inversePrimary), lessThan(lum(light.inversePrimary)));
      // 不再是 seed 派生的青色 inversePrimary。
      expect(
        light.inversePrimary,
        isNot(
          ColorScheme.fromSeed(
            seedColor: seed,
            brightness: Brightness.light,
          ).inversePrimary,
        ),
      );
    });
  });

  group('buildFushiColorScheme · 中性派生', () {
    // sRGB 灰阶经 HCT 量化后 chroma 并不严格为 0（≈2.5～2.8），门槛与
    // isAchromaticSeed 同为 4；带主题色相的派生色 chroma ≥ 16。
    Hct hct(Color c) => Hct.fromInt(c.toARGB32());

    test('无彩度 seed（纯白）：表面 / 选中项 / 标签不再带蓝色相', () {
      expect(isAchromaticSeed(Colors.white), isTrue);
      expect(isAchromaticSeed(const Color(0xFF808080)), isTrue);
      expect(isAchromaticSeed(seed), isFalse);
      final ColorScheme cs = buildFushiColorScheme(
        seedColor: Colors.white,
        brightness: Brightness.light,
        primary: Colors.white,
      );
      // 以前：白 seed 在 HCT 里色相 ≈ 209°，tonalSpot 强制 chroma 6/16 → 淡蓝灰。
      expect(hct(cs.surface).chroma, lessThan(4));
      expect(hct(cs.surfaceContainer).chroma, lessThan(4));
      expect(hct(cs.secondaryContainer).chroma, lessThan(4));
      expect(hct(cs.outlineVariant).chroma, lessThan(4));
      expect(cs.primary, Colors.white);
      expect(cs.surfaceTint, Colors.transparent);
    });

    test('neutralDerived：彩色主题色保留，其余派生色灰阶', () {
      const Color blue = Color(0xFF0B57D0);
      final ColorScheme cs = buildFushiColorScheme(
        seedColor: blue,
        brightness: Brightness.light,
        primary: blue,
        neutralDerived: true,
      );
      expect(cs.primary, blue);
      // 控件底色从钉死的主色推（浅蓝），不是灰。
      expect(hct(cs.primaryContainer).chroma, greaterThan(5));
      expect(hct(cs.secondaryContainer).chroma, lessThan(4));
      expect(hct(cs.tertiary).chroma, lessThan(4));
      expect(hct(cs.surface).chroma, lessThan(4));
      expect(hct(cs.onSurfaceVariant).chroma, lessThan(4));
      expect(cs.surfaceTint, Colors.transparent);
      // 与不开中性派生的结果不同、且 memo key 区分。
      final ColorScheme tinted = buildFushiColorScheme(
        seedColor: blue,
        brightness: Brightness.light,
        primary: blue,
      );
      expect(identical(cs, tinted), isFalse);
      expect(hct(tinted.secondaryContainer).chroma, greaterThan(5));
    });

    test('neutralDerived + 自动调色调：主色仍来自 seed 的色调板，不被压成灰', () {
      const Color blue = Color(0xFF0B57D0);
      final ColorScheme cs = buildFushiColorScheme(
        seedColor: blue,
        brightness: Brightness.dark,
        neutralDerived: true,
      );
      final ColorScheme tonal = ColorScheme.fromSeed(
        seedColor: blue,
        brightness: Brightness.dark,
      );
      expect(cs.primary, tonal.primary);
      expect(cs.primaryContainer, tonal.primaryContainer);
      expect(hct(cs.secondary).chroma, lessThan(4));
    });
  });

  group('CustomThemeEntry · 新字段序列化', () {
    test('surfaceColor / followSystemAccent 往返 JSON', () {
      const CustomThemeEntry e = CustomThemeEntry(
        id: 'x',
        name: 'X',
        seed: 0xFF112233,
        surfaceColor: 0xFFFFFFFF,
        followSystemAccent: true,
        neutralDerived: true,
      );
      final CustomThemeEntry back = CustomThemeEntry.fromJson(e.toJson());
      expect(back.surfaceColor, 0xFFFFFFFF);
      expect(back.followSystemAccent, isTrue);
      expect(back.neutralDerived, isTrue);
      expect(back.copyWith(name: 'Y').neutralDerived, isTrue);
      expect(back.copyWith(name: 'Y').surfaceColor, 0xFFFFFFFF);
      expect(back.copyWith(name: 'Y').followSystemAccent, isTrue);
    });

    test('旧 JSON 没这两个键 → null / false', () {
      final CustomThemeEntry old = CustomThemeEntry.fromJson(<String, dynamic>{
        'id': 'o',
        'name': '',
        'seed': 0xFF112233,
      });
      expect(old.surfaceColor, isNull);
      expect(old.followSystemAccent, isFalse);
      expect(old.neutralDerived, isFalse);
      expect(old.toJson().containsKey('followSystemAccent'), isFalse);
      expect(old.toJson().containsKey('neutralDerived'), isFalse);
    });
  });
}
