import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_mining_target.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi_anki/fushi_anki.dart' show AnkiDeck;
import 'package:fushi_core/fushi_core.dart' show ProfileRow;
import 'package:material_ui/material_ui.dart';

/// 用户建议 #fiwDIpFep7：查词弹窗顶栏就地切换制卡目标（配置 / 牌组）。
void main() {
  ProfileRow profile(int id, String name) =>
      ProfileRow(id: id, name: name, createdAt: 0, updatedAt: 0);

  group('buildDictionaryPopupMiningTargetItems', () {
    test('配置一节 + 牌组一节，当前项打勾，节间有分隔', () {
      final List<PopupMenuEntry<DictionaryPopupMiningTarget>> items =
          buildDictionaryPopupMiningTargetItems(
            profiles: <ProfileRow>[profile(1, 'Default'), profile(2, 'Lapis')],
            activeProfileId: 2,
            decks: const <AnkiDeck>[
              AnkiDeck(id: 10, name: 'Mining'),
              AnkiDeck(id: 11, name: 'Audio'),
            ],
            selectedDeckId: 10,
          );
      final List<CheckedPopupMenuItem<DictionaryPopupMiningTarget>> checked =
          items
              .whereType<CheckedPopupMenuItem<DictionaryPopupMiningTarget>>()
              .toList();
      expect(
        checked
            .map(
              (CheckedPopupMenuItem<DictionaryPopupMiningTarget> i) => i.value,
            )
            .toList(),
        <DictionaryPopupMiningTarget>[
          const DictionaryPopupProfileTarget(1),
          const DictionaryPopupProfileTarget(2),
          const DictionaryPopupDeckTarget(AnkiDeck(id: 10, name: 'Mining')),
          const DictionaryPopupDeckTarget(AnkiDeck(id: 11, name: 'Audio')),
        ],
      );
      expect(
        checked
            .map(
              (CheckedPopupMenuItem<DictionaryPopupMiningTarget> i) =>
                  i.checked,
            )
            .toList(),
        <bool>[false, true, true, false],
      );
      expect(items.whereType<PopupMenuDivider>(), hasLength(1));
    });

    test('没有任何候选：只给一条不可点的提示，不弹空菜单', () {
      final List<PopupMenuEntry<DictionaryPopupMiningTarget>> items =
          buildDictionaryPopupMiningTargetItems(
            profiles: const <ProfileRow>[],
            activeProfileId: -1,
            decks: const <AnkiDeck>[],
            selectedDeckId: null,
          );
      expect(items, hasLength(1));
      final PopupMenuItem<DictionaryPopupMiningTarget> only =
          items.single as PopupMenuItem<DictionaryPopupMiningTarget>;
      expect(only.enabled, isFalse);
      expect((only.child! as Text).data, t.popup_mining_target_empty);
    });
  });

  Future<void> pumpLayer(
    WidgetTester tester, {
    required bool show,
    required double width,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 240,
                child: DictionaryPopupLayer(
                  result: null,
                  isSearching: false,
                  webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
                  headerWidget: const SizedBox(
                    key: Key('test-popup-header'),
                    width: 96,
                    height: 40,
                  ),
                  showMiningTargetSwitch: show,
                  onClose: () {},
                  onDismiss: () {},
                  onTextSelected: (String text, Rect rect) {},
                  onLinkClick: (String query, Rect rect) {},
                  onMineEntry: (Map<String, String> fields) async =>
                      const MinePopupResult(),
                  onDuplicateCheck: (String expression, String reading) async =>
                      false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final Finder button = find.byKey(
    const ValueKey<String>('popup_mining_target'),
  );

  testWidgets('制卡宿主的顶栏出现切换键，且不压到居中 header', (WidgetTester tester) async {
    for (final double width in <double>[
      kLookupPopupMinWidth,
      kDictionaryPopupTopBarCompactWidth + 40,
    ]) {
      await pumpLayer(tester, show: true, width: width);
      expect(tester.takeException(), isNull);
      expect(button, findsOneWidget, reason: 'width=$width');
      final Rect header = tester.getRect(
        find.byKey(const Key('test-popup-header')),
      );
      expect(
        tester.getRect(button).right,
        lessThanOrEqualTo(header.left + 0.5),
        reason: 'width=$width：左簇不得压到居中 header',
      );
    }
  });

  testWidgets('不制卡的层（默认）不出现切换键', (WidgetTester tester) async {
    await pumpLayer(tester, show: false, width: 400);
    expect(button, findsNothing);
  });
}
