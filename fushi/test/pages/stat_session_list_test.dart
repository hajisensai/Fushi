import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_session_list.dart';
import 'package:fushi/src/stats/study_sessions.dart';
import 'package:fushi_core/fushi_core.dart';

/// 统计页会话流（用户 2026-09-08：每个域都要会话级统计，能删误点的会话）的行为守卫：
///  * 每行显示 标题 · 起止 · 量纲；空串标题回退 mediaKey；
///  * BUG-2417：命中合集的行在条目名上方挂合集名，标题最多两行（不再单行截断）；
///  * 区块只显示前 [limit] 行，多出来时给「全部会话 (N)」入口进 sheet；
///  * 垃圾桶 → 确认框（会话专用文案）→ 点删除才回调 [onDelete] 并移除该行；取消不动。
StudySession _session(
  String uid, {
  String kind = kActivityMediaBook,
  String title = 'T',
  int start = 0,
  int end = 60000,
  int ms = 60000,
  int chars = 0,
}) => StudySession(
  mediaKind: kind,
  mediaKey: 'k-$uid',
  title: title,
  format: '',
  deviceId: 'dev',
  startAt: start,
  endAt: end,
  durationMs: ms,
  chars: chars,
  pages: 0,
  segmentUids: <String>[uid],
);

Future<void> _pump(
  WidgetTester tester, {
  required List<StudySession> sessions,
  required Future<void> Function(StudySession) onDelete,
  StatSessionEditOf? onEdit,
  StatSessionClearAll? onClearAll,
  StatSessionCollectionOf? collectionOf,
  int limit = 8,
}) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Builder(
              builder: (BuildContext context) => buildStatSessionSection(
                context,
                sessions: sessions,
                titleOf: (StudySession s) => s.title,
                collectionOf: collectionOf,
                onDelete: onDelete,
                onEdit: onEdit ?? (StudySession s, StudySessionEdit e) async {},
                onClearAll: onClearAll ?? (List<StudySession> b) async {},
                limit: limit,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('每行：标题 + 起止 · 量纲；空标题回退 mediaKey', (WidgetTester tester) async {
    await _pump(
      tester,
      sessions: <StudySession>[
        _session('a', title: '小説', chars: 1200),
        _session('b', title: '', kind: kActivityMediaVideo),
      ],
      onDelete: (_) async {},
    );
    expect(find.text('小説'), findsOneWidget);
    expect(find.text('k-b'), findsOneWidget, reason: '空标题回退 mediaKey');
    expect(find.text(t.stat_sessions_recent), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
    expect(find.textContaining(formatStatSessionMeta(_session('a', chars: 1200))),
        findsOneWidget);
    expect(find.text(t.stat_sessions_empty), findsNothing);
  });

  testWidgets('BUG-2417：命中合集的行带合集名，未命中只有条目名', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      sessions: <StudySession>[
        _session('a', title: '暗中行动', kind: kActivityMediaVideo),
        _session('b', title: '独立的一本书'),
      ],
      collectionOf: (StudySession s) =>
          s.mediaKey == 'k-a' ? 'Re：从零开始的异世界生活' : null,
      onDelete: (_) async {},
    );
    expect(
      find.text('Re：从零开始的异世界生活'),
      findsOneWidget,
      reason: '分集名单看认不出作品，合集名必须上屏',
    );
    expect(find.text('暗中行动'), findsOneWidget, reason: '合集名不顶掉条目名');
    expect(find.text('独立的一本书'), findsOneWidget);
    expect(
      find.byIcon(Icons.folder_outlined),
      findsOneWidget,
      reason: '不属于合集的行不挂标签',
    );
  });

  testWidgets('BUG-2417：合集名进删除确认文案', (WidgetTester tester) async {
    await _pump(
      tester,
      sessions: <StudySession>[
        _session('a', title: '暗中行动', kind: kActivityMediaVideo),
      ],
      collectionOf: (StudySession s) => '异世界生活',
      onDelete: (_) async {},
    );
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.textContaining('异世界生活 - 暗中行动'), findsOneWidget);
  });

  testWidgets('BUG-2417：长标题排到第二行而不是单行省略', (WidgetTester tester) async {
    const String long = 'Re：从零开始的异世界生活 第三期 第七话 暗中行动する者たち';
    // 手机宽度：用户实报的截图就是这个宽度下的单行截断。
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      sessions: <StudySession>[
        _session('a', title: long, kind: kActivityMediaVideo),
      ],
      onDelete: (_) async {},
    );
    final RenderParagraph title = tester.renderObject<RenderParagraph>(
      find.text(long),
    );
    expect(
      title.didExceedMaxLines,
      isFalse,
      reason: '两行装得下这个长度的媒体名',
    );
    expect(
      title.size.height,
      greaterThan(title.preferredLineHeight * 1.5),
      reason: '真的排到了第二行（单行 ellipsis 会停在一行高）',
    );
  });

  testWidgets('空列表显示空态', (WidgetTester tester) async {
    await _pump(tester, sessions: const <StudySession>[], onDelete: (_) async {});
    expect(find.text(t.stat_sessions_empty), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('超过 limit 只显示前 N 行，「全部会话」进 sheet 列全量', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      sessions: <StudySession>[
        for (int i = 0; i < 5; i++) _session('s$i', title: 'S$i'),
      ],
      onDelete: (_) async {},
      limit: 2,
    );
    expect(find.text('S0'), findsOneWidget);
    expect(find.text('S1'), findsOneWidget);
    expect(find.text('S4'), findsNothing);
    final Finder showAll = find.text('${t.stat_sessions_show_all} (5)');
    expect(showAll, findsOneWidget);
    await tester.tap(showAll);
    await tester.pumpAndSettle();
    expect(find.text('S4'), findsOneWidget, reason: 'sheet 里是全量');
  });

  testWidgets('垃圾桶 → 会话专用确认文案 → 删除回调 + 行移除；取消不动', (
    WidgetTester tester,
  ) async {
    final List<String> deleted = <String>[];
    await _pump(
      tester,
      sessions: <StudySession>[
        _session('a', title: 'A'),
        _session('b', title: 'B'),
      ],
      onDelete: (StudySession s) async => deleted.add(s.segmentUids.single),
    );
    // 取消。
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    // 确认框正文 = 「标题\n\n文案」一个 Text，按包含匹配。
    expect(find.textContaining(t.stat_session_delete_message), findsOneWidget);
    expect(
      find.textContaining(t.stat_delete_message),
      findsNothing,
      reason: '删单次会话不许套「删该项全部统计」的文案',
    );
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
    expect(find.text('A'), findsOneWidget);
    // 确认。
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_delete));
    await tester.pumpAndSettle();
    expect(deleted, <String>['a']);
    expect(find.text('A'), findsNothing);
    expect(find.text('B'), findsOneWidget);
  });

  // ↓ 用户 2026-09-10：「里面的每个会话做成可编辑」+「再加个清除所有会话记录并且防呆」。

  testWidgets('整行点击弹的是会话编辑框（初值来自这一行）', (WidgetTester tester) async {
    await _pump(
      tester,
      sessions: <StudySession>[
        _session('a', title: 'A', chars: 1200),
        _session('b', title: 'B'),
      ],
      onDelete: (_) async {},
    );
    // 编辑入口是**整行**，不是 trailing 上的第二颗图标按钮：那 48dp 预算里塞两颗
    // 会把标题挤回单行省略（BUG-2417 的回归，见下面「长标题」那条守卫）。
    expect(
      find.byIcon(Icons.edit_outlined),
      findsNothing,
      reason: 'trailing 只放得下一颗按钮，编辑走整行 onTap',
    );
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('stat-session-edit-date')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('stat-session-edit-chars')),
      findsOneWidget,
    );
    expect(find.text('A'), findsWidgets, reason: '编辑的是这一行，标题进正文');
  });

  testWidgets('改完保存：onEdit 拿到只带真改过项的 edit，那一行当场显示新值', (
    WidgetTester tester,
  ) async {
    final List<StudySessionEdit> edits = <StudySessionEdit>[];
    await _pump(
      tester,
      sessions: <StudySession>[_session('a', title: 'A', chars: 1200)],
      onDelete: (_) async {},
      onEdit: (StudySession s, StudySessionEdit e) async => edits.add(e),
    );
    expect(
      find.textContaining(formatStatSessionMeta(_session('a', chars: 1200))),
      findsOneWidget,
    );

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('stat-session-edit-chars')),
      '900',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, t.dialog_save));
    await tester.pumpAndSettle();

    expect(edits, hasLength(1));
    expect(edits.single.chars, 900);
    expect(edits.single.date, isNull, reason: '没动日期就别传，避免一次无谓的平移写');
    // sheet 拿的是打开那一刻的快照，页面在它底下重聚合不会传上来——改完还显示旧值
    // 是用户第一眼就能看见的假。真相仍以关掉之后的重聚合为准。
    expect(
      find.textContaining(formatStatSessionMeta(_session('a', chars: 900))),
      findsOneWidget,
      reason: '那一行当场换成编辑后的展示副本',
    );
    expect(
      find.textContaining(formatStatSessionMeta(_session('a', chars: 1200))),
      findsNothing,
    );
  });

  testWidgets('清除全部会话：防呆确认后 onClearAll 拿到的是整批，不是截断后的 8 条', (
    WidgetTester tester,
  ) async {
    List<StudySession>? cleared;
    final List<StudySession> all = <StudySession>[
      for (int i = 0; i < 12; i++) _session('s$i', title: 'S$i'),
    ];
    await _pump(
      tester,
      sessions: all,
      onDelete: (_) async {},
      onClearAll: (List<StudySession> batch) async => cleared = batch,
    );
    expect(find.text('S8'), findsNothing, reason: '屏幕上只有前 8 条');

    await tester.tap(
      find.byKey(const ValueKey<String>('stat-sessions-clear-all')),
    );
    await tester.pumpAndSettle();
    final Finder confirm =
        find.widgetWithText(FilledButton, t.stat_clear_all_confirm);
    expect(
      tester.widget<FilledButton>(confirm).onPressed,
      isNull,
      reason: '防呆：没勾确认项之前不许清',
    );
    expect(cleared, isNull);

    await tester.tap(
      find.byKey(const ValueKey<String>('stat-clear-sessions-ack')),
    );
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(cleared, isNotNull);
    expect(
      cleared,
      hasLength(12),
      reason: '清的是这一页拿到的整批（域 tab = 本域全部），不是屏幕上那 8 条',
    );
  });

  testWidgets('取消防呆框 → 一条都不清', (WidgetTester tester) async {
    List<StudySession>? cleared;
    await _pump(
      tester,
      sessions: <StudySession>[_session('a', title: 'A')],
      onDelete: (_) async {},
      onClearAll: (List<StudySession> batch) async => cleared = batch,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('stat-sessions-clear-all')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(cleared, isNull);
    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('空列表：不显示「清除全部会话」按钮（没有东西可清）', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      sessions: const <StudySession>[],
      onDelete: (_) async {},
    );
    expect(
      find.byKey(const ValueKey<String>('stat-sessions-clear-all')),
      findsNothing,
    );
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });
}
