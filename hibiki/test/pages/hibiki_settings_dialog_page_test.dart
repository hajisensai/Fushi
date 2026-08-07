import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/hibiki_settings_page.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('reader settings dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 420);
    addTearDown(tester.view.reset);

    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    final ThemeNotifier themeNotifier =
        ThemeNotifier(db, () => const TextTheme())
          ..loadFromPrefsSnapshot(<String, String>{
            'design_system': PrefCodec.encode('material'),
            'app_theme_key': PrefCodec.encode('system-theme'),
            'brightness_mode': PrefCodec.encode('system'),
            'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
          });
    final AppModel appModel = _SettingsDialogTestAppModel()
      ..themeNotifier = themeNotifier;
    addTearDown(() async {
      themeNotifier.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: const FushiSettingsDialogPage(),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.reader_settings_section), findsOneWidget);
    expect(find.text(t.dialog_close), findsOneWidget);
  });
}

class _SettingsDialogTestAppModel extends AppModel {
  _SettingsDialogTestAppModel() : super(testPlatformServices());

  double _popupMaxWidth = 400;

  @override
  double get popupMaxWidth => _popupMaxWidth;

  @override
  void setPopupMaxWidth(double width) {
    _popupMaxWidth = width;
  }

  // 阅读器底栏反转开关（reader 快捷面板里）读 appModel；本 double 未初始化
  // prefsRepo，故显式后备，避免渲染该开关时 prefsRepo 空指针。
  @override
  bool get reverseReaderBottomBar => false;
}
