import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:spaces/spaces.dart';

class _ThemeOnlyAppModel extends AppModel {
  _ThemeOnlyAppModel(this._themeKey);

  String _themeKey;

  @override
  String get appThemeKey => _themeKey;

  @override
  Future<void> setAppThemeKey(String key) async {
    _themeKey = key;
    notifyListeners();
  }
}

void main() {
  testWidgets('custom theme chip uses the same selected treatment as presets',
      (tester) async {
    final model = _ThemeOnlyAppModel('custom-theme');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appProvider.overrideWith((ref) => model),
        ],
        child: MaterialApp(
          builder: (context, child) => Spacing(
            dataBuilder: (context) => SpacingData.generate(10),
            child: child!,
          ),
          home: const Scaffold(
            body: TtuSettingsDialogContent(),
          ),
        ),
      ),
    );

    final customThemeText = find.text(t.custom_theme);
    expect(customThemeText, findsOneWidget);

    final customThemeChip = find.ancestor(
      of: customThemeText,
      matching: find.byType(ChoiceChip),
    );

    expect(customThemeChip, findsOneWidget);
    expect(tester.widget<ChoiceChip>(customThemeChip).selected, isTrue);
  });
}
