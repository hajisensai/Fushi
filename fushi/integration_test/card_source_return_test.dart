import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:fushi/main.dart' show FushiReaderApp;
import 'package:fushi/src/anki/anki_mined_card_action_sheet.dart';
import 'package:fushi/src/anki/card_source_router.dart';
import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/anki/source_review_session.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (int i = 0; i < 160 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(ready(), isTrue);
}

Future<void> _finish(WidgetTester tester, Future<void> action) async {
  bool done = false;
  Object? failure;
  unawaited(
    action.then(
      (_) => done = true,
      onError: (Object error) {
        failure = error;
        done = true;
      },
    ),
  );
  await _until(tester, () => done);
  if (failure != null) throw StateError('Source action failed: $failure');
}

Future<int> _count(FushiDatabase db, String table) async =>
    (await db.customSelect('SELECT count(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<bool> _focusControl(FocusDriver driver, Finder target) =>
    driver.focusUntil(() {
      final FocusNode? focused = driver.focused;
      if (focused == null ||
          focused is FocusScopeNode ||
          focused.skipTraversal) {
        return false;
      }
      final Set<Element> controls = target.evaluate().toSet();
      final BuildContext? owner = focused.context;
      if (owner == null) return false;
      if (controls.contains(owner)) return true;
      bool inside = false;
      owner.visitAncestorElements((Element ancestor) {
        if (controls.contains(ancestor)) {
          inside = true;
          return false;
        }
        return true;
      });
      // Reader content itself is a focusable ancestor of the whole page. Only
      // a focus owner INSIDE the control proves that Tab reached its button.
      return inside;
    });

class _ViewerRepository extends BaseAnkiRepository {
  @override
  Future<Map<String, String>?> noteFields(int noteId) async => <String, String>{
        'Expression': '全員参加',
        'ExpressionReading': 'ぜんいんさんか',
        'Sentence': 'それ 全員参加 ですか？',
        'MainDefinition': '全員が参加すること。',
      };
  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      MineOutcome.failure('unused');
  @override
  Future<bool> isDuplicate(String expression, String reading) async => true;
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
  @override
  Future<bool> createDeck(String name) async => false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'source review preserves progress and existing note viewer uses one dialog',
    timeout: const Timeout(Duration(minutes: 5)),
    (WidgetTester tester) async {
      final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
      await launchFushiTestApp();
      final bool homeReady = await waitForHome(tester);
      // App startup installs its production logger. Keep test failures owned by
      // the binding so an assertion reports its real cause instead of timing out.
      FlutterError.onError = testErrorHandler;
      expect(homeReady, isTrue);
      final AppModel model = await enableFocusNavigation(tester);
      final String key = await seedReaderBook(
        tester,
        fileName: 'card_source_return.epub',
      );
      final EpubBookRow book = (await model.database.getEpubBook(key))!;
      final ReaderPositionRepository positions = ReaderPositionRepository(
        model.database,
      );
      await positions.save(
        bookUid: book.uid,
        sectionIndex: 0,
        normCharOffset: 8000,
        charOffset: 8000,
      );
      final ReaderPositionRow before = (await model.database.getReaderPosition(
        book.uid,
      ))!;
      final int historyBefore = await _count(
        model.database,
        'media_open_history',
      );
      final int statsBefore = await _count(model.database, 'study_segments');
      final WidgetRef ref = tester.element(find.byType(FushiReaderApp))
          as ConsumerStatefulElement;
      final CardSourceLink link = CardSourceLink(
        kind: CardSourceKind.book,
        uid: book.uid,
        sourceId: CardSourceLink.newSourceId(),
        chapterIndex: 0,
        charOffset: 1000,
        charLength: 15,
      );
      await _finish(
        tester,
        openCardSource(
          ref: ref,
          // BUG-2501: Windows normalizes fushi://source?... to source/?...
          link: CardSourceLink.parse(
            link.toUri().replace(path: '/').toString(),
          ),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey<String>('fushi_content_ready'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.byType(SourceReviewBanner), findsOneWidget);
      final ReaderFushiPage reader = tester.widget<ReaderFushiPage>(
        find.byType(ReaderFushiPage),
      );
      expect(reader.initialBookmarkJump?.charAnchor, 1000);
      await tester.pump(const Duration(seconds: 2));
      expect(await model.database.getReaderPosition(book.uid), before);
      expect(await _count(model.database, 'media_open_history'), historyBefore);
      expect(await _count(model.database, 'study_segments'), statsBefore);
      expect(
        (await model.database.getEpubBook(key))!.completedAt,
        book.completedAt,
      );
      final ObserveShot reviewShot = await captureFlutterFrame(
        tester,
        'card-source-review',
      );
      expect(reviewShot.saved, isTrue);
      await captureReaderWebView('card-source-review-text');
      debugPrint('[source-itest] review database assertions passed; returning');

      final FocusDriver focus = FocusDriver(tester);
      expect(
        await _focusControl(
          focus,
          find.widgetWithText(TextButton, t.card_source_review_return),
        ),
        isTrue,
      );
      await focus.activate();
      debugPrint('[source-itest] return activated');
      await _until(
        tester,
        () => find.byType(ReaderFushiPage).evaluate().isEmpty,
      );
      expect(await model.database.getReaderPosition(book.uid), before);
      expect(await _count(model.database, 'study_segments'), statsBefore);
      debugPrint('[source-itest] return preserved progress; reopening');

      await _finish(tester, openCardSource(ref: ref, link: link));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey<String>('fushi_content_ready'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        await _focusControl(
          focus,
          find.widgetWithText(TextButton, t.card_source_review_continue),
        ),
        isTrue,
      );
      await focus.activate();
      final SourceReviewBanner banner = tester.widget<SourceReviewBanner>(
        find.byType(SourceReviewBanner),
      );
      expect(banner.session.isReview, isFalse);
      bool closed = false;
      await _finish(
        tester,
        ExternalMediaNavigation.instance.closeActive().then((bool ok) {
          closed = ok;
        }),
      );
      expect(closed, isTrue);
      final ReaderPositionRow continued =
          (await model.database.getReaderPosition(book.uid))!;
      expect(continued.updatedAt, greaterThan(before.updatedAt));
      expect(continued.charOffset, isNot(before.charOffset));
      debugPrint('[source-itest] continue persisted position; checking dialog');

      // This reproduces the reported candidate -> viewer interaction in the
      // real app's dialog/focus host. The repository is an isolated UI fixture.
      final Future<AnkiMinedCardActionResult> dialog =
          showAnkiMinedCardActionSheet(
        context: model.navigatorKey.currentContext!,
        matches: const <MinedNoteRef>[
          MinedNoteRef(noteId: 1, preview: '全員参加'),
        ],
        repo: _ViewerRepository(),
        mineNew: () async => (ankiConnect: false, noteId: null),
        overwrite: (int id) async => (ankiConnect: true, noteId: id),
      );
      await _until(
        tester,
        () => find.text(t.anki_mined_card_title).evaluate().isNotEmpty,
      );
      expect(
        await focus.focusWidget(find.byTooltip(t.anki_mined_action_view)),
        isTrue,
      );
      await focus.activate();
      await _until(
        tester,
        () => find.text(t.anki_note_viewer_title).evaluate().isNotEmpty,
      );
      expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
      expect(
        find.text(t.anki_mined_card_title, skipOffstage: false),
        findsNothing,
      );
      final ObserveShot dialogShot = await captureFlutterFrame(
        tester,
        'card-source-single-note-dialog',
      );
      expect(dialogShot.saved, isTrue);
      expect(
        await focus.focusWidget(
          find.widgetWithText(
            TextButton,
            MaterialLocalizations.of(
              model.navigatorKey.currentContext!,
            ).closeButtonLabel,
          ),
        ),
        isTrue,
      );
      await focus.activate();
      await dialog;
      await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
