import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/utils.dart';

class AnkiUiState {
  const AnkiUiState({
    this.settings = const AnkiSettings(),
    this.isFetching = false,
    this.errorMessage,
  });
  final AnkiSettings settings;
  final bool isFetching;
  final String? errorMessage;

  List<AnkiDeck> get availableDecks => settings.availableDecks;
  List<AnkiNoteType> get availableNoteTypes => settings.availableNoteTypes;
  AnkiNoteType? get selectedNoteType => settings.selectedNoteType;
  bool get isConfigured => settings.isConfigured;

  AnkiUiState copyWith({
    AnkiSettings? settings,
    bool? isFetching,
    String? errorMessage,
    bool clearError = false,
  }) =>
      AnkiUiState(
        settings: settings ?? this.settings,
        isFetching: isFetching ?? this.isFetching,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      );
}

class AnkiViewModel extends StateNotifier<AnkiUiState> {
  AnkiViewModel(this._repository) : super(const AnkiUiState()) {
    _loadSettings();
  }
  final BaseAnkiRepository _repository;

  Future<void> _loadSettings() async {
    final settings = await _repository.loadSettings();
    state = state.copyWith(settings: settings);
    if (settings.selectedDeckId != null &&
        settings.selectedNoteTypeId != null &&
        (settings.availableDecks.isEmpty ||
            settings.availableNoteTypes.isEmpty)) {
      await fetchConfiguration();
    }
  }

  Future<void> fetchConfiguration() async {
    state = state.copyWith(isFetching: true, clearError: true);
    final result = await _repository.fetchConfiguration();
    switch (result) {
      case AnkiFetchSuccess():
        final settings = await _repository.loadSettings();
        state = state.copyWith(settings: settings, isFetching: false);
      case AnkiFetchError(:final message, :final code):
        state = state.copyWith(
          isFetching: false,
          errorMessage: localizeAnkiFetchError(message, code),
        );
    }
  }

  /// TODO-292: map a classified AnkiDroid fetch error to a localized,
  /// actionable hint. AnkiDroid raising "collection is not available" is
  /// external app state the host app cannot fix (collection in use / mid-sync /
  /// corrupt, AnkiDroid never opened once, API disabled, background process
  /// killed); show the user what to do instead of the raw English text.
  /// Unclassified errors keep their verbatim [message].
  static String localizeAnkiFetchError(String message, String? code) {
    if (code == AnkiErrorCode.collectionUnavailable) {
      return t.anki_error_collection_unavailable;
    }
    return message;
  }

  Future<void> selectDeck(AnkiDeck deck) async {
    final updated = await _repository.updateSettings((s) => s.copyWith(
          selectedDeckId: deck.id,
          selectedDeckName: deck.name,
        ));
    state = state.copyWith(settings: updated);
  }

  Future<void> selectNoteType(AnkiNoteType noteType) async {
    final updated = await _repository.updateSettings((s) => s.copyWith(
          selectedNoteTypeId: noteType.id,
          selectedNoteTypeName: noteType.name,
          fieldMappings: LapisPreset.applyDefaults(noteType, {}),
        ));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateFieldMapping(String field, String value) async {
    final trimmed = value.trim();
    final updated = await _repository.updateSettings((s) {
      final mappings = Map<String, String>.from(s.fieldMappings);
      if (trimmed.isEmpty) {
        mappings.remove(field);
      } else {
        mappings[field] = value;
      }
      return s.copyWith(fieldMappings: mappings);
    });
    state = state.copyWith(settings: updated);
  }

  Future<void> updateTags(String tags) async {
    final updated =
        await _repository.updateSettings((s) => s.copyWith(tags: tags));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateTagIncludeHibiki(bool value) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(tagIncludeHibiki: value));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateTagIncludeCategory(bool value) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(tagIncludeCategory: value));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateAllowDupes(bool value) async {
    final updated =
        await _repository.updateSettings((s) => s.copyWith(allowDupes: value));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateCompactGlossaries(bool value) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(compactGlossaries: value));
    state = state.copyWith(settings: updated);
  }

  /// TODO-614：切换「覆写已制卡片」范围（latest=仅最近一张 / all=全部已存在卡）。
  Future<void> updateOverwriteScope(AnkiOverwriteScope value) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(overwriteScope: value));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateAnkiConnectHost(String host) async {
    final trimmed = host.trim();
    if (trimmed.isEmpty ||
        trimmed.contains('/') ||
        trimmed.contains('?') ||
        trimmed.contains('#')) {
      return;
    }
    final updated = await _repository
        .updateSettings((s) => s.copyWith(ankiConnectHost: trimmed));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateAnkiConnectPort(String portStr) async {
    final port = int.tryParse(portStr.trim());
    if (port == null || port <= 0 || port > 65535) return;
    final updated = await _repository
        .updateSettings((s) => s.copyWith(ankiConnectPort: port));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateAnkiConnectApiKey(String apiKey) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(ankiConnectApiKey: apiKey.trim()));
    state = state.copyWith(settings: updated);
  }

  Future<LapisSetupResult> createLapisSetup() async {
    state = state.copyWith(isFetching: true, clearError: true);
    try {
      final created = await _repository.createNoteType(LapisNoteType.template);
      await _repository.createDeck(LapisNoteType.deckName);

      final fetch = await _repository.fetchConfiguration();
      if (fetch is AnkiFetchError) {
        state = state.copyWith(isFetching: false, errorMessage: fetch.message);
        return LapisSetupResult(LapisSetupOutcome.failed, fetch.message);
      }

      final settings = await _repository.loadSettings();
      final noteType = settings.availableNoteTypes.firstWhere(
          (t) => t.name == LapisNoteType.modelName,
          orElse: () => settings.availableNoteTypes.first);
      final deck = settings.availableDecks.firstWhere(
          (d) => d.name == LapisNoteType.deckName,
          orElse: () => settings.availableDecks.first);

      final updated = await _repository.updateSettings((s) => s.copyWith(
            selectedDeckId: deck.id,
            selectedDeckName: deck.name,
            selectedNoteTypeId: noteType.id,
            selectedNoteTypeName: noteType.name,
            fieldMappings: LapisPreset.applyDefaults(noteType, {}),
          ));
      state = state.copyWith(settings: updated, isFetching: false);
      return LapisSetupResult(created
          ? LapisSetupOutcome.created
          : LapisSetupOutcome.alreadyExisted);
    } catch (e, stack) {
      debugPrint('AnkiViewModel.createLapisSetup: $e\n$stack');
      state = state.copyWith(isFetching: false, errorMessage: e.toString());
      return LapisSetupResult(LapisSetupOutcome.failed, e.toString());
    }
  }
}

enum LapisSetupOutcome { created, alreadyExisted, failed }

class LapisSetupResult {
  const LapisSetupResult(this.outcome, [this.message]);
  final LapisSetupOutcome outcome;
  final String? message;
}

final ankiRepositoryProvider = Provider<BaseAnkiRepository>((_) {
  if (isAndroidPlatform) return AnkiRepository();
  return AnkiConnectRepository();
});

final ankiViewModelProvider =
    StateNotifierProvider<AnkiViewModel, AnkiUiState>((ref) {
  return AnkiViewModel(ref.read(ankiRepositoryProvider));
});
