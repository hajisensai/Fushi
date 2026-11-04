// 浏览页搜索积木 ↔ 语法互转（srs_browse_query.dart，纯函数）。
//
// 语义恒等用 fushi_srs 的 Dart 解析器比对：拼回去的查询解析出的语法树与原查询相同。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_query.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_saved_views.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show parseAnkiSearch, srsSearchNodeJson;

Map<String, Object?> _tree(String q) => srsSearchNodeJson(parseAnkiSearch(q));

void main() {
  group('srsParseBrowseChips', () {
    test('空查询 → 没有积木', () {
      expect(srsParseBrowseChips(''), isEmpty);
      expect(srsParseBrowseChips('   '), isEmpty);
    });

    test('认出牌组 / 状态 / 标签 / 笔记类型 / 出处 / 属性 / 文本', () {
      final List<SrsBrowseChip> chips = srsParseBrowseChips(
        'deck:"N2 語彙" is:due tag:verb note:Lapis src:book prop:ivl>=10 '
        'added:7 食べる -flag:0',
      );
      expect(chips.map((SrsBrowseChip c) => c.kind), <SrsBrowseChipKind>[
        SrsBrowseChipKind.deck,
        SrsBrowseChipKind.state,
        SrsBrowseChipKind.tag,
        SrsBrowseChipKind.noteType,
        SrsBrowseChipKind.source,
        SrsBrowseChipKind.property,
        SrsBrowseChipKind.property,
        SrsBrowseChipKind.text,
        SrsBrowseChipKind.property,
      ]);
      expect(chips.first.values, <String>['N2 語彙']);
      expect(chips.last.negated, isTrue);
      expect(chips.last.values, <String>['flag:0']);
    });

    test('「或」组合成一块多值积木，取反组是排除', () {
      final List<SrsBrowseChip> chips = srsParseBrowseChips(
        '(deck:A or deck:"B C") -(tag:x or tag:y)',
      );
      expect(chips, hasLength(2));
      expect(chips[0].kind, SrsBrowseChipKind.deck);
      expect(chips[0].values, <String>['A', 'B C']);
      expect(chips[0].negated, isFalse);
      expect(chips[1].kind, SrsBrowseChipKind.tag);
      expect(chips[1].negated, isTrue);
      expect(chips[1].values, <String>['x', 'y']);
    });

    test('拆不动的留成语法积木：顶层 or、字段限定、混合括号、不配对', () {
      expect(
        srsParseBrowseChips('a or b').single.kind,
        SrsBrowseChipKind.syntax,
      );
      expect(
        srsParseBrowseChips('Expression:食べる').single.kind,
        SrsBrowseChipKind.syntax,
      );
      expect(
        srsParseBrowseChips('(deck:A or tag:b)').single.kind,
        SrsBrowseChipKind.syntax,
      );
      final SrsBrowseChip broken = srsParseBrowseChips('(broken').single;
      expect(broken.kind, SrsBrowseChipKind.syntax);
      expect(broken.raw, '(broken');
      expect(srsParseBrowseChips('"unclosed').single.raw, '"unclosed');
    });

    test('整条加引号的写法与部分引号同义', () {
      final SrsBrowseChip c = srsParseBrowseChips('"deck:My Deck"').single;
      expect(c.kind, SrsBrowseChipKind.deck);
      expect(c.values, <String>['My Deck']);
      expect(c.toQuery(), 'deck:"My Deck"');
    });

    test('转义原样保留，显示时才去转义', () {
      final SrsBrowseChip c = srsParseBrowseChips(r'deck:"a\*b\"c"').single;
      expect(c.values, <String>[r'a\*b\"c']);
      expect(srsBrowseUnescape(c.values.single), 'a*b"c');
    });
  });

  group('往返语义恒等', () {
    const List<String> queries = <String>[
      'is:due',
      'deck:"JP::N3" is:new',
      '(deck:A or deck:B) -tag:verb',
      '-(is:suspended or is:buried) prop:lapses>=4',
      'Expression:*食* re:^a',
      '"a b" c -d',
      'a or b',
      'deck:日本語 and tag:x',
      'added:7 -flag:0 card:1',
      r'deck:"x\_y\*z\"q\\w"',
      'a(b)',
    ];
    for (final String q in queries) {
      test(q, () {
        final String back = srsBrowseChipsToQuery(srsParseBrowseChips(q));
        expect(_tree(back), _tree(q));
        // 再拆一次结果稳定。
        expect(srsBrowseChipsToQuery(srsParseBrowseChips(back)), back);
      });
    }
  });

  group('编辑', () {
    test('改取值、改排除、删空的积木被丢掉', () {
      final List<SrsBrowseChip> chips = srsParseBrowseChips('deck:A is:due');
      final List<SrsBrowseChip> edited = srsBrowseReplaceChip(
        chips,
        0,
        chips[0].copyWith(values: <String>['A', 'B'], negated: true),
      );
      expect(srsBrowseChipsToQuery(edited), '-(deck:A or deck:B) is:due');
      expect(
        srsBrowseChipsToQuery(
          srsBrowseReplaceChip(
            edited,
            0,
            edited[0].copyWith(values: <String>[]),
          ),
        ),
        'is:due',
      );
      expect(
        srsBrowseChipsToQuery(srsBrowseReplaceChip(edited, 1, null)),
        '-(deck:A or deck:B)',
      );
    });

    test('字面量转义：牌组名里的通配符与引号', () {
      final SrsBrowseChip c = SrsBrowseChip(SrsBrowseChipKind.deck, <String>[
        srsBrowseLiteral('x_y "z"'),
      ]);
      expect(c.toQuery(), r'deck:"x\_y \"z\""');
      expect(_tree(c.toQuery()), _tree(r'deck:"x\_y \"z\""'));
    });

    test('草稿并进积木、包含判据', () {
      final List<SrsBrowseChip> chips = srsBrowseCommitDraft(
        srsParseBrowseChips('deck:A'),
        'is:due tag:x',
      );
      expect(chips, hasLength(3));
      expect(
        srsBrowseChipsContain(chips, srsParseBrowseChips('is:due')),
        isTrue,
      );
      expect(
        srsBrowseChipsContain(chips, srsParseBrowseChips('is:new')),
        isFalse,
      );
      expect(srsBrowseChipsContain(chips, const <SrsBrowseChip>[]), isFalse);
    });
  });

  group('补全', () {
    test('牌组 / 标签 / 笔记类型包含匹配，最后一条是写成语法', () {
      final List<SrsBrowseSuggestion> s = srsBrowseSuggestions(
        'n2',
        decks: <String>['日本語::N2 語彙', 'Kaishi'],
        tags: <String>['n2', 'verb'],
        noteTypes: <String>['Lapis'],
      );
      expect(
        s.map((SrsBrowseSuggestion x) => x.kind),
        <SrsBrowseSuggestionKind>[
          SrsBrowseSuggestionKind.deck,
          SrsBrowseSuggestionKind.tag,
          SrsBrowseSuggestionKind.syntax,
        ],
      );
      expect(s.first.chip.toQuery(), 'deck:"日本語::N2 語彙"');
    });

    test('前缀只在那一类里找；状态与常用属性按前缀', () {
      final List<SrsBrowseSuggestion> s = srsBrowseSuggestions(
        'is:d',
        decks: <String>['is d deck'],
        tags: const <String>[],
        noteTypes: const <String>[],
      );
      expect(s.first.kind, SrsBrowseSuggestionKind.state);
      expect(s.first.chip.toQuery(), 'is:due');
      expect(
        srsBrowseSuggestions(
          'prop:l',
          decks: const <String>[],
          tags: const <String>[],
          noteTypes: const <String>[],
        ).first.chip.toQuery(),
        'prop:lapses>=4',
      );
    });

    test('空草稿没有补全', () {
      expect(
        srsBrowseSuggestions(
          ' ',
          decks: <String>['a'],
          tags: const <String>[],
          noteTypes: const <String>[],
        ),
        isEmpty,
      );
    });
  });

  group('视图', () {
    test('保存的视图编解码：坏数据跳过，不丢其它', () {
      const List<SrsBrowseSavedView> views = <SrsBrowseSavedView>[
        SrsBrowseSavedView(name: 'N2 难卡', query: 'deck:N2 prop:lapses>=4'),
        SrsBrowseSavedView(name: 'b', query: ''),
      ];
      expect(
        decodeSrsBrowseSavedViews(encodeSrsBrowseSavedViews(views)),
        views,
      );
      expect(encodeSrsBrowseSavedViews(const <SrsBrowseSavedView>[]), '');
      expect(decodeSrsBrowseSavedViews('not json'), isEmpty);
      expect(
        decodeSrsBrowseSavedViews(
          '[{"name":"x","query":"is:due"},{"name":1},{"name":" ","query":"a"}]',
        ),
        const <SrsBrowseSavedView>[
          SrsBrowseSavedView(name: 'x', query: 'is:due'),
        ],
      );
    });

    test('快捷视图条件：问题卡缺音频只判 Fushi 卡片类型', () {
      expect(
        srsBrowseQuickViewQuery(
          SrsBrowseQuickView.problems,
          fushiNoteTypeName: 'Fushi "卡"',
        ),
        r'(is:emptyfield or (-has:audio note:"Fushi \"卡\""))',
      );
      expect(
        srsBrowseQuickViewQuery(
          SrsBrowseQuickView.problems,
          fushiNoteTypeName: null,
        ),
        'is:emptyfield',
      );
      // 语法能被解析器接受。
      parseAnkiSearch(
        srsBrowseQuickViewQuery(
          SrsBrowseQuickView.problems,
          fushiNoteTypeName: 'Fushi',
        ),
      );
    });

    test('套用快捷视图：留下牌组积木、换掉其余；已套着再点 = 撤掉', () {
      final List<SrsBrowseChip> start = srsParseBrowseChips('deck:A tag:x');
      final List<SrsBrowseChip> due = srsParseBrowseChips('is:due');
      final List<SrsBrowseChip> on = srsBrowseToggleQuickView(start, due);
      expect(srsBrowseChipsToQuery(on), 'deck:A is:due');
      expect(
        srsBrowseChipsToQuery(srsBrowseToggleQuickView(on, due)),
        'deck:A',
      );
    });
  });
}
