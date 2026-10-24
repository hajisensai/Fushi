import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/media/manga/reader/manga_control_layout.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_bookmarks.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';
import 'package:fushi_audio/fushi_audio.dart' show Bookmark;
import 'package:material_ui/material_ui.dart';

void main() {
  group('MangaControlLayout 模型', () {
    test('出厂布局包含全部按钮：底部工具栏 / 右上角两组，顺序与布局化前一致', () {
      final MangaControlLayout d = MangaControlLayout.defaults;
      expect(d.itemsIn(MangaControlSlot.toolbar), <MangaControlItem>[
        MangaControlItem.chapters,
        MangaControlItem.pageGrid,
        MangaControlItem.readingMode,
        MangaControlItem.spreadPreference,
        MangaControlItem.direction,
        MangaControlItem.quickSettings,
        MangaControlItem.ocrBoxes,
      ]);
      expect(d.itemsIn(MangaControlSlot.top), <MangaControlItem>[
        MangaControlItem.ocrCancel,
        MangaControlItem.fullscreen,
        MangaControlItem.bookmarks,
        MangaControlItem.settings,
        MangaControlItem.ocrVolume,
        MangaControlItem.backToStart,
        MangaControlItem.ocrRerun,
        MangaControlItem.hideChrome,
      ]);
      expect(d.itemsIn(MangaControlSlot.overflow), isEmpty);
      expect(d.core.removedItems, isEmpty);
      final Set<MangaControlItem> placed = <MangaControlItem>{
        ...d.itemsIn(MangaControlSlot.toolbar),
        ...d.itemsIn(MangaControlSlot.top),
      };
      expect(placed, MangaControlItem.values.toSet());
      // 右上角出厂顺序就是按收起优先级从高到低（旧版「按优先级排序」的结果）。
      final List<int> topPriorities = <int>[
        for (final MangaControlItem i in d.itemsIn(MangaControlSlot.top))
          i.foldPriority,
      ];
      expect(
        topPriorities,
        orderedEquals(
          List<int>.of(topPriorities)..sort((int a, int b) => b - a),
        ),
      );
      expect(MangaControlLayout.compactDefaults, MangaControlLayout.defaults);
    });

    test('JSON round-trip：编码再解码得到同一布局（含移出项与更多菜单）', () {
      final ControlLayout<MangaControlSlot, MangaControlItem> moved =
          MangaControlLayout.defaults.core
              .moveItem(MangaControlItem.hideChrome, MangaControlSlot.overflow)
              .moveItem(MangaControlItem.direction, MangaControlSlot.hidden)
              .moveItem(
                MangaControlItem.bookmarks,
                MangaControlSlot.toolbar,
                index: 0,
              );
      final MangaControlLayout layout = MangaControlLayout.fromCore(moved);
      final MangaControlLayout decoded = MangaControlLayout.decode(
        layout.encode(),
      );
      expect(decoded, layout);
      expect(
        decoded.itemsIn(MangaControlSlot.toolbar).first,
        MangaControlItem.bookmarks,
      );
      expect(decoded.itemsIn(MangaControlSlot.overflow), <MangaControlItem>[
        MangaControlItem.hideChrome,
      ]);
      expect(decoded.core.removedItems, contains(MangaControlItem.direction));
      expect(
        (jsonDecode(layout.encode()) as Map<String, dynamic>)['version'],
        1,
      );
    });

    test('缺项回填：JSON 里缺席的按钮按出厂位置补回（以后新增按钮存量布局自动带上）', () {
      const String json =
          '{"version":1,"slots":{"top":["settings","hideChrome"],'
          '"toolbar":["quickSettings"]}}';
      final MangaControlLayout decoded = MangaControlLayout.decode(json);
      expect(decoded.itemsIn(MangaControlSlot.top).take(2), <MangaControlItem>[
        MangaControlItem.settings,
        MangaControlItem.hideChrome,
      ]);
      expect(
        decoded.itemsIn(MangaControlSlot.top),
        contains(MangaControlItem.bookmarks),
      );
      expect(
        decoded.itemsIn(MangaControlSlot.toolbar),
        containsAll(<MangaControlItem>[
          MangaControlItem.quickSettings,
          MangaControlItem.chapters,
          MangaControlItem.pageGrid,
        ]),
      );
      final Set<MangaControlItem> all = <MangaControlItem>{
        for (final MangaControlSlot s in MangaControlSlot.values)
          if (s != MangaControlSlot.hidden) ...decoded.itemsIn(s),
        ...decoded.core.removedItems,
      };
      expect(all, MangaControlItem.values.toSet());
    });

    test('坏 JSON / 空串 / 结构不对 → 回落出厂布局（窄窗回落窄窗出厂）', () {
      for (final String bad in <String>[
        '',
        '   ',
        'not json',
        '[]',
        '{"slots":[]}',
        '{"version":1}',
      ]) {
        expect(
          MangaControlLayout.decode(bad),
          MangaControlLayout.defaults,
          reason: bad,
        );
        expect(
          MangaControlLayout.decode(
            bad,
            fallback: MangaControlLayout.compactDefaults,
          ),
          MangaControlLayout.compactDefaults,
          reason: bad,
        );
      }
    });

    test('必需项：全部设置不能移出阅读器（移出即回到原位），但可进「更多」', () {
      expect(
        MangaControlItem.settings.canMoveToSlot(MangaControlSlot.hidden),
        isFalse,
      );
      expect(
        MangaControlItem.settings.canMoveToSlot(MangaControlSlot.overflow),
        isTrue,
      );
      final ControlLayout<MangaControlSlot, MangaControlItem> attempted =
          MangaControlLayout.defaults.core.moveItem(
            MangaControlItem.settings,
            MangaControlSlot.hidden,
          );
      expect(
        attempted.removedItems,
        isNot(contains(MangaControlItem.settings)),
      );
      // 一份把 settings 写进 removed 的坏 JSON 解码后它仍在可见区。
      final MangaControlLayout decoded = MangaControlLayout.decode(
        '{"version":1,"slots":{"top":["hideChrome"]},"removed":["settings"]}',
      );
      expect(
        decoded.core.removedItems,
        isNot(contains(MangaControlItem.settings)),
      );
      expect(decoded.core.isOnPlayer(MangaControlItem.settings), isTrue);
    });
  });

  group('出厂布局 → planMangaChrome 与布局化前视觉等价', () {
    void noop() {}

    MangaChromeAction action(String key, int priority, MangaChromeSlot slot) =>
        MangaChromeAction(
          key: ValueKey<String>(key),
          icon: Icons.circle,
          label: key,
          slot: slot,
          priority: priority,
          onPressed: noop,
        );

    /// 布局化之前 `_chromeActionGroups` 写死的那张表（书架在线条目、spread 模式、
    /// 桌面全屏、整卷 OCR 运行中、手动识别与重新识别都可用；Material 无识别框键）。
    List<List<MangaChromeAction>> legacyGroups() => <List<MangaChromeAction>>[
      <MangaChromeAction>[
        action('chapters', 8, MangaChromeSlot.toolbar),
        action('pageGrid', 4, MangaChromeSlot.toolbar),
      ],
      <MangaChromeAction>[
        action('readingMode', 6, MangaChromeSlot.toolbar),
        action('spreadPreference', 3, MangaChromeSlot.toolbar),
        action('direction', 2, MangaChromeSlot.toolbar),
      ],
      <MangaChromeAction>[action('quickSettings', 10, MangaChromeSlot.toolbar)],
      <MangaChromeAction>[
        action('ocrCancel', 9, MangaChromeSlot.top),
        action('fullscreen', 7, MangaChromeSlot.top),
        action('backToStart', 1, MangaChromeSlot.top),
        action('ocrVolume', 4, MangaChromeSlot.top),
        action('ocrRerun', 1, MangaChromeSlot.top),
        action('settings', 5, MangaChromeSlot.top),
        action('hideChrome', 0, MangaChromeSlot.top),
      ],
    ];

    /// 与页面 `_chromeActionGroups` 同形：按出厂布局三组声明，优先级取
    /// [MangaControlItem.foldPriority]；[skip] 是此刻不渲染的按钮。
    List<List<MangaChromeAction>> layoutGroups(Set<MangaControlItem> skip) {
      final MangaControlLayout layout = MangaControlLayout.defaults;
      List<MangaChromeAction> group(
        MangaControlSlot from,
        MangaChromeSlot to,
      ) => <MangaChromeAction>[
        for (final MangaControlItem i in layout.itemsIn(from))
          if (!skip.contains(i)) action(i.storageValue, i.foldPriority, to),
      ];
      return <List<MangaChromeAction>>[
        group(MangaControlSlot.toolbar, MangaChromeSlot.toolbar),
        group(MangaControlSlot.top, MangaChromeSlot.top),
        group(MangaControlSlot.overflow, MangaChromeSlot.overflow),
      ];
    }

    /// 布局化之前 planMangaChrome 的右上角口径（独立复刻作参照）：顶栏动作 + 降下来的
    /// 工具栏动作，整体按优先级从高到低**稳定排序**（同优先级保持声明顺序）。降级集合
    /// 本身两版算法相同，取自 [plan]。
    List<MangaChromeAction> legacyTop(
      List<List<MangaChromeAction>> groups,
      MangaChromePlan plan,
    ) {
      final Set<MangaChromeAction> kept = <MangaChromeAction>{
        for (final List<MangaChromeAction> g in plan.toolbar) ...g,
      };
      final List<MangaChromeAction> top = <MangaChromeAction>[
        for (final List<MangaChromeAction> g in groups)
          for (final MangaChromeAction a in g)
            if (a.slot == MangaChromeSlot.top || !kept.contains(a)) a,
      ];
      final List<int> order = <int>[for (int i = 0; i < top.length; i++) i];
      order.sort((int a, int b) {
        final int byPriority = top[b].priority.compareTo(top[a].priority);
        return byPriority != 0 ? byPriority : a.compareTo(b);
      });
      return <MangaChromeAction>[for (final int i in order) top[i]];
    }

    List<String> keys(Iterable<MangaChromeAction> actions) => <String>[
      for (final MangaChromeAction a in actions)
        (a.key! as ValueKey<String>).value,
    ];

    test('各宽度下：底部工具栏留下的、右上角的顺序都与旧版逐字相同', () {
      for (final double width in <double>[
        1600,
        1024,
        720,
        600,
        480,
        412,
        360,
        320,
        0,
      ]) {
        final List<List<MangaChromeAction>> legacyInput = legacyGroups();
        final MangaChromePlan legacy = planMangaChrome(
          width: width,
          groups: legacyInput,
          hasFab: true,
        );
        final MangaChromePlan now = planMangaChrome(
          width: width,
          // 旧版没有书签键，Material 下识别框是 FAB。
          groups: layoutGroups(<MangaControlItem>{
            MangaControlItem.bookmarks,
            MangaControlItem.ocrBoxes,
          }),
          hasFab: true,
        );
        expect(
          keys(now.toolbar.expand((List<MangaChromeAction> g) => g)),
          keys(legacy.toolbar.expand((List<MangaChromeAction> g) => g)),
          reason: '$width dp 底部工具栏',
        );
        expect(
          keys(now.top),
          keys(legacyTop(legacyInput, legacy)),
          reason: '$width dp 右上角',
        );
        expect(now.overflow, isEmpty);
      }
    });

    test('书签键按优先级 6 落在全屏与全部设置之间；降下来的同优先级阅读模式排它前面', () {
      final MangaChromePlan plan = planMangaChrome(
        width: 320,
        groups: layoutGroups(<MangaControlItem>{MangaControlItem.ocrBoxes}),
        hasFab: true,
      );
      final List<String> top = keys(plan.top);
      expect(top.indexOf('bookmarks'), greaterThan(top.indexOf('fullscreen')));
      expect(top.indexOf('bookmarks'), lessThan(top.indexOf('settings')));
      if (top.contains('readingMode')) {
        expect(top.indexOf('readingMode'), lessThan(top.indexOf('bookmarks')));
      }
    });

    test('自定义顺序：右上角保持用户排的顺序；「更多」里的恒进 ⋯', () {
      final MangaChromePlan plan = planMangaChrome(
        width: 1600,
        groups: <List<MangaChromeAction>>[
          <MangaChromeAction>[
            action('quickSettings', 10, MangaChromeSlot.toolbar),
          ],
          <MangaChromeAction>[
            action('hideChrome', 0, MangaChromeSlot.top),
            action('settings', 5, MangaChromeSlot.top),
          ],
          <MangaChromeAction>[
            action('backToStart', 1, MangaChromeSlot.overflow),
          ],
        ],
      );
      expect(keys(plan.top), <String>['hideChrome', 'settings']);
      expect(keys(plan.overflow), <String>['backToStart']);
    });
  });

  group('书签纯逻辑', () {
    Bookmark bm(int page, {String? chapterKey, int id = 1}) => Bookmark(
      id: id,
      sectionIndex: page,
      normCharOffset: 0,
      label: 'L',
      createdAt: DateTime(2026, 10, 23),
      chapterKey: chapterKey,
    );

    test('当前屏有书签：同章 + 页码落在可见范围（双页两页都算）', () {
      final List<Bookmark> list = <Bookmark>[bm(5), bm(9, id: 2)];
      expect(
        mangaBookmarkOnScreen(
          list,
          chapterKey: null,
          startPage: 4,
          endPage: 6,
        )?.id,
        1,
      );
      expect(
        mangaBookmarkOnScreen(
          list,
          chapterKey: null,
          startPage: 5,
          endPage: 6,
        )?.id,
        1,
      );
      expect(
        mangaBookmarkOnScreen(list, chapterKey: null, startPage: 6, endPage: 8),
        isNull,
      );
    });

    test('当前屏有书签：章键不同不算（在线别章同页码）；都为 null 算同章', () {
      final List<Bookmark> list = <Bookmark>[bm(3, chapterKey: 'ch-2')];
      expect(
        mangaBookmarkOnScreen(
          list,
          chapterKey: 'ch-1',
          startPage: 3,
          endPage: 4,
        ),
        isNull,
      );
      expect(
        mangaBookmarkOnScreen(
          list,
          chapterKey: 'ch-2',
          startPage: 3,
          endPage: 4,
        ),
        isNotNull,
      );
      expect(
        mangaBookmarkOnScreen(
          <Bookmark>[bm(3)],
          chapterKey: null,
          startPage: 3,
          endPage: 4,
        ),
        isNotNull,
      );
    });

    test('跳转：本地卷 / 同章 → 当前章跳页', () {
      final MangaBookmarkJump local = resolveMangaBookmarkJump(
        bm(7),
        currentChapterKey: null,
        chapterKeys: null,
      );
      expect(local.kind, MangaBookmarkJumpKind.currentChapter);
      expect(local.page, 7);
      final MangaBookmarkJump same = resolveMangaBookmarkJump(
        bm(2, chapterKey: 'b'),
        currentChapterKey: 'b',
        chapterKeys: <String>['a', 'b', 'c'],
      );
      expect(same.kind, MangaBookmarkJumpKind.currentChapter);
      expect(same.page, 2);
    });

    test('跳转：在线别章 → 按章键找下标（不认存下的下标）', () {
      final MangaBookmarkJump other = resolveMangaBookmarkJump(
        bm(4, chapterKey: 'c'),
        currentChapterKey: 'a',
        chapterKeys: <String>['a', 'b', 'c'],
      );
      expect(other.kind, MangaBookmarkJumpKind.otherChapter);
      expect(other.chapterIndex, 2);
      expect(other.page, 4);
    });

    test('跳转：章已不在列表里 / 本地卷遇到带章键的书签 → 不跳', () {
      expect(
        resolveMangaBookmarkJump(
          bm(4, chapterKey: 'gone'),
          currentChapterKey: 'a',
          chapterKeys: <String>['a', 'b'],
        ).kind,
        MangaBookmarkJumpKind.chapterMissing,
      );
      expect(
        resolveMangaBookmarkJump(
          bm(4, chapterKey: 'x'),
          currentChapterKey: null,
          chapterKeys: null,
        ).kind,
        MangaBookmarkJumpKind.chapterMissing,
      );
    });

    test('跳转：负页码钳到 0', () {
      expect(
        resolveMangaBookmarkJump(
          bm(-3),
          currentChapterKey: null,
          chapterKeys: null,
        ).page,
        0,
      );
    });

    test('标题与存储 label：在线「章名 · 第 N 页」/ 本地「第 N 页」', () {
      expect(mangaBookmarkTitle(bm(0)), contains('1'));
      final String online = mangaBookmarkTitle(
        bm(4, chapterKey: 'c'),
        chapterName: 'Chapter 3',
      );
      expect(online, contains('Chapter 3'));
      expect(online, contains('5'));
      expect(
        mangaBookmarkStoredLabel(page: 4, chapterName: 'Chapter 3'),
        'Chapter 3',
      );
      expect(mangaBookmarkStoredLabel(page: 4), contains('5'));
    });
  });
}
