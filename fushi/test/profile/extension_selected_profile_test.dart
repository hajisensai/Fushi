import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/extension_profile_adapter.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/sync/extension_profile_api.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

/// 反馈 biLEesNqWb：浏览器扩展里手动选配置。app 是单激活配置模型（查词 / 制卡读活设置），
/// 扩展所选配置 = 处理请求前把激活配置切过去，语义等同「浏览器」绑定命中：
/// - 记下回退点，之后打开无绑定条目回到用户自己选的配置；
/// - 所选配置已删 → found=false、不切换；
/// - 改名后列表回新名字（扩展据此刷新显示）。
void main() {
  late FushiDatabase db;
  late ProfileRepository repo;
  late ProfileViewModel vm;
  late ExtensionProfileApi api;
  late int defaultId;
  late int englishId;
  late int appliedCount;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = ProfileRepository(db, FakeAnkiRepository());
    appliedCount = 0;
    vm = ProfileViewModel(
      repo,
      () async => appliedCount++,
      ProfileDraftCoordinator(),
    );
    final ProfileUiState loaded = await vm.stream.firstWhere(
      (ProfileUiState s) => !s.isLoading && s.profiles.isNotEmpty,
    );
    defaultId = loaded.activeProfileId;
    englishId = await repo.createProfile('英语');
    api = ProfileViewModelExtensionProfileApi(() => vm);
  });

  tearDown(() async {
    vm.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await db.close();
  });

  test('列出全部配置与当前激活配置', () async {
    final ExtensionProfileList list = await api.listProfiles();
    expect(
      list.profiles.map((ExtensionProfileSummary p) => p.id),
      containsAll(<int>[defaultId, englishId]),
    );
    expect(list.activeProfileId, defaultId);
  });

  test('所选配置在返回前已生效，并记下回退点', () async {
    final ExtensionProfileApplyResult r = await api.applySelectedProfile(
      englishId,
    );
    expect(r.found, isTrue);
    expect(r.activeProfileId, englishId);
    expect(await repo.getActiveProfileId(), englishId);
    expect(vm.debugState.activeProfileId, englishId);
    expect(appliedCount, 1, reason: '切换走完整的应用链（刷新偏好 / 词典缓存）');
    expect(await repo.getFallbackProfileId(), defaultId);

    // 之后打开无绑定的书：回到用户自己选的配置（与「浏览器」绑定同一套回退点）。
    await vm.autoApplyBinding(
      bookUid: 'free-book',
      mediaType: ProfileMediaKind.epub,
      restoreFallback: true,
    );
    expect(await repo.getActiveProfileId(), defaultId);
  });

  test('所选配置已生效时不重复切换', () async {
    await api.applySelectedProfile(englishId);
    await api.applySelectedProfile(englishId);
    await api.applySelectedProfile(englishId);
    expect(appliedCount, 1);
  });

  test('所选配置已被删除：不切换，found=false，回报当前激活配置', () async {
    final int gone = await repo.createProfile('临时');
    await vm.reload();
    await vm.deleteProfile(gone);
    final ExtensionProfileApplyResult r = await api.applySelectedProfile(gone);
    expect(r.found, isFalse);
    expect(r.activeProfileId, defaultId);
    expect(await repo.getActiveProfileId(), defaultId);
    expect(appliedCount, 0);
  });

  test('改名后列表回新名字', () async {
    await vm.renameProfile(englishId, 'English');
    final ExtensionProfileList list = await api.listProfiles();
    expect(
      list.profiles
          .firstWhere((ExtensionProfileSummary p) => p.id == englishId)
          .name,
      'English',
    );
  });

  test('并发请求串行应用，最终停在所选配置', () async {
    await Future.wait(<Future<ExtensionProfileApplyResult>>[
      for (int i = 0; i < 4; i++) api.applySelectedProfile(englishId),
    ]);
    expect(await repo.getActiveProfileId(), englishId);
    expect(appliedCount, 1);
    expect(await repo.getFallbackProfileId(), defaultId);
  });
}
