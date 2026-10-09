import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

/// BUG-3148：互联「下载配置」与对端「上传配置」入站都是在配置管理视图模型之外、
/// 用另一份 [ProfileRepository] 写进 profiles 表的。视图模型是常驻的，以前只在自己
/// 发起的操作之后重读，列表要等杀后台重进才出现新配置（issue #1997 问题二）。
void main() {
  test('别的 ProfileRepository 导入的新配置会出现在常驻视图模型的列表里', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    final ProfileViewModel viewModel = ProfileViewModel(
      ProfileRepository(db, FakeAnkiRepository()),
      () async {},
      ProfileDraftCoordinator(),
    );
    addTearDown(() async {
      viewModel.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await db.close();
    });
    final ProfileUiState loaded = await viewModel.stream.firstWhere(
      (ProfileUiState s) => !s.isLoading && s.profiles.isNotEmpty,
    );
    final int before = loaded.profiles.length;

    // 与互联下载 / host 入站同形：一份独立构造的仓库，createNew 导入。
    final ProfileRepository other = ProfileRepository(db, FakeAnkiRepository());
    final String json = await other.exportProfileToJson(
      loaded.activeProfileId,
    );
    final int importedId = await other.importProfileFromJson(json);

    final ProfileUiState refreshed = await viewModel.stream
        .firstWhere(
          (ProfileUiState s) =>
              s.profiles.any((ProfileRow p) => p.id == importedId),
        )
        .timeout(const Duration(seconds: 5));
    expect(refreshed.profiles.length, before + 1);
    // 只刷新列表：激活的那份不被入站配置顶掉。
    expect(refreshed.activeProfileId, loaded.activeProfileId);
  });

  // issue #1997（所有者 2026-10-09 拍板）：互联「下载配置」下载完直接切到新配置，
  // 不再让用户自己去「配置管理」里切。
  test('importAndSwitchProfile：新配置追加落地并成为当前配置，走切换的应用回调', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    int applied = 0;
    final ProfileRepository repo = ProfileRepository(db, FakeAnkiRepository());
    final ProfileViewModel viewModel = ProfileViewModel(
      repo,
      () async => applied++,
      ProfileDraftCoordinator(),
    );
    addTearDown(() async {
      viewModel.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await db.close();
    });
    final ProfileUiState loaded = await viewModel.stream.firstWhere(
      (ProfileUiState s) => !s.isLoading && s.profiles.isNotEmpty,
    );
    final int originalId = loaded.activeProfileId;
    final String json = await repo.exportProfileToJson(originalId);

    final int id = await viewModel.importAndSwitchProfile(json);

    expect(id, isNot(originalId));
    expect(await repo.getActiveProfileId(), id);
    expect(viewModel.debugState.activeProfileId, id);
    expect(
      viewModel.debugState.profiles.map((ProfileRow p) => p.id),
      containsAll(<int>[originalId, id]),
      reason: '原配置保留，新配置追加',
    );
    expect(applied, 1, reason: '与手动切换同一条路径：应用后刷新偏好 / 词典 / 阅读器');
  });

  test('互联「下载配置」走 importAndSwitchProfile 并刷新设置页（源码守卫）', () {
    final String src = File(
      'lib/src/sync/sync_settings_schema/interconnect.part.dart',
    ).readAsStringSync();
    final int at = src.indexOf('Future<String?> _download(AppModel appModel)');
    expect(at, greaterThanOrEqualTo(0));
    final String body = src.substring(at, src.indexOf('\n  }\n', at));
    expect(body, contains('importAndSwitchProfile('));
    expect(body, isNot(contains('importProfileFromJson(')),
        reason: '绕过视图模型直接写库就不会切换，也不会刷新界面');
    expect(src, contains('if (!_isUpload) widget.settingsContext.refresh();'));
  });
}
