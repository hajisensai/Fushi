// ignore_for_file: invalid_use_of_protected_member
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';

/// In-memory fake；覆写 loadSettings/saveSettings 避开 SharedPreferences，
/// 复用 base 的 updateSettings。
class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo({this.failFetch = false, this.throwOnCreateNoteType});
  AnkiSettings _settings = const AnkiSettings();
  final bool failFetch;

  /// 非 null 时 `createNoteType` 抛出它——模拟一键配置撞上传输层故障。
  final Object? throwOnCreateNoteType;
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
    // ignore: only_throw_errors
    if (throwOnCreateNoteType != null) throw throwOnCreateNoteType!;
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
    expect(s.fieldMappings['Picture'], '{card-image}');
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

  // 用户实测报告：AnkiConnect 的端口被别的程序占着（连得上、不应答）时，一键配置
  // 抛出的 TimeoutException 被 `e.toString()` 原样塞进了错误文案，用户看到的是
  // `TimeoutException after 0:00:10.000000: Future not completed`——既不知道是什么
  // 坏了，也不知道下一步该干什么。
  test('createLapisSetup 的超时不再把 TimeoutException 原文丢给用户', () async {
    final repo = _FakeRepo(
      throwOnCreateNoteType:
          TimeoutException('Future not completed', const Duration(seconds: 10)),
    );
    final vm = AnkiViewModel(repo);
    await Future<void>.delayed(Duration.zero);

    final result = await vm.createLapisSetup();

    expect(result.outcome, LapisSetupOutcome.failed);
    expect(result.message, isNot(contains('TimeoutException')));
    expect(vm.state.errorMessage, isNot(contains('TimeoutException')));
    expect(vm.state.errorMessage, isNot(contains('Future not completed')));
    // 走的是与 fetchConfiguration 同一套稳定码本地化。
    expect(vm.state.errorMessage, t.anki_error_connection_timeout);
  });

  // 本地编程错误（不经 socket）不是连接问题，套上连接文案只会误导排障方向。
  test('createLapisSetup 的非传输层异常不套连接文案', () async {
    final repo = _FakeRepo(throwOnCreateNoteType: StateError('boom'));
    final vm = AnkiViewModel(repo);
    await Future<void>.delayed(Duration.zero);

    final result = await vm.createLapisSetup();

    expect(result.outcome, LapisSetupOutcome.failed);
    expect(vm.state.errorMessage, isNot(t.anki_error_connection_timeout));
    expect(vm.state.errorMessage, contains('boom'));
  });
}
