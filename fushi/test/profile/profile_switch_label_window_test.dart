import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

class _GatedSnapshotRepository extends ProfileRepository {
  _GatedSnapshotRepository(super.db, super.anki);
  Completer<void>? snapshotGate;

  @override
  Future<void> snapshotCurrentSettings(int profileId) async {
    final Completer<void>? gate = snapshotGate;
    if (gate != null) await gate.future;
    return super.snapshotCurrentSettings(profileId);
  }
}

class _FakeAppModel extends ChangeNotifier implements AppModel {
  _FakeAppModel(this.gate);
  final Completer<void> gate;
  @override
  bool isDictionaryInstalledOnDisk(String name) => true;
  @override
  Future<void> refreshPrefCache() async {}
  @override
  Future<void> reloadDictionariesFromDb() => gate.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlatformServices implements PlatformServices {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 悬浮球「切换配置」胶囊在切换的整段秒级窗口里，绝不能显示旧配置（从默认配置切出
/// 去就是「默认配置」）：既要覆盖应用前的快照 / 锁等待，也要覆盖应用后
/// ankiRepositoryProvider 失效引发的视图模型重建。
void main() {
  test('快照还没做完时，胶囊就已显示目标配置（乐观标签）', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    final _GatedSnapshotRepository repo = _GatedSnapshotRepository(
      db,
      FakeAnkiRepository(),
    );
    final ProfileViewModel vm = ProfileViewModel(
      repo,
      () async {},
      ProfileDraftCoordinator(),
    );
    final Completer<void> gate = Completer<void>();
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      vm.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await db.close();
    });
    await vm.stream.firstWhere(
      (ProfileUiState s) => !s.isLoading && s.profiles.isNotEmpty,
    );
    final int targetId = await repo.createProfile('Target');
    await vm.reload();
    expect(vm.debugState.displayProfile?.name, 'Default');

    repo.snapshotGate = gate;
    final Future<void> switching = vm.switchProfile(targetId);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(vm.debugState.displayProfile?.name, 'Target');
    gate.complete();
    await switching;
    expect(vm.debugState.displayProfile?.name, 'Target');
  });

  test('应用回调失效 ankiRepositoryProvider 重建视图模型期间，名字不回到默认配置', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    final Completer<void> slowApply = Completer<void>();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        fushiDatabaseProvider.overrideWithValue(db),
        appProvider.overrideWith((Ref ref) => _FakeAppModel(slowApply)),
        platformServicesProvider.overrideWithValue(_FakePlatformServices()),
        ankiRepositoryProvider.overrideWith((Ref ref) => FakeAnkiRepository()),
      ],
    );
    addTearDown(() async {
      if (!slowApply.isCompleted) slowApply.complete();
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await db.close();
    });
    final List<String?> names = <String?>[];
    container.listen<ProfileUiState>(
      profileViewModelProvider,
      (ProfileUiState? _, ProfileUiState next) =>
          names.add(next.displayProfile?.name),
      fireImmediately: true,
    );
    await container
        .read(profileViewModelProvider.notifier)
        .stream
        .firstWhere(
          (ProfileUiState s) => !s.isLoading && s.profiles.isNotEmpty,
        );
    final int targetId = await container
        .read(profileRepositoryProvider)
        .createProfile('Target');
    await container.read(profileViewModelProvider.notifier).reload();

    names.clear();
    final Future<void> switching = container
        .read(profileViewModelProvider.notifier)
        .switchProfile(targetId);
    // 等到应用回调卡在「重载词典」：此时 ankiRepositoryProvider 已失效、视图模型已重建。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final ProfileUiState rebuilt = container.read(profileViewModelProvider);
    expect(
      rebuilt.displayProfile?.name,
      'Target',
      reason: 'states seen: $names',
    );
    expect(
      names.where((String? n) => n == 'Default'),
      isEmpty,
      reason: 'states seen: $names',
    );
    expect(
      names.where((String? n) => n == null),
      isEmpty,
      reason: 'no generic-label flicker either: $names',
    );
    slowApply.complete();
    await switching;
  });
}
