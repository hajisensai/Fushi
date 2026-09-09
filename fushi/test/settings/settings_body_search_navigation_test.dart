import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_expansion_state.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/settings/settings_section_container.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

const String _targetId = 'fixture.account.endpoint';
const String _sectionId = 'fixture.account.advanced';

class _RendererPage extends ConsumerWidget {
  const _RendererPage({
    required this.destination,
    required this.appModel,
    this.onContext,
  });

  final SettingsDestination destination;
  final AppModel appModel;
  final ValueChanged<SettingsContext>? onContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SettingsContext settingsContext = SettingsContext(
      context: context,
      appModel: appModel,
      ref: ref,
      readerSource: ReaderFushiSource.instance,
      refresh: () {},
    );
    onContext?.call(settingsContext);
    return const MaterialSettingsRenderer().buildDetailPage(
      settingsContext: settingsContext,
      destination: destination,
    );
  }
}

void main() {
  setUp(() {
    SettingsSearchReveal.pendingItemId = null;
    SharedPreferences.setMockInitialValues(<String, Object>{
      '${SettingsExpansionState.keyPrefix}$_sectionId': false,
    });
  });
  tearDown(() => SettingsSearchReveal.pendingItemId = null);

  for (final int depth in <int>[1, 2]) {
    testWidgets(
      'body search traverses $depth subpages, reveals collapsed real row without saving expansion',
      (WidgetTester tester) async {
        final SharedPreferences preferences =
            await SharedPreferences.getInstance();
        final SettingsExpansionState expansion = SettingsExpansionState();
        await expansion.load();
        final AppModel appModel = AppModel(testPlatformServices());
        final SettingsDestination leaf = SettingsDestination(
          id: SettingsDestinationId.services,
          title: 'Account configuration',
          icon: Icons.settings,
          sections: const <SettingsSection>[],
          bodySearchEntries: <SettingsBodySearchEntry>[
            const SettingsBodySearchEntry(
              id: _targetId,
              title: 'Fixture endpoint',
              hasRevealTarget: true,
            ),
            SettingsBodySearchEntry(
              id: 'fixture.hidden',
              title: 'Hidden credential',
              hasRevealTarget: true,
              visible: (_) => false,
            ),
          ],
          body: (_) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(
                height: 1400,
                child: Text('Configuration introduction'),
              ),
              SettingsSectionContainer(
                id: _sectionId,
                title: 'Advanced account settings',
                presentation: SettingsSectionPresentation.collapsed,
                expansionState: expansion,
                searchTargetIds: const <String>[_targetId],
                children: const <Widget>[
                  SettingsSearchTarget(
                    id: _targetId,
                    child: SizedBox(
                      height: 48,
                      child: Text(
                        'Fixture endpoint',
                        key: ValueKey<String>(_targetId),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
        final List<SettingsNavigationItem> expectedPath =
            <SettingsNavigationItem>[];
        SettingsDestination root = leaf;
        for (int level = depth; level > 0; level--) {
          final SettingsDestination child = root;
          final SettingsNavigationItem hop = SettingsNavigationItem(
            id: 'fixture.level.$level',
            title: 'Configure level $level',
            child: () => child,
          );
          expectedPath.insert(0, hop);
          root = SettingsDestination(
            id: SettingsDestinationId.services,
            title: 'Level $level',
            icon: Icons.folder,
            sections: <SettingsSection>[
              SettingsSection(
                id: 'fixture.level.$level.section',
                items: <SettingsItem>[hop],
              ),
            ],
          );
        }
        late SettingsContext settingsContext;
        final GlobalKey<NavigatorState> navigatorKey =
            GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              home: _RendererPage(
                destination: root,
                appModel: appModel,
                onContext: (SettingsContext value) => settingsContext = value,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final List<SettingsSearchEntry> index = flattenVisibleSettings(
          <SettingsDestination>[root],
          settingsContext,
        );
        expect(
          index.any(
            (SettingsSearchEntry entry) => entry.item.id == 'fixture.hidden',
          ),
          isFalse,
        );
        final SettingsSearchEntry entry = filterSettingsEntries(
          index,
          'Fixture endpoint',
        ).single;
        expect(entry.destination, same(root));
        expect(entry.subPagePath, expectedPath);
        expect(entry.isBodyEntry, isTrue);
        expect(entry.hasRevealTarget, isTrue);
        expect(find.byKey(const ValueKey<String>(_targetId)), findsNothing);

        // Use the indexed route chain and production body renderer together.
        // The real row consumes the same pending slot as SettingsHomePage uses.
        SettingsSearchReveal.pendingItemId = entry.hasRevealTarget
            ? entry.item.id
            : null;
        for (final SettingsNavigationItem hop in entry.subPagePath) {
          navigatorKey.currentState!.push<void>(
            MaterialPageRoute<void>(
              builder: (_) =>
                  _RendererPage(destination: hop.child!(), appModel: appModel),
            ),
          );
          await tester.pumpAndSettle();
        }
        final Finder target = find.byKey(const ValueKey<String>(_targetId));
        expect(target, findsOneWidget);
        expect(
          SettingsSearchReveal.pendingItemId,
          isNull,
          reason: 'The body target must consume the reveal request',
        );
        final Rect bounds = tester.getRect(target);
        final Size viewport =
            tester.view.physicalSize / tester.view.devicePixelRatio;
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.bottom, lessThanOrEqualTo(viewport.height));
        expect(
          Scrollable.of(tester.element(target)).position.pixels,
          greaterThan(0),
          reason: 'The target began more than one viewport below the fold',
        );
        expect(expansion.value(_sectionId, defaultValue: true), isFalse);
        expect(preferences.getKeys(), <String>{
          '${SettingsExpansionState.keyPrefix}$_sectionId',
        });
        expect(
          preferences.getBool('${SettingsExpansionState.keyPrefix}$_sectionId'),
          isFalse,
          reason: 'Search expansion must never persist as a manual preference',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expansion.dispose();
      },
    );
  }
}
