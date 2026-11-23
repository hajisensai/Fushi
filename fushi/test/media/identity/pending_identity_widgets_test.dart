// BUG-5283：书 / 漫画与游戏没认出来的条目要和视频一样看得见、能处理。共享的提醒条
// （显隐判据、计数文案、「×」只收起当前这批）、待确认弹窗（原因 + 上次尝试、AI 重试
// 与手动搜索动作、忽略 / 撤销在两组之间挪动、AI 模块关着不画重试）与重试结论文案。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/src/media/identity/app_pending_identity.dart'
    show pendingIdentityRetryOutcomeText;
import 'package:fushi/src/media/identity/pending_identity_text.dart';
import 'package:fushi/src/media/identity/pending_identity_widgets.dart';
import 'package:fushi_engine/media/identity/pending_identity.dart';
import 'package:fushi_engine/media/library_curate/library_curate_run.dart';
import 'package:material_ui/material_ui.dart';

class _FakeSource implements PendingIdentitySource {
  _FakeSource(this.entries);

  final List<PendingIdentityEntry> entries;
  final Set<String> ignoredKeys = <String>{};
  int loads = 0;

  @override
  Future<PendingIdentityListing> load() async {
    loads++;
    return PendingIdentityListing(
      pending: <PendingIdentityEntry>[
        for (final PendingIdentityEntry e in entries)
          if (!ignoredKeys.contains(e.key)) e,
      ],
      ignored: <PendingIdentityEntry>[
        for (final PendingIdentityEntry e in entries)
          if (ignoredKeys.contains(e.key)) e,
      ],
    );
  }

  @override
  Future<void> setIgnored(
    Iterable<String> keys, {
    required bool ignored,
  }) async {
    if (ignored) {
      ignoredKeys.addAll(keys);
    } else {
      ignoredKeys.removeAll(keys);
    }
  }
}

PendingIdentityEntry _book(
  String key,
  String title, {
  PendingIdentityMediaKind kind = PendingIdentityMediaKind.book,
  PendingIdentityCause? cause,
  PendingIdentityAiOutcome? ai,
  int candidates = 0,
  DateTime? at,
}) => PendingIdentityEntry(
  kind: kind,
  key: key,
  title: title,
  cause: cause,
  aiOutcome: ai,
  candidateCount: candidates,
  lastAttemptAt: at,
  memberKeys: <String>[key.split(':').last],
);

void main() {
  group('提醒条', () {
    test('显隐判据：有待确认、且不全是收起时那批', () {
      expect(pendingIdentityBannerVisible(<String>{}, <String>{}), isFalse);
      expect(pendingIdentityBannerVisible(<String>{'a'}, <String>{}), isTrue);
      expect(
        pendingIdentityBannerVisible(<String>{'a'}, <String>{'a', 'b'}),
        isFalse,
      );
      expect(
        pendingIdentityBannerVisible(<String>{'a', 'c'}, <String>{'a', 'b'}),
        isTrue,
      );
    });

    testWidgets('按媒体出计数文案；「×」交给宿主；收起后零高度', (WidgetTester tester) async {
      Set<String> dismissed = <String>{};
      int opened = 0;
      late StateSetter setOuter;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                setOuter = setState;
                return Column(
                  children: <Widget>[
                    PendingIdentityBanner(
                      keyPrefix: 'b',
                      pendingKeys: const <String>{'x', 'y'},
                      dismissedKeys: dismissed,
                      message: (int n) => pendingIdentityBannerText(
                        PendingIdentityMediaKind.game,
                        n,
                      ),
                      onDismiss: () =>
                          setState(() => dismissed = <String>{'x', 'y'}),
                      onOpen: () => opened++,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(t.identity_pending_banner_game(count: 2)),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('b-open')));
      expect(opened, 1);
      await tester.tap(find.byKey(const ValueKey<String>('b-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('b')), findsNothing);
      setOuter(() => dismissed = <String>{});
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('b')), findsOneWidget);
    });

    testWidgets('宿主自己加载：只数本媒体，变动信号来了重算', (WidgetTester tester) async {
      final _FakeSource source = _FakeSource(<PendingIdentityEntry>[
        _book('book:a', 'A'),
        _book('collection:1', 'Saga', kind: PendingIdentityMediaKind.manga),
      ]);
      final StreamController<void> changes = StreamController<void>.broadcast();
      addTearDown(changes.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                PendingIdentityBannerHost(
                  kind: PendingIdentityMediaKind.manga,
                  source: () => source,
                  changes: changes.stream,
                  onOpen: () async {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(t.identity_pending_banner_manga(count: 1)),
        findsOneWidget,
      );
      source.entries.add(
        _book('book:b', 'B', kind: PendingIdentityMediaKind.manga),
      );
      changes.add(null);
      await tester.pumpAndSettle();
      expect(
        find.text(t.identity_pending_banner_manga(count: 2)),
        findsOneWidget,
      );
    });
  });

  group('待确认弹窗', () {
    Future<void> open(
      WidgetTester tester,
      _FakeSource source,
      PendingIdentityActions actions,
    ) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PendingIdentityDialog(
              kind: PendingIdentityMediaKind.book,
              source: source,
              actions: actions,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('列出原因与上次尝试；AI 重试 / 手动搜索把结论放进结论卡', (WidgetTester tester) async {
      final _FakeSource source = _FakeSource(<PendingIdentityEntry>[
        _book(
          'book:a',
          'Alpha',
          cause: PendingIdentityCause.awaitingConfirmation,
          ai: PendingIdentityAiOutcome.unassigned,
          candidates: 3,
          at: DateTime(2026, 11, 20, 9, 5),
        ),
        _book('book:b', 'Beta'),
        // 别的媒体不在这个弹窗里。
        _book('game:1', 'Gamma', kind: PendingIdentityMediaKind.game),
      ]);
      final List<String> retried = <String>[];
      final List<String> manual = <String>[];
      await open(
        tester,
        source,
        PendingIdentityActions(
          retryWithAi: (BuildContext _, PendingIdentityEntry e) async {
            retried.add(e.key);
            return 'retried ${e.title}';
          },
          identifyManually: (BuildContext _, PendingIdentityEntry e) async {
            manual.add(e.key);
            return null;
          },
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('identity-book-pending-work-book:a')),
        findsOneWidget,
      );
      expect(find.text('Gamma'), findsNothing);
      final Text reason = tester.widget<Text>(
        find.byKey(
          const ValueKey<String>('identity-book-pending-reason-book:a'),
        ),
      );
      expect(
        reason.data,
        '${t.video_scrape_pending_cause_awaiting_confirmation(count: 3)} · '
        '${t.video_scrape_pending_ai_unassigned}\n'
        '${t.identity_pending_last_attempt(time: '2026-11-20 09:05')}',
      );
      final Text missing = tester.widget<Text>(
        find.byKey(
          const ValueKey<String>('identity-book-pending-reason-book:b'),
        ),
      );
      expect(missing.data, t.video_scrape_pending_record_missing);

      await tester.tap(
        find.byKey(const ValueKey<String>('identity-book-pending-ai-book:a')),
      );
      await tester.pumpAndSettle();
      expect(retried, <String>['book:a']);
      expect(find.text('retried Alpha'), findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('identity-book-pending-manual-book:b'),
        ),
      );
      await tester.pumpAndSettle();
      expect(manual, <String>['book:b']);
    });

    testWidgets('动作还在跑时弹窗关了：动作回来后不再重读、不在已卸载的弹窗上 setState', (
      WidgetTester tester,
    ) async {
      final _FakeSource source = _FakeSource(<PendingIdentityEntry>[
        _book('book:a', 'Alpha'),
      ]);
      final Completer<String?> retry = Completer<String?>();
      await open(
        tester,
        source,
        PendingIdentityActions(
          retryWithAi: (BuildContext _, PendingIdentityEntry e) => retry.future,
        ),
      );
      final int loadsBefore = source.loads;
      await tester.tap(
        find.byKey(const ValueKey<String>('identity-book-pending-ai-book:a')),
      );
      await tester.pump();
      // 用户关掉弹窗，AI 重试这时才回来。
      await tester.pumpWidget(const SizedBox.shrink());
      retry.complete('done');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(source.loads, loadsBefore);
    });

    testWidgets('忽略 → 挪进「已忽略」；撤销 → 回到待确认；没给重试就不画', (WidgetTester tester) async {
      final _FakeSource source = _FakeSource(<PendingIdentityEntry>[
        _book('book:a', 'Alpha'),
      ]);
      await open(tester, source, const PendingIdentityActions());
      expect(
        find.byKey(const ValueKey<String>('identity-book-pending-ai-book:a')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>('identity-book-pending-ignore-book:a'),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.ignoredKeys, <String>{'book:a'});
      expect(
        find.byKey(const ValueKey<String>('identity-book-ignored-work-book:a')),
        findsOneWidget,
      );
      expect(find.text(t.identity_pending_empty), findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('identity-book-ignored-restore-book:a'),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.ignoredKeys, isEmpty);
      expect(
        find.byKey(const ValueKey<String>('identity-book-pending-work-book:a')),
        findsOneWidget,
      );
    });
  });

  group('文案', () {
    test('旧记录没有候选数：不说「有 0 个候选」', () {
      expect(
        pendingIdentityCauseText(PendingIdentityCause.awaitingConfirmation, 0),
        t.identity_pending_cause_awaiting_confirmation_unknown,
      );
    });

    test('单条重试结论：没跑完 / 仍待确认 / 认出来了', () {
      LibraryCurateRun run(
        LibraryCurateStageStatus status, {
        bool pending = false,
      }) => LibraryCurateRun(
        id: 1,
        trigger: LibraryCurateTrigger.manual,
        startedAt: 1,
        target: 'book:a',
        stages: <LibraryCurateStageResult>[
          LibraryCurateStageResult(
            stage: LibraryCurateStage.scrapeBooks,
            status: status,
          ),
        ],
        pendingItems: <LibraryCuratePendingItem>[
          if (pending)
            const LibraryCuratePendingItem(
              stage: LibraryCurateStage.scrapeBooks,
              kind: 'book_scrape_pending',
              title: 'A',
              ref: 'book:a',
            ),
        ],
      );
      expect(
        pendingIdentityRetryOutcomeText(run(LibraryCurateStageStatus.partial)),
        t.identity_pending_retry_failed,
      );
      expect(
        pendingIdentityRetryOutcomeText(
          run(LibraryCurateStageStatus.done, pending: true),
        ),
        t.identity_pending_retry_still_pending,
      );
      expect(
        pendingIdentityRetryOutcomeText(run(LibraryCurateStageStatus.done)),
        t.identity_pending_retry_identified,
      );
    });
  });
}
