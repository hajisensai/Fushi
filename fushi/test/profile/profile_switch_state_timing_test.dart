import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

/// 悬浮球「切换配置」胶囊读 displayProfile.name：切换期间（applyProfile / 应用回调
/// 还在跑）必须已经是目标配置，而不是停在旧的「默认配置」直到全部做完。
/// activeProfileId 则只代表已生效的配置，应用完成前不得提前变成目标（草稿作用域、
/// 删除判据依赖它，见 dictionary_css_editor_dialog_test 的并发用例）。
void main() {
  test('切换配置：展示配置在重活完成前就是目标，生效配置等应用完成才切', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    final Completer<void> gate = Completer<void>();
    final Completer<void> applyStarted = Completer<void>();
    final ProfileRepository repo = ProfileRepository(db, FakeAnkiRepository());
    final ProfileViewModel vm = ProfileViewModel(repo, () async {
      applyStarted.complete();
      await gate.future;
    }, ProfileDraftCoordinator());
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      vm.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await db.close();
    });
    final ProfileUiState loaded = await vm.stream.firstWhere(
      (ProfileUiState s) => !s.isLoading && s.profiles.isNotEmpty,
    );
    final int newId = await repo.createProfile('Target');
    await vm.reload();

    final Future<void> switching = vm.switchProfile(newId);
    await applyStarted.future;

    expect(
      vm.debugState.displayProfile?.name,
      'Target',
      reason: '重活还没结束，胶囊就该显示目标配置',
    );
    expect(loaded.activeProfileId, isNot(newId));
    gate.complete();
    await switching;
    expect(vm.debugState.activeProfileId, newId);
    expect(vm.debugState.displayProfile?.name, 'Target');
  });
}
