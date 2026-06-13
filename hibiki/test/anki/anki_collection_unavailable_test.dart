// ignore_for_file: invalid_use_of_protected_member
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

// BUG-241 (TODO-292): fetching decks/models/fields from AnkiDroid used to
// surface AnkiDroid's raw English "collection is not available" exception text
// verbatim, with no guidance. AnkiDroid raising this is external app state the
// host app cannot fix (collection in use / mid-sync / corrupt, AnkiDroid never
// opened once, API disabled, background process killed). The fix classifies it
// with a dedicated ANKI_COLLECTION_UNAVAILABLE channel code and maps it to a
// localized, actionable hint; all other errors keep their verbatim message.

/// In-memory fake repository that returns a pre-built fetch error, so the
/// view-model classification can be exercised without a platform channel.
class _FetchErrorRepo extends BaseAnkiRepository {
  _FetchErrorRepo(this._error);
  final AnkiFetchResult _error;
  AnkiSettings _settings = const AnkiSettings();

  @override
  Future<AnkiSettings> loadSettings() async => _settings;
  @override
  Future<void> saveSettings(AnkiSettings s) async => _settings = s;

  @override
  Future<AnkiFetchResult> fetchConfiguration() async => _error;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
  @override
  Future<bool> createDeck(String name) async => false;
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      MineOutcome.failure('test stub');
  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocaleRaw('en');

  group('AnkiViewModel.localizeAnkiFetchError', () {
    test(
        'collection-unavailable code maps to the localized actionable hint, '
        'not the raw English message', () {
      final String localized = AnkiViewModel.localizeAnkiFetchError(
        'collection is not available',
        AnkiErrorCode.collectionUnavailable,
      );

      expect(localized, t.anki_error_collection_unavailable);
      expect(localized, isNot('collection is not available'));
    });

    test('unclassified error keeps its verbatim message', () {
      const String raw = 'Some other provider failure';
      expect(
        AnkiViewModel.localizeAnkiFetchError(raw, 'ANKI_PROVIDER_ERROR'),
        raw,
      );
      expect(AnkiViewModel.localizeAnkiFetchError(raw, null), raw);
    });
  });

  group('AnkiViewModel.fetchConfiguration error surfacing', () {
    test(
        'collection-unavailable fetch error shows the friendly localized '
        'message in state', () async {
      final repo = _FetchErrorRepo(
        const AnkiFetchResult.error(
          'collection is not available',
          code: AnkiErrorCode.collectionUnavailable,
        ),
      );
      final vm = AnkiViewModel(repo);
      await Future<void>.delayed(Duration.zero); // let constructor settle

      await vm.fetchConfiguration();

      expect(vm.state.isFetching, isFalse);
      expect(vm.state.errorMessage, t.anki_error_collection_unavailable);
      // The raw AnkiDroid English text must not leak through.
      expect(vm.state.errorMessage, isNot('collection is not available'));
    });

    test('non-classified fetch error is shown verbatim (no regression)',
        () async {
      final repo = _FetchErrorRepo(
        const AnkiFetchResult.error('AnkiDroid is not available.'),
      );
      final vm = AnkiViewModel(repo);
      await Future<void>.delayed(Duration.zero);

      await vm.fetchConfiguration();

      expect(vm.state.errorMessage, 'AnkiDroid is not available.');
    });
  });

  group('AnkiChannelHandler source guard', () {
    // The Java ContentProvider client cannot be host-tested; guard at the
    // source that the catch blocks classify the collection-unavailable failure
    // with a dedicated error code instead of the generic provider error.
    test('classifies collection-unavailable with ANKI_COLLECTION_UNAVAILABLE',
        () {
      final File f = File(
        '../hibiki/android/app/src/main/java/app/hibiki/reader/'
        'AnkiChannelHandler.java',
      );
      // Run from either repo root or the hibiki package directory.
      final File java = f.existsSync()
          ? f
          : File(
              'android/app/src/main/java/app/hibiki/reader/'
              'AnkiChannelHandler.java',
            );
      expect(java.existsSync(), isTrue,
          reason: 'AnkiChannelHandler.java not found at ${java.path}');
      final String src = java.readAsStringSync();

      expect(src.contains('ANKI_COLLECTION_UNAVAILABLE'), isTrue,
          reason: 'must emit the dedicated collection-unavailable error code');
      expect(src.toLowerCase().contains('collection is not available'), isTrue,
          reason: 'must match AnkiDroid\'s collection-unavailable message');
      // getDecks/getModelList/getFieldList route through the classifier.
      expect(src.contains('providerErrorCode('), isTrue,
          reason: 'fetch catch blocks must classify via providerErrorCode()');
    });
  });
}
