import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/galgame_library_query.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_merge.dart';

/// 游戏库查询层（搜索归一化 / 筛选 / 排序 / 视图偏好编解码）的纯函数守卫。
/// 全部不碰 DB、磁盘与时钟——输入一样输出必然一样。
void main() {
  GalgameEntry entry({
    required String id,
    String name = 'game',
    String exePath = r'Z:\g\game.exe',
    DateTime? addedAt,
    GalgamePlayStatus status = GalgamePlayStatus.unset,
    String? releaseDate,
    int lastPlayedMs = 0,
    double? score,
    double? userRating,
    List<String> tags = const <String>[],
    List<String> aliases = const <String>[],
    String? nameCn,
    bool? nsfw,
  }) {
    return GalgameEntry(
      id: id,
      name: name,
      exePath: exePath,
      workdir: r'Z:\g',
      addedAt: addedAt ?? DateTime(2026),
      playStatus: status,
      releaseDate: releaseDate,
      lastPlayedMs: lastPlayedMs,
      customData: GalgameCustomData(userRating: userRating),
      metadata: GalgameMetadataDraft(
        nameCn: nameCn,
        aliases: aliases,
        score: score,
        tags: tags,
        nsfw: nsfw,
      ),
    );
  }

  group('搜索归一化', () {
    test('全角 → 半角、大写 → 小写、丢空白与标点', () {
      expect(normalizeGalgameSearchText('Ｆａｔｅ／ｓｔａｙ night'),
          normalizeGalgameSearchText('fate stay night'));
      expect(normalizeGalgameSearchText('  A-B_C!  '), 'abc');
    });

    test('片假名折叠成平假名', () {
      expect(
          normalizeGalgameSearchText('カノン'), normalizeGalgameSearchText('かのん'));
      // 长音符按排版噪音丢弃，不影响命中。
      expect(normalizeGalgameSearchText('セーラー'), 'せら');
    });

    test('空串归一化仍是空串', () {
      expect(normalizeGalgameSearchText(''), '');
      expect(normalizeGalgameSearchText('・・・'), '');
    });
  });

  group('搜索匹配', () {
    final GalgameEntry game = entry(
      id: 'g1',
      name: 'sakura_moyu',
      nameCn: '樱之刻',
      aliases: <String>['サクラノ刻'],
    );

    test('空查询恒命中', () {
      expect(matchesGalgameSearch(game, ''), isTrue);
      expect(matchesGalgameSearch(game, '   '), isTrue);
    });

    test('本地名 / 中文名 / 别名都参与匹配', () {
      expect(matchesGalgameSearch(game, 'sakura'), isTrue);
      expect(matchesGalgameSearch(game, '樱之刻'), isTrue);
      expect(matchesGalgameSearch(game, 'さくらの刻'), isTrue);
    });

    test('不相关词不命中', () {
      expect(matchesGalgameSearch(game, 'clannad'), isFalse);
    });
  });

  group('筛选', () {
    test('游玩状态', () {
      final GalgameEntry playing =
          entry(id: 'a', status: GalgamePlayStatus.playing);
      const GalgameLibraryView view =
          GalgameLibraryView(status: GalgamePlayStatus.playing);
      expect(matchesGalgameFilters(playing, view), isTrue);
      expect(
        matchesGalgameFilters(
            entry(id: 'b', status: GalgamePlayStatus.dropped), view),
        isFalse,
      );
    });

    test('本地 exe / 仅元数据', () {
      final GalgameEntry local = entry(id: 'a');
      final GalgameEntry online = entry(id: 'b', exePath: '');
      const GalgameLibraryView onlyLocal =
          GalgameLibraryView(localFilter: GalgameLocalFilter.localOnly);
      const GalgameLibraryView onlyMeta =
          GalgameLibraryView(localFilter: GalgameLocalFilter.metadataOnly);
      expect(matchesGalgameFilters(local, onlyLocal), isTrue);
      expect(matchesGalgameFilters(online, onlyLocal), isFalse);
      expect(matchesGalgameFilters(online, onlyMeta), isTrue);
      expect(matchesGalgameFilters(local, onlyMeta), isFalse);
    });

    test('标签多选是 AND 语义', () {
      final GalgameEntry game = entry(id: 'a', tags: <String>['泣きゲー', '学园']);
      expect(
        matchesGalgameFilters(
            game, const GalgameLibraryView(tags: <String>{'学园'})),
        isTrue,
      );
      expect(
        matchesGalgameFilters(
            game, const GalgameLibraryView(tags: <String>{'学园', '悬疑'})),
        isFalse,
      );
    });

    test('隐藏成人向', () {
      const GalgameLibraryView view = GalgameLibraryView(hideNsfw: true);
      expect(matchesGalgameFilters(entry(id: 'a', nsfw: true), view), isFalse);
      expect(matchesGalgameFilters(entry(id: 'b', nsfw: false), view), isTrue);
      // nsfw 未知（未刮削）不算成人向，不该被隐藏。
      expect(matchesGalgameFilters(entry(id: 'c'), view), isTrue);
    });
  });

  group('排序', () {
    test('添加时间升降序', () {
      final GalgameEntry older = entry(id: 'a', addedAt: DateTime(2025));
      final GalgameEntry newer = entry(id: 'b', addedAt: DateTime(2026));
      expect(
        compareGalgameEntries(older, newer,
            field: GalgameSortField.added, ascending: true),
        lessThan(0),
      );
      expect(
        compareGalgameEntries(older, newer,
            field: GalgameSortField.added, ascending: false),
        greaterThan(0),
      );
    });

    test('缺值恒沉底，不随升降序翻转', () {
      final GalgameEntry rated = entry(id: 'a', score: 8.2);
      final GalgameEntry unrated = entry(id: 'b');
      for (final bool asc in <bool>[true, false]) {
        expect(
          compareGalgameEntries(rated, unrated,
              field: GalgameSortField.siteScore, ascending: asc),
          lessThan(0),
          reason: '未刮削评分的条目在任何方向都排在有评分的后面',
        );
      }
    });

    test('从未游玩视作缺值', () {
      final GalgameEntry played = entry(id: 'a', lastPlayedMs: 1000);
      final GalgameEntry never = entry(id: 'b');
      expect(
        compareGalgameEntries(played, never,
            field: GalgameSortField.lastPlayed, ascending: true),
        lessThan(0),
      );
    });

    test('applyGalgameLibraryView 组合筛选 + 搜索 + 排序', () {
      final List<GalgameEntry> games = <GalgameEntry>[
        entry(id: 'a', name: 'alpha', releaseDate: '2020-01-01'),
        entry(id: 'b', name: 'beta', releaseDate: '2024-06-30'),
        entry(id: 'c', name: 'gamma'),
        entry(id: 'd', name: 'alphabet', status: GalgamePlayStatus.dropped),
      ];
      final List<GalgameEntry> out = applyGalgameLibraryView(
        games,
        const GalgameLibraryView(
          search: 'alpha',
          sortField: GalgameSortField.name,
          ascending: true,
        ),
      );
      expect(out.map((GalgameEntry g) => g.id).toList(), <String>['a', 'd']);

      final List<GalgameEntry> byRelease = applyGalgameLibraryView(
        games,
        const GalgameLibraryView(
          sortField: GalgameSortField.releaseDate,
          ascending: false,
        ),
      );
      // 有发行日的按倒序在前，未知发行日沉底。
      expect(byRelease.map((GalgameEntry g) => g.id).take(2).toList(),
          <String>['b', 'a']);
    });

    test('排序结果确定：同值按名称 → id 兜底', () {
      final List<GalgameEntry> games = <GalgameEntry>[
        entry(id: 'z', name: 'same'),
        entry(id: 'a', name: 'same'),
      ];
      final List<GalgameEntry> out = applyGalgameLibraryView(
          games, const GalgameLibraryView(sortField: GalgameSortField.name));
      expect(out.map((GalgameEntry g) => g.id).toList(), <String>['a', 'z']);
    });

    // BUG-1113：共享用户标签筛出的 id 白名单（DB 查询结果）与页内元数据标签筛选
    // 是两条正交轴，都在这个纯函数里收口，同时生效。
    test('allowedIds 为 null = 不过滤（未选任何用户标签时的行为不变）', () {
      final List<GalgameEntry> games = <GalgameEntry>[
        entry(id: 'a', name: 'alpha'),
        entry(id: 'b', name: 'beta'),
      ];
      final List<GalgameEntry> out = applyGalgameLibraryView(
        games,
        const GalgameLibraryView(sortField: GalgameSortField.name),
      );
      expect(out.map((GalgameEntry g) => g.id).toList(), <String>['a', 'b']);
    });

    test('allowedIds 只保留白名单内的游戏，空集 = 一个都不留', () {
      final List<GalgameEntry> games = <GalgameEntry>[
        entry(id: 'a', name: 'alpha'),
        entry(id: 'b', name: 'beta'),
      ];
      expect(
        applyGalgameLibraryView(
          games,
          const GalgameLibraryView(sortField: GalgameSortField.name),
          allowedIds: <String>{'b'},
        ).map((GalgameEntry g) => g.id).toList(),
        <String>['b'],
      );
      expect(
        applyGalgameLibraryView(
          games,
          const GalgameLibraryView(sortField: GalgameSortField.name),
          allowedIds: <String>{},
        ),
        isEmpty,
      );
    });

    test('allowedIds 与元数据标签/搜索是 AND 关系，不互相覆盖', () {
      final List<GalgameEntry> games = <GalgameEntry>[
        entry(id: 'a', name: 'alpha', tags: <String>['学园']),
        entry(id: 'b', name: 'alphabet', tags: <String>['学园']),
        entry(id: 'c', name: 'alpha2'),
      ];
      final List<GalgameEntry> out = applyGalgameLibraryView(
        games,
        const GalgameLibraryView(
          search: 'alpha',
          tags: <String>{'学园'},
          sortField: GalgameSortField.name,
        ),
        allowedIds: <String>{'b', 'c'},
      );
      // a 被 allowedIds 挡掉；c 没有元数据标签「学园」被挡掉；只剩 b 三条都过。
      expect(out.map((GalgameEntry g) => g.id).toList(), <String>['b']);
    });
  });

  group('视图偏好编解码', () {
    test('往返一致', () {
      const GalgameLibraryView view = GalgameLibraryView(
        sortField: GalgameSortField.userRating,
        ascending: false,
        status: GalgamePlayStatus.onHold,
        localFilter: GalgameLocalFilter.metadataOnly,
        tags: <String>{'学园'},
        hideNsfw: true,
      );
      final GalgameLibraryView back = GalgameLibraryView.decode(view.encode());
      expect(back.sortField, GalgameSortField.userRating);
      expect(back.ascending, isFalse);
      expect(back.status, GalgamePlayStatus.onHold);
      expect(back.localFilter, GalgameLocalFilter.metadataOnly);
      expect(back.tags, <String>{'学园'});
      expect(back.hideNsfw, isTrue);
      // 搜索词刻意不持久化。
      expect(back.search, '');
    });

    test('脏数据回落默认视图，不抛', () {
      for (final String raw in <String>['', '   ', 'not json', '[1,2]']) {
        final GalgameLibraryView view = GalgameLibraryView.decode(raw);
        expect(view.sortField, GalgameSortField.added);
        expect(view.ascending, isTrue);
        expect(view.hasActiveFilter, isFalse);
      }
    });

    test('clearFilters 只清筛选、保排序', () {
      const GalgameLibraryView view = GalgameLibraryView(
        sortField: GalgameSortField.siteScore,
        ascending: false,
        hideNsfw: true,
        status: GalgamePlayStatus.played,
      );
      final GalgameLibraryView cleared = view.clearFilters();
      expect(cleared.hasActiveFilter, isFalse);
      expect(cleared.sortField, GalgameSortField.siteScore);
      expect(cleared.ascending, isFalse);
    });
  });

  test('collectGalgameTags 去重并排序', () {
    final List<String> tags = collectGalgameTags(<GalgameEntry>[
      entry(id: 'a', tags: <String>['b', 'a']),
      entry(id: 'b', tags: <String>['a', 'c']),
    ]);
    expect(tags, <String>['a', 'b', 'c']);
  });
}
