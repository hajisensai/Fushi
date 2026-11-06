/// 反馈 biLEesNqWb：浏览器扩展里选 Fushi 配置（Profile）的 server 契约。
///
/// 选择**只影响扩展**：扩展把用户选的配置 id 放在请求头 [kExtensionProfileRequestHeader]
/// 里，随查词 / 制卡 / 查重 / 单词音频 / 在 Anki 中打开这些「按配置生效」的请求一起发；
/// server 经 [ExtensionProfileApi.resolveScope] 拿到这次请求该用的服务组
/// （[ExtensionRequestServices]，按那个配置的只读设置视图读设置），交给 handler 处理——
/// App 的激活配置与全局偏好一概不动。
///
/// 选哪份配置的优先级：扩展手动选择 > 「浏览器」媒体类型绑定 > 跟随 App。三者都只决定
/// 这次扩展请求读哪份设置，都不切换 App。
///
/// 带请求头时响应头回报实际生效的配置（[kExtensionProfileActiveHeader]）；所选配置已被
/// 删除时再回 [kExtensionProfileMissingHeader]，扩展据此回退到「跟随 Fushi」并提示用户。
/// 不带请求头且没有「浏览器」绑定时，请求走 server 的默认服务组，与本契约引入前逐字节一致。
library;

import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart'
    show RemotePopupDictionaryCss, RemoteThemeColorsProvider;
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';

import 'package:fushi/src/sync/fushi_api_server.dart' show SrsExtensionApi;

/// 请求头：扩展所选配置的 id（正整数）。
const String kExtensionProfileRequestHeader = 'x-fushi-profile-id';

/// 响应头：处理该请求时实际生效的配置 id。
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

/// 配置列表 + App 当前激活的配置（扩展「跟随 Fushi」一项显示它的名字）。
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

/// 一次扩展请求用的服务组：查词 / 制卡服务与随查词响应下发的弹窗设置供给器，全部按同一份
/// 配置读设置——不存在「词典按所选配置、牌组按 App 配置」这种混搭。
class ExtensionRequestServices {
  const ExtensionRequestServices({
    required this.lookup,
    this.mining,
    this.themeColorsProvider,
    this.audioSourcesProvider,
    this.autoReadOnLookupProvider,
    this.dictionaryUnifiedStyleProvider,
    this.popupDictionaryCssProvider,
    this.srsApiProvider,
  });

  final FushiRemoteLookupService lookup;
  final FushiRemoteMiningService? mining;
  final RemoteThemeColorsProvider? themeColorsProvider;
  final List<String> Function()? audioSourcesProvider;
  final bool Function()? autoReadOnLookupProvider;
  final bool Function()? dictionaryUnifiedStyleProvider;
  final RemotePopupDictionaryCss Function()? popupDictionaryCssProvider;

  /// 复习标记（`/api/srs/*`：词状态 / 点标记打开笔记）按这份配置的复习处理；供给器回 null =
  /// 复习模块关着（端点 404）。
  final SrsExtensionApi? Function()? srsApiProvider;
}

/// [ExtensionProfileApi.resolveScope] 的结果。
class ExtensionProfileScope {
  const ExtensionProfileScope({
    required this.effectiveProfileId,
    this.missingRequestedProfileId,
    this.services,
  });

  /// 这次请求实际按哪份配置处理。
  final int effectiveProfileId;

  /// 请求头所选的配置已不存在时为那个 id（请求按 [effectiveProfileId] 回退处理）。
  final int? missingRequestedProfileId;

  /// 按 [effectiveProfileId] 的只读设置视图建的服务组；null = 它就是 App 的激活配置，
  /// 用 server 默认（App 当前生效设置）的那一组。
  final ExtensionRequestServices? services;
}

/// app 侧实现。
abstract interface class ExtensionProfileApi {
  Future<ExtensionProfileList> listProfiles();

  /// [requestedProfileId] 是请求头里扩展所选的配置（null = 未选，跟随浏览器绑定 / App）。
  /// 只解析、不切换 App 的激活配置。
  Future<ExtensionProfileScope> resolveScope(int? requestedProfileId);
}

/// 从请求头值解析所选配置 id；缺失 / 非正整数返回 null（= 未选择）。
int? parseExtensionProfileHeader(String? raw) {
  if (raw == null) return null;
  final int? id = int.tryParse(raw.trim());
  if (id == null || id <= 0) return null;
  return id;
}
