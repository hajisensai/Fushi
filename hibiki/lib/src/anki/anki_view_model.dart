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
      case AnkiFetchError(:final message):
        state = state.copyWith(isFetching: false, errorMessage: message);
    }
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
}

final ankiRepositoryProvider = Provider<BaseAnkiRepository>((_) {
  if (isAndroidPlatform) return AnkiRepository();
  return AnkiConnectRepository();
});

final ankiViewModelProvider =
    StateNotifierProvider<AnkiViewModel, AnkiUiState>((ref) {
  return AnkiViewModel(ref.read(ankiRepositoryProvider));
});
