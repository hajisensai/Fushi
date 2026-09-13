import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-2380：`AnkiSettings.canMineCards` 是「这套配置真能制出卡吗」的**唯一判据**，
/// 新手引导的下一步与设置页/引导页的连接后自检共用它。
///
/// 判据必须与制卡时 `BaseAnkiRepository.preflightNoteFields` 同源：Anki 的
/// `fields_check()` 只看笔记类型的第一个字段，它空了就拒收整张卡。
///
/// 反面同样重要：不能拿「是不是 Lapis」当合格线，否则自己配好笔记类型的用户会被
/// 反复劝去建 Lapis。
void main() {
  const AnkiNoteType lapis = AnkiNoteType(
    id: 7,
    name: 'Lapis',
    fields: ['Expression', 'MainDefinition', 'Sentence'],
  );
  const AnkiNoteType basic = AnkiNoteType(
    id: 8,
    name: '基础',
    fields: ['正面', '背面'],
  );
  const AnkiDeck lapisDeck = AnkiDeck(id: 1, name: 'Lapis');
  const AnkiDeck userDeck = AnkiDeck(id: 2, name: '日语');

  AnkiSettings settings({
    int? deckId = 1,
    String? deckName = 'Lapis',
    int? noteTypeId = 7,
    String? noteTypeName = 'Lapis',
    List<AnkiDeck> decks = const [lapisDeck, userDeck],
    List<AnkiNoteType> noteTypes = const [lapis, basic],
    Map<String, String> mappings = const {'Expression': '{expression}'},
  }) =>
      AnkiSettings(
        selectedDeckId: deckId,
        selectedDeckName: deckName,
        selectedNoteTypeId: noteTypeId,
        selectedNoteTypeName: noteTypeName,
        availableDecks: decks,
        availableNoteTypes: noteTypes,
        fieldMappings: mappings,
      );

  test('首字段接了模板 → 能制卡', () {
    expect(settings().canMineCards, isTrue);
  });

  test('没配过（两个 id 都空）→ 不能制卡', () {
    expect(
      settings(
        deckId: null,
        deckName: null,
        noteTypeId: null,
        noteTypeName: null,
      ).canMineCards,
      isFalse,
    );
  });

  test('首字段没被映射 → 不能制卡（Anki 会以「卡片为空」拒收）', () {
    // 映射存在，但落在**非首**字段上；Anki 的 fields_check 只看首字段。
    expect(
      settings(mappings: const {'Sentence': '{sentence}'}).canMineCards,
      isFalse,
    );
  });

  test('首字段映射是空白串 → 不能制卡', () {
    expect(
      settings(mappings: const {'Expression': '   '}).canMineCards,
      isFalse,
    );
  });

  test('字段映射整个为空 → 不能制卡', () {
    expect(settings(mappings: const {}).canMineCards, isFalse);
  });

  test('选中的牌组已经不在 Anki 里（用户在 Anki 端删了它）→ 不能制卡', () {
    expect(settings(decks: const [userDeck]).canMineCards, isFalse);
  });

  test('牌组清单为空（这次没拉到 / 没连上）→ 无从判断，不拦', () {
    expect(settings(decks: const []).canMineCards, isTrue);
  });

  // 关键的反面：不是 Lapis 也照样合格。拿 Lapis 当唯一合格线，会把自己配好
  // 笔记类型的用户也弹一遍窗。
  test('用户自己的笔记类型，只要首字段接了模板就算合格', () {
    expect(
      settings(
        deckId: 2,
        deckName: '日语',
        noteTypeId: 8,
        noteTypeName: '基础',
        mappings: const {'正面': '{expression}'},
      ).canMineCards,
      isTrue,
    );
  });

  // 用户报的原始故障形态：牌组被静默换成自己的「日语」、笔记类型是「基础」，
  // 而字段映射还是按 Lapis 的字段名排的 —— 一个都对不上，首字段恒空。
  test('BUG-2380 Lapis 字段映射套在别人的笔记类型上 → 不能制卡', () {
    expect(
      settings(
        deckId: 2,
        deckName: '日语',
        noteTypeId: 8,
        noteTypeName: '基础',
        mappings: const {
          'Expression': '{expression}',
          'MainDefinition': '{meaning}',
        },
      ).canMineCards,
      isFalse,
    );
  });

  test('后端没报出字段表 → 无从预检，不拦（与 preflightNoteFields 同一放行）', () {
    expect(
      settings(
        noteTypeId: 9,
        noteTypeName: '无字段',
        noteTypes: const [AnkiNoteType(id: 9, name: '无字段', fields: [])],
        mappings: const {},
      ).canMineCards,
      isTrue,
    );
  });
}
