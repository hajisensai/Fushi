import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_text_process.dart';

GalTextProcessStep _step(
  GalTextProcessKind kind, {
  int? repeatCount,
  int lineCount = 1,
  bool fromEnd = false,
  String pattern = '',
  String replacement = '',
  bool isRegex = true,
}) => GalTextProcessStep(
  id: kind.storageKey,
  kind: kind,
  repeatCount: repeatCount,
  lineCount: lineCount,
  fromEnd: fromEnd,
  pattern: pattern,
  replacement: replacement,
  isRegex: isRegex,
);

String _apply(GalTextProcessKind kind, String text, {int? repeatCount}) =>
    applyGalTextProcessStep(text, _step(kind, repeatCount: repeatCount));

void main() {
  group('去重复类（断言用 LunaTranslator 文档给出的原样示例）', () {
    test('去除重复字符 AAAABBBBCCCC -> ABC', () {
      expect(dedupeGalTextChars('AAAABBBBCCCC', null), 'ABC');
    });

    test('重复次数不成统一倍数时原样返回，不写坏本来就叠字的台词', () {
      // 「ああ」是真台词里的叠字：游程 [2,1,1] 的 gcd 为 1，不该被压。
      expect(dedupeGalTextChars('ああそう', null), 'ああそう');
      // 「ああそう」被每字绘制 3 次：游程 [6,3,3] 的 gcd 为 3，叠字还原成两个而不是一个。
      expect(dedupeGalTextChars('ああああああそそそううう', null), 'ああそう');
      // 全文只有一个游程时无从区分「重复 6 次的あ」与「重复 3 次的ああ」，按最大倍数压。
      expect(dedupeGalTextChars('ああああああ', null), 'あ');
    });

    test('自动分析取最常见的游程长度：只画了一遍的标点不再让整步失效', () {
      // 游程 [3,3,1]：旧的 gcd 判据得 1、原样返回；按众数取 3（同 LunaTranslator）。
      expect(dedupeGalTextChars('恵恵恵麻麻麻。', null), '恵麻。');
      expect(
        dedupeGalTextChars('恵恵恵麻麻麻さささんんんははは……', null),
        '恵麻さんは……',
      );
      // 游程 [6,3,1] 各出现一次打平：1 让位，取其余最小的 3。
      expect(dedupeGalTextChars('ああああああそそそ。', null), 'ああそ。');
      // 多数字只出现一次（众数是 1）→ 真台词，原样返回。
      expect(dedupeGalTextChars('ああああああそそそ。、', null), 'ああああああそそそ。、');
    });

    test('显式给定重复次数时只压整除的游程', () {
      expect(dedupeGalTextChars('AAAABBBBCC', 4), 'ABCC');
      expect(dedupeGalTextChars('AAAA', 1), 'AAAA');
    });

    test('去除整块重复 ABCDABCDABCD -> ABCD', () {
      expect(dedupeGalTextBlock('ABCDABCDABCD', null), 'ABCD');
      expect(dedupeGalTextBlock('ABCDABCDABCD', 3), 'ABCD');
      // 份数对不上时不动。
      expect(dedupeGalTextBlock('ABCDABCDABCD', 5), 'ABCDABCDABCD');
      expect(dedupeGalTextBlock('ABCDE', null), 'ABCDE');
    });

    test('去除连续重复行 S1S1S1S2S2S2 -> S1S2', () {
      expect(dedupeGalTextLines('S1\nS1\nS1\nS2\nS2\nS2'), 'S1\nS2');
      // 不连续的相同行不折叠（A B A 是真的来回对话）。
      expect(dedupeGalTextLines('A\nB\nA'), 'A\nB\nA');
      // 单行时退化为整串最小周期折叠。
      expect(dedupeGalTextLines('やあやあ'), 'やあ');
    });

    test('去除递减子串 ABCDBCDCDD -> ABCD', () {
      expect(dedupeGalTextDescending('ABCDBCDCDD'), 'ABCD');
      expect(dedupeGalTextDescending('ABCD\nBCD\nCD\nD'), 'ABCD');
      expect(dedupeGalTextDescending('ふつうの文'), 'ふつうの文');
    });

    test('去除逐字绘制递增子串 AABABCABCD -> ABCD', () {
      expect(dedupeGalTextAscending('AABABCABCD'), 'ABCD');
      expect(dedupeGalTextAscending('A\nAB\nABC\nABCD'), 'ABCD');
      expect(dedupeGalTextAscending('ふつうの文'), 'ふつうの文');
    });

    test('三角数长度但拼不回去的文本不动', () {
      // 长度 10 能反解出 n=4，但重建结果对不上原文 → 不是绘制伪影。
      expect(dedupeGalTextAscending('あいうえおかきくけこ'), 'あいうえおかきくけこ');
      expect(dedupeGalTextDescending('あいうえおかきくけこ'), 'あいうえおかきくけこ');
    });
  });

  group('过滤类', () {
    test('过滤控制字符但不动换行与制表', () {
      expect(
        _apply(GalTextProcessKind.filterControlChars, 'あいう\nえ\tお'),
        'あいう\nえ\tお',
      );
    });

    test('过滤非日语字符集字符', () {
      // 韩文/泰文/emoji 不在 CP932 里，日文与 ASCII 留下。
      expect(
        _apply(GalTextProcessKind.filterNonJapanese, '안녕あいうABC①※'),
        'あいうABC①※',
      );
    });

    test('过滤英文标点', () {
      expect(
        _apply(GalTextProcessKind.filterAsciiPunctuation, 'a,b.c!「あ」。'),
        'abc「あ」。',
      );
    });

    test('去掉「」外的文字（保留「」本身）；没有「」的旁白原样保留', () {
      // LunaTranslator 文档原例。
      expect(
        _apply(GalTextProcessKind.keepJapaneseQuotes, 'こなみ「ひとめぼれってやつだよね……」'),
        '「ひとめぼれってやつだよね……」',
      );
      expect(
        _apply(GalTextProcessKind.keepJapaneseQuotes, '彼は言った「おはよう」と。'),
        '「おはよう」',
      );
      expect(
        _apply(GalTextProcessKind.keepJapaneseQuotes, '「あ」つなぎ「い」'),
        '「あ」「い」',
      );
      // 回归：旧实现把旁白处理成空串，整行被丢弃。
      expect(
        _apply(GalTextProcessKind.keepJapaneseQuotes, 'ただの地の文'),
        'ただの地の文',
      );
    });

    test('去除花括号注音：斜杠 / 冒号留基字，成对标签留中间，其余整体删', () {
      expect(
        _apply(GalTextProcessKind.stripCurlyBraces, '{漢字/かんじ}を{r}読む'),
        '漢字を読む',
      );
      // LunaTranslator 文档原例（两种分隔符）。
      expect(
        _apply(GalTextProcessKind.stripCurlyBraces, '「{恵麻/えま}さん、まだ{起き/おき}てる？」'),
        '「恵麻さん、まだ起きてる？」',
      );
      expect(
        _apply(GalTextProcessKind.stripCurlyBraces, '「{恵麻:えま}さん、まだ{起き:おき}てる？」'),
        '「恵麻さん、まだ起きてる？」',
      );
      expect(
        _apply(GalTextProcessKind.stripCurlyBraces, '{color=red}赤い{/color}花'),
        '赤い花',
      );
    });

    test('过滤尖括号标签', () {
      expect(
        _apply(GalTextProcessKind.stripAngleBrackets, '<ruby>あ</ruby>い'),
        'あい',
      );
    });

    test('过滤数字与英文字母（含全角）', () {
      expect(
        _apply(GalTextProcessKind.filterDigits, '第３章 no.12 あ'),
        '第章 no. あ',
      );
      expect(_apply(GalTextProcessKind.filterLatinLetters, 'aあＢい'), 'あい');
    });

    test('过滤换行符可替换成指定字符串', () {
      expect(
        applyGalTextProcessStep(
          'あ\nい\r\nう',
          _step(GalTextProcessKind.filterLineBreaks),
        ),
        'あいう',
      );
      expect(
        applyGalTextProcessStep(
          'あ\nい',
          _step(GalTextProcessKind.filterLineBreaks, replacement: ' '),
        ),
        'あ い',
      );
      // 空行先丢再拼：不会拼出两个连续的替换物。
      expect(
        applyGalTextProcessStep(
          'あ\n\nい\n',
          _step(GalTextProcessKind.filterLineBreaks, replacement: ' '),
        ),
        'あ い',
      );
    });

    test('截取指定行数，可从末尾取', () {
      expect(
        applyGalTextProcessStep(
          '1\n2\n3\n4',
          _step(GalTextProcessKind.takeLines, lineCount: 2),
        ),
        '1\n2',
      );
      expect(
        applyGalTextProcessStep(
          '1\n2\n3\n4',
          _step(GalTextProcessKind.takeLines, lineCount: 2, fromEnd: true),
        ),
        '3\n4',
      );
    });
  });

  group('全角/半角正规化', () {
    test('全角 ASCII 与全角空格转半角', () {
      expect(normalizeGalTextWidth('ＡＢＣ　１２３'), 'ABC 123');
    });

    test('半角片假名转全角，浊点/半浊点被合成', () {
      expect(normalizeGalTextWidth('ｱｲｳ'), 'アイウ');
      expect(normalizeGalTextWidth('ｶﾞｷﾞ'), 'ガギ');
      expect(normalizeGalTextWidth('ﾊﾟﾋﾟ'), 'パピ');
      expect(normalizeGalTextWidth('ｳﾞ'), 'ヴ');
      // 孤立的浊点没有可合成的前字时原样保留。
      expect(normalizeGalTextWidth('ｱﾟ'), 'ア゜');
    });

    test('本来就是全角的日文不动', () {
      expect(normalizeGalTextWidth('あいうアイウ漢字'), 'あいうアイウ漢字');
    });
  });

  group('替换步骤', () {
    test('正则替换', () {
      expect(
        applyGalTextProcessStep(
          'あ123い',
          _step(GalTextProcessKind.replace, pattern: r'\d+', replacement: '#'),
        ),
        'あ#い',
      );
    });

    test('关掉正则时按字面替换', () {
      expect(
        applyGalTextProcessStep(
          r'a.c abc',
          _step(
            GalTextProcessKind.replace,
            pattern: 'a.c',
            replacement: 'X',
            isRegex: false,
          ),
        ),
        'X abc',
      );
    });

    test('正则写坏时保持原文，不把整行吞掉', () {
      expect(tryCompileGalTextPattern('('), isNull);
      expect(
        applyGalTextProcessStep(
          'あいう',
          _step(GalTextProcessKind.replace, pattern: '(', replacement: 'X'),
        ),
        'あいう',
      );
    });

    test('空匹配式是 no-op', () {
      expect(
        applyGalTextProcessStep(
          'あいう',
          _step(GalTextProcessKind.replace, replacement: 'X'),
        ),
        'あいう',
      );
    });
  });

  group('默认管线', () {
    test('列出除「字符串替换」外的全部步骤，各一步，id 即种类名', () {
      final List<GalTextProcessKind> kinds = kGalDefaultTextProcessPipeline.steps
          .map((GalTextProcessStep s) => s.kind)
          .toList();
      expect(
        kinds.toSet(),
        GalTextProcessKind.values.toSet()..remove(GalTextProcessKind.replace),
      );
      expect(kinds, hasLength(kinds.toSet().length));
      for (final GalTextProcessStep step in kGalDefaultTextProcessPipeline.steps) {
        expect(step.id, step.kind.storageKey);
      }
    });

    test('默认只开「去除花括号注音」与「过滤换行符」', () {
      expect(
        kGalDefaultTextProcessPipeline.steps
            .where((GalTextProcessStep s) => s.enabled)
            .map((GalTextProcessStep s) => s.kind),
        <GalTextProcessKind>[
          GalTextProcessKind.stripCurlyBraces,
          GalTextProcessKind.filterLineBreaks,
        ],
      );
    });

    test('默认管线不丢旁白、不改普通台词，只清注音花括号与换行', () {
      const GalTextProcessPipeline pipeline = kGalDefaultTextProcessPipeline;
      expect(pipeline.apply('ただの地の文'), 'ただの地の文');
      expect(pipeline.apply('こなみ「ねえねえ、ああ」'), 'こなみ「ねえねえ、ああ」');
      expect(
        pipeline.apply('「{恵麻/えま}さん、\nまだ{起き:おき}てる？」'),
        '「恵麻さん、まだ起きてる？」',
      );
    });

    test('新加一步沿用默认参数且启用：截取行数默认取末尾', () {
      final GalTextProcessStep take = defaultGalTextProcessStep(
        'takeLines#2',
        GalTextProcessKind.takeLines,
      );
      expect(take.id, 'takeLines#2');
      expect(take.enabled, isTrue);
      expect(take.fromEnd, isTrue);
      final GalTextProcessStep replace = defaultGalTextProcessStep(
        'replace',
        GalTextProcessKind.replace,
      );
      expect(replace.enabled, isTrue);
      expect(replace.isRegex, isTrue);
    });
  });

  group('管线', () {
    test('存档里某一步字段类型坏了只丢那一步，合法步骤原样读回', () {
      final GalTextProcessPipeline pipeline = GalTextProcessPipeline.fromJson(
        <Object?>[
          <String, Object?>{'id': 'filterDigits', 'kind': 'filterDigits'},
          <String, Object?>{'id': 'r', 'kind': 'replace', 'isRegex': 'true'},
          <String, Object?>{'id': 7, 'kind': 'filterLatinLetters'},
          <String, Object?>{
            'id': 'takeLines',
            'kind': 'takeLines',
            'lineCount': 2,
            'fromEnd': true,
            'enabled': false,
          },
        ],
      );
      expect(pipeline.steps.map((GalTextProcessStep s) => s.id), <String>[
        'filterDigits',
        'takeLines',
      ]);
      final GalTextProcessStep take = pipeline.steps.last;
      expect(take.lineCount, 2);
      expect(take.fromEnd, isTrue);
      expect(take.enabled, isFalse);
    });

    test('合法存档经 toJson/fromJson 往返不变', () {
      final GalTextProcessPipeline original = GalTextProcessPipeline(
        steps: <GalTextProcessStep>[
          const GalTextProcessStep(
            id: 'replace',
            kind: GalTextProcessKind.replace,
            pattern: 'a+',
            replacement: 'b',
            isRegex: false,
          ),
          const GalTextProcessStep(
            id: 'takeLines',
            kind: GalTextProcessKind.takeLines,
            lineCount: 3,
            fromEnd: true,
            enabled: false,
          ),
        ],
      );
      expect(
        GalTextProcessPipeline.fromJson(original.toJson()).steps,
        original.steps,
      );
    });

    test('空管线是恒等变换', () {
      const GalTextProcessPipeline empty = GalTextProcessPipeline();
      expect(empty.isEmpty, isTrue);
      expect(empty.apply('あいう'), 'あいう');
    });

    test('全部步骤 disabled 也算空管线', () {
      final GalTextProcessPipeline pipeline = GalTextProcessPipeline(
        steps: <GalTextProcessStep>[
          _step(GalTextProcessKind.filterDigits).copyWith(enabled: false),
        ],
      );
      expect(pipeline.isEmpty, isTrue);
      expect(pipeline.apply('あ1'), 'あ1');
    });

    test('按顺序执行，换序结果不同', () {
      final GalTextProcessStep keepQuotes = _step(
        GalTextProcessKind.keepJapaneseQuotes,
      );
      final GalTextProcessStep stripPunct = _step(
        GalTextProcessKind.filterAsciiPunctuation,
      );
      const String input = '"彼"は「おはよう」と言った';
      final String quotesFirst = GalTextProcessPipeline(
        steps: <GalTextProcessStep>[keepQuotes, stripPunct],
      ).apply(input);
      final String punctFirst = GalTextProcessPipeline(
        steps: <GalTextProcessStep>[stripPunct, keepQuotes],
      ).apply(input);
      expect(quotesFirst, '「おはよう」');
      expect(punctFirst, '「おはよう」');
      // 顺序真的会改结果的场景：先删数字就没有行可截了。
      final GalTextProcessStep take1 = _step(
        GalTextProcessKind.takeLines,
        lineCount: 1,
      );
      final GalTextProcessStep dropDigits = _step(
        GalTextProcessKind.filterDigits,
      );
      expect(
        GalTextProcessPipeline(
          steps: <GalTextProcessStep>[take1, dropDigits],
        ).apply('1\n2'),
        '',
      );
      expect(
        GalTextProcessPipeline(
          steps: <GalTextProcessStep>[dropDigits, take1],
        ).apply('1\n2'),
        '',
      );
    });

    test('run 的逐步留痕与 apply 的最终结果一致', () {
      final GalTextProcessPipeline pipeline = GalTextProcessPipeline(
        steps: <GalTextProcessStep>[
          _step(GalTextProcessKind.dedupeChars),
          _step(GalTextProcessKind.filterDigits),
          _step(
            GalTextProcessKind.filterAsciiPunctuation,
          ).copyWith(enabled: false),
        ],
      );
      const String input = 'AABB11';
      final GalTextProcessTrace trace = pipeline.run(input);
      expect(trace.output, pipeline.apply(input));
      expect(trace.steps, hasLength(3));
      expect(trace.steps.first.input, input);
      expect(trace.steps.first.changed, isTrue);
      // disabled 的一步留痕但不改文本。
      expect(trace.steps.last.changed, isFalse);
      expect(trace.changed, isTrue);
    });

    test('留痕标出「这一步清空了整行」', () {
      final GalTextProcessPipeline pipeline = GalTextProcessPipeline(
        steps: <GalTextProcessStep>[
          _step(GalTextProcessKind.replace, pattern: '.+'),
        ],
      );
      final GalTextProcessTrace trace = pipeline.run('ただの地の文');
      expect(trace.steps.single.emptied, isTrue);
      expect(trace.emptied, isTrue);
    });

    test('JSON 往返保留步骤、顺序、开关与参数', () {
      final GalTextProcessPipeline pipeline = GalTextProcessPipeline(
        steps: <GalTextProcessStep>[
          _step(GalTextProcessKind.dedupeChars, repeatCount: 3),
          _step(
            GalTextProcessKind.takeLines,
            lineCount: 2,
            fromEnd: true,
          ).copyWith(enabled: false),
          GalTextProcessStep(
            id: 'replace#2',
            kind: GalTextProcessKind.replace,
            pattern: r'\s+',
            replacement: '',
            isRegex: true,
          ),
        ],
      );
      final GalTextProcessPipeline restored = GalTextProcessPipeline.fromJson(
        pipeline.toJson(),
      );
      expect(restored.steps, pipeline.steps);
    });

    test('存档里 id 撞车时丢掉后来的，重排不会因重复 key 崩', () {
      final GalTextProcessPipeline restored = GalTextProcessPipeline.fromJson(
        <Object?>[
          <String, Object?>{'id': 'a', 'kind': 'filterDigits'},
          <String, Object?>{'id': 'a', 'kind': 'filterLatinLetters'},
        ],
      );
      expect(restored.steps, hasLength(1));
      expect(restored.steps.single.kind, GalTextProcessKind.filterDigits);
    });

    test('坏 JSON 不炸，退回空管线', () {
      expect(GalTextProcessPipeline.fromJson(null).isEmpty, isTrue);
      expect(GalTextProcessPipeline.fromJson('x').isEmpty, isTrue);
      expect(GalTextProcessPipeline.fromJson(<Object?>['x']).steps, isEmpty);
    });

    test('nextIdFor 在同种步骤重复添加时给出唯一 id', () {
      GalTextProcessPipeline pipeline = const GalTextProcessPipeline();
      final String first = pipeline.nextIdFor(GalTextProcessKind.replace);
      expect(first, 'replace');
      pipeline = pipeline.withSteps(<GalTextProcessStep>[
        GalTextProcessStep(id: first, kind: GalTextProcessKind.replace),
      ]);
      final String second = pipeline.nextIdFor(GalTextProcessKind.replace);
      expect(second, 'replace#2');
    });

    test('未知 kind 的存档条目退回一个安全步骤而不是抛异常', () {
      final GalTextProcessPipeline restored = GalTextProcessPipeline.fromJson(
        <Object?>[
          <String, Object?>{'id': 'x', 'kind': 'no_such_kind_v99'},
        ],
      );
      expect(restored.steps.single.kind, GalTextProcessKind.filterControlChars);
    });
  });

  group('步骤元信息', () {
    test('只有替换规则允许在管线里重复出现', () {
      for (final GalTextProcessKind kind in GalTextProcessKind.values) {
        expect(
          kind.allowsDuplicates,
          kind == GalTextProcessKind.replace,
          reason: '$kind',
        );
      }
    });

    test('storageKey 全枚举可往返，改名会被这条挡住', () {
      for (final GalTextProcessKind kind in GalTextProcessKind.values) {
        expect(GalTextProcessKind.fromStorageKey(kind.storageKey), kind);
      }
      expect(GalTextProcessKind.fromStorageKey('nope'), isNull);
      expect(GalTextProcessKind.fromStorageKey(null), isNull);
    });
  });
}
