import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 片段时间窗占位符 `{clip-timestamp}`：卡片底部「Misc. info → === Details ===」
/// 栏此前只有媒体名，卡片攒多了回溯不到原片位置。时间窗本就躺在
/// `ImmersionMiningRequest.clipStartMs|clipEndMs` 里（与音频裁剪同源），这里锁定
/// 它渲染成人类可读区间、以及「没有时间窗就不渲染」这条负向语义。
void main() {
  const AnkiMiningPayload payload = AnkiMiningPayload(expression: '言葉');

  AnkiMiningContext contextWithClip(int? startMs, int? endMs) =>
      AnkiMiningContext(
        sentence: 'これは言葉です。',
        documentTitle: 'Initial.D.Third.Stage',
        clipStartMs: startMs,
        clipEndMs: endMs,
      );

  String render(String template, AnkiMiningContext ctx) =>
      AnkiHandlebarRenderer.render(template, payload, ctx);

  group('AnkiHandlebarRenderer {clip-timestamp}', () {
    test('渲染成 HH:MM:SS - HH:MM:SS 区间', () {
      expect(
        render('{clip-timestamp}', contextWithClip(754000, 758000)),
        '00:12:34 - 00:12:38',
      );
    });

    test('小时/分/秒各自补零，跨小时不进位丢失', () {
      // 1h02m03s = 3723000ms，1h02m09s = 3729000ms
      expect(
        render('{clip-timestamp}', contextWithClip(3723000, 3729000)),
        '01:02:03 - 01:02:09',
      );
      // 超过 10 小时也照常（不做 12 小时制、不截断小时位）
      expect(
        render('{clip-timestamp}', contextWithClip(36000000, 36061000)),
        '10:00:00 - 10:01:01',
      );
    });

    test('毫秒截断到秒（不四舍五入，与片段起点语义一致）', () {
      expect(
        render('{clip-timestamp}', contextWithClip(1999, 2999)),
        '00:00:01 - 00:00:02',
      );
    });

    test('片段从 0 秒开头也照常渲染（start==0 不是「没有时间窗」）', () {
      expect(
        render('{clip-timestamp}', contextWithClip(0, 4000)),
        '00:00:00 - 00:00:04',
      );
    });

    test('无时间轴来源（书 / galgame，两端 null）→ 空串', () {
      expect(render('{clip-timestamp}', contextWithClip(null, null)), '');
      expect(render('{clip-timestamp}', contextWithClip(754000, null)), '');
      expect(render('{clip-timestamp}', contextWithClip(null, 758000)), '');
    });

    test('取不到 cue 的兜底 0/0 → 空串，不产出 00:00:00 - 00:00:00 伪信息', () {
      expect(
        render('{clip-timestamp}', contextWithClip(0, 0)),
        '',
        reason: '视频侧 _resolveVideoMiningRange 取不到 cue 时兜底成 0/0',
      );
    });

    test('end <= start 的无效窗 → 空串（唯一有效性判据，与 hasRange 同语义）', () {
      expect(render('{clip-timestamp}', contextWithClip(758000, 754000)), '');
      expect(render('{clip-timestamp}', contextWithClip(754000, 754000)), '');
    });

    test('formatClipTimestamp 是纯函数，可脱离 context 直接用', () {
      expect(
        AnkiHandlebarRenderer.formatClipTimestamp(754000, 758000),
        '00:12:34 - 00:12:38',
      );
      expect(AnkiHandlebarRenderer.formatClipTimestamp(null, 1), '');
    });
  });

  group('AnkiHandlebarOptions.coreOptions', () {
    test('含 {clip-timestamp}，用户能在字段映射选择器里选到它', () {
      expect(AnkiHandlebarOptions.coreOptions, contains('{clip-timestamp}'));
    });

    test('不是弃用别名（正常出现在候选里）', () {
      expect(
        AnkiHandlebarOptions.deprecatedAliases,
        isNot(contains('{clip-timestamp}')),
      );
    });
  });

  group('Lapis 出厂默认 MiscInfo', () {
    test('同时带媒体名与片段时间窗', () {
      final String mapping = LapisNoteType.defaultFieldMappings['MiscInfo']!;
      expect(mapping, contains('{document-title}'));
      expect(mapping, contains('{clip-timestamp}'));
    });

    test('整体渲染出「媒体名 时间窗」，一个字段里两个占位符照常展开', () {
      final String mapping = LapisNoteType.defaultFieldMappings['MiscInfo']!;
      expect(
        render(mapping, contextWithClip(754000, 758000)),
        'Initial.D.Third.Stage 00:12:34 - 00:12:38',
      );
    });

    test('无时间轴来源时只剩媒体名（不留 00:00:00 尾巴）', () {
      final String mapping = LapisNoteType.defaultFieldMappings['MiscInfo']!;
      final String value = render(mapping, contextWithClip(null, null));
      expect(value.trim(), 'Initial.D.Third.Stage');
      expect(value, isNot(contains(':')));
    });
  });

  group('BaseAnkiRepository 载入期迁移：MiscInfo 补上片段时间', () {
    String settingsJson(Map<String, String> mappings) =>
        jsonEncode(<String, dynamic>{
          'selectedDeckName': 'Lapis',
          'fieldMappings': mappings,
          'tags': '',
        });

    Map<String, String>? mappingsOf(String? raw) {
      if (raw == null) return null;
      final Map<String, dynamic> decoded =
          jsonDecode(raw) as Map<String, dynamic>;
      return Map<String, String>.from(decoded['fieldMappings'] as Map);
    }

    test('恰好是旧出厂默认 → 补成新出厂默认', () {
      final String? upgraded = BaseAnkiRepository.upgradeMiscInfoMapping(
        settingsJson(<String, String>{
          'Expression': '{expression}',
          'MiscInfo': '{document-title}',
        }),
      );
      expect(upgraded, isNotNull);
      expect(
        mappingsOf(upgraded)!['MiscInfo'],
        LapisNoteType.defaultFieldMappings['MiscInfo'],
      );
      // 其余映射一个字都不动。
      expect(mappingsOf(upgraded)!['Expression'], '{expression}');
    });

    test('迁移幂等：改写过的串再进来不再改（返回 null = 无需回写）', () {
      final String once = BaseAnkiRepository.upgradeMiscInfoMapping(
        settingsJson(<String, String>{'MiscInfo': '{document-title}'}),
      )!;
      expect(BaseAnkiRepository.upgradeMiscInfoMapping(once), isNull);
    });

    test('用户改过的值一律不动（清空 / 换占位符 / 自拼组合）', () {
      for (final String userValue in <String>[
        '',
        '{expression}',
        '{document-title} 出自',
        '{clip-timestamp}',
      ]) {
        expect(
          BaseAnkiRepository.upgradeMiscInfoMapping(
            settingsJson(<String, String>{'MiscInfo': userValue}),
          ),
          isNull,
          reason: '用户自己设过的 "$userValue" 被覆盖 = 吞掉用户意图',
        );
      }
    });

    test('没有 MiscInfo 映射 / 没有 fieldMappings → 不改', () {
      expect(
        BaseAnkiRepository.upgradeMiscInfoMapping(
          settingsJson(<String, String>{'Expression': '{expression}'}),
        ),
        isNull,
      );
      expect(
        BaseAnkiRepository.upgradeMiscInfoMapping(
          jsonEncode(<String, dynamic>{'tags': ''}),
        ),
        isNull,
      );
    });

    test('串损坏 → 返回 null 而非抛（诊断留给 loadSettings 的既有 try-catch）', () {
      expect(BaseAnkiRepository.upgradeMiscInfoMapping('not json'), isNull);
      expect(BaseAnkiRepository.upgradeMiscInfoMapping('[1,2,3]'), isNull);
      expect(BaseAnkiRepository.upgradeMiscInfoMapping(''), isNull);
    });
  });
}
