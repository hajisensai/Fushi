import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/dictionary_settings_dialog_page.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

class _FakeCssAppModel extends AppModel {
  _FakeCssAppModel()
      : _dictionaries = [
          Dictionary(name: 'JMdict', formatKey: 'yomichan', order: 0),
          Dictionary(
            name: 'Very long dictionary name that must not overflow dialogs',
            formatKey: 'yomichan',
            order: 1,
          ),
        ];

  final List<Dictionary> _dictionaries;
  final Map<String, String> savedCustomCss = <String, String>{};
  String savedGlobalCss = '.glossary-content { font-size: 18px; }';

  @override
  List<Dictionary> get dictionaries => _dictionaries;

  @override
  String get globalDictCSS => savedGlobalCss;

  @override
  Map<String, String> get customDictCSS => savedCustomCss;

  @override
  String getCustomCSSForDict(String dictName) => savedCustomCss[dictName] ?? '';

  @override
  Future<void> setCustomCSSForDict(String dictName, String css) async {
    savedCustomCss[dictName] = css;
  }

  @override
  Future<void> setGlobalDictCSS(String css) async {
    savedGlobalCss = css;
  }
}

Widget _buildApp({
  required AppModel appModel,
  required Widget home,
}) {
  return ProviderScope(
    overrides: [
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF386A58),
          ),
        ),
        home: home,
      ),
    ),
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  test('dictionary manager delegates custom CSS editing to settings dialog',
      () {
    final source = File(
      'lib/src/pages/implementations/dictionary_dialog_page.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('_showCustomCSSDialog')));
    expect(source, contains('DictCssEditorDialog('));
    expect(source, contains('initialDictionaryName: dictionary.name'));
    expect(source, isNot(contains('custom_css_title')));
  });

  testWidgets('dictionary CSS editor fits a compact mobile dialog', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _buildApp(
        appModel: _FakeCssAppModel(),
        home: const DictCssEditorDialog(),
      ),
    );

    expect(tester.takeException(), isNull);

    final Rect dialogRect = tester.getRect(find.byType(AlertDialog));
    expect(dialogRect.left, greaterThanOrEqualTo(0));
    expect(dialogRect.right, lessThanOrEqualTo(393));

    final Finder cssEditorField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.expands,
    );
    final Rect menuRect = tester.getRect(find.byType(DropdownMenu<int>));
    final Rect textFieldRect = tester.getRect(cssEditorField);
    expect(menuRect.left, greaterThanOrEqualTo(dialogRect.left));
    expect(menuRect.right, lessThanOrEqualTo(dialogRect.right));
    expect(textFieldRect.left, greaterThanOrEqualTo(dialogRect.left));
    expect(textFieldRect.right, lessThanOrEqualTo(dialogRect.right));
  });

  testWidgets('dictionary CSS editor can start on a specific dictionary', (
    WidgetTester tester,
  ) async {
    final _FakeCssAppModel appModel = _FakeCssAppModel();
    appModel.savedCustomCss['JMdict'] = '.entry { color: red; }';

    await tester.pumpWidget(
      _buildApp(
        appModel: appModel,
        home: const DictCssEditorDialog(initialDictionaryName: 'JMdict'),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('JMdict'), findsOneWidget);
    expect(find.textContaining('color: red'), findsOneWidget);
  });
}
