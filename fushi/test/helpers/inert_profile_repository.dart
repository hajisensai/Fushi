import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_settings_view.dart';
import 'package:fushi_core/fushi_core.dart' show ProfileMediaKind, ProfileRow;

/// 不发任何 I/O 的配置仓库测试替身：所有方法都显式实现，**没有 `noSuchMethod` 兜底**。
///
/// 以前各测试各写一个 `implements ProfileRepository` + `noSuchMethod => super...`
/// 的桩，只覆盖当时 `ProfileViewModel` 用到的那几个方法。`ProfileRepository` 一加
/// 新方法（如作品级配置引入的 [getFallbackProfileId]），编译器不报错，运行期才在
/// `ProfileViewModel._initialLoad` 里炸 `NoSuchMethodError`，一次拖红几十个宿主
/// 页面测试。这里没有兜底：仓库再加公开方法，这个文件**编译不过**，在一处补齐即可；
/// 需要定制行为的测试 `extends InertProfileRepository` 只覆写自己关心的方法。
///
/// 默认语义：只有一份 id=1 的「Default」配置且处于激活；没有任何绑定、没有
/// 「绑定切换前」的回落配置；写操作全是空操作。
class InertProfileRepository implements ProfileRepository {
  InertProfileRepository({
    List<ProfileRow> profiles = const <ProfileRow>[
      ProfileRow(id: 1, name: 'Default', createdAt: 0, updatedAt: 0),
    ],
    int activeProfileId = 1,
  }) : _profiles = profiles,
       _activeProfileId = activeProfileId;

  final List<ProfileRow> _profiles;
  final int _activeProfileId;

  @override
  Future<List<ProfileRow>> getAllProfiles() async => _profiles;

  @override
  Stream<void> watchProfilesChanged() => const Stream<void>.empty();

  @override
  Future<ProfileRow?> getProfileById(int id) async {
    for (final ProfileRow row in await getAllProfiles()) {
      if (row.id == id) return row;
    }
    return null;
  }

  @override
  Future<int> getActiveProfileId() async => _activeProfileId;

  @override
  Future<void> setActiveProfileId(int id) async {}

  @override
  Future<int?> getFallbackProfileId() async => null;

  @override
  Future<void> setFallbackProfileId(int? id) async {}

  @override
  Future<int> createProfile(String name) async => _activeProfileId;

  @override
  Future<void> renameProfile(int id, String name) async {}

  @override
  Future<void> deleteProfile(int id) async {}

  @override
  Future<void> snapshotCurrentSettings(int profileId) async {}

  @override
  Future<void> applyProfile(int profileId) async {}

  @override
  Future<int> copyProfile(int sourceId, String newName) async =>
      _activeProfileId;

  @override
  Future<Map<String, int>> getAllMediaTypeBindings() async =>
      const <String, int>{};

  @override
  Future<void> setMediaTypeBinding(
    ProfileMediaKind mediaType,
    int profileId,
  ) async {}

  @override
  Future<void> removeMediaTypeBinding(ProfileMediaKind mediaType) async {}

  @override
  Future<Map<String, int>> getAllLanguageBindings() async =>
      const <String, int>{};

  @override
  Future<void> setLanguageBinding(String languageTag, int profileId) async {}

  @override
  Future<void> removeLanguageBinding(String languageTag) async {}

  @override
  Future<int?> getBookProfileId(String bookUid) async => null;

  @override
  Future<void> setBookProfile(String bookUid, int profileId) async {}

  @override
  Future<void> removeBookProfile(String bookUid) async {}

  @override
  Future<void> writeWorkScopedPref(
    int profileId,
    String key,
    String? raw,
  ) async {}

  @override
  Future<int> resolveProfileId({
    required String? bookUid,
    String? languageTag,
    required ProfileMediaKind? mediaType,
  }) async =>
      (await resolveBoundProfileId(
        bookUid: bookUid,
        languageTag: languageTag,
        mediaType: mediaType,
      )) ??
      await getActiveProfileId();

  @override
  Future<int?> resolveBoundProfileId({
    required String? bookUid,
    String? languageTag,
    required ProfileMediaKind? mediaType,
  }) async => null;

  @override
  Future<String> exportProfileToJson(
    int profileId, {
    String? fontsRootDirectory,
  }) => throw UnsupportedError('InertProfileRepository does not export');

  @override
  ProfileExport parseProfileExport(String json) =>
      throw UnsupportedError('InertProfileRepository does not import');

  @override
  Future<int> importProfileFromJson(
    String json, {
    ProfileImportMode mode = ProfileImportMode.createNew,
    int? targetProfileId,
  }) => throw UnsupportedError('InertProfileRepository does not import');

  @override
  Future<ProfileSettingsView?> loadSettingsView(int profileId) async => null;

  @override
  Future<void> ensureDefaultProfile() async {}
}
