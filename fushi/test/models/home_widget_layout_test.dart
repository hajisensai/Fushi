// 首页小组件网格的纯模型（spec docs/specs/2026-11-15-home-widgets-design.md）：
// 目录 / 尺寸档、行高、密集装箱、编辑操作与撤销、偏好编解码、从旧「首页面板」
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
    test('11 种组件，持久化 id 冻结且唯一', () {
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
        ],
      );
      for (final HomeWidgetKind k in HomeWidgetKind.values) {
        expect(HomeWidgetKind.fromId(k.id), k);
      }
      expect(HomeWidgetKind.fromId('nope'), isNull);
      expect(HomeWidgetKind.fromId(3), isNull);
    });

    test('尺寸档与规格一致；窄网格里没有 4 列宽的档', () {
      expect(HomeWidgetKind.continueHero.sizes, <HomeWidgetSize>[
        s22,
        s23,
        s42,
      ]);
      expect(
        HomeWidgetKind.continueHero.sizesFor(HomeGridKind.compact),
        <HomeWidgetSize>[s22, s23],
      );
      expect(HomeWidgetKind.today.sizes, <HomeWidgetSize>[s11, s21]);
      expect(HomeWidgetKind.week.sizes, <HomeWidgetSize>[s21, s22]);
      expect(HomeWidgetKind.srsReview.sizes, <HomeWidgetSize>[s11, s21]);
      expect(HomeWidgetKind.recentlyAdded.sizes, <HomeWidgetSize>[s22, s42]);
      expect(
        HomeWidgetKind.recentlyAdded.sizesFor(HomeGridKind.compact),
        <HomeWidgetSize>[s22],
      );
      expect(HomeWidgetKind.tracking.sizes, <HomeWidgetSize>[s21]);
      expect(HomeWidgetKind.aiAgent.sizes, <HomeWidgetSize>[s11, s21]);
      expect(HomeWidgetKind.panorama.sizes, <HomeWidgetSize>[s22, s42]);
      for (final HomeWidgetKind k in <HomeWidgetKind>[
        HomeWidgetKind.continueReading,
        HomeWidgetKind.continueWatching,
        HomeWidgetKind.continuePlaying,
      ]) {
        expect(k.sizes, <HomeWidgetSize>[s21, s22]);
      }
      expect(s21.toString(), '2×1');
    });

    test('nearestHomeWidgetSize：取最近合法档，平局取目录靠前', () {
      expect(
        nearestHomeWidgetSize(
          HomeWidgetKind.continueHero,
          HomeGridKind.compact,
          s42,
        ),
        s22,
      );
      expect(
        nearestHomeWidgetSize(HomeWidgetKind.tracking, HomeGridKind.wide, s11),
        s21,
      );
      expect(
        nearestHomeWidgetSize(
          HomeWidgetKind.today,
          HomeGridKind.wide,
          const HomeWidgetSize(0, 0),
        ),
        s11,
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

    test('换尺寸在可选档里循环（正反向）；只有一档原样返回', () {
      expect(cycleHomeWidgetSize(base, 0, HomeGridKind.compact)[0].size, s23);
      expect(
        cycleHomeWidgetSize(
          cycleHomeWidgetSize(base, 0, HomeGridKind.compact),
          0,
          HomeGridKind.compact,
        )[0].size,
        s22,
      );
      expect(
        cycleHomeWidgetSize(base, 0, HomeGridKind.wide, step: -1)[0].size,
        s42,
      );
      final List<HomeWidgetItem> tracking = <HomeWidgetItem>[
        item(HomeWidgetKind.tracking, s21),
      ];
      expect(
        cycleHomeWidgetSize(tracking, 0, HomeGridKind.wide),
        same(tracking),
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
  });

  group('迁移 / 默认模板', () {
    List<HomeWidgetItem> migrate(
      HomeGridKind grid, {
      Map<HomeDashboardPanel, HomeDashboardPanelMode> modes =
          const <HomeDashboardPanel, HomeDashboardPanelMode>{},
      HomeWidgetAutoFacts auto = const HomeWidgetAutoFacts(),
    }) => migrateHomeWidgetLayout(grid: grid, modes: modes, auto: auto);

    test('窄 / 宽默认模板（可选面板全部自动且判据全否）', () {
      expect(migrate(HomeGridKind.compact), <HomeWidgetItem>[
        item(HomeWidgetKind.continueHero, s22),
        item(HomeWidgetKind.today, s11),
        item(HomeWidgetKind.week, s21),
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
      expect(kinds(all), <HomeWidgetKind>[
        HomeWidgetKind.continueHero,
        HomeWidgetKind.today,
        HomeWidgetKind.srsReview,
        HomeWidgetKind.week,
        HomeWidgetKind.tracking,
        HomeWidgetKind.aiAgent,
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
}
