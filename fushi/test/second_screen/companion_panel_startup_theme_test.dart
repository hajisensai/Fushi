import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion_panel_app.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

const Color _appSeed = Color(0xFF2E7D32);

/// An AppModel whose start-up stages the test drives: preferences
/// (appearance) loaded or not, initialisation failed or not.
class _StagedAppModel extends AppModel {
  _StagedAppModel() : super(testPlatformServices());

  bool appearanceReady = false;
  String? failure;

  final ThemeData _theme = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: _appSeed),
  );

  void loadAppearance() {
    appearanceReady = true;
    notifyListeners();
  }

  void fail(String error) {
    failure = error;
    notifyListeners();
  }

  @override
  bool get isAppearanceReady => appearanceReady;

  @override
  bool get isInitialised => false;

  @override
  String? get initError => failure;

  @override
  ThemeData get theme => _theme;

  @override
  ThemeData get darkTheme => _theme;

  @override
  ThemeMode get themeMode => ThemeMode.light;

  @override
  Locale get appLocale => const Locale('en', 'US');

  @override
  Map<String, Locale> get locales => <String, Locale>{
    'en-US': const Locale('en', 'US'),
  };
}

/// Records the primary colour of every themed frame the panel content gets.
class _ThemeProbe extends StatelessWidget {
  const _ThemeProbe(this.primaries);

  final List<Color> primaries;

  @override
  Widget build(BuildContext context) {
    primaries.add(Theme.of(context).colorScheme.primary);
    return const Text('panel content');
  }
}

Future<(_StagedAppModel, List<Color>)> _pumpPanel(WidgetTester tester) async {
  final _StagedAppModel appModel = _StagedAppModel();
  final CompanionPanelSession session = CompanionPanelSession(
    send: (String _) async {},
  );
  final List<Color> primaries = <Color>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appProvider.overrideWith((Ref ref) => appModel),
        companionPanelSessionProvider.overrideWith((Ref ref) => session),
      ],
      child: CompanionPanelApp(home: _ThemeProbe(primaries)),
    ),
  );
  return (appModel, primaries);
}

void main() {
  final Color appPrimary = ColorScheme.fromSeed(seedColor: _appSeed).primary;

  testWidgets('no themed frame before the preferences are in; the first one '
      'already has the app colours', (WidgetTester tester) async {
    final (_StagedAppModel appModel, List<Color> primaries) = await _pumpPanel(
      tester,
    );
    // Still loading: nothing painted (window background), no app, no
    // seed-colour content.
    expect(find.byType(ColoredBox), findsNothing);
    expect(find.byType(MaterialApp), findsNothing);
    expect(find.text('panel content'), findsNothing);
    expect(primaries, isEmpty);

    appModel.loadAppearance();
    await tester.pump();

    expect(find.text('panel content'), findsOneWidget);
    expect(primaries, isNotEmpty);
    expect(
      primaries.every((Color c) => c == appPrimary),
      isTrue,
      reason:
          'every frame of the content uses the app theme, never the '
          'fallback seed colour',
    );
    final MaterialApp app = tester.widget(find.byType(MaterialApp));
    expect(app.theme, same(appModel.theme));
  });

  testWidgets('a failed initialisation still shows the panel (fallback '
      'theme)', (WidgetTester tester) async {
    final (_StagedAppModel appModel, List<Color> primaries) = await _pumpPanel(
      tester,
    );
    expect(find.text('panel content'), findsNothing);

    appModel.fail('database unavailable');
    await tester.pump();

    expect(find.text('panel content'), findsOneWidget);
    expect(primaries, isNotEmpty);
    expect(primaries.last, isNot(appPrimary));
  });
}
