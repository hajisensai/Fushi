import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/language_binding.dart';

/// 语言级 Profile 绑定键归一化的契约。
///
/// 这个函数是「用户绑了 `ja`、书里写的是 `ja-JP`，绑定为什么不生效」这类静默
/// 失效的唯一防线：写入侧与查询侧都过它，两侧结果必须逐字相等。下面每条用例
/// 对应一种真实会进到 DB 列里的写法。
void main() {
  group('normalizeLanguageBinding', () {
    test('裸语言码原样保留（已是归一形态）', () {
      expect(normalizeLanguageBinding('ja'), 'ja');
      expect(normalizeLanguageBinding('en'), 'en');
      expect(normalizeLanguageBinding('zh'), 'zh');
    });

    test('丢弃 region 子标签——它不影响用哪套词典/牌组', () {
      expect(normalizeLanguageBinding('ja-JP'), 'ja');
      expect(normalizeLanguageBinding('en-US'), 'en');
      expect(normalizeLanguageBinding('en-GB'), 'en');
      expect(normalizeLanguageBinding('zh-CN'), 'zh');
      // 数字型 region（BCP-47 允许 3 位数字，如拉丁美洲 419）同样丢弃。
      expect(normalizeLanguageBinding('es-419'), 'es');
    });

    test('保留 script 子标签——简繁是两套配置，不能塌成一个键', () {
      expect(normalizeLanguageBinding('zh-Hans'), 'zh-Hans');
      expect(normalizeLanguageBinding('zh-Hant'), 'zh-Hant');
      expect(normalizeLanguageBinding('zh-Hans-CN'), 'zh-Hans');
      expect(normalizeLanguageBinding('zh-Hant-TW'), 'zh-Hant');
      expect(normalizeLanguageBinding('zh-Hant-HK'), 'zh-Hant');
    });

    test('大小写归一：语言小写、script 首字母大写', () {
      expect(normalizeLanguageBinding('JA'), 'ja');
      expect(normalizeLanguageBinding('Ja-Jp'), 'ja');
      expect(normalizeLanguageBinding('ZH-HANT-TW'), 'zh-Hant');
      expect(normalizeLanguageBinding('zh-hant'), 'zh-Hant');
    });

    test('下划线分隔（Java locale 风格）与连字符等价', () {
      expect(normalizeLanguageBinding('ja_JP'), 'ja');
      expect(normalizeLanguageBinding('zh_Hans_CN'), 'zh-Hans');
      expect(normalizeLanguageBinding('ZH_hant_tw'), 'zh-Hant');
    });

    test('前后空白不影响结果', () {
      expect(normalizeLanguageBinding('  ja  '), 'ja');
      expect(normalizeLanguageBinding('\tzh-Hant\n'), 'zh-Hant');
    });

    test('空 / null / 纯空白 → 空串（语言未知）', () {
      expect(normalizeLanguageBinding(null), '');
      expect(normalizeLanguageBinding(''), '');
      expect(normalizeLanguageBinding('   '), '');
      expect(normalizeLanguageBinding('-'), '');
      expect(normalizeLanguageBinding('--'), '');
    });

    test('und（BCP-47 未确定）等同于没标注，绝不成为伪语言键', () {
      expect(normalizeLanguageBinding('und'), '');
      expect(normalizeLanguageBinding('UND'), '');
      expect(normalizeLanguageBinding('und-JP'), '');
    });

    test('非法输入 → 空串，而不是一个垃圾键', () {
      expect(normalizeLanguageBinding('!!'), '');
      expect(normalizeLanguageBinding('123'), '');
      expect(normalizeLanguageBinding('j'), ''); // 单字母不是合法语言子标签
      expect(normalizeLanguageBinding('日本語'), '');
      expect(normalizeLanguageBinding('verylonglanguagetag'), ''); // >8 字母
    });

    test('三字母 ISO 639-3 语言码合法', () {
      expect(normalizeLanguageBinding('yue'), 'yue');
      expect(normalizeLanguageBinding('yue-Hant-HK'), 'yue-Hant');
    });

    test('幂等：归一结果再归一一次不变', () {
      const List<String> inputs = <String>[
        'ja-JP',
        'zh-Hant-TW',
        'EN_us',
        'yue-Hant-HK',
        'und',
        '!!',
      ];
      for (final String input in inputs) {
        final String once = normalizeLanguageBinding(input);
        expect(
          normalizeLanguageBinding(once),
          once,
          reason: '归一必须幂等，否则写入键与查询键会漂开：$input',
        );
      }
    });

    test('同语言的不同写法折叠到同一个键（本函数存在的理由）', () {
      final Set<String> japanese = <String>{
        normalizeLanguageBinding('ja'),
        normalizeLanguageBinding('ja-JP'),
        normalizeLanguageBinding('JA'),
        normalizeLanguageBinding('ja_jp'),
        normalizeLanguageBinding(' ja-JP '),
      };
      expect(japanese, <String>{'ja'});
    });
  });
}
