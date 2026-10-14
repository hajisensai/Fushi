import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/advanced_mining_deck_section.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 「高级制卡」卡组分区的组装：可选卡组按名字排序，默认卡组与后端
/// `resolveSelectedDeck` 同口径（id 优先、名字兜底）。
void main() {
  const List<AnkiDeck> decks = <AnkiDeck>[
    AnkiDeck(id: 3, name: 'Mining::Video'),
    AnkiDeck(id: 1, name: 'Default'),
    AnkiDeck(id: 2, name: 'Mining::Novel'),
  ];

  test('卡组名按名字排序，默认卡组按 id 解析', () {
    final AdvancedMiningDeckSection section = buildAdvancedMiningDeckSection(
      const AnkiSettings(availableDecks: decks, selectedDeckId: 2),
    );
    expect(section.decks, <String>[
      'Default',
      'Mining::Novel',
      'Mining::Video',
    ]);
    expect(section.defaultDeckName, 'Mining::Novel');
    expect(section.setDefaultDeck, isNull);
  });

  test('id 对不上时按名字兜底；都对不上时退回存档里的名字', () {
    expect(
      buildAdvancedMiningDeckSection(
        const AnkiSettings(
          availableDecks: decks,
          selectedDeckId: 99,
          selectedDeckName: 'Mining::Video',
        ),
      ).defaultDeckName,
      'Mining::Video',
    );
    expect(
      buildAdvancedMiningDeckSection(
        const AnkiSettings(
          availableDecks: decks,
          selectedDeckId: 99,
          selectedDeckName: 'Renamed',
        ),
      ).defaultDeckName,
      'Renamed',
    );
  });

  test('没连过 Anki：卡组列表为空、默认卡组为 null', () {
    final AdvancedMiningDeckSection section = buildAdvancedMiningDeckSection(
      const AnkiSettings(),
    );
    expect(section.decks, isEmpty);
    expect(section.defaultDeckName, isNull);
  });

  test('setDefaultDeck 原样挂上', () async {
    final List<String> written = <String>[];
    final AdvancedMiningDeckSection section = buildAdvancedMiningDeckSection(
      const AnkiSettings(availableDecks: decks),
      setDefaultDeck: (String name) async => written.add(name),
    );
    await section.setDefaultDeck!('Default');
    expect(written, <String>['Default']);
  });
}
