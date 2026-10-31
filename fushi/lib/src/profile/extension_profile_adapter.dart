import 'package:fushi_core/fushi_core.dart' show ProfileRow;

import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/sync/extension_profile_api.dart';

/// 反馈 biLEesNqWb：[ExtensionProfileApi] 的 app 实现，委托给 [ProfileViewModel]。
///
/// AppModel 不在 Riverpod 图里，由 main.dart 用「读 notifier」的闭包装配（与
/// `browserLookupProfileApplier` 同一模式），每次调用现读，不持有过期实例。
class ProfileViewModelExtensionProfileApi implements ExtensionProfileApi {
  const ProfileViewModelExtensionProfileApi(this._viewModel);

  final ProfileViewModel Function() _viewModel;

  @override
  Future<ExtensionProfileList> listProfiles() async {
    final ({List<ProfileRow> profiles, int activeProfileId}) snapshot =
        await _viewModel().profilesForExtension();
    return ExtensionProfileList(
      profiles: <ExtensionProfileSummary>[
        for (final ProfileRow p in snapshot.profiles)
          ExtensionProfileSummary(id: p.id, name: p.name),
      ],
      activeProfileId: snapshot.activeProfileId,
    );
  }

  @override
  Future<ExtensionProfileApplyResult> applySelectedProfile(
    int profileId,
  ) async {
    final ({bool found, int activeProfileId}) result = await _viewModel()
        .applyExtensionSelectedProfile(profileId);
    return ExtensionProfileApplyResult(
      found: result.found,
      activeProfileId: result.activeProfileId,
    );
  }
}
