/// 本机 Irodori-TTS-Server 的进程托管：探活判据（`GET /health` + `GET /v1/models`）、
/// pid 文件名；启动 / 等就绪 / 日志尾 / 认领 / 停止都是共用的 [LocalServiceProcess]。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/tts/local/local_service_process.dart';

/// 自起服务的 pid 记录文件名（放在服务源码目录，即启动的工作目录）。
const String kIrodoriPidFileName = '.fushi_irodori.pid';

/// 探活响应读取上限：两份 JSON 都只有几 KB，超过就不是它。
const int _kProbeMaxBytes = 256 * 1024;

/// `/health` 与 `/v1/models` 是不是官方 Irodori-TTS-Server 的（纯函数，测试直接调）。
///
/// `/health` 形如 `{status: ok, model: {id, hf_checkpoint, ...}, runtime: {...},
/// voices: {...}}`；`/v1/models` 的 `data[].owned_by` 是 `irodori-tts`。两样都对上才
/// 算——端口上随便一个答 `/health` 的服务（或别的 OpenAI 兼容服务）不能被当成
/// Irodori 借用。
bool irodoriProbeLooksLikeServer(String healthBody, String modelsBody) {
  try {
    final Object? health = jsonDecode(healthBody);
    if (health is! Map || health['status'] != 'ok') return false;
    final Object? model = health['model'];
    if (model is! Map || !model.containsKey('hf_checkpoint')) return false;
    if (health['runtime'] is! Map || health['voices'] is! Map) return false;
    final Object? models = jsonDecode(modelsBody);
    final Object? data = models is Map ? models['data'] : null;
    return data is List &&
        data.any((Object? m) => m is Map && m['owned_by'] == 'irodori-tts');
  } on FormatException {
    return false;
  }
}

Future<String?> _getText(HttpClient client, Uri uri) async {
  final HttpClientRequest request = await client.getUrl(uri);
  final HttpClientResponse response = await request.close().timeout(
    const Duration(seconds: 5),
  );
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>().catchError((Object _) {});
    return null;
  }
  final BytesBuilder bytes = BytesBuilder(copy: false);
  await for (final List<int> chunk in response.timeout(
    const Duration(seconds: 5),
  )) {
    bytes.add(chunk);
    if (bytes.length > _kProbeMaxBytes) return null;
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}

/// 默认探活。官方服务开着 `IRODORI_PRELOAD` 时先把模型读进来再开端口，所以端口能
/// 答、且答的是 Irodori，就是已就绪。
Future<bool> irodoriDefaultProbe(int port) async {
  // 只打本机回环（本进程拉起的服务）：故意不走 app 代理，登记在
  // outbound_http_discipline_guard_test 的 kBareOutboundRegistry。
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..findProxy = (Uri _) => 'DIRECT';
  try {
    final String? health = await _getText(
      client,
      Uri.parse('http://127.0.0.1:$port/health'),
    );
    if (health == null) return false;
    final String? models = await _getText(
      client,
      Uri.parse('http://127.0.0.1:$port/v1/models'),
    );
    if (models == null) return false;
    return irodoriProbeLooksLikeServer(health, models);
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

class IrodoriLocalServer extends LocalServiceProcess {
  IrodoriLocalServer({
    super.spawn,
    LocalServiceProbe? probe,
    super.pidOwnerCheck,
    super.pidKill,
    // 首次启动要 import torch 并把约 3 GB 的模型读进来；CPU / 慢盘上几分钟很常见。
    super.readyTimeout = const Duration(minutes: 10),
    super.probeInterval,
    super.portReleaseTimeout = const Duration(seconds: 10),
  }) : super(
         probe: probe ?? irodoriDefaultProbe,
         pidFileName: kIrodoriPidFileName,
       );
}
