// 反馈 JNyykxvuY9：制卡成功提示上的「撤销」——门控（后端删不了 / 覆写 / 进队列
// 都不给按钮）、删完通知界面重新探测 ✓、失败不当成已删。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/mined_card_undo.dart';
import 'package:fushi/src/anki/mined_state_signal.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:material_ui/material_ui.dart';

class _Repo extends BaseAnkiRepository {
  _Repo({this.canDelete = true, this.fail = false, this.exists = true});

  final bool canDelete;
  final bool fail;
  final bool exists;
  final List<int> deleted = <int>[];

  @override
  bool get canDeleteMinedNotes => canDelete;

  @override
  Future<bool> deleteMinedNote(int noteId) async {
    if (fail) throw StateError('unreachable');
    if (!exists) return false;
    deleted.add(noteId);
    return true;
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => const MineOutcome.success();
  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
  @override
  Future<bool> createDeck(String name) async => false;
}

void main() {
  group('MinedCardUndo.of 门控', () {
    test('新制成功 + 有 note id + 后端删得了 → 可撤销', () {
      expect(
        MinedCardUndo.of(_Repo(), const MineOutcome.success(noteId: 7)),
        isNotNull,
      );
    });

    test('后端删不了（AnkiMobile / 互联转发）→ 不给按钮', () {
      expect(
        MinedCardUndo.of(
          _Repo(canDelete: false),
          const MineOutcome.success(noteId: 7),
        ),
        isNull,
      );
    });

    test('没有 note id / 未成功 → 不给按钮', () {
      expect(MinedCardUndo.of(_Repo(), const MineOutcome.success()), isNull);
      expect(MinedCardUndo.of(_Repo(), const MineOutcome.duplicate()), isNull);
    });

    test('覆写已有卡 → 不给按钮（撤销会删掉用户原来那张）', () {
      expect(
        minedCardUndoToastAction(
          _Repo(),
          const MineOutcome.success(noteId: 7),
          overwrite: true,
        ),
        isNull,
      );
      expect(
        minedCardUndoToastAction(_Repo(), const MineOutcome.success(noteId: 7)),
        isNotNull,
      );
    });
  });

  group('deleteMinedCard', () {
    test('删掉后通知这个词的制卡态变了', () async {
      final _Repo repo = _Repo();
      final List<String?> changed = <String?>[];
      final StreamSubscription<MinedStateChange> sub = MinedStateSignal
          .instance
          .changes
          .listen((MinedStateChange c) => changed.add(c.expression));
      final MinedCardDeleteResult result = await deleteMinedCard(
        repo: repo,
        noteId: 42,
        expression: ' 雪 ',
      );
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(result, MinedCardDeleteResult.deleted);
      expect(repo.deleted, <int>[42]);
      expect(changed, <String?>['雪']);
    });

    test('已不在 → alreadyGone；后端出错 → failed（不当成删了，不发通知）', () async {
      expect(
        await deleteMinedCard(repo: _Repo(exists: false), noteId: 1),
        MinedCardDeleteResult.alreadyGone,
      );
      final List<MinedStateChange> changed = <MinedStateChange>[];
      final StreamSubscription<MinedStateChange> sub = MinedStateSignal
          .instance
          .changes
          .listen(changed.add);
      expect(
        await deleteMinedCard(repo: _Repo(fail: true), noteId: 1),
        MinedCardDeleteResult.failed,
      );
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(changed, isEmpty);
    });
  });

  testWidgets('制卡成功 toast 带「撤销」：可点，点下收起并删卡', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = key;
    final _Repo repo = _Repo();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: key,
          home: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    FushiToast.showMine(
      msg: 'added',
      status: MineToastStatus.added,
      action: minedCardUndoToastAction(
        repo,
        const MineOutcome.success(noteId: 9),
        expression: '雪',
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final Finder undo = find.byKey(
      const ValueKey<String>('mine-notice-action'),
    );
    expect(undo, findsOneWidget);
    expect(find.text(t.card_notice_undo), findsOneWidget);

    // 普通结果 toast 2.4 秒就收；带按钮的还在。
    await tester.pump(const Duration(seconds: 2));
    expect(undo, findsOneWidget);

    await tester.tap(undo);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(repo.deleted, <int>[9]);
    expect(find.text(t.anki_mined_card_deleted), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
