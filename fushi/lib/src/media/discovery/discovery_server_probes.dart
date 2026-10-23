/// 自配发现源（OPDS / AList / Audiobookshelf）的「连接测试 / 登录」执行体。
///
/// 从三个设置区的 State 里搬出来：设置页按钮与控制通道（`fushi_cli config run`）
/// 调同一份实现，不各写一遍请求与结论文案。
///
/// 只把**协议层的稳定失败**（[ExternalProviderFailure]，文案已脱敏）折成
/// `ok: false` 结论；其余异常原样抛给调用方——设置页按自己的兜底文案展示，控制
/// 通道把它报成错误，而不是吞成一句空原因。
library;

import 'package:fushi/src/media/discovery/alist_site_config.dart';
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/discovery/sources/alist_discovery_source.dart';
import 'package:fushi/src/media/discovery/sources/audiobookshelf_discovery_source.dart';
import 'package:fushi/src/media/discovery/sources/opds_discovery_source.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/external_provider.dart';

/// 一次连接测试的结论。
class DiscoveryProbeOutcome {
  const DiscoveryProbeOutcome({
    required this.ok,
    required this.message,
    this.count,
    this.resolvedUrl,
  });

  final bool ok;

  /// 给用户看的结论文案（已本地化、已脱敏）。
  final String message;

  /// 成功时根目录的条目数 / 有声书库数。
  final int? count;

  /// OPDS：用户填的地址不是目录、按已知端点探测打通的那条（BUG-3526）；
  /// 原地址本身可用时为 null。调用方负责写回配置。
  ///
  /// Kavita 这类路径里带 key 的端点，这里是占位形态（`kOpdsApiKeyPlaceholder`），
  /// 不含 key 明文——写回配置、控制通道列表都只见占位段，请求时才展开。
  final Uri? resolvedUrl;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    'message': message,
    if (count != null) 'count': count,
  };
}

/// OPDS 连接自检：真发一次根目录请求，报回条目数或稳定的失败原因。
Future<DiscoveryProbeOutcome> probeOpdsServer(OpdsServerConfig config) async {
  // 必须走统一出站装配点（代理 / 超时；outbound_http_discipline 守卫）。
  final OpdsDiscoverySource source = OpdsDiscoverySource(
    config: config,
    client: createAppHttpIoClient(),
  );
  try {
    final ProviderBatchResult<DiscoveryResultPage> page = await source.browse(
      const DiscoveryRequest(kind: DiscoveryMediaKind.novel),
    );
    final int count = page.items.isEmpty ? 0 : page.items.single.entries.length;
    final Uri? resolved = source.resolvedCatalogUrl;
    final bool moved =
        resolved != null && resolved.toString() != config.catalogUrl.toString();
    return DiscoveryProbeOutcome(
      ok: true,
      message: moved
          ? t.discovery_opds_test_ok_resolved(count: count)
          : t.discovery_opds_test_ok(count: count),
      count: count,
      resolvedUrl: moved ? resolved : null,
    );
  } on ExternalProviderFailure catch (failure) {
    return DiscoveryProbeOutcome(
      ok: false,
      message: opdsProbeFailureMessage(failure),
    );
  } finally {
    source.close();
  }
}

/// OPDS 连接测试失败的给人看的结论。
///
/// 两种最常见的配错单独给本地化说明，其余沿用脱敏后的协议层原因：
/// - 地址是网页（Komga 根地址回 200 HTML，BUG-3526）；
/// - 凭据被拒（Komga 的账号是登录邮箱、API key 走单独字段，BUG-3521）。
String opdsProbeFailureMessage(ExternalProviderFailure failure) {
  if (failure is OpdsWebPageFailure) return t.discovery_opds_test_web_page;
  if (failure.kind == ExternalProviderFailureKind.unauthorized ||
      failure.kind == ExternalProviderFailureKind.forbidden) {
    return t.discovery_opds_test_unauthorized;
  }
  return t.discovery_opds_test_failed(reason: failure.message);
}

/// AList 连接自检：真列一次根目录（游客 / 账号同一条 `fs/list`）。
Future<DiscoveryProbeOutcome> probeAListSite(AListSiteConfig config) async {
  final AListDiscoverySource source = AListDiscoverySource.fromConfig(
    config,
    client: createAppHttpIoClient(),
  );
  try {
    final ProviderBatchResult<DiscoveryResultPage> page = await source.browse(
      DiscoveryRequest(kind: config.kinds.first),
    );
    final int count = page.items.isEmpty ? 0 : page.items.single.entries.length;
    return DiscoveryProbeOutcome(
      ok: true,
      message: t.discovery_alist_test_ok(count: count),
      count: count,
    );
  } on ExternalProviderFailure catch (failure) {
    return DiscoveryProbeOutcome(
      ok: false,
      message: t.discovery_alist_test_failed(reason: failure.message),
    );
  } finally {
    source.close();
  }
}

/// Audiobookshelf 登录 / 测试的结论：成功时带回协议层当前令牌与用户名。
class AudiobookshelfConnectOutcome extends DiscoveryProbeOutcome {
  const AudiobookshelfConnectOutcome({
    required super.ok,
    required super.message,
    super.count,
    this.tokens,
    required this.username,
  });

  /// 探测结束时协议层手上的令牌（登录换来的 / 刷新轮换后的）；失败时 null。
  final AudiobookshelfTokens? tokens;
  final String username;
}

/// 未登录：用 [apiKey] 或 [username]/[password] 换令牌；已登录：用现有令牌列一次
/// 库（顺带验证令牌还活着）。两条路径都以「列出有声书库」收尾。
///
/// 只返回结论，不落盘：令牌写回由调用方决定（设置页走草稿，控制通道直接写偏好）。
Future<AudiobookshelfConnectOutcome> connectAudiobookshelfServer(
  AudiobookshelfServerConfig config, {
  String username = '',
  String password = '',
  String apiKey = '',
}) async {
  final AudiobookshelfTokens? currentTokens = config.tokens;
  final bool useApiKey = currentTokens == null && apiKey.trim().isNotEmpty;
  final AudiobookshelfApi api = AudiobookshelfApi(
    serverUrl: config.serverUrl,
    providerId: audiobookshelfSourceIdFor(config.id),
    tokens: useApiKey
        ? AudiobookshelfTokens(accessToken: apiKey.trim())
        : currentTokens,
    client: createAppHttpIoClient(),
  );
  String resolvedUser = currentTokens == null ? username : config.username;
  try {
    if (currentTokens == null) {
      // 先问一句免鉴权的 /status：地址填错（对面不是 ABS）和「只开了 OpenID、没有
      // 账号密码登录」这两种情况，用一句能照着改的话报出来，而不是登录失败的 401。
      // 只对**明确**的信号下结论；超时 / 404 / 网络错误交给后面的登录去报。
      final ({AudiobookshelfServerStatus? status, bool notAbs}) probe =
          await _probeStatus(api);
      final AudiobookshelfServerStatus? status = probe.status;
      if (probe.notAbs) {
        return AudiobookshelfConnectOutcome(
          ok: false,
          message: t.discovery_audiobookshelf_not_abs,
          username: resolvedUser,
        );
      }
      if (status != null && !useApiKey && !status.supportsPasswordLogin) {
        return AudiobookshelfConnectOutcome(
          ok: false,
          message: t.discovery_audiobookshelf_password_login_unavailable,
          username: resolvedUser,
        );
      }
    }
    if (useApiKey) {
      resolvedUser = (await api.me()).username;
    } else if (currentTokens == null) {
      resolvedUser = (await api.login(username.trim(), password)).user.username;
    }
    final int books = (await api.libraries())
        .where((AudiobookshelfLibrary library) => library.isBookLibrary)
        .length;
    return AudiobookshelfConnectOutcome(
      ok: true,
      message: t.discovery_audiobookshelf_session_sign_in_ok(count: books),
      count: books,
      tokens: api.tokens,
      username: resolvedUser,
    );
  } on ExternalProviderFailure catch (failure) {
    return AudiobookshelfConnectOutcome(
      ok: false,
      message: t.discovery_audiobookshelf_session_sign_in_failed(
        reason: failure.message,
      ),
      username: resolvedUser,
    );
  } finally {
    api.close();
  }
}

/// `/status` 探测：[status] 非空 = 确认是 ABS；[notAbs] = 对面明确不是 ABS（响应
/// 不是 ABS 的状态载荷）。两者都假 = 没结论（超时 / 404 / 网络错误）。
Future<({AudiobookshelfServerStatus? status, bool notAbs})> _probeStatus(
  AudiobookshelfApi api,
) async {
  try {
    return (status: await api.status(), notAbs: false);
  } on ExternalProviderFailure catch (failure) {
    return (
      status: null,
      notAbs: failure.kind == ExternalProviderFailureKind.invalidResponse,
    );
  }
}
