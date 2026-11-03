import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/platform/widget_snapshot.dart';
import 'package:fushi/src/platform/widget_snapshot_labels.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// Android 桌面小组件快照：纯构建函数的 JSON 形状 / 夹取 / 模块门控 / 空态 / 目标 /
/// provider 隔离 / 词汇，以及发布器的签名去重（与原生侧 `WidgetSnapshot.kt` 的解析
/// 契约对齐，契约文档 docs/agent/android-widgets.md）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String today = '2026-10-23'; // 周五
  final WidgetSnapshotLabels labels = WidgetSnapshotLabels(<String, String>{
    for (final String key in kWidgetLabelKeys) key: 'L:$key',
  });

  String time(int ms) => '${ms ~/ 60000}m';
  String chars(int n) => '$n chars';
  String count(int n) => '#$n';
  String age(int epochMs) => 'age:$epochMs';
  String weekday(String key) => 'wd:${key.substring(8)}';

  WidgetMediaInput item(
    String id, {
    WidgetMediaKind kind = WidgetMediaKind.book,
    int recentAt = 0,
    double progress = 0.5,
    String cover = '',
    String subtitle = '',
    String title = 'T',
  }) => WidgetMediaInput(
    kind: kind,
    id: id,
    title: title,
    subtitle: subtitle,
    progress: progress,
    coverPath: cover,
    recentAt: recentAt,
  );

  Map<String, Object?> build({
    List<WidgetMediaInput> media = const <WidgetMediaInput>[],
    WidgetModulesInput modules = const WidgetModulesInput(),
    WidgetImmersionInput immersion = const WidgetImmersionInput(),
    WidgetGoalsInput goals = const WidgetGoalsInput(),
    WidgetSrsInput srs = const WidgetSrsInput(),
    List<WidgetVocabInput> vocab = const <WidgetVocabInput>[],
    String day = today,
    int generatedAt = 1000,
    bool hideTitles = false,
    bool hideDefinitions = false,
    bool hideProfile = false,
    String profileName = 'Default',
    bool multiProfile = false,
  }) => buildWidgetSnapshot(
    day: day,
    generatedAt: generatedAt,
    labels: labels,
    modules: modules,
    media: media,
    immersion: immersion,
    goals: goals,
    srs: srs,
    vocab: vocab,
    formatTime: time,
    formatChars: chars,
    formatCount: count,
    formatAge: age,
    weekdayLabel: weekday,
    categoryLabels: <WidgetImmersionCategory, String>{
      for (final WidgetImmersionCategory c in WidgetImmersionCategory.values)
        c: 'C:${c.wire}',
    },
    goalLabels: <String, String>{
      for (final String id in <String>[
        'total',
        'reading',
        'listening',
        'watching',
        'reviews',
        'mined',
        'chars',
      ])
        id: 'G:$id',
    },
    profileName: profileName,
    multiProfile: multiProfile,
    hideTitles: hideTitles,
    hideDefinitions: hideDefinitions,
    hideProfile: hideProfile,
  );

  List<Map<String, Object?>> listOf(Object? v) =>
      (v! as List<Object?>).cast<Map<String, Object?>>();
  Map<String, Object?> mapOf(Object? v) => v! as Map<String, Object?>;
  List<Map<String, Object?>> shelfOf(Map<String, Object?> s) =>
      listOf(s['shelf']);

  /// 一天的沉浸毫秒。
  Map<WidgetImmersionCategory, int> day(
    int reading, [
    int listening = 0,
    int watching = 0,
    int games = 0,
  ]) => <WidgetImmersionCategory, int>{
    WidgetImmersionCategory.reading: reading * 60000,
    WidgetImmersionCategory.listening: listening * 60000,
    WidgetImmersionCategory.watching: watching * 60000,
    WidgetImmersionCategory.games: games * 60000,
  };

  group('buildWidgetSnapshot shape', () {
    test('has the exact v2 JSON shape the native side parses', () {
      final Map<String, Object?> s = build(
        media: <WidgetMediaInput>[
          item(
            'b1',
            title: '  Title  ',
            subtitle: ' Author ',
            progress: 0.25,
            cover: '/data/cover.jpg',
            recentAt: 10,
          ),
        ],
        immersion: WidgetImmersionInput(
          msByDay: <String, Map<WidgetImmersionCategory, int>>{
            today: day(30, 0, 12),
          },
          charsByDay: const <String, int>{today: 12400},
          activeDays: const <String>{today},
        ),
        goals: const WidgetGoalsInput(chars: 24800),
        multiProfile: true,
      );
      // 能原样过 JSON（通道里发的就是 jsonEncode）。
      final Map<String, dynamic> json =
          jsonDecode(jsonEncode(s)) as Map<String, dynamic>;
      expect(json['v'], 2);
      expect(json['day'], today);
      expect(json['generatedAt'], 1000);
      expect(json['profile'], <String, Object?>{
        'name': 'Default',
        'multi': true,
      });
      expect(json['privacy'], <String, bool>{
        'hideTitles': false,
        'hideDefinitions': false,
        'hideProfile': false,
      });
      expect((json['labels'] as Map<String, dynamic>).keys.toSet(), <String>{
        ...kWidgetLabelKeys,
      });
      expect(json['modules'], <String, bool>{
        'books': true,
        'manga': true,
        'video': true,
        'lookup': true,
        'srs': true,
        'music': true,
        'games': true,
      });
      final Map<String, dynamic> cont =
          json['continue'] as Map<String, dynamic>;
      expect(cont, <String, Object?>{
        'kind': 'book',
        'id': 'b1',
        'title': 'Title',
        'subtitle': 'Author',
        'progress': 0.25,
        'cover': '/data/cover.jpg',
        'position': '25%',
        'lastActive': 'age:10',
      });
      expect(
        (json['today'] as Map<String, dynamic>).keys,
        containsAll(<String>[
          'time',
          'chars',
          'goal',
          'streak',
          'totalMs',
          'categories',
          'goalMs',
          'goalTime',
          'goalFrac',
        ]),
      );
      expect(
        (json['week'] as Map<String, dynamic>).keys,
        containsAll(<String>[
          'minutes',
          'days',
          'time',
          'chars',
          'prevTime',
          'deltaPct',
          'reviews',
          'goalDays',
        ]),
      );
      expect(
        (json['month'] as Map<String, dynamic>).keys,
        containsAll(<String>[
          'minutes',
          'reviews',
          'time',
          'activeDays',
          'firstWeekday',
        ]),
      );
      expect(
        (json['streak'] as Map<String, dynamic>).keys,
        containsAll(<String>[
          'current',
          'longest',
          'srsCurrent',
          'srsLongest',
          'week',
        ]),
      );
      expect(json['goals'], isA<List<Object?>>());
      expect(json['vocab'], isA<List<Object?>>());
    });

    test('is deterministic: same inputs give identical JSON', () {
      Map<String, Object?> make() => build(
        media: <WidgetMediaInput>[item('a', recentAt: 1), item('b')],
        vocab: <WidgetVocabInput>[
          const WidgetVocabInput(term: 'x', createdAt: 1, origin: 'mined'),
        ],
      );
      expect(jsonEncode(make()), jsonEncode(make()));
    });

    test('empty everything: zeros, empty lists, null delta, no throw', () {
      final Map<String, Object?> s = build();
      expect(s['continue'], isNull);
      expect(shelfOf(s), isEmpty);
      expect(s['goals'], isEmpty);
      expect(s['vocab'], isEmpty);
      final Map<String, Object?> t = mapOf(s['today']);
      expect(t['totalMs'], 0);
      expect(t['goalMs'], 0);
      expect(t['goalTime'], '');
      expect(t['goalFrac'], 0);
      expect(t['goal'], 0);
      final Map<String, Object?> w = mapOf(s['week']);
      expect(w['minutes'], List<int>.filled(7, 0));
      expect(w['deltaPct'], isNull);
      expect(w['goalDays'], isNull);
      expect(w['reviews'], isNull);
      final Map<String, Object?> m = mapOf(s['month']);
      expect(m['minutes'], List<int>.filled(35, 0));
      expect(m['reviews'], isNull);
      expect(m['activeDays'], 0);
      final Map<String, Object?> st = mapOf(s['streak']);
      expect(st['current'], 0);
      expect(st['longest'], 0);
      expect(st['week'], List<bool>.filled(7, false));
    });
  });

  group('media shelf', () {
    test('continue is the most recent item; shelf is capped at 4', () {
      final Map<String, Object?> s = build(
        media: <WidgetMediaInput>[
          item('old', recentAt: 1),
          item('newest', kind: WidgetMediaKind.video, recentAt: 99),
          item('mid', recentAt: 50),
          item('m2', kind: WidgetMediaKind.manga, recentAt: 40),
          item('m3', recentAt: 30),
          item('m4', recentAt: 20),
        ],
      );
      expect(mapOf(s['continue'])['id'], 'newest');
      expect(shelfOf(s).map((Map<String, Object?> e) => e['id']), <String>[
        'newest',
        'mid',
        'm2',
        'm3',
      ]);
    });

    test('ties keep input order; missing recentAt gives empty lastActive', () {
      final Map<String, Object?> s = build(
        media: <WidgetMediaInput>[item('a'), item('b'), item('c')],
      );
      expect(shelfOf(s).map((Map<String, Object?> e) => e['id']), <String>[
        'a',
        'b',
        'c',
      ]);
      expect(shelfOf(s).first['lastActive'], '');
    });

    test('progress is clamped, NaN becomes 0, position hides at 0', () {
      final Map<String, Object?> s = build(
        media: <WidgetMediaInput>[
          item('hi', progress: 7, recentAt: 4),
          item('lo', progress: -1, recentAt: 3),
          item('nan', progress: double.nan, recentAt: 2),
          item('half', progress: 0.456, recentAt: 1),
        ],
      );
      final List<Map<String, Object?>> shelf = shelfOf(s);
      expect(shelf[0]['progress'], 1);
      expect(shelf[0]['position'], '100%');
      expect(shelf[1]['progress'], 0);
      expect(shelf[1]['position'], '');
      expect(shelf[2]['progress'], 0);
      expect(shelf[3]['position'], '46%');
    });

    test('a disabled module drops its items before continue / shelf', () {
      final List<WidgetMediaInput> media = <WidgetMediaInput>[
        item('manga', kind: WidgetMediaKind.manga, recentAt: 9),
        item('video', kind: WidgetMediaKind.video, recentAt: 8),
        item('book', recentAt: 1),
      ];
      final Map<String, Object?> s = build(
        media: media,
        modules: const WidgetModulesInput(manga: false, video: false),
      );
      expect(mapOf(s['continue'])['id'], 'book');
      expect(shelfOf(s), hasLength(1));
      expect(mapOf(s['modules'])['manga'], false);
      expect(
        build(
          media: media,
          modules: const WidgetModulesInput(books: false),
        )['continue'],
        isNotNull,
      );
    });

    test('items without an id are skipped; titles pass through untouched', () {
      final Map<String, Object?> s = build(
        media: <WidgetMediaInput>[
          item('', recentAt: 9),
          item('rtl', title: 'كتاب القراءة', subtitle: '著者', recentAt: 1),
        ],
      );
      expect(shelfOf(s), hasLength(1));
      expect(shelfOf(s).single['title'], 'كتاب القراءة');
      expect(shelfOf(s).single['subtitle'], '著者');
    });
  });

  group('immersion', () {
    test('categories keep a fixed order, links and per-category time', () {
      final Map<String, Object?> s = build(
        immersion: WidgetImmersionInput(
          msByDay: <String, Map<WidgetImmersionCategory, int>>{
            today: day(10, 20, 30, 40),
          },
        ),
      );
      final List<Map<String, Object?>> cats = listOf(
        mapOf(s['today'])['categories'],
      );
      expect(cats.map((Map<String, Object?> c) => c['id']), <String>[
        'reading',
        'listening',
        'watching',
        'games',
      ]);
      expect(cats.map((Map<String, Object?> c) => c['time']), <String>[
        '10m',
        '20m',
        '30m',
        '40m',
      ]);
      expect(cats.map((Map<String, Object?> c) => c['link']), <String>[
        'fushi://widget/tab/books',
        'fushi://widget/tab/music',
        'fushi://widget/tab/video',
        'fushi://widget/tab/games',
      ]);
      expect(mapOf(s['today'])['totalMs'], 100 * 60000);
      // 每个链接都能被 WidgetLink 解析回对应 tab。
      for (final Map<String, Object?> c in cats) {
        expect(WidgetLink.tryParse(c['link']! as String), isA<WidgetTabLink>());
      }
    });

    test(
      'mediaKind mapping: reading=book, listening=music, review ignored',
      () {
        expect(
          WidgetImmersionCategory.fromMediaKind('book'),
          WidgetImmersionCategory.reading,
        );
        expect(
          WidgetImmersionCategory.fromMediaKind('music'),
          WidgetImmersionCategory.listening,
        );
        expect(
          WidgetImmersionCategory.fromMediaKind('video'),
          WidgetImmersionCategory.watching,
        );
        expect(
          WidgetImmersionCategory.fromMediaKind('game'),
          WidgetImmersionCategory.games,
        );
        expect(WidgetImmersionCategory.fromMediaKind('review'), isNull);
        expect(WidgetImmersionCategory.fromMediaKind('???'), isNull);
      },
    );

    test('week / month arrays are oldest to today, with weekday labels', () {
      final Map<String, Object?> s = build(
        immersion: WidgetImmersionInput(
          msByDay: <String, Map<WidgetImmersionCategory, int>>{
            '2026-10-23': day(5),
            '2026-10-22': day(3, 0, 1),
            '2026-10-17': day(7),
            '2026-10-16': day(60), // 周窗口之外（上周窗口内），月内
            '2026-09-19': day(11), // 月窗口第一天
            '2026-09-18': day(99), // 月窗口之外
          },
        ),
      );
      final Map<String, Object?> w = mapOf(s['week']);
      expect(w['minutes'], <int>[7, 0, 0, 0, 0, 4, 5]);
      expect(w['days'], <String>[
        'wd:17',
        'wd:18',
        'wd:19',
        'wd:20',
        'wd:21',
        'wd:22',
        'wd:23',
      ]);
      expect(w['time'], '16m');
      final Map<String, Object?> m = mapOf(s['month']);
      final List<int> minutes = (m['minutes']! as List<Object?>).cast<int>();
      expect(minutes, hasLength(35));
      expect(minutes.first, 11);
      expect(minutes.last, 5);
      expect(minutes[34 - 7], 60);
      expect(m['time'], '${11 + 60 + 7 + 4 + 5}m');
      expect(m['firstWeekday'], 6, reason: '2026-09-19 is a Saturday');
    });

    test('week-over-week: null without previous data, signed percent else', () {
      final Map<String, Object?> none = build(
        immersion: WidgetImmersionInput(
          msByDay: <String, Map<WidgetImmersionCategory, int>>{today: day(10)},
        ),
      );
      expect(mapOf(none['week'])['deltaPct'], isNull);
      expect(mapOf(none['week'])['prevTime'], '0m');

      final Map<String, Object?> up = build(
        immersion: WidgetImmersionInput(
          msByDay: <String, Map<WidgetImmersionCategory, int>>{
            today: day(118),
            '2026-10-16': day(50), // 上周窗口 = 10-10 .. 10-16
            '2026-10-10': day(50),
          },
        ),
      );
      expect(mapOf(up['week'])['deltaPct'], 18);
      expect(mapOf(up['week'])['prevTime'], '100m');

      final Map<String, Object?> down = build(
        immersion: WidgetImmersionInput(
          msByDay: <String, Map<WidgetImmersionCategory, int>>{
            today: day(50),
            '2026-10-12': day(100),
          },
        ),
      );
      expect(mapOf(down['week'])['deltaPct'], -50);
    });

    test('negative milliseconds never leak out', () {
      final Map<String, Object?> s = build(
        immersion: WidgetImmersionInput(
          msByDay: <String, Map<WidgetImmersionCategory, int>>{
            today: <WidgetImmersionCategory, int>{
              WidgetImmersionCategory.reading: -5000,
            },
          },
          charsByDay: const <String, int>{today: -3},
        ),
      );
      expect(mapOf(s['today'])['totalMs'], 0);
      expect(mapOf(s['today'])['chars'], '0 chars');
    });

    test('month rolls over a year boundary with key arithmetic', () {
      final Map<String, Object?> s = build(day: '2027-01-03');
      expect(mapOf(s['week'])['days'], <String>[
        'wd:28',
        'wd:29',
        'wd:30',
        'wd:31',
        'wd:01',
        'wd:02',
        'wd:03',
      ]);
    });
  });

  group('streaks', () {
    test('computeLongestStreak', () {
      expect(computeLongestStreak(<String>{}), 0);
      expect(computeLongestStreak(<String>{'2026-10-23'}), 1);
      expect(
        computeLongestStreak(<String>{
          '2026-10-01',
          '2026-10-02',
          '2026-10-04',
          '2026-10-05',
          '2026-10-06',
          '2026-10-08',
        }),
        3,
      );
      // 跨月 / 跨年连续。
      expect(
        computeLongestStreak(<String>{
          '2026-12-30',
          '2026-12-31',
          '2027-01-01',
          '2027-01-02',
        }),
        4,
      );
    });

    test('computeCurrentStreak: today optional, gap resets', () {
      expect(computeCurrentStreak(<String>{}, today), 0);
      expect(
        computeCurrentStreak(<String>{'2026-10-23', '2026-10-22'}, today),
        2,
      );
      // 今天还没学，从昨天起算。
      expect(
        computeCurrentStreak(<String>{'2026-10-22', '2026-10-21'}, today),
        2,
      );
      // 昨天也断了。
      expect(computeCurrentStreak(<String>{'2026-10-21'}, today), 0);
    });

    test('snapshot carries current, longest and the active week', () {
      final Map<String, Object?> s = build(
        immersion: const WidgetImmersionInput(
          activeDays: <String>{
            '2026-10-23',
            '2026-10-22',
            '2026-10-20',
            '2026-08-01',
            '2026-08-02',
            '2026-08-03',
            '2026-08-04',
          },
        ),
      );
      final Map<String, Object?> st = mapOf(s['streak']);
      expect(st['current'], 2);
      expect(st['longest'], 4);
      expect(st['week'], <bool>[false, false, false, true, false, true, true]);
      expect(mapOf(s['today'])['streak'], 2);
      expect(mapOf(s['month'])['activeDays'], 3);
    });
  });

  group('goals', () {
    test('only configured goals appear, with frac / done / formatting', () {
      final Map<String, Object?> s = build(
        immersion: WidgetImmersionInput(
          msByDay: <String, Map<WidgetImmersionCategory, int>>{
            today: day(30, 5, 25),
          },
          charsByDay: const <String, int>{today: 2000},
        ),
        goals: const WidgetGoalsInput(
          totalMinutes: 120,
          readingMinutes: 30,
          videoMinutes: 50,
          chars: 1000,
          minedCards: 4,
          minedToday: 1,
        ),
      );
      final List<Map<String, Object?>> goals = listOf(s['goals']);
      expect(goals.map((Map<String, Object?> g) => g['id']), <String>[
        'total',
        'reading',
        'watching',
        'mined',
        'chars',
      ]);
      final Map<String, Object?> total = goals[0];
      expect(total['label'], 'G:total');
      expect(total['value'], '60m');
      expect(total['target'], '120m');
      expect(total['frac'], 0.5);
      expect(total['done'], false);
      expect(goals[1]['done'], true, reason: '30 of 30 minutes');
      expect(goals[1]['frac'], 1);
      expect(goals[2]['frac'], 0.5);
      expect(goals[3]['value'], '#1');
      expect(goals[3]['target'], '#4');
      expect(goals[3]['frac'], 0.25);
      expect(goals[4]['frac'], 1, reason: 'clamped');
      expect(goals[4]['value'], '2000 chars');

      final Map<String, Object?> t = mapOf(s['today']);
      expect(t['goalMs'], 120 * 60000);
      expect(t['goalTime'], '120m');
      expect(t['goalFrac'], 0.5);
      expect(t['goal'], 1, reason: 'legacy char goal fraction, clamped');
    });

    test('no goals set: empty list', () {
      expect(build(goals: const WidgetGoalsInput())['goals'], isEmpty);
    });

    test('week goalDays counts days meeting the time goal', () {
      final Map<String, Object?> s = build(
        immersion: WidgetImmersionInput(
          msByDay: <String, Map<WidgetImmersionCategory, int>>{
            '2026-10-23': day(30),
            '2026-10-22': day(20, 10),
            '2026-10-21': day(29),
            '2026-10-20': day(0, 0, 45),
          },
        ),
        goals: const WidgetGoalsInput(totalMinutes: 30),
      );
      expect(mapOf(s['week'])['goalDays'], 3);
    });

    test('reviews goal only exists for Fushi SRS', () {
      const WidgetGoalsInput goals = WidgetGoalsInput(reviews: 100);
      final Map<String, Object?> fushi = build(
        goals: goals,
        srs: const WidgetSrsInput(
          provider: WidgetSrsProvider.fushi,
          reviewedToday: 40,
        ),
      );
      expect(listOf(fushi['goals']).single, containsPair('value', '#40'));
      for (final WidgetSrsProvider p in <WidgetSrsProvider>[
        WidgetSrsProvider.anki,
        WidgetSrsProvider.none,
      ]) {
        expect(
          build(
            goals: goals,
            srs: WidgetSrsInput(provider: p, reviewedToday: 40),
          )['goals'],
          isEmpty,
        );
      }
    });
  });

  group('srs provider isolation', () {
    const WidgetSrsInput loaded = WidgetSrsInput(
      provider: WidgetSrsProvider.fushi,
      label: 'Fushi SRS',
      newCount: 20,
      learnCount: 18,
      reviewCount: 90,
      reviewedToday: 52,
      dueTomorrow: 75,
      streakCurrent: 5,
      streakLongest: 41,
      reviewsByDay: <int>[1, 2, 3],
    );

    test('fushi carries all counts, streaks and review series', () {
      final Map<String, Object?> s = build(srs: loaded);
      final Map<String, Object?> srs = mapOf(s['srs']);
      expect(srs['provider'], 'fushi');
      expect(srs['label'], 'Fushi SRS');
      expect(srs['enabled'], true);
      expect(srs['due'], 128);
      expect(srs['new'], 20);
      expect(srs['learn'], 18);
      expect(srs['review'], 90);
      expect(srs['reviewedToday'], 52);
      expect(srs['dueTomorrow'], 75);
      expect(srs.containsKey('ankiPackage'), isFalse);
      expect(mapOf(s['streak'])['srsCurrent'], 5);
      expect(mapOf(s['streak'])['srsLongest'], 41);
      final List<int> series = (mapOf(s['month'])['reviews']! as List<Object?>)
          .cast<int>();
      expect(series, hasLength(35));
      expect(series.sublist(32), <int>[1, 2, 3]);
      expect(mapOf(s['week'])['reviews'], 6);
    });

    test('anki and none never carry Fushi counts, even if given', () {
      for (final WidgetSrsProvider p in <WidgetSrsProvider>[
        WidgetSrsProvider.anki,
        WidgetSrsProvider.none,
      ]) {
        final Map<String, Object?> s = build(
          srs: WidgetSrsInput(
            provider: p,
            label: p == WidgetSrsProvider.anki ? 'AnkiDroid' : '',
            newCount: 20,
            learnCount: 18,
            reviewCount: 90,
            reviewedToday: 52,
            dueTomorrow: 75,
            streakCurrent: 5,
            streakLongest: 41,
            reviewsByDay: const <int>[1, 2, 3],
          ),
        );
        final Map<String, Object?> srs = mapOf(s['srs']);
        expect(srs['provider'], p.wire);
        expect(srs['enabled'], false);
        expect(srs['due'], 0);
        for (final String key in <String>[
          'new',
          'learn',
          'review',
          'reviewedToday',
          'dueTomorrow',
        ]) {
          expect(srs.containsKey(key), isFalse, reason: '$p leaked $key');
        }
        expect(srs.containsKey('ankiPackage'), p == WidgetSrsProvider.anki);
        expect(mapOf(s['streak'])['srsCurrent'], isNull);
        expect(mapOf(s['streak'])['srsLongest'], isNull);
        expect(mapOf(s['month'])['reviews'], isNull);
        expect(mapOf(s['week'])['reviews'], isNull);
      }
    });

    test('anki reports the package to query', () {
      final Map<String, Object?> s = build(
        srs: const WidgetSrsInput(provider: WidgetSrsProvider.anki),
      );
      expect(mapOf(s['srs'])['ankiPackage'], 'com.ichi2.anki');
    });

    test('negative counts are clamped to zero', () {
      final Map<String, Object?> s = build(
        srs: const WidgetSrsInput(
          provider: WidgetSrsProvider.fushi,
          newCount: -1,
          learnCount: -2,
          reviewCount: 4,
          reviewsByDay: <int>[-5],
        ),
      );
      expect(mapOf(s['srs'])['due'], 4);
      expect(mapOf(s['srs'])['new'], 0);
      expect(mapOf(s['week'])['reviews'], 0);
    });
  });

  group('vocab', () {
    WidgetVocabInput word(
      String term,
      int at, {
      String origin = 'mined',
      String reading = '',
      String definition = '',
    }) => WidgetVocabInput(
      term: term,
      reading: reading,
      definition: definition,
      createdAt: at,
      origin: origin,
      source: ' Book ',
      sentence: '<b>Sentence</b>',
    );

    test('merged newest first, capped at 12, stable on ties', () {
      final List<WidgetVocabInput> input = <WidgetVocabInput>[
        for (int i = 0; i < 10; i++) word('m$i', i * 10),
        for (int i = 0; i < 10; i++)
          word('f$i', i * 10 + 5, origin: 'favorite'),
        word('tie-a', 1000),
        word('tie-b', 1000),
      ];
      final List<Map<String, Object?>> out = listOf(
        build(vocab: input)['vocab'],
      );
      expect(out, hasLength(kWidgetVocabLimit));
      expect(out.first['term'], 'tie-a');
      expect(out[1]['term'], 'tie-b');
      expect(out[2]['term'], 'f9');
      expect(out[2]['origin'], 'favorite');
      expect(out[3]['term'], 'm9');
      expect(out[3]['origin'], 'mined');
      expect(out.last['term'], 'm5');
    });

    test('fields are trimmed, markup stripped, text passes through', () {
      final List<Map<String, Object?>> out = listOf(
        build(
          vocab: <WidgetVocabInput>[
            word(
              '  食べる ',
              1,
              reading: ' たべる ',
              definition:
                  '<ol><li>to eat</li><li>to live&nbsp;on</li></ol>'
                  '<style>.x{color:red}</style>&amp; كلمة',
            ),
          ],
        )['vocab'],
      );
      expect(out.single, <String, Object?>{
        'term': '食べる',
        'reading': 'たべる',
        'definition': 'to eat to live on & كلمة',
        'sentence': 'Sentence',
        'source': 'Book',
        'origin': 'mined',
      });
    });

    test('content does not depend on privacy flags (native hides it)', () {
      final List<WidgetVocabInput> input = <WidgetVocabInput>[
        word('a', 1, definition: 'def'),
      ];
      final Map<String, Object?> shown = build(vocab: input);
      final Map<String, Object?> hidden = build(
        vocab: input,
        hideTitles: true,
        hideDefinitions: true,
        hideProfile: true,
      );
      expect(shown['vocab'], hidden['vocab']);
      expect(mapOf(hidden['privacy']), <String, bool>{
        'hideTitles': true,
        'hideDefinitions': true,
        'hideProfile': true,
      });
    });

    test(
      'same word mined and favorited shows once (the newest); empty terms drop',
      () {
        final List<Map<String, Object?>> out = listOf(
          build(
            vocab: <WidgetVocabInput>[
              word('犬', 5, reading: 'いぬ'),
              word('犬', 9, reading: 'いぬ', origin: 'favorite'),
              word('犬', 7, reading: 'けん'),
              word('   ', 99),
            ],
          )['vocab'],
        );
        expect(out.map((Map<String, Object?> e) => e['origin']), <String>[
          'favorite',
          'mined',
        ]);
        expect(out.map((Map<String, Object?> e) => e['reading']), <String>[
          'いぬ',
          'けん',
        ]);
      },
    );

    test('widgetPlainText truncates by code points with an ellipsis', () {
      expect(widgetPlainText(''), '');
      final String long = '😀' * 300;
      final String cut = widgetPlainText(long);
      expect(cut.runes.length, kWidgetDefinitionMaxChars + 1);
      expect(cut.endsWith('…'), isTrue);
      expect(widgetPlainText('a  b\n c'), 'a b c');
    });
  });

  group('privacy / profile / stale data', () {
    test('privacy and profile come straight from the inputs', () {
      final Map<String, Object?> s = build(
        hideProfile: true,
        profileName: 'Étudiant',
        multiProfile: true,
      );
      expect(mapOf(s['profile']), <String, Object?>{
        'name': 'Étudiant',
        'multi': true,
      });
      expect(mapOf(s['privacy'])['hideProfile'], true);
    });

    test('generatedAt is passed through for the stale-age display', () {
      expect(build(generatedAt: 123456)['generatedAt'], 123456);
    });
  });

  group('labels', () {
    test('every label key is present and non-empty (en)', () {
      final Map<String, String> values = buildWidgetLabels().values;
      expect(values.keys.toSet(), kWidgetLabelKeys.toSet());
      for (final MapEntry<String, String> e in values.entries) {
        expect(e.value, isNotEmpty, reason: e.key);
      }
    });

    test('templates keep their placeholders for the native side', () {
      final Map<String, String> v = buildWidgetLabels().values;
      expect(v['updatedAgo'], contains('{age}'));
      expect(v['agoMinutes'], contains('{n}'));
      expect(v['agoHours'], contains('{n}'));
      expect(v['agoDays'], contains('{n}'));
    });

    test('category and goal labels cover every id', () {
      expect(
        buildWidgetCategoryLabels().keys.toSet(),
        WidgetImmersionCategory.values.toSet(),
      );
      expect(buildWidgetGoalLabels().keys.toSet(), <String>{
        'total',
        'reading',
        'listening',
        'watching',
        'reviews',
        'mined',
        'chars',
      });
    });

    test('label keys are unique', () {
      expect(kWidgetLabelKeys.toSet().length, kWidgetLabelKeys.length);
    });
  });

  test('clampWidgetFraction', () {
    expect(clampWidgetFraction(0.5), 0.5);
    expect(clampWidgetFraction(-3), 0);
    expect(clampWidgetFraction(3), 1);
    expect(clampWidgetFraction(double.nan), 0);
    expect(clampWidgetFraction(double.infinity), 0);
  });

  group('WidgetSnapshotPublisher', () {
    final List<MethodCall> calls = <MethodCall>[];
    bool failNext = false;
    DateTime clock = DateTime(2026, 10, 23, 8);

    setUp(() {
      calls.clear();
      failNext = false;
      clock = DateTime(2026, 10, 23, 8);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.widgets, (
            MethodCall call,
          ) async {
            calls.add(call);
            if (failNext) {
              failNext = false;
              throw PlatformException(code: 'boom');
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.widgets, null);
    });

    WidgetSnapshotPublisher publisher({bool supported = true}) =>
        WidgetSnapshotPublisher(platformSupported: supported, now: () => clock);

    WidgetSrsInput srsDue(int n) =>
        WidgetSrsInput(provider: WidgetSrsProvider.fushi, reviewCount: n);

    test('uses the native channel name', () {
      expect(FushiChannels.widgets.name, 'app.fushi.reader/widgets');
    });

    test('sends one JSON string through updateSnapshot', () async {
      final Map<String, Object?> snapshot = build(srs: srsDue(3));
      await publisher().publish(snapshot);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'updateSnapshot');
      expect(calls.single.arguments, isA<String>());
      expect(
        jsonDecode(calls.single.arguments as String),
        jsonDecode(jsonEncode(snapshot)),
      );
    });

    test('identical snapshots are deduped, changed ones go through', () async {
      final WidgetSnapshotPublisher p = publisher();
      await p.publish(build(srs: srsDue(3)));
      await p.publish(build(srs: srsDue(3)));
      expect(calls, hasLength(1));
      await p.publish(build(srs: srsDue(4)));
      expect(calls, hasLength(2));
    });

    test('generatedAt alone does not defeat the dedup', () async {
      final WidgetSnapshotPublisher p = publisher();
      await p.publish(build(srs: srsDue(3), generatedAt: 1));
      clock = clock.add(const Duration(minutes: 1));
      await p.publish(build(srs: srsDue(3), generatedAt: 2));
      expect(calls, hasLength(1));
    });

    test(
      'an unchanged snapshot is re-sent after the refresh interval',
      () async {
        final WidgetSnapshotPublisher p = publisher();
        await p.publish(build(srs: srsDue(3), generatedAt: 1));
        clock = clock.add(const Duration(minutes: 11));
        await p.publish(build(srs: srsDue(3), generatedAt: 2));
        expect(calls, hasLength(2));
        expect(
          (jsonDecode(calls.last.arguments as String)
              as Map<String, dynamic>)['generatedAt'],
          2,
        );
      },
    );

    test('a failed send is retried by the next identical publish', () async {
      final WidgetSnapshotPublisher p = publisher();
      failNext = true;
      await p.publish(build(srs: srsDue(3)));
      expect(calls, hasLength(1));
      await p.publish(build(srs: srsDue(3)));
      expect(calls, hasLength(2), reason: 'signature cleared on failure');
    });

    test('is a no-op where there is no native side', () async {
      await publisher(supported: false).publish(build());
      expect(calls, isEmpty);
    });
  });

  test('WidgetMediaKind wire values match the native contract', () {
    expect(WidgetMediaKind.values.map((WidgetMediaKind k) => k.wire), <String>[
      'book',
      'manga',
      'video',
    ]);
  });
}
