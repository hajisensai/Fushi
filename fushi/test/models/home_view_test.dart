import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_view.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';

/// 首页视图（models/home_view.dart）的模型 / 匹配器 / 编解码 / 自动名，以及开关关着
/// 时的过滤短路与设置默认值。
void main() {
  const HomeView ja = HomeView(id: 'v1', languages: <String>{'ja'});

  group('matchesHomeView：语言', () {
    test('原始语言按 normalizeLanguageBinding 归一（ja-JP = ja）', () {
      expect(matchesHomeView(ja, language: 'ja-JP'), isTrue);
      expect(matchesHomeView(ja, language: 'JA_jp'), isTrue);
      expect(matchesHomeView(ja, language: 'zh'), isFalse);
    });

    test('没设语言只在包含「未设语言」时出现', () {
      expect(matchesHomeView(ja), isFalse);
      expect(matchesHomeView(ja, language: ''), isFalse);
      expect(matchesHomeView(ja, language: 'und'), isFalse);
      const HomeView none = HomeView(id: 'v2', includeNoLanguage: true);
      expect(matchesHomeView(none), isTrue);
      expect(matchesHomeView(none, language: '  '), isTrue);
      expect(matchesHomeView(none, language: 'ja'), isFalse);
      final HomeView both = ja.copyWith(includeNoLanguage: true);
      expect(matchesHomeView(both), isTrue);
      expect(matchesHomeView(both, language: 'ja'), isTrue);
      expect(matchesHomeView(both, language: 'en'), isFalse);
    });

    test('不带文字子标签的视图语言含其各种文字，带的只含自己', () {
      const HomeView zh = HomeView(id: 'v', languages: <String>{'zh'});
      expect(matchesHomeView(zh, language: 'zh-Hant-TW'), isTrue);
      expect(matchesHomeView(zh, language: 'zh-CN'), isTrue);
      const HomeView hant = HomeView(id: 'v', languages: <String>{'zh-Hant'});
      expect(matchesHomeView(hant, language: 'zh-Hant-TW'), isTrue);
      expect(matchesHomeView(hant, language: 'zh-Hans'), isFalse);
      expect(matchesHomeView(hant, language: 'zh'), isFalse);
    });
  });

  group('matchesHomeView：标签', () {
    const HomeView anyTags = HomeView(
      id: 'v',
      tags: <String>{'anime', 'school'},
    );
    final HomeView allTags = anyTags.copyWith(matchAllTags: true);

    test('任一', () {
      expect(matchesHomeView(anyTags, tags: <String>{'school', 'x'}), isTrue);
      expect(matchesHomeView(anyTags, tags: <String>{'x'}), isFalse);
      expect(matchesHomeView(anyTags), isFalse);
    });

    test('全部', () {
      expect(
        matchesHomeView(allTags, tags: <String>{'anime', 'school', 'x'}),
        isTrue,
      );
      expect(matchesHomeView(allTags, tags: <String>{'anime'}), isFalse);
    });

    test('语言与标签都非空时取 AND', () {
      final HomeView view = ja.copyWith(tags: <String>{'ln'});
      expect(
        matchesHomeView(view, language: 'ja', tags: <String>{'ln'}),
        isTrue,
      );
      expect(matchesHomeView(view, language: 'ja'), isFalse);
      expect(
        matchesHomeView(view, language: 'en', tags: <String>{'ln'}),
        isFalse,
      );
    });

    test('没有任何条件 = 全部', () {
      const HomeView empty = HomeView(id: 'v');
      expect(empty.isEverything, isTrue);
      expect(matchesHomeView(empty), isTrue);
      expect(
        matchesHomeView(empty, language: 'xx', tags: <String>{'a'}),
        isTrue,
      );
    });
  });

  group('resolveActiveHomeView', () {
    final List<HomeView> views = <HomeView>[ja, const HomeView(id: 'empty')];

    test('开关关着 / 全部 / 指不到 / 空条件视图都是 null', () {
      expect(
        resolveActiveHomeView(enabled: false, views: views, activeId: 'v1'),
        isNull,
      );
      expect(
        resolveActiveHomeView(
          enabled: true,
          views: views,
          activeId: kHomeViewEverythingId,
        ),
        isNull,
      );
      expect(
        resolveActiveHomeView(enabled: true, views: views, activeId: 'gone'),
        isNull,
      );
      expect(
        resolveActiveHomeView(enabled: true, views: views, activeId: 'empty'),
        isNull,
      );
      expect(
        resolveActiveHomeView(enabled: true, views: views, activeId: 'v1'),
        ja,
      );
    });
  });

  group('编解码', () {
    test('往返', () {
      final List<HomeView> views = <HomeView>[
        const HomeView(
          id: 'a',
          name: 'Mine',
          languages: <String>{'ja', 'zh-Hant'},
          includeNoLanguage: true,
          tags: <String>{'school', 'anime'},
          matchAllTags: true,
        ),
        const HomeView(id: 'b', tags: <String>{'ln'}),
      ];
      expect(decodeHomeViews(encodeHomeViews(views)), views);
    });

    test('宽容解码：坏 JSON / 非数组 / 缺 id / 重复 id / 错类型', () {
      expect(decodeHomeViews(''), isEmpty);
      expect(decodeHomeViews('{not json'), isEmpty);
      expect(decodeHomeViews('{"id":"a"}'), isEmpty);
      final List<HomeView> views = decodeHomeViews(
        '[{"name":"no id"},{"id":""},'
        '{"id":"a","name":3,"langs":["ja-JP","!!",5],"noLang":"yes",'
        '"tags":[1," anime ","",null,"school"],"all":1},'
        '{"id":"a","langs":["en"]},7]',
      );
      expect(views, hasLength(1));
      final HomeView a = views.single;
      expect(a.id, 'a');
      expect(a.name, '');
      expect(a.languages, <String>{'ja'});
      expect(a.includeNoLanguage, isFalse);
      expect(a.tags, <String>{'anime', 'school'});
      expect(a.matchAllTags, isFalse);
    });
  });

  group('自动名', () {
    String nameOf(HomeView v) => homeViewDisplayName(
      v,
      languageLabel: (String l) =>
          <String, String>{'ja': '日本語', 'zh': '中文', 'en': 'English'}[l] ?? l,
      noLanguageLabel: 'No language set',
      everythingLabel: 'Everything',
    );

    test('语言显示名、#标签、组合与空', () {
      expect(nameOf(ja), '日本語');
      expect(
        nameOf(
          const HomeView(
            id: 'v',
            languages: <String>{'zh', 'en'},
            includeNoLanguage: true,
          ),
        ),
        'English + 中文 + No language set',
      );
      expect(
        nameOf(const HomeView(id: 'v', tags: <String>{'anime'})),
        '#anime',
      );
      expect(
        nameOf(ja.copyWith(tags: <String>{'school', 'anime'})),
        '日本語 · #anime + #school',
      );
      expect(nameOf(const HomeView(id: 'v')), 'Everything');
    });

    test('用户起的名字优先，空白回落自动名', () {
      expect(nameOf(ja.copyWith(name: 'Study')), 'Study');
      expect(nameOf(ja.copyWith(name: '   ')), '日本語');
    });
  });

  group('关着时不过滤', () {
    test('view 为 null：原样返回同一个列表，不查任何事实', () {
      final List<String> entries = <String>['a', 'b'];
      int lookups = 0;
      final List<String> out = filterForHomeView<String>(
        entries,
        view: null,
        subjectOf: (String _) {
          lookups++;
          return (language: null, tags: const <String>{});
        },
      );
      expect(identical(out, entries), isTrue);
      expect(lookups, 0);
    });

    test('开关关着时 resolveActiveHomeView 给 null，过滤短路', () {
      final HomeView? view = resolveActiveHomeView(
        enabled: false,
        views: <HomeView>[ja],
        activeId: ja.id,
      );
      final List<String> entries = <String>['x'];
      expect(
        identical(
          filterForHomeView<String>(
            entries,
            view: view,
            subjectOf: (String _) => throw StateError('must not look up'),
          ),
          entries,
        ),
        isTrue,
      );
    });

    test('开着时按事实过滤并保持顺序', () {
      final Map<String, String?> langs = <String, String?>{
        'a': 'ja-JP',
        'b': 'en',
        'c': null,
        'd': 'ja',
      };
      expect(
        filterForHomeView<String>(
          langs.keys.toList(),
          view: ja,
          subjectOf: (String e) => (language: langs[e], tags: const <String>{}),
        ),
        <String>['a', 'd'],
      );
    });
  });

  test('设置：首页视图开关默认关', () {
    final SettingsSection section = buildHomePanelsSection();
    final SettingsSwitchItem item = section.items
        .whereType<SettingsSwitchItem>()
        .singleWhere(
          (SettingsSwitchItem i) => i.id == 'navigation.home_widgets.views',
        );
    expect(item.defaultValue, isFalse);
  });
}
