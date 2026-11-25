// 首页小组件网格的纯模型（spec docs/specs/2026-11-15-home-widgets-design.md）：
// 目录 / 连续尺寸范围与拖角吸附、行高、密集装箱、编辑操作与撤销、偏好编解码、从旧「首页面板」
// 显示档迁移、可用性判据。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/models/home_widget_layout.dart';

const HomeWidgetSize s11 = HomeWidgetSize(1, 1);
const HomeWidgetSize s21 = HomeWidgetSize(2, 1);
const HomeWidgetSize s22 = HomeWidgetSize(2, 2);
const HomeWidgetSize s23 = HomeWidgetSize(2, 3);
const HomeWidgetSize s42 = HomeWidgetSize(4, 2);

HomeWidgetItem item(HomeWidgetKind kind, HomeWidgetSize size) =>
    HomeWidgetItem(kind, size);

List<HomeWidgetKind> kinds(List<HomeWidgetItem> items) => <HomeWidgetKind>[
  for (final HomeWidgetItem e in items) e.kind,
];

void main() {
  group('目录', () {
    test('13 种组件，持久化 id 冻结且唯一', () {
      expect(
        HomeWidgetKind.values.map((HomeWidgetKind k) => k.id).toList(),
        <String>[
          'continue',
          'continue_reading',
          'continue_watching',
          'continue_playing',
          'today',
          'week',
          'srs_review',
          'recently_added',
          'tracking',
          'ai_agent',
          'panorama',
          'language_goals',
          'favorites',
        ],
      );
      for (final HomeWidgetKind k in HomeWidgetKind.values) {
        expect(HomeWidgetKind.fromId(k.id), k);
      }
      expect(HomeWidgetKind.fromId('nope'), isNull);
      expect(HomeWidgetKind.fromId(3), isNull);
    });

    test('尺寸范围与 spec 一致（宽网格口径 min…max）', () {
      const Map<HomeWidgetKind, (HomeWidgetSize, HomeWidgetSize)> spec =
          <HomeWidgetKind, (HomeWidgetSize, HomeWidgetSize)>{
            HomeWidgetKind.continueHero: (
              HomeWidgetSize(1, 2),
              HomeWidgetSize(6, 4),
            ),
            HomeWidgetKind.continueReading: (s11, HomeWidgetSize(6, 3)),
            HomeWidgetKind.continueWatching: (s11, HomeWidgetSize(6, 3)),
            HomeWidgetKind.continuePlaying: (s11, HomeWidgetSize(6, 3)),
            HomeWidgetKind.today: (s11, HomeWidgetSize(3, 2)),
            HomeWidgetKind.week: (s11, HomeWidgetSize(6, 3)),
            HomeWidgetKind.srsReview: (s11, HomeWidgetSize(3, 2)),
            HomeWidgetKind.recentlyAdded: (
              HomeWidgetSize(1, 2),
              HomeWidgetSize(6, 4),
            ),
            HomeWidgetKind.tracking: (s11, HomeWidgetSize(6, 2)),
            HomeWidgetKind.aiAgent: (s11, HomeWidgetSize(3, 2)),
            HomeWidgetKind.panorama: (s11, HomeWidgetSize(6, 4)),
            HomeWidgetKind.languageGoals: (s11, HomeWidgetSize(3, 2)),
            HomeWidgetKind.favorites: (s11, HomeWidgetSize(6, 4)),
          };
      expect(spec.keys.toSet(), HomeWidgetKind.values.toSet());
      for (final HomeWidgetKind k in HomeWidgetKind.values) {
        expect(k.minFor(HomeGridKind.wide), spec[k]!.$1, reason: k.id);
        expect(k.maxFor(HomeGridKind.wide), spec[k]!.$2, reason: k.id);
        // 高度不超过 4 行；宽网格最多 6 列。
        expect(k.maxFor(HomeGridKind.wide).rows, lessThanOrEqualTo(4));
        expect(k.maxFor(HomeGridKind.wide).cols, lessThanOrEqualTo(6));
        // 每种组件在两种网格里都能调（范围不止一格）。
        expect(k.resizableIn(HomeGridKind.wide), isTrue, reason: k.id);
        expect(k.resizableIn(HomeGridKind.compact), isTrue, reason: k.id);
      }
      expect(s21.toString(), '2×1');
    });

    test('「收藏句子」：学习类、默认 2×2 / 4×2，可选组件不进默认模板', () {
      const HomeWidgetKind k = HomeWidgetKind.favorites;
      expect(k.category, HomeWidgetCategory.study);
      expect(k.defaultFor(HomeGridKind.compact), s22);
      expect(k.defaultFor(HomeGridKind.wide), s42);
      expect(k.maxFor(HomeGridKind.compact), const HomeWidgetSize(2, 4));
      expect(k.repeatable, isFalse);
      for (final bool on in <bool>[false, true]) {
        for (final HomeGridKind g in HomeGridKind.values) {
          final List<HomeWidgetItem> migrated = migrateHomeWidgetLayout(
            grid: g,
            modes: <HomeDashboardPanel, HomeDashboardPanelMode>{
              for (final HomeDashboardPanel p in HomeDashboardPanel.values)
                p: on
                    ? HomeDashboardPanelMode.shown
                    : HomeDashboardPanelMode.hidden,
            },
            auto: HomeWidgetAutoFacts(
              srsReview: on,
              tracking: on,
              aiAgent: on,
              panorama: on,
            ),
          );
          expect(
            kinds(migrated),
            isNot(contains(HomeWidgetKind.favorites)),
            reason: g.wire,
          );
        }
      }
    });

    test('窄网格宽度封顶 2 列，高度范围不变', () {
      for (final HomeWidgetKind k in HomeWidgetKind.values) {
        final HomeWidgetSize max = k.maxFor(HomeGridKind.compact);
        expect(max.cols, lessThanOrEqualTo(2), reason: k.id);
        expect(max.rows, k.maxFor(HomeGridKind.wide).rows, reason: k.id);
        expect(
          k.minFor(HomeGridKind.compact),
          k.minFor(HomeGridKind.wide),
          reason: '下限都不超过 2 列：${k.id}',
        );
      }
      expect(
        HomeWidgetKind.continueHero.maxFor(HomeGridKind.compact),
        const HomeWidgetSize(2, 4),
      );
      expect(
        HomeWidgetKind.today.maxFor(HomeGridKind.compact),
        const HomeWidgetSize(2, 2),
      );
    });

    test('默认尺寸落在范围内；窄 / 宽各一份', () {
      for (final HomeWidgetKind k in HomeWidgetKind.values) {
        for (final HomeGridKind g in HomeGridKind.values) {
          final HomeWidgetSize d = k.defaultFor(g);
          expect(clampHomeWidgetSize(k, g, d), d, reason: '${k.id} ${g.wire}');
        }
      }
      expect(HomeWidgetKind.continueHero.defaultFor(HomeGridKind.wide), s42);
      expect(HomeWidgetKind.continueHero.defaultFor(HomeGridKind.compact), s22);
      expect(HomeWidgetKind.today.defaultFor(HomeGridKind.compact), s11);
      // 窄网格默认半栏（所有者 2026-11-15）；宽网格默认不变。
      expect(HomeWidgetKind.week.defaultFor(HomeGridKind.compact), s11);
      expect(HomeWidgetKind.tracking.defaultFor(HomeGridKind.compact), s11);
      expect(HomeWidgetKind.week.defaultFor(HomeGridKind.wide), s22);
      expect(HomeWidgetKind.tracking.defaultFor(HomeGridKind.wide), s21);
    });

    test('1 列下限：半栏组件在两种网格里都能缩到 1 列', () {
      for (final HomeWidgetKind k in HomeWidgetKind.values) {
        for (final HomeGridKind g in HomeGridKind.values) {
          expect(k.minFor(g).cols, 1, reason: '${k.id} ${g.wire}');
        }
      }
      expect(
        HomeWidgetKind.recentlyAdded.minFor(HomeGridKind.compact),
        const HomeWidgetSize(1, 2),
      );
      expect(
        HomeWidgetKind.continueHero.minFor(HomeGridKind.wide),
        const HomeWidgetSize(1, 2),
      );
      expect(
        clampHomeWidgetSize(
          HomeWidgetKind.recentlyAdded,
          HomeGridKind.compact,
          s11,
        ),
        const HomeWidgetSize(1, 2),
      );
    });

    test('clampHomeWidgetSize：各轴独立钳进范围（含窄网格列数封顶）', () {
      expect(
        clampHomeWidgetSize(
          HomeWidgetKind.continueHero,
          HomeGridKind.compact,
          s42,
        ),
        s22,
      );
      expect(
        clampHomeWidgetSize(
          HomeWidgetKind.continueHero,
          HomeGridKind.wide,
          const HomeWidgetSize(9, 9),
        ),
        const HomeWidgetSize(6, 4),
      );
      expect(
        clampHomeWidgetSize(
          HomeWidgetKind.today,
          HomeGridKind.wide,
          const HomeWidgetSize(0, 0),
        ),
        s11,
      );
      expect(
        clampHomeWidgetSize(
          HomeWidgetKind.tracking,
          HomeGridKind.wide,
          const HomeWidgetSize(5, 3),
        ),
        const HomeWidgetSize(5, 2),
      );
      // 范围内原样不动（连续尺寸，不再吸到离散档）。
      expect(
        clampHomeWidgetSize(
          HomeWidgetKind.week,
          HomeGridKind.wide,
          const HomeWidgetSize(5, 3),
        ),
        const HomeWidgetSize(5, 3),
      );
    });
  });

  group('拖角吸附', () {
    // 宽网格：格宽 150、行高 118、间距 14 → 列步长 164、行步长 132。
    HomeWidgetSize drag(
      HomeWidgetKind kind,
      HomeWidgetSize start,
      double dx,
      double dy, {
      HomeGridKind grid = HomeGridKind.wide,
    }) => homeWidgetDragSize(
      kind: kind,
      grid: grid,
      start: start,
      dx: dx,
      dy: dy,
      columnExtent: 150,
      rowExtent: 118,
      gap: 14,
    );

    test('没动 / 动得不到半格：原尺寸', () {
      expect(drag(HomeWidgetKind.week, s22, 0, 0), s22);
      expect(drag(HomeWidgetKind.week, s22, 81, 65), s22);
      expect(drag(HomeWidgetKind.week, s22, -81, -65), s22);
    });

    test('过半格就吸到下一格（四舍五入到最近格线）', () {
      expect(drag(HomeWidgetKind.week, s22, 83, 0), const HomeWidgetSize(3, 2));
      expect(drag(HomeWidgetKind.week, s22, 0, 67), const HomeWidgetSize(2, 3));
      expect(
        drag(HomeWidgetKind.week, s22, 164 * 2, 132),
        const HomeWidgetSize(4, 3),
      );
      expect(
        drag(HomeWidgetKind.week, const HomeWidgetSize(4, 3), -164 * 2, -132),
        s22,
      );
    });

    test('拖过头钳进范围：不小于下限、不大于上限 / 网格列数', () {
      expect(drag(HomeWidgetKind.week, s22, -2000, -2000), s11);
      expect(
        drag(HomeWidgetKind.continueHero, s22, -2000, -2000),
        const HomeWidgetSize(1, 2),
      );
      expect(
        drag(HomeWidgetKind.week, s22, 5000, 5000),
        const HomeWidgetSize(6, 3),
      );
      expect(
        drag(HomeWidgetKind.today, s11, 5000, 5000),
        const HomeWidgetSize(3, 2),
      );
      expect(
        drag(
          HomeWidgetKind.continueHero,
          s22,
          5000,
          5000,
          grid: HomeGridKind.compact,
        ),
        const HomeWidgetSize(2, 4),
      );
    });

    test('格宽为 0（还没排版）时不乱跳', () {
      expect(
        homeWidgetDragSize(
          kind: HomeWidgetKind.week,
          grid: HomeGridKind.wide,
          start: s22,
          dx: 40,
          dy: 40,
          columnExtent: 0,
          rowExtent: 0,
          gap: 0,
        ),
        s22,
      );
    });
  });

  group('行高', () {
    test('窄网格 390 宽手机约 84，宽网格桌面约 118，两端夹住', () {
      // 390 宽 - 2 × 16 页边 = 358；列宽 (358 - 12) / 2 = 173 → 83.04。
      expect(
        homeWidgetRowExtent(HomeGridKind.compact, 358, 12),
        closeTo(83.04, 0.01),
      );
      expect(homeWidgetRowExtent(HomeGridKind.compact, 100, 12), 76);
      expect(homeWidgetRowExtent(HomeGridKind.compact, 2000, 12), 96);
      // (1100 - 5 × 12) / 6 = 173.3 → 117.0。
      expect(
        homeWidgetRowExtent(HomeGridKind.wide, 1100, 12),
        closeTo(117.0, 0.01),
      );
      expect(homeWidgetRowExtent(HomeGridKind.wide, 300, 12), 104);
      expect(homeWidgetRowExtent(HomeGridKind.wide, 4000, 12), 140);
    });
  });

  group('密集装箱', () {
    test('窄默认模板：继续 2×2 占前两行，今日 / 复习并排，近 7 天下一行', () {
      final HomeWidgetPacking p = packHomeWidgets(<HomeWidgetItem>[
        item(HomeWidgetKind.continueHero, s22),
        item(HomeWidgetKind.today, s11),
        item(HomeWidgetKind.srsReview, s11),
        item(HomeWidgetKind.week, s21),
      ], 2);
      expect(
        p.placements.map((HomeWidgetPlacement e) => e.toString()).toList(),
        <String>[
          'continue@(0,0)',
          'today@(0,2)',
          'srs_review@(1,2)',
          'week@(0,3)',
        ],
      );
      expect(p.rowCount, 4);
    });

    test('小块回填前面留下的空位，不重叠不悬空', () {
      // 宽 6 列：4×2 + 1×1 + 2×2（第一行只剩 1 列，落到第二行起的结束侧两列）+
      // 1×1 回填第一行最后一格。
      final HomeWidgetPacking p = packHomeWidgets(<HomeWidgetItem>[
        item(HomeWidgetKind.continueHero, s42),
        item(HomeWidgetKind.srsReview, s11),
        item(HomeWidgetKind.week, s22),
        item(HomeWidgetKind.aiAgent, s11),
      ], 6);
      expect(
        p.placements.map((HomeWidgetPlacement e) => e.toString()).toList(),
        <String>[
          'continue@(0,0)',
          'srs_review@(4,0)',
          'week@(4,1)',
          'ai_agent@(5,0)',
        ],
      );
      // 任意两块不重叠。
      final Set<String> cells = <String>{};
      for (final HomeWidgetPlacement e in p.placements) {
        for (int r = e.row; r < e.row + e.rows; r++) {
          for (int c = e.col; c < e.col + e.cols; c++) {
            expect(cells.add('$r/$c'), isTrue, reason: '$e 与别的块重叠');
          }
        }
      }
    });

    test('宽于网格的项被钳到网格列数；空列表 0 行', () {
      final HomeWidgetPacking p = packHomeWidgets(<HomeWidgetItem>[
        item(HomeWidgetKind.panorama, s42),
      ], 2);
      expect(p.placements.single.cols, 2);
      expect(packHomeWidgets(const <HomeWidgetItem>[], 2).rowCount, 0);
    });
  });

  group('编辑操作', () {
    final List<HomeWidgetItem> base = <HomeWidgetItem>[
      item(HomeWidgetKind.continueHero, s22),
      item(HomeWidgetKind.today, s11),
      item(HomeWidgetKind.srsReview, s11),
      item(HomeWidgetKind.week, s21),
    ];

    test('添加追加到末尾；同种已在则原样返回', () {
      final List<HomeWidgetItem> added = addHomeWidget(
        base,
        item(HomeWidgetKind.aiAgent, s11),
      );
      expect(added.last.kind, HomeWidgetKind.aiAgent);
      expect(addHomeWidget(base, item(HomeWidgetKind.today, s21)), same(base));
    });

    test('移除 / 越界原样返回；不改入参', () {
      expect(kinds(removeHomeWidgetAt(base, 1)), <HomeWidgetKind>[
        HomeWidgetKind.continueHero,
        HomeWidgetKind.srsReview,
        HomeWidgetKind.week,
      ]);
      expect(removeHomeWidgetAt(base, 9), same(base));
      expect(base, hasLength(4));
    });

    test('移动：挪完后下标就是目标；目标越界被钳住', () {
      expect(kinds(moveHomeWidget(base, 0, 2)), <HomeWidgetKind>[
        HomeWidgetKind.today,
        HomeWidgetKind.srsReview,
        HomeWidgetKind.continueHero,
        HomeWidgetKind.week,
      ]);
      expect(kinds(moveHomeWidget(base, 3, -5)).first, HomeWidgetKind.week);
      expect(moveHomeWidget(base, 1, 1), same(base));
    });

    test('设尺寸钳进范围；没变原样返回；不改入参', () {
      final List<HomeWidgetItem> wider = setHomeWidgetSize(
        base,
        0,
        HomeGridKind.wide,
        const HomeWidgetSize(5, 3),
      );
      expect(wider[0].size, const HomeWidgetSize(5, 3));
      expect(base[0].size, s22);
      expect(
        setHomeWidgetSize(
          base,
          0,
          HomeGridKind.compact,
          const HomeWidgetSize(6, 6),
        )[0].size,
        const HomeWidgetSize(2, 4),
      );
      expect(setHomeWidgetSize(base, 0, HomeGridKind.wide, s22), same(base));
      expect(setHomeWidgetSize(base, 9, HomeGridKind.wide, s42), same(base));
    });

    test('逐格改尺寸：加减一格、到边界停住原样返回', () {
      expect(
        resizeHomeWidgetBy(base, 0, HomeGridKind.wide, dCols: 1)[0].size,
        const HomeWidgetSize(3, 2),
      );
      expect(
        resizeHomeWidgetBy(base, 0, HomeGridKind.wide, dRows: 1)[0].size,
        s23,
      );
      // 继续能缩到 1 列（半栏），1×2 是下限：再缩原样返回。
      final List<HomeWidgetItem> half = resizeHomeWidgetBy(
        base,
        0,
        HomeGridKind.compact,
        dCols: -1,
      );
      expect(half[0].size, const HomeWidgetSize(1, 2));
      expect(
        resizeHomeWidgetBy(half, 0, HomeGridKind.compact, dCols: -1),
        same(half),
      );
      expect(
        resizeHomeWidgetBy(
          <HomeWidgetItem>[
            item(HomeWidgetKind.continueHero, const HomeWidgetSize(1, 2)),
          ],
          0,
          HomeGridKind.wide,
          dRows: -1,
        )[0].size,
        const HomeWidgetSize(1, 2),
      );
      // 近 7 天 2×1 → 1×1 半栏；再缩不变。
      final List<HomeWidgetItem> week = resizeHomeWidgetBy(
        base,
        3,
        HomeGridKind.compact,
        dCols: -1,
      );
      expect(week[3].size, s11);
      expect(
        resizeHomeWidgetBy(week, 3, HomeGridKind.compact, dCols: -1),
        same(week),
      );
      // 窄网格里 2 列已是上限。
      expect(
        resizeHomeWidgetBy(base, 0, HomeGridKind.compact, dCols: 1),
        same(base),
      );
      expect(
        resizeHomeWidgetBy(base, 1, HomeGridKind.compact, dCols: 1)[1].size,
        s21,
      );
    });

    test('上下移动：跳到上 / 下一行里水平中心最近的块；没有上一行原位、没有下一行到末尾', () {
      // 布局：continue(0,0 2×2) / today(0,2) srs(1,2) / week(0,3 2×1)。
      expect(
        homeWidgetVerticalTarget(base, 2, 2, up: true),
        0,
        reason: 'srs 上一行是 continue 的第二行',
      );
      expect(homeWidgetVerticalTarget(base, 1, 2, up: false), 3);
      expect(homeWidgetVerticalTarget(base, 0, 2, up: true), 0);
      expect(homeWidgetVerticalTarget(base, 3, 2, up: false), 3);
    });

    test('编辑会话：每次操作进撤销栈，撤销逐步回退；无变化不入栈', () {
      HomeWidgetEditSession s = HomeWidgetEditSession(base);
      expect(s.canUndo, isFalse);
      s = s.apply(removeHomeWidgetAt(s.items, 3));
      s = s.apply(moveHomeWidget(s.items, 0, 2));
      expect(s.history, hasLength(2));
      expect(s.apply(s.items), same(s));
      s = s.undo();
      expect(kinds(s.items), kinds(base).sublist(0, 3));
      s = s.undo();
      expect(s.items, base);
      expect(s.canUndo, isFalse);
      expect(s.undo(), same(s));
    });
  });

  group('偏好编解码', () {
    test('往返；只写编辑过的那份', () {
      final HomeWidgetLayout layout = HomeWidgetLayout(
        compact: <HomeWidgetItem>[
          item(HomeWidgetKind.continueHero, s23),
          item(HomeWidgetKind.today, s11),
        ],
      );
      final String json = encodeHomeWidgetLayout(layout);
      expect(
        json,
        '{"v":1,"compact":[{"k":"continue","c":2,"r":3},{"k":"today","c":1,"r":1}]}',
      );
      final HomeWidgetLayout back = decodeHomeWidgetLayout(json);
      expect(back.compact, layout.compact);
      expect(back.wide, isNull);
      expect(encodeHomeWidgetLayout(const HomeWidgetLayout()), '');
      expect(
        decodeHomeWidgetLayout('{"v":1,"wide":[]}').wide,
        isEmpty,
        reason: '用户删光了也是「编辑过」，不能回落到迁移',
      );
    });

    test('语言目标格：挑的目标（goals）往返；旧 zh-Hans 归一成 zh，带 lx 的保留', () {
      const HomeWidgetItem picked = HomeWidgetItem(
        HomeWidgetKind.languageGoals,
        HomeWidgetSize(2, 2),
        language: 'ja',
        goals: <String>['g2', 'g1'],
      );
      const HomeWidgetItem hant = HomeWidgetItem(
        HomeWidgetKind.languageGoals,
        HomeWidgetSize(2, 1),
        language: 'zh-Hant',
      );
      final String json = encodeHomeWidgetLayout(
        const HomeWidgetLayout(wide: <HomeWidgetItem>[picked, hant]),
      );
      expect(json, contains('"goals":["g2","g1"]'));
      expect(json, contains('"l":"zh-Hant","lx":true'));
      expect(decodeHomeWidgetLayout(json).wide, const <HomeWidgetItem>[
        picked,
        hant,
      ]);
      // 旧布局：没有 goals = 自动；没有 lx 的 zh-Hans = 整门中文；goals 至多 3 条。
      final List<HomeWidgetItem> old = decodeHomeWidgetLayout(
        '{"v":1,"wide":[{"k":"language_goals","c":2,"r":2,"l":"zh-Hans"},'
        '{"k":"language_goals","c":2,"r":2,"l":"ko","goals":["a","b","c","d",3]}]}',
      ).wide!;
      expect(old[0].language, 'zh');
      expect(old[0].goals, isEmpty);
      expect(old[1].goals, <String>['a', 'b', 'c']);
      // 换语言 / 尺寸不丢挑的目标。
      expect(picked.withSize(const HomeWidgetSize(2, 1)).goals, picked.goals);
      expect(picked.withLanguage('ko').goals, picked.goals);
    });

    test('容错：坏 JSON / 非对象 / 未知组件 / 重复 / 非法尺寸', () {
      expect(decodeHomeWidgetLayout('').compact, isNull);
      expect(decodeHomeWidgetLayout('not json').compact, isNull);
      expect(decodeHomeWidgetLayout('[1,2]').compact, isNull);
      expect(decodeHomeWidgetLayout('{"compact":"x"}').compact, isNull);
      final HomeWidgetLayout l = decodeHomeWidgetLayout(
        '{"v":9,"compact":['
        '{"k":"mystery","c":2,"r":2},'
        '"junk",'
        '{"k":"continue","c":4,"r":2},'
        '{"k":"today","c":"x"},'
        '{"k":"today","c":2,"r":1}'
        ']}',
      );
      expect(l.compact, <HomeWidgetItem>[
        item(HomeWidgetKind.continueHero, s22),
        item(HomeWidgetKind.today, s11),
      ]);
    });

    test('解码按网格钳尺寸：范围内的连续尺寸原样保留，超出钳到边界', () {
      final HomeWidgetLayout l = decodeHomeWidgetLayout(
        '{"v":1,"wide":['
        '{"k":"week","c":5,"r":3},'
        '{"k":"tracking","c":3,"r":4},'
        '{"k":"today","c":6,"r":1}'
        '],"compact":[{"k":"recently_added","c":6,"r":4}]}',
      );
      expect(l.wide, <HomeWidgetItem>[
        item(HomeWidgetKind.week, const HomeWidgetSize(5, 3)),
        item(HomeWidgetKind.tracking, const HomeWidgetSize(3, 2)),
        item(HomeWidgetKind.today, const HomeWidgetSize(3, 1)),
      ]);
      expect(l.compact, <HomeWidgetItem>[
        item(HomeWidgetKind.recentlyAdded, const HomeWidgetSize(2, 4)),
      ]);
    });
  });

  group('可重复组件（语言目标）', () {
    const HomeWidgetItem ja = HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      s11,
      language: 'ja',
    );
    const HomeWidgetItem ko = HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      s21,
      language: 'ko',
    );
    const HomeWidgetItem all = HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      s11,
    );

    test('slot：普通组件 = id；语言目标 = id + 语言', () {
      expect(HomeWidgetKind.languageGoals.repeatable, isTrue);
      expect(HomeWidgetKind.today.repeatable, isFalse);
      expect(item(HomeWidgetKind.today, s11).slot, 'today');
      expect(ja.slot, 'language_goals:ja');
      expect(all.slot, 'language_goals');
      expect(ja == ja.withSize(s11), isTrue);
      expect(ja == ja.withLanguage('ko'), isFalse);
    });

    test('添加按 slot 去重：不同语言可并存，同语言只一格', () {
      List<HomeWidgetItem> items = addHomeWidget(<HomeWidgetItem>[], ja);
      items = addHomeWidget(items, ko);
      items = addHomeWidget(items, all);
      expect(items, <HomeWidgetItem>[ja, ko, all]);
      expect(addHomeWidget(items, ja.withSize(s21)), items);
    });

    test('改语言：换成已占的语言 / 非可重复组件时不变', () {
      final List<HomeWidgetItem> items = <HomeWidgetItem>[
        item(HomeWidgetKind.today, s11),
        ja,
        ko,
      ];
      expect(setHomeWidgetLanguage(items, 1, 'ko'), items);
      expect(setHomeWidgetLanguage(items, 0, 'ko'), items);
      expect(setHomeWidgetLanguage(items, 9, 'en'), items);
      final List<HomeWidgetItem> next = setHomeWidgetLanguage(items, 1, 'en');
      expect(next[1].language, 'en');
      expect(next[1].size, s11);
      expect(setHomeWidgetLanguage(items, 2, null)[2].slot, 'language_goals');
    });

    test('默认语言：第一个还没有格子的候选语言', () {
      expect(
        homeLanguageGoalsDefaultLanguage(
          candidates: <String>['ja', 'ko', 'en'],
          taken: <String>{'today', 'language_goals:ja'},
        ),
        'ko',
      );
      expect(
        homeLanguageGoalsDefaultLanguage(
          candidates: <String>['ja'],
          taken: <String>{'language_goals:ja'},
        ),
        isNull,
      );
    });

    test('编解码：语言写进 "l"，往返保持；同 slot 重复只留第一个', () {
      const HomeWidgetLayout layout = HomeWidgetLayout(
        compact: <HomeWidgetItem>[ja, ko, all],
      );
      final String json = encodeHomeWidgetLayout(layout);
      expect(json, contains('"l":"ja"'));
      expect(decodeHomeWidgetLayout(json).compact, layout.compact);
      final HomeWidgetLayout dup = decodeHomeWidgetLayout(
        '{"v":1,"compact":['
        '{"k":"language_goals","c":1,"r":1,"l":"ja"},'
        '{"k":"language_goals","c":2,"r":1,"l":"ja"},'
        '{"k":"language_goals","c":1,"r":1,"l":"ko"}'
        ']}',
      );
      expect(dup.compact!.map((HomeWidgetItem e) => e.slot), <String>[
        'language_goals:ja',
        'language_goals:ko',
      ]);
    });
  });

  group('迁移 / 默认模板', () {
    List<HomeWidgetItem> migrate(
      HomeGridKind grid, {
      Map<HomeDashboardPanel, HomeDashboardPanelMode> modes =
          const <HomeDashboardPanel, HomeDashboardPanelMode>{},
      HomeWidgetAutoFacts auto = const HomeWidgetAutoFacts(),
    }) => migrateHomeWidgetLayout(grid: grid, modes: modes, auto: auto);

    test('窄 / 宽默认模板（可选面板全部自动且判据全否）', () {
      // 窄：今日 / 近 7 天半栏并排（所有者 2026-11-15「占半栏就够了」）。
      expect(migrate(HomeGridKind.compact), <HomeWidgetItem>[
        item(HomeWidgetKind.continueHero, s22),
        item(HomeWidgetKind.today, s11),
        item(HomeWidgetKind.week, s11),
      ]);
      expect(migrate(HomeGridKind.wide), <HomeWidgetItem>[
        item(HomeWidgetKind.continueHero, s42),
        item(HomeWidgetKind.today, s21),
        item(HomeWidgetKind.week, s22),
        item(HomeWidgetKind.recentlyAdded, s42),
      ]);
    });

    test('自动档按判据放；钉了显示必放、钉了隐藏不放', () {
      final List<HomeWidgetItem> all = migrate(
        HomeGridKind.compact,
        auto: const HomeWidgetAutoFacts(
          srsReview: true,
          tracking: true,
          aiAgent: true,
        ),
      );
      expect(all, <HomeWidgetItem>[
        item(HomeWidgetKind.continueHero, s22),
        item(HomeWidgetKind.today, s11),
        item(HomeWidgetKind.week, s11),
        item(HomeWidgetKind.srsReview, s11),
        item(HomeWidgetKind.tracking, s11),
        // 半栏组件个数为奇数：最后一个放宽占满一行。
        item(HomeWidgetKind.aiAgent, s21),
      ]);
      final List<HomeWidgetItem> pinned = migrate(
        HomeGridKind.wide,
        modes: <HomeDashboardPanel, HomeDashboardPanelMode>{
          HomeDashboardPanel.srsReview: HomeDashboardPanelMode.hidden,
          HomeDashboardPanel.panorama: HomeDashboardPanelMode.shown,
        },
        auto: const HomeWidgetAutoFacts(srsReview: true),
      );
      expect(kinds(pinned), <HomeWidgetKind>[
        HomeWidgetKind.continueHero,
        HomeWidgetKind.today,
        HomeWidgetKind.week,
        HomeWidgetKind.recentlyAdded,
        HomeWidgetKind.panorama,
      ]);
      expect(pinned.last.size, s22);
    });

    test('窄默认模板任意组合装箱后都没有空洞（每一行两列都占满）', () {
      for (int mask = 0; mask < 16; mask++) {
        HomeDashboardPanelMode mode(int bit) => mask & (1 << bit) != 0
            ? HomeDashboardPanelMode.shown
            : HomeDashboardPanelMode.hidden;
        final List<HomeWidgetItem> items = migrate(
          HomeGridKind.compact,
          modes: <HomeDashboardPanel, HomeDashboardPanelMode>{
            HomeDashboardPanel.srsReview: mode(0),
            HomeDashboardPanel.tracking: mode(1),
            HomeDashboardPanel.aiAgent: mode(2),
            HomeDashboardPanel.panorama: mode(3),
          },
        );
        final HomeWidgetPacking p = packHomeWidgets(items, 2);
        final int area = items.fold<int>(
          0,
          (int sum, HomeWidgetItem e) => sum + e.size.cols * e.size.rows,
        );
        expect(area, p.rowCount * 2, reason: 'mask=$mask: $items');
        for (final HomeWidgetItem e in items) {
          expect(
            clampHomeWidgetSize(e.kind, HomeGridKind.compact, e.size),
            e.size,
            reason: '模板尺寸在范围内：${e.kind.id}',
          );
        }
      }
    });
  });

  group('可用性 / 继续条目归类', () {
    bool available(
      HomeWidgetKind kind, {
      bool reading = true,
      bool watching = true,
      bool playing = true,
      bool srs = true,
      bool tracking = true,
      bool ai = true,
    }) => homeWidgetAvailable(
      kind,
      reading: reading,
      watching: watching,
      playing: playing,
      srs: srs,
      tracking: tracking,
      ai: ai,
    );

    test('各自跟自己的门；通用组件始终可用', () {
      expect(
        available(HomeWidgetKind.continueReading, reading: false),
        isFalse,
      );
      expect(
        available(HomeWidgetKind.continueWatching, watching: false),
        isFalse,
      );
      expect(
        available(HomeWidgetKind.continuePlaying, playing: false),
        isFalse,
      );
      expect(available(HomeWidgetKind.srsReview, srs: false), isFalse);
      expect(available(HomeWidgetKind.tracking, tracking: false), isFalse);
      expect(available(HomeWidgetKind.aiAgent, ai: false), isFalse);
      for (final HomeWidgetKind k in <HomeWidgetKind>[
        HomeWidgetKind.continueHero,
        HomeWidgetKind.today,
        HomeWidgetKind.week,
        HomeWidgetKind.recentlyAdded,
        HomeWidgetKind.panorama,
        HomeWidgetKind.favorites,
      ]) {
        expect(
          available(
            k,
            reading: false,
            watching: false,
            playing: false,
            srs: false,
            tracking: false,
            ai: false,
          ),
          isTrue,
          reason: k.id,
        );
      }
    });

    test('书 / 有声书 = 继续阅读，视频 = 继续观看，游戏 = 继续游玩', () {
      HomeWidgetKind? of({
        bool book = false,
        bool audio = false,
        bool video = false,
        bool game = false,
      }) => homeWidgetContinueKindOf(
        isBook: book,
        isAudiobook: audio,
        isVideo: video,
        isGame: game,
      );
      expect(of(book: true), HomeWidgetKind.continueReading);
      expect(of(audio: true), HomeWidgetKind.continueReading);
      expect(of(video: true), HomeWidgetKind.continueWatching);
      expect(of(game: true), HomeWidgetKind.continuePlaying);
      expect(of(), isNull);
    });
  });

  group('默认布局补洞', () {
    HomeWidgetItem w(HomeWidgetKind k, int c, int r) =>
        HomeWidgetItem(k, HomeWidgetSize(c, r));

    test('宽网格默认模板：最近添加向下长一行补掉追踪右边的 4×1 洞', () {
      final List<HomeWidgetItem> items = <HomeWidgetItem>[
        w(HomeWidgetKind.continueHero, 4, 2),
        w(HomeWidgetKind.today, 2, 1),
        w(HomeWidgetKind.srsReview, 1, 1),
        w(HomeWidgetKind.aiAgent, 1, 1),
        w(HomeWidgetKind.week, 2, 2),
        w(HomeWidgetKind.recentlyAdded, 4, 2),
        w(HomeWidgetKind.tracking, 2, 1),
      ];
      final List<HomeWidgetItem> filled = fillHomeWidgetGaps(
        items,
        HomeGridKind.wide,
      );
      expect(filled[5].size, const HomeWidgetSize(4, 3));
      expect(filled[6].size, const HomeWidgetSize(2, 1));
      final HomeWidgetPacking packing = packHomeWidgets(filled, 6);
      int area = 0;
      for (final HomeWidgetPlacement p in packing.placements) {
        area += p.cols * p.rows;
      }
      expect(area, packing.rowCount * 6);
    });

    test('洞上方没有等宽组件时，同一行起始侧的组件横向拉宽', () {
      final List<HomeWidgetItem> filled = fillHomeWidgetGaps(<HomeWidgetItem>[
        w(HomeWidgetKind.today, 2, 1),
        w(HomeWidgetKind.aiAgent, 2, 1),
        w(HomeWidgetKind.recentlyAdded, 1, 2),
        w(HomeWidgetKind.srsReview, 2, 1),
        w(HomeWidgetKind.week, 2, 1),
      ], HomeGridKind.wide);
      expect(filled[2].size, const HomeWidgetSize(2, 2));
    });

    test('窄网格：洞上方的半栏组件先向下长（先竖后横）', () {
      final List<HomeWidgetItem> filled = fillHomeWidgetGaps(<HomeWidgetItem>[
        w(HomeWidgetKind.continueHero, 2, 2),
        w(HomeWidgetKind.today, 1, 1),
        w(HomeWidgetKind.week, 1, 1),
        w(HomeWidgetKind.aiAgent, 1, 1),
      ], HomeGridKind.compact);
      expect(filled[2].size, const HomeWidgetSize(1, 2));
      expect(filled[3].size, const HomeWidgetSize(1, 1));
    });

    test('超上限的扩展不做；所有组件装箱位置不变', () {
      // 今日（上限 3 宽）拉不到 4 宽，第 1 行 3、4 列补不上；第 5 列由 AI 向下长补。
      final List<HomeWidgetItem> items = <HomeWidgetItem>[
        w(HomeWidgetKind.continueHero, 5, 1),
        w(HomeWidgetKind.aiAgent, 1, 1),
        w(HomeWidgetKind.today, 3, 1),
      ];
      final List<HomeWidgetItem> filled = fillHomeWidgetGaps(
        items,
        HomeGridKind.wide,
      );
      final HomeWidgetPacking before = packHomeWidgets(items, 6);
      final HomeWidgetPacking after = packHomeWidgets(filled, 6);
      for (int i = 0; i < items.length; i++) {
        expect(after.placements[i].col, before.placements[i].col);
        expect(after.placements[i].row, before.placements[i].row);
      }
      expect(after.rowCount, before.rowCount);
      expect(filled[1].size, const HomeWidgetSize(1, 2));
      expect(filled[2].size, const HomeWidgetSize(3, 1));
    });

    test('没有洞时原样返回', () {
      final List<HomeWidgetItem> items = <HomeWidgetItem>[
        w(HomeWidgetKind.continueHero, 4, 2),
        w(HomeWidgetKind.today, 2, 2),
      ];
      expect(fillHomeWidgetGaps(items, HomeGridKind.wide), items);
    });
  });
}
