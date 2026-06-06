// ignore_for_file: invalid_use_of_protected_member
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';

/// In-memory fake；覆写 loadSettings/saveSettings 避开 SharedPreferences，
/// 复用 base 的 updateSettings。
class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo({this.failFetch = false});
  AnkiSettings _settings = const AnkiSettings();
  final bool failFetch;
  int createNoteTypeCalls = 0;
  int createDeckCalls = 0;
  bool noteTypeExists = false;
  bool deckExists = false;

  @override
  Future<AnkiSettings> loadSettings() async => _settings;
  @override
  Future<void> saveSettings(AnkiSettings s) async => _settings = s;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async {
    createNoteTypeCalls++;
    if (noteTypeExists) return false;
    noteTypeExists = true;
    return true;
  }

  @override
  Future<bool> createDeck(String name) async {
    createDeckCalls++;
    if (deckExists) return false;
    deckExists = true;
    return true;
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    if (failFetch) return const AnkiFetchResult.error('boom');
    final decks = [const AnkiDeck(id: 1, name: 'Lapis')];
    final noteTypes = [
      AnkiNoteType(id: 7, name: 'Lapis', fields: LapisNoteType.fields),
    ];
    _settings = _settings.copyWith(
      availableDecks: decks,
      availableNoteTypes: noteTypes,
    );
    return AnkiFetchResult.success(decks: decks, noteTypes: noteTypes);
  }

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

  test('createLapisSetup creates, fetches, selects Lapis + applies preset',
      () async {
    final repo = _FakeRepo();
    final vm = AnkiViewModel(repo);
    await Future<void>.delayed(Duration.zero); // 让构造里的 _loadSettings 完成

    final result = await vm.createLapisSetup();

    expect(result.outcome, LapisSetupOutcome.created);
    expect(repo.createNoteTypeCalls, 1);
    expect(repo.createDeckCalls, 1);
    final s = vm.state.settings;
    expect(s.selectedNoteTypeName, 'Lapis');
    expect(s.selectedDeckName, 'Lapis');
    expect(s.fieldMappings['Expression'], '{expression}');
    expect(s.fieldMappings['Picture'], '{book-cover}');
    expect(vm.state.isFetching, isFalse);
  });

  test('createLapisSetup reports alreadyExisted when model present', () async {
    final repo = _FakeRepo()
      ..noteTypeExists = true
      ..deckExists = true;
    final vm = AnkiViewModel(repo);
    await Future<void>.delayed(Duration.zero);

    final result = await vm.createLapisSetup();
    expect(result.outcome, LapisSetupOutcome.alreadyExisted);
  });

  test('createLapisSetup surfaces fetch failure', () async {
    final repo = _FakeRepo(failFetch: true);
    final vm = AnkiViewModel(repo);
    await Future<void>.delayed(Duration.zero);

    final result = await vm.createLapisSetup();
    expect(result.outcome, LapisSetupOutcome.failed);
    expect(vm.state.errorMessage, isNotNull);
  });
}
