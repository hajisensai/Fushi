// BUG-4698 / issue #3494：单卡编辑页的卡型开关互斥，与批量「设置卡型」同一语义。
import 'package:fushi_engine/srs/srs_note_batch_edit.dart';
import 'package:test/test.dart';

void main() {
  test('打开一个卡型开关会清空其余三个', () {
    expect(srsCardTypeFlagToggle('IsAudioCard', on: true), <String, String>{
      'IsSentenceCard': '',
      'IsWordAndSentenceCard': '',
      'IsClickCard': '',
      'IsAudioCard': kSrsCardTypeFlagOn,
    });
  });

  test('关掉开关只清空它自己，不动老数据里同时开着的其它开关', () {
    expect(srsCardTypeFlagToggle('IsSentenceCard', on: false), <String, String>{
      'IsSentenceCard': '',
    });
  });

  test('打开后的结果与批量设卡型写入的开关一致', () {
    for (final SrsCardType type in SrsCardType.values) {
      final String? flag = type.flagField;
      if (flag == null) continue;
      expect(srsCardTypeFlagToggle(flag, on: true), <String, String>{
        for (final String f in kSrsCardTypeFlagFields)
          f: f == flag ? kSrsCardTypeFlagOn : '',
      });
    }
  });

  test('不是卡型开关的字段不改', () {
    expect(srsCardTypeFlagToggle('Sentence', on: true), isEmpty);
  });
}
