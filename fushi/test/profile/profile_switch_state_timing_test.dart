import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

/// 悬浮球「切换配置」胶囊读 activeProfile.name：切换期间（applyProfile / 应用回调
/// 还在跑）必须已经是目标配置，而不是停在旧的「默认配置」直到全部做完。
void main() {
  test('切换配置：激活 id 在重活（应用回调）完成前就已同步到 state', () async {
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

    expect(vm.debugState.activeProfileId, newId, reason: '重活还没结束，胶囊就该显示目标配置');
    expect(vm.debugState.activeProfile?.name, 'Target');
    expect(loaded.activeProfileId, isNot(newId));
    gate.complete();
    await switching;
  });
}
