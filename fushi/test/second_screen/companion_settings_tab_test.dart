import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/settings_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_settings_tab.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:material_ui/material_ui.dart';

import 'companion_panel_harness.dart';

const CompanionSettingsCategory _reader = CompanionSettingsCategory(
  id: 'reader',
  title: 'Reader',
);
const CompanionSettingsCategory _appearance = CompanionSettingsCategory(
  id: 'appearance',
  title: 'Appearance',
);

const CompanionSettingRow _fontSize = CompanionSettingRow(
  key: 'reader.fontSize',
  title: 'Font size',
  control: CompanionSettingControl.slider,
  value: 22.0,
  display: '22',
  min: 10,
  max: 40,
  divisions: 30,
  integer: true,
);
const CompanionSettingRow _vertical = CompanionSettingRow(
  key: 'reader.vertical',
  title: 'Vertical text',
  control: CompanionSettingControl.toggle,
  value: false,
  display: 'Off',
);
const CompanionSettingRow _viewMode = CompanionSettingRow(
  key: 'reader.viewMode',
  title: 'View mode',
  control: CompanionSettingControl.choice,
  value: 'paginated',
  display: 'Paginated',
  options: <CompanionSettingOption>[
    CompanionSettingOption(value: 'paginated', label: 'Paginated'),
    CompanionSettingOption(value: 'continuous', label: 'Continuous'),
    CompanionSettingOption(value: 'vn', label: 'VN'),
  ],
);
const CompanionSettingRow _font = CompanionSettingRow(
  key: 'reader.font',
  title: 'Reader font',
  control: CompanionSettingControl.open,
  display: 'Noto Serif JP',
);
const CompanionSettingRow _locked = CompanionSettingRow(
  key: 'reader.locked',
  title: 'Locked option',
  control: CompanionSettingControl.toggle,
  value: true,
  display: 'On',
  enabled: false,
);

const List<CompanionSettingsCategory> _categories = <CompanionSettingsCategory>[
  _appearance,
  CompanionSettingsCategory(id: 'lookup', title: 'Lookup'),
  CompanionSettingsCategory(id: 'mining', title: 'Card creation'),
  CompanionSettingsCategory(id: 'video', title: 'Video'),
  _reader,
];

final CompanionSettingsPage _appearancePage = CompanionSettingsPage(
  category: _appearance,
  rows: <CompanionSettingRow>[
    const CompanionSettingRow(
      key: 'appearance.dark',
      title: 'Dark mode',
      control: CompanionSettingControl.toggle,
      value: true,
      display: 'On',
      section: 'Theme',
    ),
    CompanionSettingRow(
      key: 'appearance.accent',
      title: 'Accent color',
      control: CompanionSettingControl.choice,
      value: 'blue',
      display: 'Blue',
      section: 'Theme',
      options: <CompanionSettingOption>[
        for (final String c in <String>[
          'blue',
          'green',
          'red',
          'purple',
          'orange',
        ])
          CompanionSettingOption(
            value: c,
            label: '${c[0].toUpperCase()}${c.substring(1)}',
          ),
      ],
    ),
    const CompanionSettingRow(
      key: 'appearance.uiScale',
      title: 'Interface scale',
      control: CompanionSettingControl.stepper,
      value: 100.0,
      display: '100%',
      section: 'Layout › Spacing',
      min: 80,
      max: 120,
      step: 10,
      integer: true,
    ),
  ],
);

class _HostError implements Exception {
  const _HostError(this.message);

  final String message;
}

/// The main engine's side of the `settings.*` requests, answered on demand.
class _SettingsHost {
  _SettingsHost(this.rec);

  final RecordingCompanionSession rec;
  final Set<int> _answered = <int>{};

  CompanionSettingsPage? context = const CompanionSettingsPage(
    category: _reader,
    rows: <CompanionSettingRow>[
      _fontSize,
      _vertical,
      _viewMode,
      _font,
      _locked,
    ],
  );

  /// While true, requests wait (see [answerPending]).
  bool hold = false;

  /// The next `settings.list` fails.
  bool failNextList = false;

  /// The next `settings.set` fails.
  bool failNextSet = false;

  List<CompanionRequestMessage> get requests =>
      rec.sent.whereType<CompanionRequestMessage>().toList();

  List<CompanionRequestMessage> of(String method) => requests
      .where((CompanionRequestMessage r) => r.method == method)
      .toList();

  Object? _answer(CompanionRequestMessage r) {
    final Map<String, Object?> args = r.args;
    switch (r.method) {
      case CompanionRequestMethods.settingsList:
        if (failNextList) {
          failNextList = false;
          throw const _HostError('boom');
        }
        final Object? category = args[CompanionSettingsArgs.category];
        final Object? query = args[CompanionSettingsArgs.query];
        if (category == 'appearance') return _appearancePage.toJson();
        if (query is String) {
          return CompanionSettingsPage(
            rows: <CompanionSettingRow>[
              if ('font'.contains(query.toLowerCase()) ||
                  query.toLowerCase().contains('font'))
                const CompanionSettingRow(
                  key: 'reader.fontSize',
                  title: 'Font size',
                  control: CompanionSettingControl.stepper,
                  value: 22.0,
                  display: '22',
                  step: 1,
                  section: 'Reader › Text',
                ),
            ],
          ).toJson();
        }
        return CompanionSettingsOverview(
          context: context,
          categories: _categories,
        ).toJson();
      case CompanionRequestMethods.settingsSet:
        if (failNextSet) {
          failNextSet = false;
          throw const _HostError('nope');
        }
        final String key = args[CompanionSettingsArgs.key]! as String;
        final String value = args[CompanionSettingsArgs.value]! as String;
        final CompanionSettingRow row = <CompanionSettingRow>[
          ...?context?.rows,
          ..._appearancePage.rows,
        ].firstWhere((CompanionSettingRow r) => r.key == key);
        return switch (row.control) {
          CompanionSettingControl.toggle => row.withValue(
            value == 'true',
            value == 'true' ? 'On' : 'Off',
          ),
          CompanionSettingControl.choice => row.withValue(
            value,
            row.options
                .firstWhere((CompanionSettingOption o) => o.value == value)
                .label,
          ),
          _ => row.withValue(double.parse(value), '$value echoed'),
        }.toJson();
      case CompanionRequestMethods.settingsOpenOnMain:
        return null;
    }
    throw _HostError('unknown ${r.method}');
  }

  /// Replies to every request not answered yet; true when there was one.
  bool answerPending() {
    if (hold) return false;
    bool any = false;
    for (final CompanionRequestMessage r in requests) {
      if (!_answered.add(r.id)) continue;
      any = true;
      try {
        rec.push(CompanionReplyMessage(id: r.id, value: _answer(r)));
      } on _HostError catch (error) {
        rec.push(CompanionReplyMessage(id: r.id, error: error.message));
      }
    }
    return any;
  }
}

void main() {
  late RecordingCompanionSession rec;
  late _SettingsHost host;

  setUp(() {
    rec = RecordingCompanionSession();
    host = _SettingsHost(rec);
  });

  /// Pumps, answering requests until none are left, then settles.
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 20; i++) {
      await tester.pump();
      if (!host.answerPending()) break;
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpTab(WidgetTester tester) async {
    await pumpCompanionPanel(
      tester,
      rec.session,
      const CompanionSettingsTab(),
      settle: false,
    );
    await settle(tester);
  }

  /// Lets a snack bar time out so no timer is left at the end.
  Future<void> dismissSnackBars(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  Finder inRow(String key, Finder matching) => find.descendant(
    of: find.byKey(ValueKey<String>('companion-setting-$key')),
    matching: matching,
  );

  CompanionRequestMessage lastSet() =>
      host.of(CompanionRequestMethods.settingsSet).last;

  testWidgets('overview shows the screen section and all categories', (
    WidgetTester tester,
  ) async {
    await pumpTab(tester);
    expect(host.of(CompanionRequestMethods.settingsList).single.args, isEmpty);
    expect(
      find.text(t.second_screen_settings_context(title: 'Reader')),
      findsOneWidget,
    );
    for (final String title in <String>[
      'Font size',
      'Vertical text',
      'View mode',
      'Reader font',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    await tester.scrollUntilVisible(
      find.text('Card creation'),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey<String>('companion-settings-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text(t.second_screen_settings_all), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Card creation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no context section when the top screen has no settings', (
    WidgetTester tester,
  ) async {
    host.context = null;
    await pumpTab(tester);
    expect(
      find.text(t.second_screen_settings_context(title: 'Reader')),
      findsNothing,
    );
    expect(find.text(t.second_screen_settings_all), findsOneWidget);
  });

  testWidgets('toggle writes "true" and applies the echo', (
    WidgetTester tester,
  ) async {
    await pumpTab(tester);
    await tester.tap(inRow('reader.vertical', find.byType(FushiSwitch)));
    await tester.pump();
    final CompanionRequestMessage set = lastSet();
    expect(set.args, <String, Object?>{
      CompanionSettingsArgs.key: 'reader.vertical',
      CompanionSettingsArgs.value: 'true',
    });
    // Optimistic before the echo.
    expect(
      tester
          .widget<FushiSwitch>(
            inRow('reader.vertical', find.byType(FushiSwitch)),
          )
          .value,
      isTrue,
    );
    await settle(tester);
    expect(
      tester
          .widget<FushiSwitch>(
            inRow('reader.vertical', find.byType(FushiSwitch)),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('a failed write puts the old value back and says so', (
    WidgetTester tester,
  ) async {
    await pumpTab(tester);
    host.failNextSet = true;
    await tester.tap(inRow('reader.vertical', find.byType(FushiSwitch)));
    await settle(tester);
    expect(
      tester
          .widget<FushiSwitch>(
            inRow('reader.vertical', find.byType(FushiSwitch)),
          )
          .value,
      isFalse,
    );
    expect(find.text(t.second_screen_settings_write_failed), findsOneWidget);
    await dismissSnackBars(tester);
  });

  testWidgets('disabled rows do not write', (WidgetTester tester) async {
    await pumpTab(tester);
    await tester.ensureVisible(
      inRow('reader.locked', find.byType(FushiSwitch)),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      inRow('reader.locked', find.byType(FushiSwitch)),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(host.of(CompanionRequestMethods.settingsSet), isEmpty);
  });

  testWidgets('choice segments write the option token', (
    WidgetTester tester,
  ) async {
    await pumpTab(tester);
    await tester.tap(inRow('reader.viewMode', find.text('Continuous')));
    await tester.pump();
    expect(lastSet().args, <String, Object?>{
      CompanionSettingsArgs.key: 'reader.viewMode',
      CompanionSettingsArgs.value: 'continuous',
    });
    await settle(tester);
  });

  testWidgets('the slider writes once, when the drag ends', (
    WidgetTester tester,
  ) async {
    await pumpTab(tester);
    final Finder slider = inRow('reader.fontSize', find.byType(Slider));
    final TestGesture drag = await tester.startGesture(
      tester.getCenter(slider),
    );
    await tester.pump();
    await drag.moveBy(const Offset(40, 0));
    await tester.pump();
    await drag.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(host.of(CompanionRequestMethods.settingsSet), isEmpty);
    await drag.up();
    await tester.pump();
    final List<CompanionRequestMessage> sets = host.of(
      CompanionRequestMethods.settingsSet,
    );
    expect(sets, hasLength(1));
    expect(sets.single.args[CompanionSettingsArgs.key], 'reader.fontSize');
    final String token =
        sets.single.args[CompanionSettingsArgs.value]! as String;
    expect(int.tryParse(token), isNotNull, reason: 'integer slider token');
    expect(int.parse(token), greaterThan(22));
    await settle(tester);
    expect(find.text('$token echoed'), findsWidgets);
  });

  testWidgets('open rows ask the main screen to open them', (
    WidgetTester tester,
  ) async {
    await pumpTab(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('companion-setting-reader.font-open')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('companion-setting-reader.font-open')),
    );
    await settle(tester);
    expect(
      host.of(CompanionRequestMethods.settingsOpenOnMain).single.args,
      <String, Object?>{CompanionSettingsArgs.key: 'reader.font'},
    );
    expect(find.text(t.second_screen_settings_opened_on_main), findsOneWidget);
    await dismissSnackBars(tester);
  });

  testWidgets('a category opens as a page grouped by section', (
    WidgetTester tester,
  ) async {
    await pumpTab(tester);
    final Finder tile = find.byKey(
      const ValueKey<String>('companion-settings-category-appearance'),
    );
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await settle(tester);
    expect(
      host.of(CompanionRequestMethods.settingsList).last.args,
      <String, Object?>{CompanionSettingsArgs.category: 'appearance'},
    );
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Layout › Spacing'), findsOneWidget);
    expect(find.text('Dark mode'), findsOneWidget);

    // Stepper: + by step.
    await tester.tap(
      find.byKey(
        const ValueKey<String>('companion-setting-appearance.uiScale-up'),
      ),
    );
    await tester.pump();
    expect(lastSet().args, <String, Object?>{
      CompanionSettingsArgs.key: 'appearance.uiScale',
      CompanionSettingsArgs.value: '110',
    });
    await settle(tester);

    // A long choice opens a picker page.
    await tester.tap(
      find.byKey(
        const ValueKey<String>('companion-setting-appearance.accent-pick'),
      ),
    );
    await settle(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('companion-setting-option-green')),
    );
    await settle(tester);
    expect(lastSet().args, <String, Object?>{
      CompanionSettingsArgs.key: 'appearance.accent',
      CompanionSettingsArgs.value: 'green',
    });
    expect(find.text('Green'), findsOneWidget);

    // The category itself on the main screen.
    await tester.tap(
      find.byKey(const ValueKey<String>('companion-settings-category-open')),
    );
    await settle(tester);
    expect(
      host.of(CompanionRequestMethods.settingsOpenOnMain).single.args,
      <String, Object?>{CompanionSettingsArgs.category: 'appearance'},
    );
    await dismissSnackBars(tester);

    // Back to the overview.
    await tester.tap(
      find.byKey(const ValueKey<String>('companion-settings-back')),
    );
    await settle(tester);
    expect(find.text(t.second_screen_settings_search_hint), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typing searches; clearing goes back to the overview', (
    WidgetTester tester,
  ) async {
    await pumpTab(tester);
    await tester.enterText(
      find.byKey(const ValueKey<String>('companion-settings-search')),
      'font',
    );
    await settle(tester);
    expect(
      host.of(CompanionRequestMethods.settingsList).last.args,
      <String, Object?>{CompanionSettingsArgs.query: 'font'},
    );
    expect(find.text(t.second_screen_settings_search_results), findsOneWidget);
    expect(find.text('Reader › Text'), findsOneWidget);
    expect(find.text('Font size'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('companion-settings-search')),
      'zzz',
    );
    await settle(tester);
    expect(find.text(t.second_screen_settings_no_match), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('companion-settings-search')),
      '',
    );
    await settle(tester);
    expect(
      find.text(t.second_screen_settings_context(title: 'Reader')),
      findsOneWidget,
    );
  });

  testWidgets('a reply overtaken by a newer query is dropped', (
    WidgetTester tester,
  ) async {
    await pumpTab(tester);
    host.hold = true;
    final Finder field = find.byKey(
      const ValueKey<String>('companion-settings-search'),
    );
    await tester.enterText(field, 'zz');
    await tester.pump();
    await tester.enterText(field, 'font');
    await tester.pump();
    // One request in flight; the newer query waits for it.
    expect(
      host.of(CompanionRequestMethods.settingsList).last.args,
      <String, Object?>{CompanionSettingsArgs.query: 'zz'},
    );
    host.hold = false;
    await settle(tester);
    expect(
      host.of(CompanionRequestMethods.settingsList).last.args,
      <String, Object?>{CompanionSettingsArgs.query: 'font'},
    );
    expect(find.text(t.second_screen_settings_no_match), findsNothing);
    expect(find.text('Reader › Text'), findsOneWidget);
  });

  testWidgets('settingsChanged reloads; changes during a fetch fetch once', (
    WidgetTester tester,
  ) async {
    await pumpTab(tester);
    expect(host.of(CompanionRequestMethods.settingsList), hasLength(1));
    host.hold = true;
    rec.push(const CompanionSettingsChangedMessage());
    await tester.pump();
    expect(host.of(CompanionRequestMethods.settingsList), hasLength(2));
    rec.push(const CompanionSettingsChangedMessage());
    rec.push(const CompanionSettingsChangedMessage());
    await tester.pump();
    expect(host.of(CompanionRequestMethods.settingsList), hasLength(2));
    host.context = const CompanionSettingsPage(
      category: _reader,
      rows: <CompanionSettingRow>[
        CompanionSettingRow(
          key: 'reader.vertical',
          title: 'Vertical text',
          control: CompanionSettingControl.toggle,
          value: true,
          display: 'On',
        ),
      ],
    );
    host.hold = false;
    await settle(tester);
    expect(host.of(CompanionRequestMethods.settingsList), hasLength(3));
    expect(find.text('Font size'), findsNothing);
    expect(
      tester
          .widget<FushiSwitch>(
            inRow('reader.vertical', find.byType(FushiSwitch)),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('a new top screen context reloads the overview', (
    WidgetTester tester,
  ) async {
    await pumpTab(tester);
    host.context = null;
    rec.push(
      const CompanionContextMessage(
        CompanionContext(CompanionContextKind.home),
      ),
    );
    await settle(tester);
    expect(host.of(CompanionRequestMethods.settingsList), hasLength(2));
    expect(
      find.text(t.second_screen_settings_context(title: 'Reader')),
      findsNothing,
    );
  });

  testWidgets('a failed load shows an error with retry', (
    WidgetTester tester,
  ) async {
    host.failNextList = true;
    await pumpTab(tester);
    expect(find.text(t.second_screen_settings_load_failed), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('companion-settings-retry')),
    );
    await settle(tester);
    expect(find.text(t.second_screen_settings_load_failed), findsNothing);
    expect(
      find.text(t.second_screen_settings_context(title: 'Reader')),
      findsOneWidget,
    );
  });
}
