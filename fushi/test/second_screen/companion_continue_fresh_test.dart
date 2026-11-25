import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/second_screen/companion/companion_continue.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/stats/stat_facts.dart';

import '../helpers/test_platform_services.dart';

/// The daily summary's Continue entry showed a book at 50 % while the reader
/// had saved 68 %: the collector read the home shelf's provider caches,
/// which the reader only refreshes in its exit hook, after the summary was
/// collected. The collector reads the database itself, so a saved position
/// shows at the next collection whatever the shelf caches hold.
void main() {
  test('the Continue candidates follow the saved position, not the shelf '
      'caches', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wirePreferencesForTesting(prefs);
    // A local manga volume: page-based progress (sectionIndex + 1 of 10).
    await db
        .into(db.epubBooks)
        .insert(
          EpubBooksCompanion.insert(
            bookKey: 'vol-1',
            uid: const Value<String>('uid-vol-1'),
            title: 'Volume 1',
            epubPath: '/fake/vol-1.cbz',
            extractDir: '/fake/vol-1',
            chapterCount: 10,
            chaptersJson: '[]',
            importedAt: 1000,
            format: const Value<String>('manga'),
          ),
        );
    final ReaderPositionRepository positions = ReaderPositionRepository(db);
    await positions.save(
      bookUid: 'uid-vol-1',
      sectionIndex: 4,
      normCharOffset: 0,
    );

    final ProviderContainer container = ProviderContainer(
      overrides: [appProvider.overrideWith((ref) => appModel)],
    );
    addTearDown(container.dispose);
    final FutureProvider<List<CompanionContinueCandidate>> collect =
        FutureProvider<List<CompanionContinueCandidate>>(
          (Ref ref) =>
              collectCompanionContinueCandidates(ref, facts: StatFacts.empty),
        );

    Future<double?> progress() async {
      final List<CompanionContinueCandidate> all = await container.read(
        collect.future,
      );
      container.invalidate(collect);
      return all.single.item.progress;
    }

    // The shelf caches are warm (the library was shown before reading).
    // Listened, like the shelf does: the provider rebuilds once its book-key
    // stream emits, and an unlistened rebuild while loading never finishes.
    final Completer<void> warm = Completer<void>();
    final ProviderSubscription<AsyncValue<List<MediaItem>>> shelf = container
        .listen<AsyncValue<List<MediaItem>>>(
          fushiBooksProvider(JapaneseLanguage.instance),
          (AsyncValue<List<MediaItem>>? _, AsyncValue<List<MediaItem>> next) {
            if (next.hasValue && !warm.isCompleted) warm.complete();
          },
          fireImmediately: true,
        );
    addTearDown(shelf.close);
    await warm.future;
    expect(await progress(), closeTo(0.5, 1e-9));

    // Reading on top saves positions; the shelf caches stay as they were
    // until the reader's exit hook invalidates them.
    await positions.save(
      bookUid: 'uid-vol-1',
      sectionIndex: 6,
      normCharOffset: 0,
    );
    expect(await progress(), closeTo(0.7, 1e-9));
  });
}
