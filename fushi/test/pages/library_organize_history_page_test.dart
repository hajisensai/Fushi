// AI 整理记录页（AI 库管家设计稿 §7 / §8）：挪走（move）出「从 A 挪到 B」文案与
// 专用图标、移出 / 挪走带 AI 理由时显示理由、待确认建议不混进改动列表；顶部确认卡
// 写清「把 X、Y 并进 Z」/「把 X 改名为 Y」，接受以用户身份执行、建议失效（stale）
// 时提示并让卡消失。MD3 与 Apple 两套设计系统各跑一遍；按钮一律焦点驱动（Enter）。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/library_organize_history_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart'
    show FushiMastheadHeader;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiPageHeader;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiListLeadingIcon;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });

  tearDown(() => db.close());

  ThemeData theme({required bool apple}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: FushiGlassMaterial.off,
    glassDesign: apple,
  );

  Future<int> seedRun() => db
      .into(db.libraryOrganizeRuns)
      .insert(
        LibraryOrganizeRunsCompanion.insert(
          domain: 'books',
          trigger: 'manual',
          startedAt: DateTime(2026, 11, 18).millisecondsSinceEpoch,
          status: 'done',
        ),
      );

  Future<int> seedChange(
    int runId,
    String kind,
    String name,
    Map<String, Object?> payload, {
    String source = 'ai',
  }) => db
      .into(db.libraryOrganizeChanges)
      .insert(
        LibraryOrganizeChangesCompanion.insert(
          runId: runId,
          kind: kind,
          collectionName: name,
          collectionType: 'collection',
          organizeKey: const Value<String?>(null),
          source: source,
          confidence: 'high',
          payloadJson: jsonEncode(payload),
        ),
      );

  Map<String, Object?> member(String key) => <String, Object?>{
    't': 'book',
    'k': key,
  };

  Future<void> pumpPage(WidgetTester tester, {required bool apple}) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(apple: apple),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: LibraryOrganizeHistoryPage(db: db, prefs: prefs),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 焦点驱动按下 [key] 指向的按钮：聚焦后按 Enter。
  Future<void> pressByFocus(WidgetTester tester, Key key) async {
    final Finder label = find.descendant(
      of: find.byKey(key),
      matching: find.byType(Text),
    );
    await tester.ensureVisible(label.first);
    Focus.of(tester.element(label.first)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('$ds：挪走出「从 A 挪到 B」与理由；待确认建议不进改动列表', (
      WidgetTester tester,
    ) async {
      final int runId = await seedRun();
      final int moveId = await seedChange(
        runId,
        'move',
        '去处',
        <String, Object?>{
          'from': <String, Object?>{
            'name': '来处',
            'type': 'collection',
            'origin': 'ai',
          },
          'members': <Object?>[member('a'), member('b')],
          'added': <Object?>[member('a')],
          'reason': '同一系列',
        },
      );
      final int evictId = await seedChange(
        runId,
        'evict',
        '杂项',
        <String, Object?>{
          'members': <Object?>[member('c')],
          'origin': 'ai',
          'reason': '不是这个系列',
        },
      );
      await seedChange(runId, 'proposal', '我的合集', <String, Object?>{
        'proposal': 'rename',
        'state': 'accepted',
        'newName': '新名',
      });

      await pumpPage(tester, apple: apple);

      final Finder moveTile = find.byKey(
        ValueKey<String>('library_organize_change_$moveId'),
      );
      expect(
        find.descendant(
          of: moveTile,
          matching: find.text(
            t.library_organize_change_move(from: '来处', name: '去处', n: 2),
          ),
        ),
        findsOneWidget,
      );
      // 图标看传给行首的语义图标（Apple 下会再映射成 SF 风格字形）。
      expect(
        tester
            .widget<FushiListLeadingIcon>(
              find.descendant(
                of: moveTile,
                matching: find.byType(FushiListLeadingIcon),
              ),
            )
            .icon,
        FushiIcons.move,
      );
      expect(
        find.descendant(
          of: moveTile,
          matching: find.textContaining(
            t.library_organize_change_reason(reason: '同一系列'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>('library_organize_change_$evictId')),
          matching: find.textContaining(
            t.library_organize_change_reason(reason: '不是这个系列'),
          ),
        ),
        findsOneWidget,
      );
      // 已处理的建议行不出确认卡、也不当改动列（不会落成「标签」文案）。
      expect(find.text(t.library_organize_proposal_title), findsNothing);
      expect(find.textContaining('我的合集'), findsNothing);
      // 本次摘要只数 2 处改动（建议不算）。
      expect(
        find.textContaining(
          t.library_organize_run_summary(
            library: t.library_organize_domain_books,
            trigger: t.library_organize_trigger_manual,
            n: 2,
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('$ds：确认卡写清合并 / 改名与理由；接受以用户身份执行、失效提示后消失', (
      WidgetTester tester,
    ) async {
      final int runId = await seedRun();
      await db.createMediaCollection('旧名');
      final int renameId =
          await seedChange(runId, 'proposal', '旧名', <String, Object?>{
            'proposal': 'rename',
            'state': 'pending',
            'newName': '新名',
            'reason': '统一成正式译名',
          });
      final int mergeId = await seedChange(
        runId,
        'proposal',
        '不在了',
        <String, Object?>{
          'proposal': 'merge',
          'state': 'pending',
          'sources': <String>['甲', '乙'],
        },
      );

      await pumpPage(tester, apple: apple);

      expect(find.text(t.library_organize_proposal_title), findsOneWidget);
      expect(
        find.text(
          t.library_organize_proposal_rename(name: '旧名', newName: '新名'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(t.library_organize_change_reason(reason: '统一成正式译名')),
        findsOneWidget,
      );
      final String merged = t.library_organize_proposal_merge(
        sources: <String>[
          t.library_organize_proposal_quoted(name: '甲'),
          t.library_organize_proposal_quoted(name: '乙'),
        ].join(t.library_organize_proposal_separator),
        name: '不在了',
      );
      expect(find.text(merged), findsOneWidget);

      // 接受改名：真的改名了，卡消失。
      await pressByFocus(
        tester,
        ValueKey<String>('library_organize_proposal_accept_$renameId'),
      );
      expect(
        await db.getMediaCollectionByNaturalKey('新名', 'collection'),
        isNotNull,
      );
      expect(
        await db.getMediaCollectionByNaturalKey('旧名', 'collection'),
        isNull,
      );
      expect(
        find.byKey(ValueKey<String>('library_organize_proposal_$renameId')),
        findsNothing,
      );

      // 合并目标已不在：接受 → 失效提示，卡消失，标题随最后一张卡一起消失。
      await pressByFocus(
        tester,
        ValueKey<String>('library_organize_proposal_accept_$mergeId'),
      );
      expect(find.text(t.library_organize_proposal_stale), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('library_organize_proposal_$mergeId')),
        findsNothing,
      );
      expect(find.text(t.library_organize_proposal_title), findsNothing);
    });

    testWidgets('$ds：「不用」记为拒绝，不执行', (WidgetTester tester) async {
      final int runId = await seedRun();
      await db.createMediaCollection('旧名');
      final int id = await seedChange(
        runId,
        'proposal',
        '旧名',
        <String, Object?>{
          'proposal': 'rename',
          'state': 'pending',
          'newName': '新名',
        },
      );
      await pumpPage(tester, apple: apple);

      await pressByFocus(
        tester,
        ValueKey<String>('library_organize_proposal_decline_$id'),
      );
      expect(
        await db.getMediaCollectionByNaturalKey('旧名', 'collection'),
        isNotNull,
      );
      expect(
        await db.getMediaCollectionByNaturalKey('新名', 'collection'),
        isNull,
      );
      expect(
        find.byKey(ValueKey<String>('library_organize_proposal_$id')),
        findsNothing,
      );
      expect(find.text(t.library_organize_proposal_stale), findsNothing);
    });

    // BUG-5171（反馈 SPRCuY_gVh）：列表顶部留白曾在脚手架之上的 context 里量，
    // 读不到页头大字外壳注入正文的让位，首个分组头与第一行被「整理记录」大字盖住。
    testWidgets('$ds：首个分组头与第一行都排在页头下沿之下', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1200);
      addTearDown(tester.view.reset);
      final int runId = await seedRun();
      final int changeId = await seedChange(
        runId,
        'evict',
        '杂项',
        <String, Object?>{
          'members': <Object?>[member('c')],
          'origin': 'ai',
        },
      );
      await pumpPage(tester, apple: apple);

      // M3E = 页头大字外壳；Apple = iOS 27 / macOS 27 导航栏行（二级页不走
      // 页头大字，3ea6f9358b4）。两者都要把正文让到栏下沿之下。
      final double headerBottom = tester
          .getRect(
            find.byType(apple ? FushiPageHeader : FushiMastheadHeader).first,
          )
          .bottom;
      expect(headerBottom, greaterThan(0));
      expect(
        tester
            .getRect(
              find.byKey(ValueKey<String>('library_organize_undo_run_$runId')),
            )
            .top,
        greaterThanOrEqualTo(headerBottom),
        reason: '首个分组头（含「撤销本次」）不能被页头盖住',
      );
      expect(
        tester
            .getRect(
              find.byKey(ValueKey<String>('library_organize_change_$changeId')),
            )
            .top,
        greaterThan(headerBottom),
      );
    });
  }
}
