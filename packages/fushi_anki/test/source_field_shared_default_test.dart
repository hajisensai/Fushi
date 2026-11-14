import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 反馈 GNiu1BuCKw：视频制卡要把（清洗后的）文件名和时间点写进 MiscInfo。
///
/// Lapis / Fushi 卡片 / Senren 预设的 MiscInfo（来源）早就是「标题回跳链接 + 片段
/// 时间窗」，但任意笔记类型的按名默认映射只认 `Source` 且只给 `{source-link}`、完全
/// 不认 `MiscInfo`——那些笔记类型的视频卡拿不到时间点。这里钉住：所有来源字段默认值
/// 都引用同一个 [FushiCardFields.sourceDefaultMapping]，且视频卡渲染出标题 + 时间。
void main() {
  test('共用值本身：标题回跳链接 + 片段时间窗', () {
    expect(
      FushiCardFields.sourceDefaultMapping,
      '{source-link} {clip-timestamp}',
    );
  });

  test('内置预设的来源字段都是同一份共用值', () {
    expect(
      LapisNoteType.defaultFieldMappings['MiscInfo'],
      FushiCardFields.sourceDefaultMapping,
    );
    expect(
      FushiCardNoteType.defaultFieldMappings[FushiCardFields.source],
      FushiCardFields.sourceDefaultMapping,
    );
    expect(
      SenrenPreset.defaultFieldMappings['miscInfo'],
      FushiCardFields.sourceDefaultMapping,
    );
  });

  group('任意笔记类型的按名默认映射', () {
    test('带 MiscInfo 字段的非预设笔记类型：MiscInfo 拿到共用值', () {
      const AnkiNoteType custom = AnkiNoteType(
        id: 41,
        name: 'My Mining Note',
        fields: <String>['Word', 'Meaning', 'Sentence', 'MiscInfo'],
      );
      expect(
        noteTypeDefaultMappings(custom)['MiscInfo'],
        FushiCardFields.sourceDefaultMapping,
      );
    });

    test('Source / 中日韩「来源」类字段同样拿到共用值（含片段时间）', () {
      for (final String field in <String>[
        'Source',
        'misc_info',
        '来源',
        '來源',
        '出处',
        '出處',
        '出典',
        '출처',
      ]) {
        final AnkiNoteType t = AnkiNoteType(
          id: 42,
          name: 'Custom',
          fields: <String>['Word', 'Meaning', field],
        );
        expect(
          noteTypeDefaultMappings(t)[field],
          FushiCardFields.sourceDefaultMapping,
          reason: field,
        );
      }
    });

    test('同时有 Source 与 MiscInfo：只给第一个，不往两个字段灌同一份来源', () {
      const AnkiNoteType both = AnkiNoteType(
        id: 43,
        name: 'Custom',
        fields: <String>['Word', 'Meaning', 'Source', 'MiscInfo'],
      );
      final Map<String, String> m = noteTypeDefaultMappings(both);
      expect(m['Source'], FushiCardFields.sourceDefaultMapping);
      expect(m.containsKey('MiscInfo'), isFalse);
    });
  });

  test('存量设置迁移的目标就是共用值', () {
    final String upgraded = BaseAnkiRepository.upgradeMiscInfoMapping(
      '{"fieldMappings":{"MiscInfo":"{document-title}"}}',
    )!;
    expect(
      upgraded,
      contains('"MiscInfo":"${FushiCardFields.sourceDefaultMapping}"'),
    );
  });

  test('视频卡按共用值渲染出标题与片段时间点', () {
    const AnkiMiningContext video = AnkiMiningContext(
      sentence: '例文',
      documentTitle: 'Frieren - 01',
      clipStartMs: 83 * 1000 + 250,
      clipEndMs: 86 * 1000,
    );
    expect(
      AnkiHandlebarRenderer.render(
        FushiCardFields.sourceDefaultMapping,
        const AnkiMiningPayload(expression: 'word'),
        video,
      ),
      'Frieren - 01 00:01:23 - 00:01:26',
    );
  });
}
