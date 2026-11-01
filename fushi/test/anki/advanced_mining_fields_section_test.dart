import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/advanced_mining_deck_section.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 反馈 -K86qlwBg6：「高级制卡」卡片字段分区的组装（字段映射 → 可编辑字段）。
void main() {
  const AnkiSettings settings = AnkiSettings(
    fieldMappings: <String, String>{
      'Expression': '{expression}',
      'Sentence': '{sentence}',
      'MainDefinition': '{glossary-first}',
      'Glossary': '{glossary}',
      'Hint': '',
    },
  );

  List<String> names(AdvancedMiningFieldsSection s) => <String>[
    for (final AdvancedMiningField f in s.fields) f.name,
  ];

  test('字段 = 映射里模板非空的字段（映射顺序），模板原样带上', () {
    final AdvancedMiningFieldsSection s = buildAdvancedMiningFieldsSection(
      settings,
    )!;
    expect(names(s), <String>[
      'Expression',
      'Sentence',
      'MainDefinition',
      'Glossary',
    ]);
    expect(s.fields[2].template, '{glossary-first}');
  });

  test('从没选过：默认显示释义类字段', () {
    final AdvancedMiningFieldsSection s = buildAdvancedMiningFieldsSection(
      settings,
    )!;
    expect(s.visibleFields, <String>{'MainDefinition', 'Glossary'});
  });

  test('记住的选择优先；映射里已不存在的名字丢掉；空列表 = 一个都不显示', () {
    expect(
      buildAdvancedMiningFieldsSection(
        settings,
        remembered: const <String>['Sentence', 'Gone'],
      )!.visibleFields,
      <String>{'Sentence'},
    );
    expect(
      buildAdvancedMiningFieldsSection(
        settings,
        remembered: const <String>[],
      )!.visibleFields,
      isEmpty,
    );
  });

  test('没配字段映射：没有这个分区', () {
    expect(buildAdvancedMiningFieldsSection(const AnkiSettings()), isNull);
  });
}
