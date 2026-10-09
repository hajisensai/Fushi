import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';

bool _pinsSurfaceThroughSharedScheme(
  String page,
  String notifier,
  String appModel,
) {
  String code(String source, String signature) => maskCommentsAndStrings(
    methodBody(source, signature),
  ).replaceAll(RegExp(r'\s+'), '');

  final String entry = code(page, 'CustomThemeEntry _buildEntry(');
  final String preview = code(page, 'ColorScheme _buildSchemeFor(');
  // 190147fb54f：编辑页经 AppModel 门面取配色（不穿透 themeNotifier），门面与
  // ThemeNotifier 同名方法都委托到同一个顶层纯函数——派生链仍只有一份。
  final String facade = code(appModel, 'ColorScheme buildCustomThemeColorScheme(');
  final String delegate = code(
    notifier,
    'ColorScheme buildCustomThemeColorScheme(',
  );
  final String runtime = code(
    notifier,
    'ColorScheme buildCustomThemeEntryColorScheme(',
  );
  return entry.contains('returnCustomThemeEntry(') &&
      entry.contains('surfaceColor:argb(_overrides[_ThemeRole.surface]),') &&
      preview.contains(
        'returnappModelNoUpdate.buildCustomThemeColorScheme('
        '_buildEntry(),brightness,);',
      ) &&
      facade.contains('theme_notifier.buildCustomThemeEntryColorScheme(') &&
      delegate.contains('buildCustomThemeEntryColorScheme(') &&
      runtime.contains('returnbuildFushiColorScheme(') &&
      runtime.contains('surface:role(entry.surfaceColor),');
}

/// 自定义主题编辑页重设计（2026-09）的结构守卫。
///
/// 用户原始抱怨：PC 上滚动灾难（包内 ColorPicker 按窗口宽撑满、每个启用的颜色都
/// 内联一块）、选项全是 Material 术语看不懂改了什么、选的颜色和看到的不一致
/// （BUG-2187 + 种子色派生）。守卫锁住：
/// - 页面不再内联包内整块 `ColorPicker(`，选色器是固定尺寸的组合件；
/// - 宽屏走左列表 / 右预览+选色器的两栏；
/// - 角色按用途命名（theme_role_*），四个板块按「主题色 / 阅读器 / 有声书 /
///   微调派生色」组织；
/// - 预览走真机同一条阅读器解析链（resolveReaderThemeColors）；
/// - 主题色默认就是所选色（钉死为 primary）；「自动调色调」「跟随系统取色」是显式开关；
///   「界面背景」可钉死 surface（纯白等）。
void main() {
  final String source = File(
    'lib/src/pages/implementations/custom_theme_page.dart',
  ).readAsStringSync();
  final String notifier = File(
    'lib/src/models/theme_notifier.dart',
  ).readAsStringSync();
  final String appModel = File(
    'lib/src/models/app_model.dart',
  ).readAsStringSync();

  group('CustomThemePage · 选色器不在滚动主路径上', () {
    test('不再内联包内整块 ColorPicker', () {
      expect(
        RegExp(r'\bColorPicker\(').hasMatch(source),
        isFalse,
        reason: '包内 ColorPicker 会按可用宽度撑满，桌面上是近千像素高的色板',
      );
      expect(source.contains('pickerAreaHeightPercent'), isFalse);
      expect(source.contains('_holdScroll'), isFalse);
    });

    test('选色器由固定尺寸的 palette 构件组合', () {
      expect(source.contains('ColorPickerArea('), isTrue);
      expect(source.contains('ColorPickerSlider('), isTrue);
      expect(source.contains('ColorPickerInput('), isTrue);
      expect(source.contains('class _ThemeColorPicker'), isTrue);
    });

    test('宽屏两栏：预览 sticky 在左、编辑在右；取色器按需弹出不常驻', () {
      expect(source.contains('kCustomThemeWideLayoutMinWidth'), isTrue);
      expect(source.contains('_buildSidePickerCard'), isFalse);
      expect(source.contains('_showRolePickerDialog('), isTrue);
      expect(source.contains('adaptiveModalSheet<void>('), isTrue);
      expect(source.contains('SettingsKitScaffold('), isTrue);
    });
  });

  group('CustomThemePage · 按用途命名的角色与板块', () {
    test('分组按 主题色（种子）/ 界面配色 / 阅读器 排列，主题色只有一处', () {
      final int seed = source.indexOf('title: t.theme_role_accent');
      final int ui = source.indexOf('title: t.theme_section_accent');
      final int reader = source.indexOf('title: t.theme_section_reader');
      expect(seed, greaterThanOrEqualTo(0));
      expect(ui, greaterThan(seed));
      expect(reader, greaterThan(ui));
      // 2026-10 M3E：不再常驻侧栏选色器，也不再在「界面配色」里重复一排主题色板。
      expect(source.contains('_buildAccentPresetRow'), isFalse);
      expect(source.contains('_buildTonalPalette()'), isTrue);
    });

    test('十个角色全部用 theme_role_* 文案，不再出现 Material 术语 key', () {
      for (final String key in <String>[
        'theme_role_accent',
        'theme_role_surface',
        'theme_role_reader_text',
        'theme_role_reader_background',
        'theme_role_link',
        'theme_role_selection',
        'theme_role_audio_highlight',
        'theme_role_secondary',
        'theme_role_tertiary',
        'theme_role_container',
      ]) {
        expect(source.contains('t.$key'), isTrue, reason: '缺 $key');
      }
      for (final String old in <String>[
        't.seed_color',
        't.color_primary',
        't.color_tertiary',
        't.color_container',
        't.theme_seed_preview_hint',
      ]) {
        expect(source.contains(old), isFalse, reason: '$old 应已删除');
      }
    });

    test('视频字幕颜色说明行保留', () {
      expect(source.contains('t.video_subtitle_color_note'), isTrue);
      expect(source.contains('_buildNoteRow('), isTrue);
    });

    test('自定义主题跟随全局明暗：没有自己的深色开关，预览可临时切明暗', () {
      expect(source.contains('t.dark_mode'), isFalse);
      expect(source.contains('_setBrightnessMode'), isFalse);
      expect(source.contains('brightnessMode: _brightnessMode'), isFalse);
      expect(source.contains('_previewBrightness'), isTrue);
    });
  });

  group('CustomThemePage · 所见即所得', () {
    test('预览走真机同一条阅读器解析链', () {
      expect(source.contains('resolveReaderThemeColors('), isTrue);
      expect(source.contains('customOverrides:'), isTrue);
    });

    test('主题色默认钉死为所选色；自动调色调 / 跟随系统取色是显式开关', () {
      expect(
        source.contains('primaryColor: _accentAutoTone ? null : _accent'),
        isTrue,
      );
      expect(source.contains('bool _accentAutoTone = false'), isTrue);
      expect(source.contains('t.theme_accent_auto_tone'), isTrue);
      expect(source.contains('t.theme_role_actual_color'), isTrue);
      expect(source.contains('t.theme_accent_follow_system'), isTrue);
      expect(
        source.contains('followSystemAccent: _followSystemAccent'),
        isTrue,
      );
      expect(source.contains('t.theme_neutral_derived'), isTrue);
      expect(source.contains('neutralDerived: _neutralDerived'), isTrue);
    });

    test('界面背景角色钉死 surface，与真机同一派生链', () {
      expect(source.contains('_ThemeRole.surface'), isTrue);
      expect(
        // 45fc6d88b17 将预览接到运行期共享入口：覆盖色先写草稿 entry，
        // 再由 ThemeNotifier 派生。必须守住三段，不能只找全文件里的 surface。
        _pinsSurfaceThroughSharedScheme(source, notifier, appModel),
        isTrue,
      );
      expect(source.contains('t.theme_role_surface'), isTrue);
    });

    test('surface 接线守卫拒绝丢失覆盖色、错误草稿及只剩注释的派生参数', () {
      expect(
        _pinsSurfaceThroughSharedScheme(
          source.replaceFirst(
            'surfaceColor: argb(_overrides[_ThemeRole.surface]),',
            'surfaceColor: null,',
          ),
          notifier,
          appModel,
        ),
        isFalse,
      );
      expect(
        _pinsSurfaceThroughSharedScheme(
          source.replaceFirst('_buildEntry(),', '_otherEntry(),'),
          notifier,
          appModel,
        ),
        isFalse,
      );
      expect(
        _pinsSurfaceThroughSharedScheme(
          source,
          notifier.replaceFirst(
            'surface: role(entry.surfaceColor),',
            'surface: null, /* surface: role(entry.surfaceColor), */',
          ),
          appModel,
        ),
        isFalse,
      );
    });

    test('预览按角色框出影响位置', () {
      expect(source.contains('Widget _spot(_ThemeRole role'), isTrue);
      expect(source.contains('t.theme_preview_hint'), isTrue);
    });

    test('墨水屏模式下预览同样黑白', () {
      expect(
        methodBody(source, 'ColorScheme _buildSchemeFor('),
        contains('appModelNoUpdate.buildCustomThemeColorScheme('),
      );
      expect(
        methodBody(appModel, 'ColorScheme buildCustomThemeColorScheme('),
        contains('einkMode: einkMode'),
      );
      final String scheme = methodBody(
        notifier,
        'ColorScheme buildCustomThemeEntryColorScheme(',
      );
      expect(scheme, contains('einkMode'));
      expect(scheme, contains('buildEinkColorScheme('));
    });
  });
}
