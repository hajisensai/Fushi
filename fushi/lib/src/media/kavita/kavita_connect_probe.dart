/// Kavita 连接探测：用配置里的 API key 鉴权并列一次库，报回库数或失败原因。
///
/// 只返回结论，不落盘。错误文案经 `redactCredentialsInText` 脱敏，绝不带 key。
library;

import 'package:fushi/src/media/discovery/discovery_server_probes.dart'
    show DiscoveryProbeOutcome;
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:fushi_engine/media/metadata/credential_redaction.dart'
    show redactCredentialsInText;

Future<DiscoveryProbeOutcome> connectKavitaServer(
  KavitaServerConfig config,
) async {
  if (!config.hasApiKey) {
    return DiscoveryProbeOutcome(
      ok: false,
      message: t.kavita_connect_failed(reason: t.kavita_api_key_label),
    );
  }
  final KavitaApi api = config.createApi();
  try {
    await api.authenticate();
    final List<KavitaLibrary> libraries = await api.getLibraries();
    return DiscoveryProbeOutcome(
      ok: true,
      message: t.kavita_connect_ok(count: libraries.length),
      count: libraries.length,
    );
  } on KavitaApiException catch (e) {
    return DiscoveryProbeOutcome(
      ok: false,
      message: e.isUnauthorized || e.isForbidden
          ? t.kavita_connect_unauthorized
          : t.kavita_connect_failed(reason: 'HTTP ${e.statusCode}'),
    );
  } on Object catch (e) {
    return DiscoveryProbeOutcome(
      ok: false,
      message: t.kavita_connect_failed(
        reason: redactCredentialsInText(e.toString()),
      ),
    );
  } finally {
    api.close();
  }
}
