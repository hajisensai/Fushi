// ignore_for_file: invalid_use_of_protected_member
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';

/// In-memory fake；覆写 loadSettings/saveSettings 避开 SharedPreferences，
/// 复用 base 的 updateSettings。
class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo({
    this.failFetch = false,
    this.throwOnCreateNoteType,
    this.lapisInvisibleAfterCreate = false,
  });
  AnkiSettings _settings = const AnkiSettings();
  final bool failFetch;

  /// BUG-2380：后端把创建**静默吞掉**——`createDeck` / `createNoteType` 报成功，
  /// 但回读的清单里根本没有 Lapis，只有用户自己的牌组。这正是 AnkiDroid 的
  /// `addNewDeck` 返回 null 而 native 侧照样 `result.success` 时的形态。
  final bool lapisInvisibleAfterCreate;

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
    final decks = lapisInvisibleAfterCreate
        ? const [AnkiDeck(id: 1, name: '日语')]
        : const [AnkiDeck(id: 1, name: 'Lapis')];
    final noteTypes = lapisInvisibleAfterCreate
        ? const [AnkiNoteType(id: 7, name: '基础', fields: ['正面', '背面'])]
        : [AnkiNoteType(id: 7, name: 'Lapis', fields: LapisNoteType.fields)];
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

  // BUG-2380（用户实测报告）：手机端新装 AnkiDroid、自己建了个叫「日语」的牌组，
  // 点「创建并选用 Lapis」之后，界面显示的选中牌组是「日语」而不是 Lapis。
  //
  // 根因两段：native 的 `createDeck` 丢掉了 `addNewDeck` 的返回值（失败返回 null）
  // 并无条件报成功；Dart 这一侧拿到「成功」后用
  // `firstWhere(name == 'Lapis', orElse: () => list.first)` 找不到就退而选清单里的
  // **第一个**牌组/笔记类型，还顺手套上 Lapis 的字段映射、返回 created。
  // 「一键把三样对齐」于是变成「静默把用户自己的牌组配成一个字段全对不上的目标」。
  test('BUG-2380 建完在清单里看不到 Lapis 时失败，绝不改选用户自己的牌组', () async {
    final repo = _FakeRepo(lapisInvisibleAfterCreate: true);
    final vm = AnkiViewModel(repo);
    await Future<void>.delayed(Duration.zero);

    final result = await vm.createLapisSetup();

    expect(result.outcome, LapisSetupOutcome.failed);
    expect(result.code, AnkiErrorCode.lapisSetupMissing);

    final s = vm.state.settings;
    // 关键断言：不许**谎称**选中了 Lapis。选中的仍是 fetchConfiguration 自动挑的
    // 那个用户牌组（那是它一贯的行为，与本 bug 无关），但 createLapisSetup 这一步
    // 不再往上面盖一层「这就是 Lapis」。
    expect(s.selectedDeckName, isNot('Lapis'));
    expect(s.selectedNoteTypeName, isNot('Lapis'));
    // 更关键：Lapis 的字段映射绝不许套到别人的笔记类型上——那正是让制卡时
    // 「字段一个都对不上 / 首字段为空」的来源。
    expect(s.fieldMappings, isEmpty);
    expect(vm.state.isFetching, isFalse);
    expect(vm.state.errorMessage, t.anki_create_lapis_not_found);
    // 这套配置制不出卡，正是弹窗（promptCreateLapisIfCannotMine）该被触发的形态。
    expect(s.canMineCards, isFalse);
  });

  // 牌组是这次补建的、笔记类型早就在 —— 也算「这次创建过」。此前 `createDeck` 的
  // 返回值被丢掉，只看 `createNoteType`，于是这种情形报成「已存在」。
  test('BUG-2380 只补建了牌组时报 created 而非 alreadyExisted', () async {
    final repo = _FakeRepo()..noteTypeExists = true;
    final vm = AnkiViewModel(repo);
    await Future<void>.delayed(Duration.zero);

    final result = await vm.createLapisSetup();

    expect(result.outcome, LapisSetupOutcome.created);
  });
}
