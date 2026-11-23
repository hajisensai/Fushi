// 拍板台 vJSj4RsKFt：阅读器纸色行——真实 `buildReaderPaperSelector`，点色卡写的
// 是该明暗那一份纸色偏好，「跟随主题」清掉显式选择；控制通道读写同一份。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';

import '../helpers/test_platform_services.dart';

class _PaperAppModel extends AppModel {
  _PaperAppModel() : super(testPlatformServices());

  final Map<bool, String?> papers = <bool, String?>{false: null, true: null};
  final List<(bool, String?)> writes = <(bool, String?)>[];

  @override
  String? readerPaperFor({required bool dark}) => papers[dark];

  @override
  Future<void> setReaderPaper({required bool dark, String? key}) async {
    writes.add((dark, key));
    papers[dark] = key;
    notifyListeners();
  }

  @override
  String get readerFollowThemeKey => 'm3-teal';

  @override
  ColorScheme buildColorScheme(Brightness brightness) => ColorScheme.fromSeed(
    seedColor: const Color(0xFF00897B),
    brightness: brightness,
  );

  @override
  Color? get activeCustomThemeBackgroundColor => null;
  @override
  Color? get activeCustomThemeFontColor => null;
  @override
  Color? get activeCustomThemeSelectionColor => null;
  @override
  Color? get activeCustomThemeLinkColor => null;

  @override
  bool get einkMode => false;
}

SettingsContext _settingsContext(
  BuildContext context,
  WidgetRef ref,
  AppModel appModel,
) => SettingsContext(
  context: context,
  appModel: appModel,
  ref: ref,
  readerSource: ReaderFushiSource.instance,
  refresh: () {},
);

Widget _host(_PaperAppModel appModel) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: Scaffold(
          body: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              final SettingsContext sc = _settingsContext(
                context,
                ref,
                appModel,
              );
              return SingleChildScrollView(
                child: Column(
                  children: <Widget>[
                    buildReaderPaperSelector(sc, dark: false),
                    buildReaderPaperSelector(sc, dark: true),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('tapping a paper card writes that brightness only', (
    WidgetTester tester,
  ) async {
    final _PaperAppModel appModel = _PaperAppModel();
    await tester.pumpWidget(_host(appModel));
    await tester.pumpAndSettle();

    for (final String id in <String>[
      'follow',
      'ecru-theme',
      'water-theme',
      'eyecare-theme',
    ]) {
      expect(find.byKey(ValueKey<String>('reader-paper-light-$id')), findsOne);
    }
    for (final String id in <String>[
      'follow',
      'gray-theme',
      'dark-theme',
      'black-theme',
    ]) {
      expect(find.byKey(ValueKey<String>('reader-paper-dark-$id')), findsOne);
    }

    await tester.tap(
      find.byKey(const ValueKey<String>('reader-paper-light-ecru-theme')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('reader-paper-dark-gray-theme')),
    );
    await tester.pumpAndSettle();
    expect(appModel.writes, <(bool, String?)>[
      (false, 'ecru-theme'),
      (true, 'gray-theme'),
    ]);

    await tester.tap(
      find.byKey(const ValueKey<String>('reader-paper-light-follow')),
    );
    await tester.pumpAndSettle();
    expect(appModel.writes.last, (false, null));
    expect(appModel.papers[false], isNull);
    expect(appModel.papers[true], 'gray-theme');
  });

  testWidgets('control channel reads and writes the same preference', (
    WidgetTester tester,
  ) async {
    final _PaperAppModel appModel = _PaperAppModel();
    late SettingsContext sc;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (BuildContext context, WidgetRef ref, _) {
            sc = _settingsContext(context, ref, appModel);
            return const SizedBox();
          },
        ),
      ),
    );
    final SettingsCliValue light = readerPaperCliValue(dark: false);
    expect(light.read(sc), 'follow');
    expect(light.options!(sc), <String>[
      'follow',
      'ecru-theme',
      'water-theme',
      'eyecare-theme',
    ]);
    await light.write(sc, 'eyecare-theme');
    expect(light.read(sc), 'eyecare-theme');
    await light.write(sc, ' follow ');
    expect(appModel.papers[false], isNull);
  });
}
