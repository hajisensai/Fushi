import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi_core/fushi_core.dart' show ProfileRow;

import 'fake_anki_repository.dart';

/// 查词浮层宿主测试的制卡目标依赖：空 Anki 设置 + 只有一份默认配置。
///
/// 查词弹窗顶栏的「制卡目标」按钮（`DictionaryPopupMiningTargetButton`，用户建议
/// #fiwDIpFep7）在制卡宿主（`showMiningTargetSwitch`）里随弹窗常驻，build 时
/// `watch` 了 [ankiViewModelProvider] 与 [profileViewModelProvider]。生产里这两条
/// 仓库链经 `platformServicesProvider`（三个 entry point 都在根 ProviderScope 覆盖）
/// 与 `AppModel.database`（`initialise()` 后才有）落地；宿主页面测试（阅读器 / 首页 /
/// 弹窗栈行为）只覆盖了 `appProvider`、不初始化 AppModel，按钮一挂载就抛
/// 「platformServicesProvider must be overridden」。
///
/// 这里在仓库这一层换成惰性假货，切断那两条依赖：按钮照常挂载，不发任何 I/O。
/// 断言制卡目标菜单本身行为的用例用
/// `test/pages/dictionary_popup_mining_target_test.dart` 的完整接线，不用这份。
List<Override> popupMiningTargetTestOverrides() => <Override>[
  ankiRepositoryProvider.overrideWith((Ref ref) => FakeAnkiRepository()),
  profileRepositoryProvider.overrideWith((Ref ref) {
    // 与生产同形：配置仓库跟着 Anki 仓库重建。
    ref.watch(ankiRepositoryProvider);
    return _InertProfileRepository();
  }),
];

class _InertProfileRepository implements ProfileRepository {
  static const int _defaultProfileId = 1;

  @override
  Future<void> ensureDefaultProfile() async {}

  @override
  Future<List<ProfileRow>> getAllProfiles() async => const <ProfileRow>[
    ProfileRow(
      id: _defaultProfileId,
      name: 'Default',
      createdAt: 0,
      updatedAt: 0,
    ),
  ];

  @override
  Future<int> getActiveProfileId() async => _defaultProfileId;

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
