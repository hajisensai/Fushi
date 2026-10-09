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
}
