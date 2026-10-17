import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_deck_reposition_dialogs.dart';
import 'package:fushi/src/anki/anki_deck_reposition_runner.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/glass_unwrap.dart';

class _InertAnki extends BaseAnkiRepository {
  AnkiSettings current = const AnkiSettings(
    selectedDeckId: 1,
    availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'review fixture deck')],
    repositionDictionaries: <String>['review frequency'],
  );

  @override
  bool get supportsDeckReposition => true;

  @override
  Future<AnkiSettings> loadSettings() async => current;

  @override
  Future<void> saveSettings(AnkiSettings settings) async => current = settings;

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('inert review repository');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => MineOutcome.failure('inert review repository');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

class _HeldOptionsViewModel extends AnkiViewModel {
  _HeldOptionsViewModel(this.fixture, this.scratch) : super(fixture);

  final _InertAnki fixture;
  final Directory scratch;
  Completer<void> release = Completer<void>();
  bool hold = false;
  int heldWrites = 0;

  @override
  AnkiDeckRepositionRunner get deckRepositionRunner =>
      AnkiDeckRepositionRunner(fixture, snapshotDirectory: () async => scratch);

  @override
  Future<void> setRepositionOptions({
    required AnkiRepositionSource source,
    required List<String> dictionaries,
    required String aggregate,
    required bool rareFirst,
  }) async {
    if (hold) {
      heldWrites++;
      await release.future;
      return;
    }
    return super.setRepositionOptions(
      source: source,
      dictionaries: dictionaries,
      aggregate: aggregate,
      rareFirst: rareFirst,
    );
  }
}

void main() {
  for (final bool failFirst in <bool>[false, true]) {
    testWidgets(
      failFirst
          ? 'failed option save restores preview and permits retry'
          : 'preview accepts only one action while saving its options',
      (WidgetTester tester) async {
        final Directory scratch = Directory.systemTemp.createTempSync(
          'fushi-round8-anki-preview-',
        );
        final _HeldOptionsViewModel viewModel = _HeldOptionsViewModel(
          _InertAnki(),
          scratch,
        );
        await viewModel.setRepositionOptions(
          source: AnkiRepositionSource.dictionaries,
          dictionaries: const <String>['review frequency'],
          aggregate: 'harmonic',
          rareFirst: false,
        );
        late BuildContext host;
        bool? enabledWhileSaving;
        int? writes;
        try {
          await tester.pumpWidget(
            TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  body: Builder(
                    builder: (BuildContext context) {
                      host = context;
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              ),
            ),
          );
          unawaited(
            showAnkiDeckRepositionDialog(
              host,
              viewModel: viewModel,
              loadedFrequencyDictionaries: const <String>['review frequency'],
            ),
          );
          await tester.pumpAndSettle();
          viewModel.hold = true;
          final Finder preview = find.byKey(
            const Key('anki_reposition_preview'),
          );
          await tester.tap(preview);
          await tester.pump();
          final FilledButton button = tester.widget<FilledButton>(
            glassUnwrap<FilledButton>(preview),
          );
          enabledWhileSaving = button.onPressed != null;
          await tester.tap(preview);
          await tester.pump();
          writes = viewModel.heldWrites;
          if (failFirst) {
            viewModel.release.completeError(
              StateError('injected options write failure'),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(
              tester
                  .widget<FilledButton>(glassUnwrap<FilledButton>(preview))
                  .onPressed,
              isNotNull,
            );
            viewModel.release = Completer<void>();
            await tester.tap(preview);
            await tester.pump();
            expect(viewModel.heldWrites, 2);
            expect(
              tester
                  .widget<FilledButton>(glassUnwrap<FilledButton>(preview))
                  .onPressed,
              isNull,
            );
          }
          debugPrint(
            'round8 Anki pending option writes=$writes '
            'previewEnabled=$enabledWhileSaving',
          );
        } finally {
          // Remove the dialog before allowing save to finish: its mounted guard
          // then prevents planning. No card query, mutation, or real Anki IPC occurs.
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          viewModel.release.complete();
          await tester.pump();
          viewModel.dispose();
          scratch.deleteSync(recursive: true);
        }
        expect(writes, 1, reason: 'busy must cover preference persistence too');
        expect(enabledWhileSaving, isFalse);
      },
    );
  }
}
