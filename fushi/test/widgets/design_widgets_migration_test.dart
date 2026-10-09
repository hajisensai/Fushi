// ignore_for_file: deprecated_member_use
// HBK-AUDIT-053: real picker inputs follow modern app and route themes.
// Legacy imports remain for Markdown / glass compatibility controls.
import 'package:cupertino_ui/cupertino_ui.dart' as cupertino;
import 'package:flutter/cupertino.dart' as legacy_cupertino;
import 'package:flutter/material.dart' as legacy;
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/video_settings_actions.dart';
import 'package:fushi/src/media/video/video_side_panel.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/changelog_page.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_theme.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/video_quick_settings_harness.dart';

ThemeData _theme({bool dark = false, bool eink = false, bool glass = false}) {
  return buildFushiThemeData(
    scheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF006C52),
      brightness: dark ? Brightness.dark : Brightness.light,
    ),
    textTheme: dark
        ? Typography.material2021().white
        : Typography.material2021().black,
    eink: eink,
    glassDesign: glass,
    glass: FushiGlassMaterial.off,
  ).copyWith(platform: TargetPlatform.android);
}

Widget _app(
  Widget home, {
  ThemeData? theme,
  Locale locale = const Locale('en'),
}) {
  return TranslationProvider(
    child: MaterialApp(
      theme: theme ?? _theme(),
      themeAnimationDuration: Duration.zero,
      locale: locale,
      supportedLocales: const <Locale>[Locale('en'), Locale('zh')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // Same ordering as main.dart: modern CupertinoTheme, compatibility, glass,
      // then Navigator. This also covers routes pushed by showAppDialog.
      builder: (BuildContext context, Widget? child) =>
          cupertino.CupertinoTheme(
            data: fushiCupertinoTheme(Theme.of(context).colorScheme),
            child: LegacyDesignCompatibility(
              child: FushiGlassScope(child: child!),
            ),
          ),
      home: home,
    ),
  );
}

Widget _picker({ValueChanged<Color>? onChanged}) {
  return ColorPicker(
    pickerColor: const Color(0xFF112233),
    onColorChanged: onChanged ?? (Color _) {},
    colorPickerWidth: 240,
    portraitOnly: true,
    enableAlpha: false,
    hexInputBar: true,
    labelTypes: const <ColorLabelType>[],
  );
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool dark in <bool>[false, true]) {
    testWidgets(
      'real ColorPicker input works with the app theme (dark=$dark)',
      (WidgetTester tester) async {
        Color? changed;
        final ThemeData theme = _theme(dark: dark);
        await tester.pumpWidget(
          _app(
            Scaffold(
              body: Center(child: _picker(onChanged: (Color c) => changed = c)),
            ),
            theme: theme,
            locale: const Locale('zh'),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final BuildContext fieldContext = tester.element(
          find.byType(EditableText),
        );
        expect(Theme.of(fieldContext).brightness, theme.brightness);
        expect(
          Theme.of(fieldContext).colorScheme.primary,
          theme.colorScheme.primary,
        );
        expect(
          legacy.MaterialLocalizations.of(fieldContext).copyButtonLabel,
          '复制',
        );
        expect(MaterialLocalizations.of(fieldContext).copyButtonLabel, '复制');
        expect(
          legacy_cupertino.CupertinoTheme.of(fieldContext).primaryColor,
          cupertino.CupertinoTheme.of(fieldContext).primaryColor,
        );
        await tester.enterText(find.byType(EditableText), '#AABBCC');
        await tester.pump();
        expect(changed, const Color(0xFFAABBCC));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('root theme update preserves hex editor state and value', (
    WidgetTester tester,
  ) async {
    final Widget home = Scaffold(body: Center(child: _picker()));
    await tester.pumpWidget(_app(home));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '#AABBCC');
    await tester.pump();
    final EditableTextState before = tester.state(find.byType(EditableText));
    await tester.pumpWidget(_app(home, theme: _theme(dark: true)));
    await tester.pumpAndSettle();
    final EditableTextState after = tester.state(find.byType(EditableText));
    expect(identical(before, after), isTrue);
    expect(after.widget.controller.text, '#AABBCC');
    expect(Theme.of(after.context).brightness, Brightness.dark);
    expect(tester.takeException(), isNull);
  });

  for (final bool eink in <bool>[false, true]) {
    testWidgets('hex editor retains Fushi input decoration (eink=$eink)', (
      WidgetTester tester,
    ) async {
      final ThemeData theme = _theme(eink: eink);
      await tester.pumpWidget(
        _app(
          Scaffold(body: Center(child: _picker())),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final InputDecorator decorator = tester.widget(
        find.byType(InputDecorator),
      );
      final InputDecoration actual = decorator.decoration;
      debugPrint(
        'migrated hex: eink=$eink, filled=${actual.filled}, '
        'border=${actual.border.runtimeType}, enabled=${actual.enabledBorder.runtimeType}; '
        'modern filled=${theme.inputDecorationTheme.filled}, '
        'border=${theme.inputDecorationTheme.border.runtimeType}',
      );
      expect(
        actual.border,
        isA<OutlineInputBorder>(),
        reason: 'ColorPicker must retain the app input shape after migration',
      );
      expect(actual.border, theme.inputDecorationTheme.border);
      expect(actual.enabledBorder, theme.inputDecorationTheme.enabledBorder);
      expect(actual.focusedBorder, theme.inputDecorationTheme.focusedBorder);
      if (!eink) {
        expect(actual.filled, isTrue);
        expect(actual.fillColor, theme.inputDecorationTheme.fillColor);
      }
    });

    testWidgets(
      'direct ColorPickerInput retains styling and edits (eink=$eink)',
      (WidgetTester tester) async {
        Color? changed;
        final ThemeData theme = _theme(eink: eink);
        await tester.pumpWidget(
          _app(
            Scaffold(
              body: Center(
                child: ColorPickerInput(
                  const Color(0xFF112233),
                  (Color color) => changed = color,
                  enableAlpha: false,
                  embeddedText: true,
                ),
              ),
            ),
            theme: theme,
          ),
        );
        await tester.pumpAndSettle();
        final InputDecorator decorator = tester.widget(
          find.byType(InputDecorator),
        );
        expect(decorator.decoration.border, theme.inputDecorationTheme.border);
        expect(
          decorator.decoration.enabledBorder,
          theme.inputDecorationTheme.enabledBorder,
        );
        expect(decorator.decoration.filled, !eink);
        await tester.enterText(find.byType(EditableText), '#AABBCC');
        await tester.pump();
        expect(changed, const Color(0xFFAABBCC));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('real changelog Markdown selectable text has bridged ancestors', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const ChangelogPage(
          initialReleases: <Map<String, dynamic>>[
            <String, dynamic>{
              'tag_name': 'v2.9.1',
              'published_at': '2026-10-06T08:00:00Z',
              'prerelease': false,
              'body': 'Migration **selection** smoke test.',
            },
          ],
        ),
        theme: _theme(dark: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final Finder selectable = find.byType(legacy.SelectableText).first;
    expect(selectable, findsOneWidget);
    await tester.longPress(selectable);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final BuildContext context = tester.element(selectable);
    expect(legacy.Theme.of(context).brightness, Brightness.dark);
    expect(legacy.MaterialLocalizations.of(context).copyButtonLabel, 'Copy');
  });

  testWidgets(
    'real glass SettingsFormField edits through legacy Cupertino input',
    (WidgetTester tester) async {
      String? changed;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                child: SettingsFormField(
                  label: 'Server',
                  initialValue: 'before',
                  onChanged: (String text) => changed = text,
                ),
              ),
            ),
          ),
          theme: _theme(dark: true, glass: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(legacy_cupertino.CupertinoTextField), findsOneWidget);
      await tester.enterText(find.byType(EditableText), 'after');
      await tester.pump();
      expect(changed, 'after');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('video panel color dialog editor follows captured dark theme', (
    WidgetTester tester,
  ) async {
    final VideoSheetHarness harness = await VideoSheetHarness.create();
    addTearDown(harness.dispose);
    final TestVideoHostState hostState = TestVideoHostState();
    await tester.pumpWidget(
      ProviderScope(
        child: _app(
          Scaffold(
            body: VideoFloatingPanelSurface(
              child: Consumer(
                builder: (BuildContext context, WidgetRef ref, Widget? child) {
                  return buildVideoSubtitleTextColorRow(
                    SettingsContext(
                      context: context,
                      appModel: harness.appModel,
                      ref: ref,
                      readerSource: ReaderFushiSource.instance,
                      refresh: () {},
                      video: buildTestVideoHost(state: hostState),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.video_setting_subtitle_text_color));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final BuildContext fieldContext = tester.element(find.byType(EditableText));
    final ThemeData modern = Theme.of(fieldContext);
    final EditableText editable = tester.widget(find.byType(EditableText));
    final Color? foreground = editable.style.color;
    final Color? materialBackground = fieldContext
        .findAncestorWidgetOfExactType<Material>()
        ?.color;
    final InputDecorator decorator = tester.widget(find.byType(InputDecorator));
    final Color? fill = decorator.decoration.filled == true
        ? decorator.decoration.fillColor
        : null;
    final Color? background = fill != null && materialBackground != null
        ? Color.alphaBlend(fill, materialBackground)
        : materialBackground;
    double? contrast;
    if (foreground != null && background != null) {
      final Color blended = Color.alphaBlend(foreground, background);
      final double a = blended.computeLuminance();
      final double b = background.computeLuminance();
      contrast = a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
    }
    debugPrint(
      'migrated video picker: modern=${modern.brightness}, '
      'modernSurface=${modern.colorScheme.surface.toARGB32()}, '
      'editableText=${foreground?.toARGB32()}, paintedMaterial=${background?.toARGB32()}, '
      'contrast=$contrast',
    );
    // Production panel deliberately has a neutral dark scheme even with a light
    // application. The actual editor must use that captured theme and remain legible.
    expect(modern.brightness, Brightness.dark);
    expect(foreground, modern.colorScheme.onSurface);
    expect(contrast, isNotNull);
    expect(contrast!, greaterThanOrEqualTo(4.5));
    // The actual production dialog callback owns persistence; editing exercises
    // the same real field and must not throw after the route theme is captured.
    await tester.enterText(find.byType(EditableText), '#AABBCC');
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '#AABBCC',
    );
    expect(tester.takeException(), isNull);
  });
}
