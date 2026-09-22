import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_settings_side_dialog.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

class _MemoryPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values[key] ?? defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async {
    values[key] = value;
  }
}

void main() {
  testWidgets(
    'moving settings keeps fields and scroll, and persists the edge',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final _MemoryPrefs preferences = _MemoryPrefs();
      final ScrollController scroll = ScrollController();
      addTearDown(scroll.dispose);
      late BuildContext owner;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                owner = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );

      void openSettings() {
        showReaderSettingsSideDialog<void>(
          context: owner,
          preferences: preferences,
          builder: (BuildContext context) => Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  const ReaderSettingsSideButton(),
                  IconButton(
                    key: const ValueKey<String>('close'),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const TextField(key: ValueKey<String>('draft')),
              Expanded(
                child: ListView.builder(
                  controller: scroll,
                  itemCount: 60,
                  itemBuilder: (BuildContext context, int index) =>
                      ListTile(title: Text('Setting $index')),
                ),
              ),
            ],
          ),
        );
      }

      final Finder panel = find.byKey(
        const ValueKey<String>('fushi_reader_side_sheet'),
      );
      final Finder toggle = find.byKey(
        const ValueKey<String>('reader_settings_side_toggle'),
      );
      openSettings();
      await tester.pumpAndSettle();
      expect(tester.getRect(panel).right, 1280);
      await tester.enterText(
        find.byKey(const ValueKey<String>('draft')),
        'Draft',
      );
      final State<StatefulWidget> fieldState = tester.state(
        find.byType(TextField),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -420));
      await tester.pumpAndSettle();
      final double oldOffset = scroll.offset;
      expect(oldOffset, greaterThan(0));

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.getRect(panel).left, 0);
      expect(find.text('Draft'), findsOneWidget);
      expect(
        identical(fieldState, tester.state(find.byType(TextField))),
        isTrue,
      );
      expect(scroll.offset, oldOffset);
      expect(preferences.values[kReaderSettingsPanelSidePref], 'left');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      openSettings();
      await tester.pumpAndSettle();
      expect(tester.getRect(panel).left, 0);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.getRect(panel).right, 1280);
      expect(preferences.values[kReaderSettingsPanelSidePref], 'right');
      await tester.tapAt(const Offset(100, 400));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow window keeps close and side controls above the keyboard',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
      addTearDown(tester.view.reset);
      final _MemoryPrefs preferences = _MemoryPrefs();
      preferences.values[kReaderSettingsPanelSidePref] = 'unknown-future-value';
      late BuildContext owner;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              owner = context;
              return const Scaffold();
            },
          ),
        ),
      );
      showReaderSettingsSideDialog<void>(
        context: owner,
        preferences: preferences,
        builder: (BuildContext context) => ReaderSideSheet(
          title: 'Reading settings',
          headerActions: const <Widget>[ReaderSettingsSideButton()],
          onClose: () => Navigator.of(context).pop(),
          child: const TextField(),
        ),
      );
      await tester.pumpAndSettle();
      final Finder panel = find.byType(ReaderSideSheet);
      expect(tester.getRect(panel).left, 48);
      await tester.tap(find.byType(TextField));
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      tester.view.padding = const FakeViewPadding(top: 24);
      await tester.pumpAndSettle();
      expect(tester.getRect(panel), const Rect.fromLTRB(48, 24, 360, 440));
      await tester.tap(
        find.byKey(const ValueKey<String>('reader_settings_side_toggle')),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(panel), const Rect.fromLTRB(0, 24, 312, 440));
      await tester.tap(
        find.byKey(const ValueKey<String>('fushi_side_sheet_close')),
      );
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('side action does not appear in non-settings panels', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ReaderSettingsSideButton())),
    );
    expect(find.byType(IconButton), findsNothing);
  });
}
