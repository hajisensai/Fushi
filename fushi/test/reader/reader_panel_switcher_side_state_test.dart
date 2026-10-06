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
    'panel with switcher preserves its session across both side moves',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final _MemoryPrefs preferences = _MemoryPrefs();
      final ValueNotifier<String> current = ValueNotifier<String>('settings');
      addTearDown(current.dispose);
      late BuildContext owner;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
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

      final Future<void> closed = showReaderSettingsSideDialog<void>(
        context: owner,
        preferences: preferences,
        bottomSheetWhenCompact: true,
        switcher: ReaderPanelSwitcher(
          current: current,
          onSelect: (String id) => current.value = id,
          items: const <({String id, IconData icon, String label})>[
            (id: 'settings', icon: Icons.settings, label: 'Settings'),
            (id: 'navigation', icon: Icons.list, label: 'Navigation'),
          ],
        ),
        builder: (BuildContext context) => ReaderSideSheet(
          title: 'Reading settings',
          headerActions: const <Widget>[ReaderSettingsSideButton()],
          onClose: () => Navigator.of(context).pop(),
          child: const TextField(key: ValueKey<String>('panel_draft')),
        ),
      );
      await tester.pumpAndSettle();
      final Finder field = find.byKey(const ValueKey<String>('panel_draft'));
      final Finder panel = find.byKey(
        const ValueKey<String>('fushi_reader_side_sheet'),
      );
      final Finder toggle = find.byKey(
        const ValueKey<String>('reader_settings_side_toggle'),
      );
      await tester.enterText(field, 'Keep this draft');
      final State<StatefulWidget> originalState = tester.state(field);
      expect(tester.getRect(panel).right, 1280);

      for (final String side in <String>['left', 'right']) {
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(identical(originalState, tester.state(field)), isTrue);
        expect(find.text('Keep this draft'), findsOneWidget);
        expect(preferences.values[kReaderSettingsPanelSidePref], side);
        expect(
          side == 'left'
              ? tester.getRect(panel).left
              : tester.getRect(panel).right,
          side == 'left' ? 0 : 1280,
        );
      }

      // 横竖屏/分屏跨过 compact 断点，整块会话应搬家而不是销毁后重新创建。
      for (final double width in <double>[420, 1280]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(identical(originalState, tester.state(field)), isTrue);
        expect(find.text('Keep this draft'), findsOneWidget);
        expect(toggle, width < 600 ? findsNothing : findsOneWidget);
      }
      // 返回宽窗后再换边，证明路由仍持有可正常通知的 controller。
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.getRect(panel).left, 0);
      expect(preferences.values[kReaderSettingsPanelSidePref], 'left');
      expect(identical(originalState, tester.state(field)), isTrue);
      expect(tester.takeException(), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await closed;
      expect(panel, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
