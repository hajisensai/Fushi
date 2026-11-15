// 反馈 80S7Esbdec：发现搜索结果的统一相关度判据（纯函数）。
import 'package:test/test.dart';

import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/discovery_search_relevance.dart';

DiscoverySearchRelevance _rel(String query, String title) =>
    discoverySearchRelevance(query: query, texts: <String>[title]);

DiscoveryResourceItem _item(
  String title, {
  String? note,
  String? fileName,
  String sourceId = 's',
}) => DiscoveryResourceItem(
  sourceId: sourceId,
  title: title,
  id: title,
  kind: DiscoveryMediaKind.game,
  payloadKind: DiscoveryPayloadKind.httpFile,
  note: note,
  payload: fileName == null
      ? null
      : DiscoveryHttpPayload(
          url: 'https://example.invalid/f',
          fileName: fileName,
        ),
);

void main() {
  group('反馈原例：搜 ユリアリス', () {
    test('真命中的条目判相关（连续子串）', () {
      final DiscoverySearchRelevance r = _rel('ユリアリス', 'ユリアリス');
      expect(r.isRelevant, isTrue);
      expect(r.contiguous, isTrue);
    });

    test('文件名带日期 / 社团 / 扩展名仍命中', () {
      expect(
        _rel('ユリアリス', '[230428][ensemble] ユリアリス ver1.01.7z').isRelevant,
        isTrue,
      );
    });

    test('shinnku 字符级模糊命中的条目一律不相关', () {
      for (final String title in <String>[
        '天文時計のアリア',
        'ユニオリズム',
        'デリシャスらんちぱっく',
      ]) {
        final DiscoverySearchRelevance r = _rel('ユリアリス', title);
        expect(r.isRelevant, isFalse, reason: title);
        expect(r.coverage, 0, reason: title);
      }
    });

    test('片假名 / 平假名、全角半角、中点长音互相命中', () {
      expect(_rel('ゆりありす', 'ユリアリス').isRelevant, isTrue);
      expect(_rel('ユリ・アリス', 'ユリアリス.zip').isRelevant, isTrue);
      expect(_rel('ＷＨＩＴＥ ＡＬＢＵＭ２', 'WHITE ALBUM2').isRelevant, isTrue);
    });
  });

  group('拉丁标题', () {
    test('大小写与标点不敏感', () {
      expect(_rel('summer pockets', 'Summer Pockets').isRelevant, isTrue);
      expect(
        _rel('fate stay night', 'Fate/stay night [Realta Nua]').contiguous,
        isTrue,
      );
    });

    test('词序颠倒：分词全覆盖，相关但排在连续命中之后', () {
      final DiscoverySearchRelevance swapped = _rel(
        'pockets summer',
        'Summer Pockets',
      );
      expect(swapped.contiguous, isFalse);
      expect(swapped.coverage, 1);
      expect(swapped.isRelevant, isTrue);
      expect(
        swapped.compareTo(_rel('summer pockets', 'Summer Pockets')),
        lessThan(0),
      );
    });

    test('只撞上一个短词不相关', () {
      // 'summer'(6) / 'pockets'(7)：只命中 summer 覆盖 6/13≈0.46 < 0.6。
      final DiscoverySearchRelevance r = _rel(
        'summer pockets',
        'Summer Vacation Diary',
      );
      expect(r.isRelevant, isFalse);
      expect(r.coverage, closeTo(6 / 13, 1e-9));
    });

    test('两个等长词只命中一半判不相关（阈值来由）', () {
      expect(_rel('abcd wxyz', 'abcd only').coverage, 0.5);
      expect(_rel('abcd wxyz', 'abcd only').isRelevant, isFalse);
    });
  });

  group('带副标题的标题', () {
    test('主标题 + 副标题中间夹了别的字：分词覆盖命中', () {
      final DiscoverySearchRelevance r = _rel(
        'white album2 coda',
        'WHITE ALBUM2 -closing chapter- coda',
      );
      expect(r.contiguous, isFalse);
      expect(r.isRelevant, isTrue);
    });

    test('只搜主标题：带副标题的条目连续命中', () {
      expect(_rel('ユリアリス', 'ユリアリス ～花咲く季節に～').contiguous, isTrue);
    });

    test('查询多带一个短修饰词：漏掉它仍算命中', () {
      // ゆりありす(5) + 汉化(2)：覆盖 5/7≈0.71 ≥ 0.6。
      final DiscoverySearchRelevance r = _rel('ユリアリス 汉化', 'ユリアリス');
      expect(r.coverage, closeTo(5 / 7, 1e-9));
      expect(r.isRelevant, isTrue);
    });
  });

  group('边界', () {
    test('空查询 / 纯空白查询恒相关', () {
      expect(_rel('', '随便什么').isRelevant, isTrue);
      expect(_rel('  　 ', '随便什么').isRelevant, isTrue);
    });

    test('条目没有任何可读文字：不相关', () {
      expect(
        discoverySearchRelevance(
          query: 'abc',
          texts: const <String>[],
        ).isRelevant,
        isFalse,
      );
    });

    test('标注（作者）与直链文件名也参与判定', () {
      expect(
        discoveryEntryRelevance(
          '鬼影スパナ',
          _item('第一巻', note: '鬼影スパナ'),
        ).isRelevant,
        isTrue,
      );
      expect(
        discoveryEntryRelevance(
          'ユリアリス',
          _item('download', fileName: 'ユリアリス.7z'),
        ).isRelevant,
        isTrue,
      );
      expect(
        discoveryEntryRelevance(
          'abc',
          const DiscoveryFolder(
            sourceId: 's',
            title: 'x',
            path: '/x',
            note: 'ABC author',
          ),
        ).isRelevant,
        isTrue,
      );
    });
  });

  group('rankDiscoveryEntriesByRelevance', () {
    test('命中的排前，同档稳定保持源给的原序，不删条目', () {
      final List<DiscoveryEntry> entries = <DiscoveryEntry>[
        _item('天文時計のアリア'),
        _item('ユリアリス 体験版'),
        _item('ユニオリズム'),
        _item('ユリアリス'),
        _item('デリシャスらんちぱっく'),
      ];
      final List<String> ranked = rankDiscoveryEntriesByRelevance(
        'ユリアリス',
        entries,
      ).map((DiscoveryEntry e) => e.title).toList();
      expect(ranked, <String>[
        'ユリアリス 体験版',
        'ユリアリス',
        '天文時計のアリア',
        'ユニオリズム',
        'デリシャスらんちぱっく',
      ]);
    });

    test('连续命中 > 分词覆盖 > 不相关', () {
      final List<String> ranked =
          rankDiscoveryEntriesByRelevance('summer pockets', <DiscoveryEntry>[
            _item('Summer Vacation'),
            _item('Pockets of Summer'),
            _item('Summer Pockets Reflection Blue'),
          ]).map((DiscoveryEntry e) => e.title).toList();
      expect(ranked, <String>[
        'Summer Pockets Reflection Blue',
        'Pockets of Summer',
        'Summer Vacation',
      ]);
    });

    test('空查询原样返回', () {
      final List<DiscoveryEntry> entries = <DiscoveryEntry>[
        _item('b'),
        _item('a'),
      ];
      expect(rankDiscoveryEntriesByRelevance('', entries), same(entries));
    });
  });
}
