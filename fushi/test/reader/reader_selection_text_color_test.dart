import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_theme_assistant.dart';
import 'package:fushi/src/models/theme_notifier.dart' show CustomThemeEntry;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 拍板台 -8azTfJh_v：自定义主题「查词高亮文字」角色——默认跟随正文，设了就让
/// 查词选区的所有绘制路径换成这个字色，做出「白底黑字 → 选中黑底白字」的反色高亮。
///
/// 三层锁定：
/// 1. 数据：条目 JSON 往返、copyWith 不丢；AI 建议能写这个角色。
/// 2. 解析链：自定义主题的覆盖经 [resolveReaderThemeColors] 透传；非自定义主题 /
///    墨水屏恒 null（跟随正文）。
/// 3. 正文 CSS：分页 / 滚动 / VN 三种 view mode 共用同一份 CSS，每种都要输出同一组
///    字色规则；没设时与历史输出逐字相同（`color: inherit`），墨水屏不输出。
Future<ReaderSettings> _settings(String viewMode) async {
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  await settings.setViewMode(viewMode);
  return settings;
}

const String _white = 'rgba(255, 255, 255, 1.0)';
const String _black = 'rgba(0, 0, 0, 1.0)';

void main() {
  group('CustomThemeEntry · selectionTextColor', () {
    test('JSON 往返与 copyWith 保留字段；未设时不写键', () {
      const CustomThemeEntry entry = CustomThemeEntry(
        id: 'ct-1',
        name: 'Ink',
        seed: 0xFF336699,
        selectionColor: 0xFF000000,
        selectionTextColor: 0xFFFFFFFF,
      );
      final Map<String, dynamic> json = entry.toJson();
      expect(json['selectionTextColor'], 0xFFFFFFFF);
      expect(CustomThemeEntry.fromJson(json).selectionTextColor, 0xFFFFFFFF);
      expect(entry.copyWith(name: 'Ink 2').selectionTextColor, 0xFFFFFFFF);

      const CustomThemeEntry plain = CustomThemeEntry(
        id: 'ct-2',
        name: '',
        seed: 0xFF336699,
      );
      expect(plain.toJson().containsKey('selectionTextColor'), isFalse);
      expect(
        CustomThemeEntry.fromJson(plain.toJson()).selectionTextColor,
        isNull,
      );
    });

    test('AI 建议能写查词高亮文字色，没给时保留原值', () {
      const CustomThemeEntry base = CustomThemeEntry(
        id: 'ct-1',
        name: '',
        seed: 0xFF336699,
        selectionTextColor: 0xFF123456,
      );
      expect(
        const AiThemeSuggestion(
          colors: <AiThemeRole, int>{AiThemeRole.selectionText: 0xFFFFFFFF},
        ).applyTo(base).selectionTextColor,
        0xFFFFFFFF,
      );
      expect(
        const AiThemeSuggestion(name: 'x').applyTo(base).selectionTextColor,
        0xFF123456,
      );
      expect(AiThemeRole.selectionText.allowsAlpha, isTrue);
    });
  });

  group('resolveReaderThemeColors · selectionText', () {
    final ColorScheme light = ColorScheme.fromSeed(
      seedColor: const Color(0xFF336699),
    );
    const ReaderThemeOverrides overrides = (
      bg: null,
      fg: null,
      selection: Color(0xFF000000),
      selectionText: Color(0xFFFFFFFF),
      link: null,
    );

    test('自定义主题：覆盖透传，查词底色同时生效', () {
      final ReaderThemeColors c = resolveReaderThemeColors(
        themeKey: 'custom-theme:ct-1',
        presetMap: kReaderPaperPresets,
        scheme: light,
        customOverrides: overrides,
        audioHighlightOverride: const Color(0x66FF0000),
      );
      expect(c.selection, const Color(0xFF000000));
      expect(c.selectionText, const Color(0xFFFFFFFF));
    });

    test('自定义主题没设 → null（跟随正文）', () {
      final ReaderThemeColors c = resolveReaderThemeColors(
        themeKey: 'custom-theme:ct-1',
        presetMap: kReaderPaperPresets,
        scheme: light,
        customOverrides: (
          bg: null,
          fg: null,
          selection: null,
          selectionText: null,
          link: null,
        ),
      );
      expect(c.selectionText, isNull);
    });

    test('非自定义主题 / 手调纸色预设恒 null，墨水屏也不换字色', () {
      for (final String key in <String>['system-theme', 'ecru-theme']) {
        final ReaderThemeColors c = resolveReaderThemeColors(
          themeKey: key,
          presetMap: kReaderPaperPresets,
          scheme: light,
          customOverrides: overrides,
        );
        expect(c.selectionText, isNull, reason: key);
      }
      final ReaderThemeColors themed = resolveReaderThemeColors(
        themeKey: 'custom-theme:ct-1',
        presetMap: kReaderPaperPresets,
        scheme: light,
        customOverrides: overrides,
      );
      expect(einkReaderThemeColors(themed, dark: false).selectionText, isNull);
    });
  });

  group('ReaderContentStyles.css · 查词高亮文字色（三种 view mode）', () {
    for (final String viewMode in <String>['paginated', 'continuous', 'vn']) {
      test('$viewMode：设了字色 → 查词各绘制路径都换色，振假名留原色', () async {
        final ReaderSettings settings = await _settings(viewMode);
        final String css = ReaderContentStyles.css(
          settings: settings,
          customBg: '#ffffff',
          customFg: _black,
          selectionColor: _black,
          selectionTextColor: _white,
        );
        expect(
          css,
          contains(
            '::highlight(fushi-selection) {\n'
            '  background-color: transparent;\n'
            '  color: $_white;\n'
            '}',
          ),
        );
        expect(
          css,
          contains(
            'ruby.fushi-selection-ruby-active {\n'
            '  background-color: transparent !important;\n'
            '  color: $_white !important;\n'
            '}',
          ),
        );
        expect(
          css,
          contains(
            'ruby.fushi-selection-ruby-active > rt, '
            'ruby.fushi-selection-ruby-active > rtc '
            '{ color: $_black !important; }',
          ),
        );
        expect(
          css,
          contains(
            '.fushi-dict-highlight {\n'
            '  background-color: transparent !important;\n'
            '  color: $_white !important;\n'
            '}',
          ),
        );
        // 查词与当前句重叠的 ruby：查词优先，字色也是查词的。
        expect(
          css,
          contains(
            'ruby.fushi-selection-ruby-active.fushi-sentence-audio-ruby-active {\n'
            '  color: $_white !important;\n'
            '}',
          ),
        );
        // 桌面鼠标原生选区与查词高亮同一观感：查词底色（预合成到纸底）+ 同字色。
        expect(
          css,
          contains(
            '::selection { background-color: $_black; '
            'color: $_white; }',
          ),
        );
      });

      test('$viewMode：没设字色 → 与历史输出一致（inherit），不写 rt / ::selection 规则', () async {
        final ReaderSettings settings = await _settings(viewMode);
        final String css = ReaderContentStyles.css(
          settings: settings,
          customBg: '#ffffff',
          customFg: _black,
          selectionColor: _black,
        );
        expect(
          css,
          contains(
            '::highlight(fushi-selection) {\n'
            '  background-color: transparent;\n'
            '  color: inherit;\n'
            '}',
          ),
        );
        expect(
          css,
          contains(
            'ruby.fushi-selection-ruby-active {\n'
            '  background-color: transparent !important;\n'
            '  color: inherit;\n'
            '}',
          ),
        );
        expect(
          css,
          contains(
            'ruby.fushi-selection-ruby-active.fushi-sentence-audio-ruby-active {\n'
            '  color: inherit !important;\n'
            '}',
          ),
        );
        expect(css, isNot(contains('ruby.fushi-selection-ruby-active > rt')));
        expect(css, isNot(contains('::selection {')));
      });

      test('$viewMode：墨水屏忽略查词高亮文字色', () async {
        final ReaderSettings settings = await _settings(viewMode);
        final String css = ReaderContentStyles.css(
          settings: settings,
          selectionTextColor: _white,
          einkMode: true,
        );
        expect(css, isNot(contains(_white)));
        expect(css, isNot(contains('::selection {')));
      });
    }
  });
}
