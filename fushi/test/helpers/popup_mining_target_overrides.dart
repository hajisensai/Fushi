import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi_core/fushi_core.dart' show ProfileRow;

import 'fake_anki_repository.dart';

/// 查词弹窗顶栏的「制卡目标」按钮（`DictionaryPopupMiningTargetButton`，用户建议
/// #fiwDIpFep7）在制卡宿主里随弹窗常驻，build 时 `watch` 了 [ankiViewModelProvider]
/// 与 [profileViewModelProvider]。生产里三个 entry point 都在根 ProviderScope 覆盖了
/// `platformServicesProvider`，这两条链自然可建；宿主页面测试（阅读器 / 首页 / 弹窗
/// 栈行为）只覆盖了 `appProvider`，按钮一挂载就抛
/// 「platformServicesProvider must be overridden」。
///
/// 这里给两条链补上惰性仓库：Anki 设置为空、无配置——按钮照常挂载（不可点，与生产
/// 「装载中」同形），不发任何 I/O。断言制卡目标本身行为的用例见
/// `test/pages/dictionary_popup_mining_target_test.dart`，不用这份。
List<Override> popupMiningTargetTestOverrides() => <Override>[
  ankiRepositoryProvider.overrideWith((Ref ref) => FakeAnkiRepository()),
  profileRepositoryProvider.overrideWith(
    (Ref ref) => _InertProfileRepository(),
  ),
];

class _InertProfileRepository implements ProfileRepository {
  @override
  Future<void> ensureDefaultProfile() async {}

  @override
  Future<List<ProfileRow>> getAllProfiles() async => const <ProfileRow>[];

  @override
  Future<int> getActiveProfileId() async => 0;

  @override
  Future<Map<String, int>> getAllMediaTypeBindings() async =>
      const <String, int>{};

  @override
  Future<Map<String, int>> getAllLanguageBindings() async =>
      const <String, int>{};

  @override
  Stream<void> watchProfilesChanged() => const Stream<void>.empty();

  @override
  Future<void> snapshotCurrentSettings(int profileId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
