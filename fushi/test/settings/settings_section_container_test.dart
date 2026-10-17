import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_expansion_state.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/settings/settings_section_container.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../integration_test/helpers/focus_driver.dart';

Widget section(
  SettingsExpansionState state,
  String id, {
  SettingsSectionPresentation presentation =
      SettingsSectionPresentation.collapsed,
}) => SettingsSectionContainer(
  key: ValueKey<String>(id),
  id: id,
  title: 'Header $id',
  summary: 'Summary $id',
  presentation: presentation,
  searchTargetIds: <String>['$id.target'],
  expansionState: state,
  children: <Widget>[Text('Body $id')],
);

Future<void> showSections(WidgetTester tester, List<Widget> sections) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: Column(children: sections)),
        ),
      ),
    );

Future<void> toggleHeader(WidgetTester tester, String id) async {
  final FocusDriver driver = FocusDriver(tester);
  final Finder header = find
      .ancestor(
        of: find.text('Header $id'),
        matching: find.byType(AdaptiveSettingsSurface),
      )
      .first;
  expect(await driver.focusWidget(header), isTrue);
  await driver.activate();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsSearchReveal.pendingItemId = null;
  });
  tearDown(() => SettingsSearchReveal.pendingItemId = null);

  testWidgets('default presentations and always-expanded header contract', (
    WidgetTester tester,
  ) async {
    final SettingsExpansionState state = SettingsExpansionState();
    await showSections(tester, <Widget>[
      section(state, 'closed'),
      section(
        state,
        'open',
        presentation: SettingsSectionPresentation.expanded,
      ),
      section(
        state,
        'fixed',
        presentation: SettingsSectionPresentation.alwaysExpanded,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Body closed'), findsNothing);
    expect(find.text('Body open'), findsOneWidget);
    expect(find.text('Body fixed'), findsOneWidget);
    // MD3 分段分组（Android 16 设置）下，不可折叠分组的标题画在分段卡上方，
    // 不再是某个 AdaptiveSettingsSurface 的内嵌标题头；契约不变：标题与正文所在
    // 的任何分组面都不提供折叠入口。
    final Iterable<AdaptiveSettingsSurface> fixedSurfaces = tester
        .widgetList<AdaptiveSettingsSurface>(
          find.ancestor(
            of: find.text('Header fixed'),
            matching: find.byType(AdaptiveSettingsSurface),
          ),
        )
        .followedBy(
          tester.widgetList<AdaptiveSettingsSurface>(
            find.ancestor(
              of: find.text('Body fixed'),
              matching: find.byType(AdaptiveSettingsSurface),
            ),
          ),
        );
    expect(fixedSurfaces, isNotEmpty);
    expect(
      fixedSurfaces.every(
        (AdaptiveSettingsSurface surface) => surface.onTitleTap == null,
      ),
      isTrue,
      reason: 'Core settings cannot be collapsed',
    );
    await toggleHeader(tester, 'closed');
    expect(find.text('Body closed'), findsOneWidget);
    expect(find.text('Body open'), findsOneWidget);
    await toggleHeader(tester, 'open');
    expect(find.text('Body open'), findsNothing);
    expect(find.text('Body closed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('recreated section and store restore user expansion', (
    WidgetTester tester,
  ) async {
    final SettingsExpansionState first = SettingsExpansionState();
    await showSections(tester, <Widget>[section(first, 'advanced')]);
    await tester.pumpAndSettle();
    await toggleHeader(tester, 'advanced');
    await tester.pumpWidget(const SizedBox.shrink());
    first.dispose();
    final SettingsExpansionState restored = SettingsExpansionState();
    await showSections(tester, <Widget>[section(restored, 'advanced')]);
    await tester.pumpAndSettle();
    expect(find.text('Body advanced'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    restored.dispose();
  });

  testWidgets(
    'search expands temporarily and repeated search reopens after manual collapse',
    (WidgetTester tester) async {
      final SettingsExpansionState state = SettingsExpansionState();
      await state.setExpanded('advanced', false);
      await showSections(tester, <Widget>[
        section(state, 'advanced'),
        section(state, 'other'),
      ]);
      await tester.pumpAndSettle();
      SettingsSearchReveal.pendingItemId = 'advanced.target';
      await showSections(tester, <Widget>[
        section(state, 'advanced'),
        section(state, 'other'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Body advanced'), findsOneWidget);
      expect(find.text('Body other'), findsNothing);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          '${SettingsExpansionState.keyPrefix}advanced',
        ),
        isFalse,
      );
      SettingsSearchReveal.pendingItemId = null;
      await toggleHeader(tester, 'advanced');
      expect(find.text('Body advanced'), findsNothing);
      SettingsSearchReveal.pendingItemId = 'advanced.target';
      await showSections(tester, <Widget>[section(state, 'advanced')]);
      await tester.pumpAndSettle();
      expect(find.text('Body advanced'), findsOneWidget);
      expect(state.value('advanced', defaultValue: true), isFalse);
      SettingsSearchReveal.pendingItemId = null;
      await tester.pumpWidget(const SizedBox.shrink());
      await showSections(tester, <Widget>[section(state, 'advanced')]);
      await tester.pumpAndSettle();
      expect(
        find.text('Body advanced'),
        findsNothing,
        reason: 'Leaving the page ends temporary search expansion',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
