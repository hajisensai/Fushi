import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/font_preview/system_font_catalog.dart';

void main() {
  group('parseSystemFontChannelResult', () {
    test('读 {family, supportsJapanese} 契约，去重并排序', () {
      final List<SystemFontFamily> parsed = parseSystemFontChannelResult(
        <Object?>[
          <String, Object?>{'family': 'Yu Mincho', 'supportsJapanese': true},
          <String, Object?>{'family': 'Arial', 'supportsJapanese': false},
          <String, Object?>{'family': 'arial', 'supportsJapanese': false},
          <String, Object?>{'family': 'MS Gothic', 'supportsJapanese': true},
        ],
      );
      expect(parsed, const <SystemFontFamily>[
        SystemFontFamily(family: 'Arial', supportsJapanese: false),
        SystemFontFamily(family: 'MS Gothic', supportsJapanese: true),
        SystemFontFamily(family: 'Yu Mincho', supportsJapanese: true),
      ]);
    });

    test('兼容旧宿主的裸字符串列表，日文支持记为未知', () {
      expect(
        parseSystemFontChannelResult(<Object?>['sans-serif', 'serif']),
        const <SystemFontFamily>[
          SystemFontFamily(family: 'sans-serif'),
          SystemFontFamily(family: 'serif'),
        ],
      );
    });

    test('丢弃空名、竖排别名族与非法项', () {
      expect(
        parseSystemFontChannelResult(<Object?>[
          '',
          '  ',
          '@MS Gothic',
          42,
          null,
          <String, Object?>{'family': 7},
          <String, Object?>{'family': ' Meiryo '},
        ]),
        const <SystemFontFamily>[SystemFontFamily(family: 'Meiryo')],
      );
      expect(parseSystemFontChannelResult(null), isEmpty);
      expect(parseSystemFontChannelResult('oops'), isEmpty);
    });
  });

  test('fc-list 输出一行多别名时取首个规范名', () {
    expect(
      parseFcListFamilies(
        'Noto Sans CJK JP,Noto Sans CJK JP Regular\n'
        'DejaVu Sans\n'
        '\n'
        'noto sans cjk jp\n'
        'IPAexMincho,IPAex明朝\n',
      ),
      <String>['Noto Sans CJK JP', 'DejaVu Sans', 'IPAexMincho'],
    );
  });

  test('按文件名推族名只作兜底：去样式后缀', () {
    expect(guessFontFamilyFromFileName('/f/KleeOne-Regular.ttf'), 'KleeOne');
    expect(
      guessFontFamilyFromFileName(r'C:\Windows\Fonts\Noto_Serif_JP-Bold.otf'),
      'Noto Serif JP',
    );
  });

  group('SystemFontCatalog.load', () {
    tearDown(SystemFontCatalog.debugReset);

    test('成功结果进程内缓存，空结果不缓存', () async {
      int calls = 0;
      SystemFontCatalog.debugLoaderOverride = () async {
        calls++;
        return calls == 1
            ? SystemFontList.empty
            : const SystemFontList(
                families: <SystemFontFamily>[
                  SystemFontFamily(family: 'Meiryo', supportsJapanese: true),
                ],
                namesReliable: true,
              );
      };
      expect((await SystemFontCatalog.load()).families, isEmpty);
      expect((await SystemFontCatalog.load()).families, hasLength(1));
      expect((await SystemFontCatalog.load()).families, hasLength(1));
      expect(calls, 2);
    });
  });
}
