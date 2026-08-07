import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/misc/lookup_input_limits.dart';
import 'package:characters/characters.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:remove_emoji/remove_emoji.dart';

void main() {
  final RegExp emojiRegex = RegExp(RemoveEmoji().getRegexString());
  final RegExp punctuationRegex =
      RegExp(r'^[\p{P}\p{S}]+|[\p{P}\p{S}]+$', unicode: true);
  final RegExp loneSurrogateRegex = RegExp(
    '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:[^\uD800-\uDBFF]|^)[\uDC00-\uDFFF]',
  );

  String legacyNormalize(String searchTerm) {
    searchTerm = searchTerm.replaceAll('\n', ' ');
    searchTerm = searchTerm.replaceAll(emojiRegex, ' ');
    searchTerm = searchTerm.replaceAll(punctuationRegex, '');
    searchTerm = searchTerm.replaceAll(loneSurrogateRegex, ' ');
    return searchTerm;
  }

  String normalize(String input) => normalizeSearchTerm(
        input,
        emojiRegex: emojiRegex,
        punctuationRegex: punctuationRegex,
        loneSurrogateRegex: loneSurrogateRegex,
      );

  void expectEquivalent(String input) {
    expect(normalize(input), legacyNormalize(input),
        reason: 'normalizeSearchTerm must equal legacy 4-step inline');
  }

  group('normalizeSearchTerm query cleanup (byte-exact vs legacy inline)', () {
    // BUG-442：词典查询前先按 kMaxLookupInputChars 截断（用 characters 不切碎
    // 代理对 / 字素簇），避免超长串让逐次 replaceAll 线性清洗卡顿。注意：这一步
    // 不在 legacyNormalize 内，故超长输入不能用 expectEquivalent。
    test('over-long input is capped to kMaxLookupInputChars (BUG-442)', () {
      final String longText = 'あ' * (kMaxLookupInputChars + 1000);
      final String out = normalize(longText);
      expect(out.characters.length, kMaxLookupInputChars);
    });

    test('input exactly at the cap is not truncated (BUG-442 boundary)', () {
      final String exact = 'い' * kMaxLookupInputChars;
      expect(normalize(exact).characters.length, kMaxLookupInputChars);
    });

    test('plain japanese term returned as-is', () {
      expect(normalize('図書館'), '図書館');
      expectEquivalent('図書館');
    });

    test('newline folds to a single space', () {
      expect(normalize('図書\n館'), '図書 館');
      expectEquivalent('図書\n館');
    });

    test('multiple newlines each fold to one space', () {
      expect(normalize('a\nb\nc'), 'a b c');
      expectEquivalent('a\nb\nc');
    });

    test('edge punctuation/symbols stripped, inner kept', () {
      expect(normalize('。図書館！'), '図書館');
      expectEquivalent('。図書館！');
      expectEquivalent('（図書・館）');
      expectEquivalent('!!!hello!!!');
    });

    test('emoji replaced with space', () {
      const String input = '図書\u{1F600}館';
      expect(normalize(input), legacyNormalize(input));
      expectEquivalent(input);
    });

    test('lone high surrogate replaced with space', () {
      const String lone = '図\uD800書';
      expectEquivalent(lone);
    });

    test('lone low surrogate replaced with space', () {
      const String lone = '図\uDC00書';
      expectEquivalent(lone);
    });

    test('valid surrogate pair not broken by lone rule', () {
      const String supplementary = '図\u{2000B}書';
      expectEquivalent(supplementary);
    });

    test('empty string and pure whitespace', () {
      expect(normalize(''), '');
      expect(normalize('   '), '   ');
      expectEquivalent('');
      expectEquivalent('   ');
    });

    test('mixed newline+emoji+edge-punct+lone-surrogate in fixed order', () {
      const String input = '。図書\n\u{1F600}館\uD800！';
      expect(normalize(input), legacyNormalize(input));
      expectEquivalent(input);
    });
  });

  group('buildSearchCacheKey byte-identical cache key', () {
    test('format len:term/maxTerms/maxResults', () {
      expect(
        buildSearchCacheKey(term: '図書館', maxTerms: 8, maxResults: 32),
        '3:図書館/8/32',
      );
    });

    test('term.length uses UTF-16 code units', () {
      expect(
        buildSearchCacheKey(term: '\u{2000B}', maxTerms: 1, maxResults: 1),
        '2:\u{2000B}/1/1',
      );
    });

    test('empty term key', () {
      expect(
          buildSearchCacheKey(term: '', maxTerms: 0, maxResults: 0), '0:/0/0');
    });

    test('term with slash/colon not escaped', () {
      expect(
        buildSearchCacheKey(term: 'a/b:c', maxTerms: 5, maxResults: 100),
        '5:a/b:c/5/100',
      );
    });

    test('byte-exact vs legacy inline interpolation', () {
      String legacyKey(String term, int maxTerms, int maxResults) =>
          '${term.length}:$term/$maxTerms/$maxResults';
      for (final term in <String>[
        '図書館',
        '',
        'a/b',
        '\u{2000B}',
        'long word here'
      ]) {
        expect(
          buildSearchCacheKey(term: term, maxTerms: 8, maxResults: 32),
          legacyKey(term, 8, 32),
          reason: 'cacheKey drift busts the cache',
        );
      }
    });
  });

  group('decodeDictTypeFromBlobHeader blob-header byte decode', () {
    List<int> blob({
      int flag = 0x01,
      required int exprLen,
      required String mode,
      int? overrideModeLen,
    }) {
      final modeBytes = mode.codeUnits;
      final modeLen = overrideModeLen ?? modeBytes.length;
      return <int>[
        flag,
        exprLen & 0xFF,
        (exprLen >> 8) & 0xFF,
        ...List<int>.filled(exprLen, 0x00),
        modeLen,
        ...modeBytes,
      ];
    }

    test('mode=freq -> frequency', () {
      expect(
        decodeDictTypeFromBlobHeader(blob(exprLen: 5, mode: 'freq')),
        DictionaryType.frequency,
      );
    });

    test('mode=pitch -> pitch', () {
      expect(
        decodeDictTypeFromBlobHeader(blob(exprLen: 0, mode: 'pitch')),
        DictionaryType.pitch,
      );
    });

    test('mode not freq|pitch -> null', () {
      expect(
          decodeDictTypeFromBlobHeader(blob(exprLen: 3, mode: 'term')), null);
      expect(
          decodeDictTypeFromBlobHeader(blob(exprLen: 0, mode: 'kanji')), null);
    });

    test('non-zero exprLen locates modeLen at offset 3+exprLen', () {
      final b = blob(exprLen: 10, mode: 'freq');
      expect(decodeDictTypeFromBlobHeader(b), DictionaryType.frequency);
    });

    test('length < 4 -> null', () {
      expect(decodeDictTypeFromBlobHeader(<int>[0x01, 0x00, 0x00]), null);
      expect(decodeDictTypeFromBlobHeader(<int>[]), null);
    });

    test('flag != 0x01 -> null', () {
      expect(
        decodeDictTypeFromBlobHeader(
            blob(flag: 0x00, exprLen: 0, mode: 'freq')),
        null,
      );
      expect(
        decodeDictTypeFromBlobHeader(
            blob(flag: 0xFF, exprLen: 0, mode: 'pitch')),
        null,
      );
    });

    test('modeLen == 0 -> null', () {
      final b = <int>[0x01, 0x00, 0x00, 0x00];
      expect(decodeDictTypeFromBlobHeader(b), null);
    });

    test('modeLen offset out of range -> null', () {
      final b = <int>[0x01, 0x02, 0x00, 0x00, 0x00];
      expect(b.length, 5);
      expect(decodeDictTypeFromBlobHeader(b), null);
    });

    test('mode bytes truncated at EOF: take remainder', () {
      final b = <int>[0x01, 0x00, 0x00, 0x04, ...'fre'.codeUnits];
      expect(decodeDictTypeFromBlobHeader(b), null,
          reason: 'truncated to fre != freq -> null');
      final liar = <int>[0x01, 0x00, 0x00, 0x0A, ...'freq'.codeUnits];
      expect(decodeDictTypeFromBlobHeader(liar), DictionaryType.frequency,
          reason: 'matches raf.readSync returning only remaining bytes');
    });

    test('mode starts exactly at EOF -> empty -> null', () {
      final b = <int>[0x01, 0x00, 0x00, 0x02];
      expect(decodeDictTypeFromBlobHeader(b), null);
    });
  });

  group('leadingPunctuationStripUnits (BUG-773 句首标点剥离长度)', () {
    int lead(String s) => leadingPunctuationStripUnits(s, punctuationRegex);

    test('句首日文书名号 『 计 1 个 code unit', () {
      expect(lead('『呪術廻戦 第1期』'), 1);
    });

    test('句首多重括号/引号连剥', () {
      expect(lead('（「図書館」）'), 2); // （「 两个
      expect(lead('！！！hello'), 3);
    });

    test('无句首标点 -> 0', () {
      expect(lead('呪術廻戦'), 0);
      expect(lead('図書館。'), 0, reason: '只有句尾标点，命中不在句首');
    });

    test('空串 -> 0', () {
      expect(lead(''), 0);
    });

    // 单一真相校验：剥掉的句首长度必须恰好等于 normalizeSearchTerm 从句首移除的量。
    // 对「仅句首标点、无 emoji/换行/代理项、无句尾标点」的输入，
    // 原始长度 - 归一化后长度 == 句首剥离长度。
    test('与 normalizeSearchTerm 句首移除量一致（无其他清洗时）', () {
      for (final String s in <String>[
        '『呪術廻戦',
        '（図書館',
        '「「テスト',
        '！！！hello',
        '普通の文', // 无句首标点：剥 0、归一化不变
      ]) {
        final int leadUnits = lead(s);
        final int removedTotal = s.length - normalize(s).length;
        expect(leadUnits, removedTotal,
            reason: '「$s」句首剥离长度须等于归一化移除总量（无句尾标点样本）');
      }
    });
  });
}
