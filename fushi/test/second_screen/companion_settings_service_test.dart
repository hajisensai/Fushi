import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart' show CtlBodyPage;
import 'package:fushi/src/ops/settings_index.dart';
import 'package:fushi/src/second_screen/companion/companion_bridge.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_settings_service.dart';
import 'package:fushi/src/second_screen/companion/modules/settings_companion_schema.dart';
import 'package:fushi/src/second_screen/second_screen_controller.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi_cli/fushi_cli.dart' show CtlFailure;
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'fake_second_screen_platform.dart';

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());
}

/// A small schema: reading (quick-panel rows, a slider, a choice, a text row,
/// a disabled switch, a drawn row without a title, a sub-page with a
/// stepper), video, and a hidden category.
class _Schema {
  final Map<String, Object> values = <String, Object>{
    'vertical': false,
    'size': 22.0,
    'mode': 'paginated',
    'font': 'Noto',
    'locked': false,
    'speed': 1.0,
    'subs': true,
    'hidden': true,
  };
  final List<String> writes = <String>[];

  Future<void> _write(String key, Object value) async {
    values[key] = value;
    writes.add('$key=$value');
  }

  List<SettingsDestination> build(SettingsContext _) => <SettingsDestination>[
    SettingsDestination(
      id: SettingsDestinationId.reading,
      title: 'Reading',
      icon: Icons.book,
      sections: <SettingsSection>[
        SettingsSection(
          title: 'Layout',
          items: <SettingsItem>[
            SettingsSwitchItem(
              id: 'reading.vertical',
              title: 'Vertical text',
              reader: const ReaderPlacement(
                group: ReaderGroup.layout,
                order: 0,
              ),
              value: (SettingsContext _) => values['vertical']! as bool,
              onChanged: (SettingsContext _, bool v) => _write('vertical', v),
            ),
            SettingsSliderItem(
              id: 'reading.size',
              title: 'Font size',
              reader: const ReaderPlacement(
                group: ReaderGroup.layout,
                order: 0,
              ),
              min: 10,
              max: 40,
              divisions: 30,
              label: (double v) => v.round().toString(),
              value: (SettingsContext _) => values['size']! as double,
              onChanged: (SettingsContext _, double v) => _write('size', v),
            ),
            SettingsSegmentedItem<String>(
              id: 'reading.mode',
              title: 'View mode',
              reader: const ReaderPlacement(
                group: ReaderGroup.layout,
                order: 0,
              ),
              options: const <SettingsSegmentOption<String>>[
                SettingsSegmentOption<String>(
                  value: 'paginated',
                  label: 'Paginated',
                ),
                SettingsSegmentOption<String>(
                  value: 'continuous',
                  label: 'Continuous',
                ),
                SettingsSegmentOption<String>(value: 'vn', label: 'VN'),
              ],
              selected: (SettingsContext _) => values['mode']! as String,
              onChanged: (SettingsContext _, String v) => _write('mode', v),
            ),
            SettingsTextItem(
              id: 'reading.font',
              title: 'Reader font',
              reader: const ReaderPlacement(
                group: ReaderGroup.layout,
                order: 0,
              ),
              value: (SettingsContext _) => values['font']! as String,
              onChanged: (SettingsContext _, String v) => _write('font', v),
            ),
            SettingsSwitchItem(
              id: 'reading.locked',
              title: 'Locked option',
              enabled: (SettingsContext _) => false,
              value: (SettingsContext _) => values['locked']! as bool,
              onChanged: (SettingsContext _, bool v) => _write('locked', v),
            ),
            SettingsCustomItem(
              id: 'reading.drawn',
              builder: (SettingsContext _) => const SizedBox.shrink(),
            ),
            SettingsSwitchItem(
              id: 'reading.invisible',
              title: 'Not on this device',
              visible: (SettingsContext _) => false,
              value: (SettingsContext _) => values['hidden']! as bool,
              onChanged: (SettingsContext _, bool v) => _write('hidden', v),
            ),
            SettingsNavigationItem(
              id: 'reading.listening',
              title: 'Listening',
              child: () => SettingsDestination(
                id: SettingsDestinationId.reading,
                title: 'Listening',
                icon: Icons.headphones,
                sections: <SettingsSection>[
                  SettingsSection(
                    title: 'Playback',
                    items: <SettingsItem>[
                      SettingsStepperItem(
                        id: 'listening.speed',
                        title: 'Speed',
                        reader: const ReaderPlacement(
                          group: ReaderGroup.audiobook,
                          order: 0,
                        ),
                        step: 0.1,
                        min: 0.5,
                        max: 3,
                        format: (double v) => '${v.toStringAsFixed(1)}x',
                        value: (SettingsContext _) =>
                            values['speed']! as double,
                        onChanged: (SettingsContext _, double v) =>
                            _write('speed', v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
    SettingsDestination(
      id: SettingsDestinationId.video,
      title: 'Video',
      icon: Icons.movie,
      sections: <SettingsSection>[
        SettingsSection(
          items: <SettingsItem>[
            SettingsSwitchItem(
              id: 'video.subs',
              title: 'Subtitles',
              value: (SettingsContext _) => values['subs']! as bool,
              onChanged: (SettingsContext _, bool v) => _write('subs', v),
            ),
          ],
        ),
      ],
    ),
    SettingsDestination(
      id: SettingsDestinationId.game,
      title: 'Games',
      icon: Icons.games,
      visible: (SettingsContext _) => false,
      sections: const <SettingsSection>[],
    ),
  ];
}

class _Fixture {
  _Fixture(this.settingsContext, this.schema);

  final SettingsContext settingsContext;
  final _Schema schema;
  CompanionContext top = CompanionContext.none;
  final List<String> opened = <String>[];

  late final CompanionSettingsService service = CompanionSettingsService(
    settingsContext: () => settingsContext,
    currentContext: () => top,
    destinations: schema.build,
    bodyPages: const <CtlBodyPage>[],
    open:
        (
          SettingsContext _, {
          SettingsSearchEntry? entry,
          SettingsDestination? destination,
        }) {
          opened.add(
            entry != null
                ? 'row:${entry.item.id}:${entry.subPagePath.length}'
                : 'category:${destination!.id.name}',
          );
        },
  );
}

Future<_Fixture> _pump(WidgetTester tester) async {
  late SettingsContext ctx;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            ctx = SettingsContext(
              context: context,
              appModel: _TestAppModel(),
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return _Fixture(ctx, _Schema());
}

List<String> _keys(Iterable<CompanionSettingRow> rows) => <String>[
  for (final CompanionSettingRow r in rows) r.key,
];

void main() {
  group('context → settings category', () {
    test('media, libraries and settings pages map to their category', () {
      SettingsDestinationId? of(CompanionContext c) =>
          companionSettingsCategoryFor(c);
      expect(
        of(const CompanionContext(CompanionContextKind.reader)),
        SettingsDestinationId.reading,
      );
      expect(
        of(const CompanionContext(CompanionContextKind.audiobook)),
        SettingsDestinationId.reading,
      );
      expect(
        of(const CompanionContext(CompanionContextKind.manga)),
        SettingsDestinationId.manga,
      );
      expect(
        of(const CompanionContext(CompanionContextKind.video)),
        SettingsDestinationId.video,
      );
      expect(
        of(const CompanionContext(CompanionContextKind.music)),
        SettingsDestinationId.music,
      );
      expect(
        of(const CompanionContext(CompanionContextKind.srs)),
        SettingsDestinationId.cardCreation,
      );
      expect(
        of(
          const CompanionContext(
            CompanionContextKind.library,
            library: CompanionLibraryKind.games,
          ),
        ),
        SettingsDestinationId.game,
      );
      expect(
        of(
          const CompanionContext(
            CompanionContextKind.settings,
            settingsCategory: 'lookup',
          ),
        ),
        SettingsDestinationId.lookup,
      );
      expect(of(const CompanionContext(CompanionContextKind.settings)), isNull);
      expect(of(const CompanionContext(CompanionContextKind.home)), isNull);
      expect(of(CompanionContext.none), isNull);
      expect(
        of(const CompanionContext(CompanionContextKind.gameStream)),
        isNull,
      );
    });

    test('the settings home tab names the category of its detail pane', () {
      final ValueNotifier<HomeTab> tab = ValueNotifier<HomeTab>(
        HomeTab.settings,
      );
      final ValueNotifier<String?> category = ValueNotifier<String?>(null);
      final CompanionContextRegistry registry = CompanionContextRegistry(
        homeTab: tab,
        settingsHomeCategory: category,
      );
      addTearDown(() {
        registry.dispose();
        tab.dispose();
        category.dispose();
      });
      expect(
        registry.current,
        const CompanionContext(CompanionContextKind.settings),
      );
      category.value = 'video';
      expect(
        registry.current,
        const CompanionContext(
          CompanionContextKind.settings,
          settingsCategory: 'video',
        ),
      );
      tab.value = HomeTab.books;
      expect(registry.current.kind, CompanionContextKind.library);
    });
  });

  group('shared index', () {
    testWidgets('records the category and the place inside it', (
      WidgetTester tester,
    ) async {
      final _Fixture f = await _pump(tester);
      final Map<String, SettingsIndexEntry> index = buildSettingsIndex(
        f.settingsContext,
        destinations: f.schema.build(f.settingsContext),
        bodyPages: const <CtlBodyPage>[],
      );
      expect(
        index['reading.size']!.destinationId,
        SettingsDestinationId.reading,
      );
      expect(index['reading.size']!.pagePath, 'Layout');
      expect(
        index['listening.speed']!.pagePath,
        'Layout › Listening › Playback',
      );
      expect(
        index['listening.speed']!.breadcrumb,
        'Reading › Layout › Listening › Playback',
      );
      expect(index['video.subs']!.pagePath, isNull);
      expect(index['reading.invisible']!.visible, isFalse);
    });
  });

  group('service', () {
    testWidgets(
      'overview: the reader quick settings first, visible categories',
      (WidgetTester tester) async {
        final _Fixture f = await _pump(tester);
        f.top = const CompanionContext(
          CompanionContextKind.reader,
          title: 'Book',
        );
        final CompanionSettingsOverview o = f.service.overview();
        expect(o.context!.category!.id, 'reading');
        expect(o.context!.category!.title, 'Reading');
        // Quick-panel rows of the reader, without the audiobook group.
        expect(_keys(o.context!.rows), <String>[
          'reading.vertical',
          'reading.size',
          'reading.mode',
          'reading.font',
        ]);
        expect(
          <String>[
            for (final CompanionSettingsCategory c in o.categories) c.id,
          ],
          <String>['reading', 'video'],
        );

        f.top = const CompanionContext(CompanionContextKind.audiobook);
        expect(_keys(f.service.overview().context!.rows), <String>[
          'listening.speed',
        ]);

        // Not a reader: the category's first page.
        f.top = const CompanionContext(
          CompanionContextKind.library,
          library: CompanionLibraryKind.video,
        );
        expect(_keys(f.service.overview().context!.rows), <String>[
          'video.subs',
        ]);

        f.top = const CompanionContext(CompanionContextKind.home);
        expect(f.service.overview().context, isNull);
        // A category hidden on this device has no section.
        f.top = const CompanionContext(
          CompanionContextKind.library,
          library: CompanionLibraryKind.games,
        );
        expect(f.service.overview().context, isNull);
      },
    );

    testWidgets('rows: controls, values, labels, ranges, enabled', (
      WidgetTester tester,
    ) async {
      final _Fixture f = await _pump(tester);
      final CompanionSettingsPage page = f.service.category('reading');
      final Map<String, CompanionSettingRow> rows =
          <String, CompanionSettingRow>{
            for (final CompanionSettingRow r in page.rows) r.key: r,
          };
      // Hidden rows and drawn rows without a title are not listed.
      expect(rows.keys, <String>[
        'reading.vertical',
        'reading.size',
        'reading.mode',
        'reading.font',
        'reading.locked',
        'listening.speed',
      ]);
      expect(rows['reading.vertical']!.control, CompanionSettingControl.toggle);
      expect(rows['reading.vertical']!.value, false);
      final CompanionSettingRow size = rows['reading.size']!;
      expect(size.control, CompanionSettingControl.slider);
      expect(size.value, 22.0);
      expect(size.display, '22');
      expect(size.min, 10);
      expect(size.max, 40);
      expect(size.divisions, 30);
      final CompanionSettingRow mode = rows['reading.mode']!;
      expect(mode.control, CompanionSettingControl.choice);
      expect(mode.value, 'paginated');
      expect(mode.display, 'Paginated');
      expect(mode.options, const <CompanionSettingOption>[
        CompanionSettingOption(value: 'paginated', label: 'Paginated'),
        CompanionSettingOption(value: 'continuous', label: 'Continuous'),
        CompanionSettingOption(value: 'vn', label: 'VN'),
      ]);
      final CompanionSettingRow font = rows['reading.font']!;
      expect(font.control, CompanionSettingControl.open);
      expect(font.value, isNull);
      expect(font.display, 'Noto');
      expect(rows['reading.locked']!.enabled, isFalse);
      final CompanionSettingRow speed = rows['listening.speed']!;
      expect(speed.control, CompanionSettingControl.stepper);
      expect(speed.step, 0.1);
      expect(speed.display, '1.0x');
      expect(speed.section, 'Layout › Listening › Playback');
      expect(page.category!.title, 'Reading');

      // JSON round trip (what crosses to the panel).
      final CompanionSettingsPage back = CompanionSettingsPage.fromJson(
        page.toJson(),
      );
      expect(back.rows.length, page.rows.length);
      expect(back.rows[2].options, mode.options);
      expect(back.rows[4].enabled, isFalse);

      expect(
        () => f.service.category('game'),
        throwsA(isA<CtlFailure>()),
        reason: 'hidden category',
      );
    });

    testWidgets('search ranks titles and leads sections with the category', (
      WidgetTester tester,
    ) async {
      final _Fixture f = await _pump(tester);
      final CompanionSettingsPage hits = f.service.search('speed');
      expect(_keys(hits.rows), <String>['listening.speed']);
      expect(
        hits.rows.single.section,
        'Reading › Layout › Listening › Playback',
      );
      expect(hits.category, isNull);
      expect(f.service.search('not on this device').rows, isEmpty);
    });

    testWidgets('set writes through the row setter and echoes the stored '
        'value; only direct, enabled rows', (WidgetTester tester) async {
      final _Fixture f = await _pump(tester);
      expect((await f.service.set('reading.vertical', 'true')).value, true);
      expect((await f.service.set('reading.mode', 'vn')).display, 'VN');
      expect((await f.service.set('reading.size', '30')).value, 30.0);
      expect((await f.service.set('listening.speed', '1.5')).display, '1.5x');
      expect(f.schema.writes, <String>[
        'vertical=true',
        'mode=vn',
        'size=30.0',
        'speed=1.5',
      ]);
      await expectLater(
        f.service.set('reading.font', 'Other'),
        throwsA(isA<CtlFailure>()),
      );
      await expectLater(
        f.service.set('reading.locked', 'true'),
        throwsA(isA<CtlFailure>()),
      );
      await expectLater(
        f.service.set('reading.invisible', 'false'),
        throwsA(isA<CtlFailure>()),
      );
      await expectLater(
        f.service.set('reading.size', '99'),
        throwsA(isA<CtlFailure>()),
        reason: 'out of range, same check as fushi_cli',
      );
      expect(f.schema.writes, hasLength(4));
    });

    testWidgets('openOnMain: a row (with its sub-page path) or a category', (
      WidgetTester tester,
    ) async {
      final _Fixture f = await _pump(tester);
      f.service.openOnMain(key: 'reading.font');
      f.service.openOnMain(key: 'listening.speed');
      f.service.openOnMain(category: 'video');
      expect(f.opened, <String>[
        'row:reading.font:0',
        'row:listening.speed:1',
        'category:video',
      ]);
      expect(
        () => f.service.openOnMain(key: 'reading.invisible'),
        throwsA(isA<CtlFailure>()),
      );
      expect(() => f.service.openOnMain(), throwsA(isA<CtlFailure>()));
    });
  });

  group('bridge methods', () {
    late Directory spill;

    setUp(() async {
      spill = await Directory.systemTemp.createTemp('companion_settings');
    });

    tearDown(() async {
      if (spill.existsSync()) await spill.delete(recursive: true);
    });

    testWidgets('list / get / set / openOnMain answer over the pipe; a write '
        'pings settingsChanged', (WidgetTester tester) async {
      final _Fixture f = await _pump(tester);
      final Map<String, Object?> prefs = <String, Object?>{
        kSecondScreenModePrefKey: SecondScreenMode.always.name,
      };
      final FakeSecondScreenPlatform platform = FakeSecondScreenPlatform(
        displays: <SecondScreenDisplayInfo>[thorBottomScreen],
      );
      final SecondScreenHost host = SecondScreenHost(platform);
      final SecondScreenController controller = SecondScreenController(
        readPref: (String k) => prefs[k],
        writePref: (String k, Object? v) async => prefs[k] = v,
        host: host,
      );
      final CompanionContextRegistry contexts = CompanionContextRegistry();
      final CompanionBridge bridge = CompanionBridge(
        host: host,
        controller: controller,
        contexts: contexts,
        collectSummary: () async => const CompanionDailySummary(dayKey: 'd'),
        spillRoot: spill,
      );
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
        host.dispose();
        contexts.dispose();
      });
      registerCompanionSettingsHandlers(bridge, f.service);
      bridge.start();
      await tester.runAsync(controller.start);

      // The bridge listens in the test zone: microtasks run on pump.
      Future<void> settle() async {
        for (int i = 0; i < 10; i++) {
          await tester.pump();
        }
      }

      Future<Map<int, CompanionReplyMessage>> send(
        List<CompanionPanelMessage> messages,
      ) async {
        platform.sent.clear();
        for (final CompanionPanelMessage m in messages) {
          platform.emit(SecondScreenPanelMessageReceived(m.encode()));
        }
        await settle();
        return <int, CompanionReplyMessage>{
          for (final String raw in platform.sent)
            if (CompanionHostMessage.decode(raw)
                case final CompanionReplyMessage r)
              r.id: r,
        };
      }

      await send(<CompanionPanelMessage>[const CompanionReadyMessage()]);
      final Map<int, CompanionReplyMessage> replies = await send(
        <CompanionPanelMessage>[
          const CompanionRequestMessage(
            id: 1,
            method: CompanionRequestMethods.settingsList,
          ),
          const CompanionRequestMessage(
            id: 2,
            method: CompanionRequestMethods.settingsList,
            args: <String, Object?>{CompanionSettingsArgs.category: 'video'},
          ),
          const CompanionRequestMessage(
            id: 3,
            method: CompanionRequestMethods.settingsList,
            args: <String, Object?>{CompanionSettingsArgs.query: 'speed'},
          ),
          const CompanionRequestMessage(
            id: 4,
            method: CompanionRequestMethods.settingsGet,
            args: <String, Object?>{CompanionSettingsArgs.key: 'video.subs'},
          ),
          const CompanionRequestMessage(
            id: 5,
            method: CompanionRequestMethods.settingsOpenOnMain,
            args: <String, Object?>{CompanionSettingsArgs.category: 'reading'},
          ),
          const CompanionRequestMessage(
            id: 6,
            method: CompanionRequestMethods.settingsSet,
            args: <String, Object?>{CompanionSettingsArgs.key: 'nope'},
          ),
        ],
      );
      final CompanionSettingsOverview overview =
          CompanionSettingsOverview.fromJson(
            replies[1]!.value! as Map<String, Object?>,
          );
      expect(overview.context, isNull);
      expect(overview.categories, hasLength(2));
      expect(
        _keys(
          CompanionSettingsPage.fromJson(
            replies[2]!.value! as Map<String, Object?>,
          ).rows,
        ),
        <String>['video.subs'],
      );
      expect(
        _keys(
          CompanionSettingsPage.fromJson(
            replies[3]!.value! as Map<String, Object?>,
          ).rows,
        ),
        <String>['listening.speed'],
      );
      expect((replies[4]!.value! as Map<String, Object?>)['value'], true);
      expect(replies[5]!.error, isNull);
      expect(f.opened, <String>['category:reading']);
      expect(replies[6]!.error, isNotNull);

      platform.sent.clear();
      platform.emit(
        SecondScreenPanelMessageReceived(
          const CompanionRequestMessage(
            id: 7,
            method: CompanionRequestMethods.settingsSet,
            args: <String, Object?>{
              CompanionSettingsArgs.key: 'video.subs',
              CompanionSettingsArgs.value: false,
            },
          ).encode(),
        ),
      );
      await settle();
      final List<CompanionHostMessage> sent = <CompanionHostMessage>[
        for (final String raw in platform.sent)
          CompanionHostMessage.decode(raw),
      ];
      final CompanionReplyMessage reply = sent
          .whereType<CompanionReplyMessage>()
          .single;
      expect(reply.error, isNull);
      expect((reply.value! as Map<String, Object?>)['value'], false);
      expect(f.schema.writes, <String>['subs=false']);
      expect(sent.whereType<CompanionSettingsChangedMessage>(), hasLength(1));
    });
  });
}
