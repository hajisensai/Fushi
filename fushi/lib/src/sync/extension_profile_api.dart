/// 反馈 biLEesNqWb：浏览器扩展里手动切换 Fushi 配置（Profile）的 server 契约。
///
/// 扩展把用户选的配置 id 放在请求头 [kExtensionProfileRequestHeader] 里，随查词 /
/// 制卡 / 查重 / 单词音频等「按配置生效」的请求一起发；server 在交给 handler 之前
/// 经 [ExtensionProfileApi.applySelectedProfile] 让 app 以该配置处理请求，再在响应头里
/// 回报实际生效的配置（[kExtensionProfileActiveHeader]），所选配置已被删除时回
/// [kExtensionProfileMissingHeader]，扩展据此回退到「跟随 Fushi」并提示用户。
///
/// 不带请求头（旧扩展 / 用户选了「跟随 Fushi」）时行为与本契约引入前逐字节一致。
library;

/// 请求头：扩展所选配置的 id（正整数）。
const String kExtensionProfileRequestHeader = 'x-fushi-profile-id';

/// 响应头：处理该请求时 app 实际生效的配置 id。
const String kExtensionProfileActiveHeader = 'x-fushi-profile-active';

/// 响应头：请求所选的配置 id 已不存在（被删除），值为请求里的那个 id。
const String kExtensionProfileMissingHeader = 'x-fushi-profile-missing';

/// 配置列表端点（POST，鉴权同查词）。
const String kExtensionProfilesPath = '/api/extension/profiles';

/// 列表里的一份配置。
class ExtensionProfileSummary {
  const ExtensionProfileSummary({required this.id, required this.name});

  final int id;
  final String name;

  Map<String, Object> toJson() => <String, Object>{'id': id, 'name': name};
}

/// 配置列表 + 当前激活的配置。
class ExtensionProfileList {
  const ExtensionProfileList({
    required this.profiles,
    required this.activeProfileId,
  });

  final List<ExtensionProfileSummary> profiles;
  final int activeProfileId;

  Map<String, Object> toJson() => <String, Object>{
    'profiles': <Map<String, Object>>[
      for (final ExtensionProfileSummary p in profiles) p.toJson(),
    ],
    'activeProfileId': activeProfileId,
  };
}

/// 扩展所选配置的应用结果。
class ExtensionProfileApplyResult {
  const ExtensionProfileApplyResult({
    required this.found,
    required this.activeProfileId,
  });

  /// false = 所选配置已不存在，app 未切换（仍按 [activeProfileId] 处理请求）。
  final bool found;

  /// 处理请求时生效的配置 id。
  final int activeProfileId;
}

/// app 侧实现（[ProfileViewModel] 适配）。
abstract interface class ExtensionProfileApi {
  Future<ExtensionProfileList> listProfiles();

  /// 让 app 以 [profileId] 处理接下来的请求；返回时切换已完成（或判定不存在）。
  Future<ExtensionProfileApplyResult> applySelectedProfile(int profileId);
}

/// 从请求头值解析所选配置 id；缺失 / 非正整数返回 null（= 跟随 Fushi，不干预）。
int? parseExtensionProfileHeader(String? raw) {
  if (raw == null) return null;
  final int? id = int.tryParse(raw.trim());
  if (id == null || id <= 0) return null;
  return id;
}
