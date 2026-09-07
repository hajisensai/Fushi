import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2216：阅读域「按书」分组与视频域同一套 unique-title 吸收
/// （[groupStatFactsByIdentity] → [groupStatRowsByIdentity]）。此前阅读统计页裸按
/// `identityKey` 分组：删书后 legacy 日行（title 反查失败 → mediaKey ''）与 v92 段
/// （带 bookKey）各成一组，同名两条；库里同名两本时 title→bookKey 反查后者覆盖前者。
StatFact _fact(
  String title, {
  String key = '',
  String dateKey = '2026-06-06',
  int chars = 0,
  int ms = 0,
}) => StatFact(
  mediaKind: kActivityMediaBook,
  mediaKey: key,
  title: title,
  format: '',
  dateKey: dateKey,
  hour: -1,
  ms: ms,
  chars: chars,
  pages: 0,
  lastActiveMs: 0,
);

void main() {
  group('groupStatFactsByIdentity（阅读域按书分组）', () {
    test('同名两本各有 bookKey → 两组，不再合并', () {
      final List<StatIdentityGroup<StatFact>> groups = groupStatFactsByIdentity(
        <StatFact>[
          _fact('同名', key: 'k1', chars: 10),
          _fact('同名', key: 'k2', chars: 20),
        ],
      );
      expect(groups.length, 2);
      expect(groups.map((g) => g.identity).toSet(), <String>{'k1', 'k2'});
      expect(groups.every((g) => g.title == '同名'), isTrue);
    });

    test('删书后重导：legacy 无身份行 unique-title 并入唯一身份组（单 tile）', () {
      final List<StatIdentityGroup<StatFact>> groups =
          groupStatFactsByIdentity(<StatFact>[
            _fact('A', key: 'k1', chars: 10, ms: 1000),
            _fact('A', chars: 5, ms: 500, dateKey: '2026-06-01'),
          ]);
      expect(groups.length, 1, reason: '一本书跨新旧数据仍是单 tile');
      final StatIdentityGroup<StatFact> g = groups.single;
      expect(g.identity, 'k1');
      expect(g.absorbedUnattributed, isTrue);
      expect(g.rows.fold<int>(0, (int s, StatFact f) => s + f.chars), 15);
    });

    test('歧义（行宇宙里同名多身份）的 legacy 行独立成无身份组，不瞎归属', () {
      final List<StatIdentityGroup<StatFact>> groups =
          groupStatFactsByIdentity(<StatFact>[
            _fact('Dup', key: 'k1', chars: 10),
            _fact('Dup', key: 'k2', chars: 20),
            _fact('Dup', chars: 5),
          ]);
      expect(groups.length, 3);
      final StatIdentityGroup<StatFact> orphan = groups.singleWhere(
        (g) => g.identity == null,
      );
      expect(orphan.title, 'Dup');
      expect(orphan.rows.single.chars, 5);
      expect(groups.where((g) => g.absorbedUnattributed), isEmpty);
    });

    test('库表判同名（ambiguousTitles）时，行宇宙唯一身份也不许吸收', () {
      final List<StatIdentityGroup<StatFact>> groups = groupStatFactsByIdentity(
        <StatFact>[_fact('A', key: 'k1', chars: 10), _fact('A', chars: 5)],
        ambiguousTitles: <String>{'A'},
      );
      expect(groups.length, 2, reason: '宁可分裂不要错贴');
      expect(groups.first.identity, 'k1');
      expect(groups.last.identity, isNull);
    });

    test('组序：身份组按首见序在前，无身份组殿后', () {
      final List<StatIdentityGroup<StatFact>> groups = groupStatFactsByIdentity(
        <StatFact>[
          _fact('orphan'),
          _fact('B', key: 'kb'),
          _fact('A', key: 'ka'),
        ],
      );
      expect(groups.map((g) => g.identity).toList(), <String?>[
        'kb',
        'ka',
        null,
      ]);
    });
  });
}
