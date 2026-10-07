import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_theme_host.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_settings_side_dialog.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

class _MemoryPrefs implements PrefStore {
  @override
  dynamic getPref(String key, {dynamic defaultValue}) => defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async {}
}

ThemeData _theme(Color seed) => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
  textTheme: Typography.material2021().white,
).copyWith(platform: TargetPlatform.windows);

// BUG-3008: the real reader route always contains LyricsThemeHost, even when
// lyrics are off. Open the production movable settings route beneath it.
void main() {
  for (final bool compact in <bool>[false, true]) {
    testWidgets(
      'open settings follows app theme without losing state ($compact)',
      (WidgetTester tester) async {
        tester.view.physicalSize = Size(compact ? 420 : 1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final ThemeData brown = _theme(const Color(0xFF924A24));
        final ThemeData blue = _theme(const Color(0xFF005AC1));
        final ValueNotifier<ThemeData> theme = ValueNotifier<ThemeData>(brown);
        final ValueNotifier<String> panel = ValueNotifier<String>('settings');
        final ScrollController scroll = ScrollController();
        addTearDown(theme.dispose);
        addTearDown(panel.dispose);
        addTearDown(scroll.dispose);
        late BuildContext owner;
        late BuildContext content;
        final Widget page = LyricsThemeHost(
          child: Builder(
            builder: (BuildContext context) {
              owner = context;
              return const Scaffold();
            },
          ),
        );
        await tester.pumpWidget(
          ValueListenableBuilder<ThemeData>(
            valueListenable: theme,
            builder: (BuildContext context, ThemeData value, Widget? _) =>
                MaterialApp(
                  theme: value,
                  themeAnimationDuration: Duration.zero,
                  home: page,
                ),
          ),
        );

        void open() => unawaited(
          showReaderSettingsSideDialog<void>(
            context: owner,
            preferences: _MemoryPrefs(),
            bottomSheetWhenCompact: true,
            switcher: ReaderPanelSwitcher(
              current: panel,
              items: const <({String id, IconData icon, String label})>[
                (id: 'settings', icon: Icons.tune, label: 'Settings'),
                (id: 'contents', icon: Icons.list, label: 'Contents'),
              ],
              onSelect: (String id) => panel.value = id,
            ),
            builder: (BuildContext context) {
              content = context;
              // Subscribe as the real settings widgets do: both Theme and tokens.
              final FushiDesignTokens tokens = FushiDesignTokens.of(context);
              return ReaderSideSheet(
                title: 'Reading settings',
                scrollable: false,
                onClose: () => Navigator.of(context).pop(),
                child: Column(
                  children: <Widget>[
                    const TextField(key: ValueKey<String>('draft')),
                    Expanded(
                      child: ListView.builder(
                        controller: scroll,
                        itemCount: 60,
                        itemBuilder: (BuildContext context, int i) => ListTile(
                          title: Text('Setting $i'),
                          tileColor: tokens.surfaces.card,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );

        void expectTheme(ThemeData expected) {
          expect(Theme.of(content).colorScheme, expected.colorScheme);
          final Finder shell = find.byKey(
            const ValueKey<String>('fushi_reader_side_sheet'),
          );
          expect(
            tester.widget<Material>(shell).color,
            expected.colorScheme.surfaceContainerLow,
          );
          expect(
            tester.widget<ListTile>(find.byType(ListTile).first).tileColor,
            expected.colorScheme.surfaceContainer,
          );
          if (!compact) {
            final Finder rail = find.byKey(
              const ValueKey<String>('fushi_reader_panel_switcher'),
            );
            final FushiFloatingPill pill = tester.widget<FushiFloatingPill>(
              find
                  .descendant(
                    of: rail,
                    matching: find.byType(FushiFloatingPill),
                  )
                  .first,
            );
            expect(pill.color, expected.colorScheme.surfaceContainer);
          }
        }

        open();
        await tester.pumpAndSettle();
        expectTheme(brown);
        await tester.enterText(
          find.byKey(const ValueKey<String>('draft')),
          'Draft',
        );
        final State<StatefulWidget> field = tester.state(
          find.byType(TextField),
        );
        scroll.jumpTo(180);
        await tester.pump();

        theme.value = blue;
        await tester.pumpAndSettle();
        expectTheme(blue);
        expect(identical(field, tester.state(find.byType(TextField))), isTrue);
        expect(find.text('Draft'), findsOneWidget);
        expect(scroll.offset, 180);
        expect(panel.value, 'settings');

        Navigator.of(content).pop();
        await tester.pumpAndSettle();
        open();
        await tester.pumpAndSettle();
        expectTheme(blue);
        Navigator.of(content).pop();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('open side panel follows lyrics cover changes and detach', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ThemeData base = _theme(const Color(0xFF005AC1));
    final GlobalKey<LyricsThemeHostState> host =
        GlobalKey<LyricsThemeHostState>();
    late BuildContext owner;
    late BuildContext content;
    await tester.pumpWidget(
      MaterialApp(
        theme: base,
        themeAnimationDuration: Duration.zero,
        home: LyricsThemeHost(
          key: host,
          child: Builder(
            builder: (BuildContext context) {
              owner = context;
              return const Scaffold();
            },
          ),
        ),
      ),
    );
    unawaited(
      showReaderSettingsSideDialog<void>(
        context: owner,
        preferences: _MemoryPrefs(),
        builder: (BuildContext context) {
          content = context;
          return Text('Settings', style: Theme.of(context).textTheme.bodyLarge);
        },
      ),
    );
    await tester.pumpAndSettle();
    final Object lyrics = Object();
    for (final Color seed in <Color>[Colors.orange, Colors.green]) {
      final ColorScheme cover = ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
      );
      host.currentState!.attach(lyrics, cover);
      await tester.pumpAndSettle();
      expect(
        Theme.of(content).colorScheme,
        rethemeFushiWithScheme(base, cover).colorScheme,
      );
    }
    host.currentState!.detach(lyrics);
    await tester.pumpAndSettle();
    expect(Theme.of(content).colorScheme, base.colorScheme);
    Navigator.of(content).pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the source before its side panel leaves no listener', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> showReader = ValueNotifier<bool>(true);
    addTearDown(showReader.dispose);
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    late BuildContext owner;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: ValueListenableBuilder<bool>(
          valueListenable: showReader,
          builder: (BuildContext context, bool visible, Widget? _) => visible
              ? LyricsThemeHost(
                  child: Builder(
                    builder: (BuildContext context) {
                      owner = context;
                      return const Scaffold();
                    },
                  ),
                )
              : const Scaffold(),
        ),
      ),
    );
    unawaited(
      showReaderSettingsSideDialog<void>(
        context: owner,
        preferences: _MemoryPrefs(),
        builder: (BuildContext context) => const Text('Open settings'),
      ),
    );
    await tester.pumpAndSettle();
    showReader.value = false;
    await tester.pumpAndSettle();
    expect(owner.mounted, isFalse);
    expect(find.text('Open settings'), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
