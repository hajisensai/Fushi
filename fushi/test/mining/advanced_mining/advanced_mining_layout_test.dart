import 'package:test/test.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_layout.dart';

/// 「高级制卡」分区布局的纯逻辑（反馈 aZ99bm9R6K）：默认布局、按栏取分区、
/// 子序列重排、存档解析的容错。
void main() {
  const AdvancedMiningPanelId deck = AdvancedMiningPanelId.deck;
  const AdvancedMiningPanelId fields = AdvancedMiningPanelId.fields;
  const AdvancedMiningPanelId wordAudio = AdvancedMiningPanelId.wordAudio;
  const AdvancedMiningPanelId audio = AdvancedMiningPanelId.sentenceAudio;
  const AdvancedMiningPanelId image = AdvancedMiningPanelId.image;
  final Set<AdvancedMiningPanelId> all = AdvancedMiningPanelId.values.toSet();

  List<AdvancedMiningPanelId> ids(AdvancedMiningLayout l) =>
      <AdvancedMiningPanelId>[
        for (final AdvancedMiningPanelSlot s in l.slots) s.id,
      ];

  group('默认布局', () {
    test('句子音频在左栏，其余在右栏（反馈：右栏太挤、左栏下方空着）', () {
      final AdvancedMiningLayout l = AdvancedMiningLayout.defaults;
      expect(
        l.visible(all, column: AdvancedMiningColumn.left),
        <AdvancedMiningPanelId>[audio],
      );
      expect(
        l.visible(all, column: AdvancedMiningColumn.right),
        <AdvancedMiningPanelId>[deck, fields, wordAudio, image],
      );
      expect(l.isDefault, isTrue);
    });

    test('每个分区恰好一次', () {
      expect(ids(AdvancedMiningLayout.defaults).toSet(), all);
      expect(AdvancedMiningLayout.defaults.slots, hasLength(all.length));
    });
  });

  group('按页面实际分区取', () {
    test('只取页面有的、未隐藏的分区，保持布局顺序', () {
      final AdvancedMiningLayout l = AdvancedMiningLayout.defaults.withHidden(
        fields,
        true,
      );
      expect(
        l.visible(<AdvancedMiningPanelId>{deck, fields, audio}),
        <AdvancedMiningPanelId>[deck, audio],
      );
      // 编辑器的行：含隐藏的。
      expect(
        <AdvancedMiningPanelId>[
          for (final AdvancedMiningPanelSlot s in l.slotsAmong(
            <AdvancedMiningPanelId>{deck, fields, audio},
          ))
            s.id,
        ],
        <AdvancedMiningPanelId>[deck, fields, audio],
      );
    });

    test('改栏位 / 显隐返回新布局，不改原值', () {
      final AdvancedMiningLayout base = AdvancedMiningLayout.defaults;
      final AdvancedMiningLayout moved = base.withColumn(
        audio,
        AdvancedMiningColumn.right,
      );
      expect(base.slotOf(audio).column, AdvancedMiningColumn.left);
      expect(moved.slotOf(audio).column, AdvancedMiningColumn.right);
      expect(moved.isDefault, isFalse);
      expect(moved.withColumn(audio, AdvancedMiningColumn.left), base);
    });
  });

  group('子序列重排', () {
    test('页面没有的分区原位不动', () {
      // 页面只有卡组 / 句子音频 / 图片；把图片（第 2 个）拖到最前。
      final Set<AdvancedMiningPanelId> present = <AdvancedMiningPanelId>{
        deck,
        audio,
        image,
      };
      final AdvancedMiningLayout l = AdvancedMiningLayout.defaults.reorderAmong(
        present,
        2,
        0,
      );
      expect(ids(l), <AdvancedMiningPanelId>[
        image,
        fields,
        wordAudio,
        deck,
        audio,
      ]);
      expect(l.visible(present), <AdvancedMiningPanelId>[image, deck, audio]);
    });

    test('越界 / 原地不动：原样返回', () {
      final AdvancedMiningLayout l = AdvancedMiningLayout.defaults;
      expect(identical(l.reorderAmong(all, 1, 1), l), isTrue);
      expect(identical(l.reorderAmong(all, -1, 0), l), isTrue);
      expect(identical(l.reorderAmong(all, 0, 9), l), isTrue);
    });
  });

  group('存档', () {
    test('往返一致', () {
      final AdvancedMiningLayout l = AdvancedMiningLayout.defaults
          .reorderAmong(all, 4, 0)
          .withColumn(deck, AdvancedMiningColumn.left)
          .withHidden(wordAudio, true);
      expect(AdvancedMiningLayout.tryParse(l.toJson()), l);
    });

    test('空 / 坏值返回 null（调用方用默认）', () {
      expect(AdvancedMiningLayout.tryParse(null), isNull);
      expect(AdvancedMiningLayout.tryParse(''), isNull);
      expect(AdvancedMiningLayout.tryParse('{oops'), isNull);
      expect(AdvancedMiningLayout.tryParse('[1,2]'), isNull);
      expect(AdvancedMiningLayout.tryParse('{"slots":3}'), isNull);
    });

    test('未知 id 丢弃、重复 id 去重、缺的分区按默认补在末尾、未知栏位按默认', () {
      final AdvancedMiningLayout? l = AdvancedMiningLayout.tryParse(
        '{"v":1,"slots":['
        '{"id":"image","col":"left","hidden":true},'
        '{"id":"future_panel","col":"left"},'
        '{"id":"image","col":"right"},'
        '{"id":"sentence_audio","col":"middle"},'
        '7'
        ']}',
      );
      expect(l, isNotNull);
      expect(ids(l!), <AdvancedMiningPanelId>[
        image,
        audio,
        deck,
        fields,
        wordAudio,
      ]);
      expect(l.slotOf(image).column, AdvancedMiningColumn.left);
      expect(l.slotOf(image).hidden, isTrue);
      expect(l.slotOf(audio).column, AdvancedMiningColumn.left);
      expect(l.slotOf(deck).column, AdvancedMiningColumn.right);
      expect(l.slotOf(deck).hidden, isFalse);
    });

    test('wire 名冻结', () {
      expect(
        <String>[
          for (final AdvancedMiningPanelId id in AdvancedMiningPanelId.values)
            id.wireName,
        ],
        <String>['deck', 'fields', 'word_audio', 'sentence_audio', 'image'],
      );
    });
  });
}
