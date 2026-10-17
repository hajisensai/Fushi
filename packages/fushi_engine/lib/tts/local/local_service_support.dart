/// 本机一键部署的推理服务（GPT-SoVITS 整合包、Irodori-TTS-Server）共用的小件：
/// 外部命令、显卡探测、下载用的 GET、托管地址判据，以及「朗读前先把本机服务拉起来」
/// 的 provider 包装。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';

/// 跑一个外部命令拿退出码与合并输出（测试注入）。
typedef LocalCommandRunner =
    Future<({int exitCode, String output})> Function(
      String executable,
      List<String> arguments,
    );

Future<({int exitCode, String output})> runLocalCommand(
  String executable,
  List<String> arguments,
) async {
  try {
    final ProcessResult r = await Process.run(
      executable,
      arguments,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    );
    return (exitCode: r.exitCode, output: '${r.stdout}\n${r.stderr}');
  } on ProcessException catch (e) {
    return (exitCode: -1, output: e.message);
  }
}

/// 本机显卡名（`nvidia-smi`）；没有 N 卡 / 没驱动返回 null。
Future<String?> detectNvidiaGpuName({LocalCommandRunner? run}) async {
  final ({int exitCode, String output}) r = await (run ?? runLocalCommand)(
    'nvidia-smi',
    const <String>['--query-gpu=name', '--format=csv,noheader'],
  );
  if (r.exitCode != 0) return null;
  final String first = const LineSplitter()
      .convert(r.output)
      .map((String l) => l.trim())
      .firstWhere((String l) => l.isNotEmpty, orElse: () => '');
  return first.isEmpty ? null : first;
}

/// 用 [client]（app 代理装配好的）发一次 GET，跟随重定向（HF 会 302 到 CDN），
/// 包成 [ResumableDownloader] 认的响应。下载与清单共用。
Future<ResumableDownloadResponse> openLocalServiceGet(
  HttpClient client,
  Uri uri,
  Map<String, String> headers,
) async {
  final HttpClientRequest request = await client.getUrl(uri);
  request.followRedirects = true;
  request.maxRedirects = 8;
  headers.forEach(request.headers.set);
  final HttpClientResponse response = await request.close();
  final Map<String, String> responseHeaders = <String, String>{};
  response.headers.forEach(
    (String name, List<String> values) =>
        responseHeaders[name] = values.join(', '),
  );
  return ResumableDownloadResponse(
    statusCode: response.statusCode,
    headers: responseHeaders,
    stream: response,
  );
}

/// [endpoint] 是不是本机托管服务的地址（回环主机 + 托管端口）。
bool localServiceEndpointIsManaged(String endpoint, int port) {
  final Uri? uri = Uri.tryParse(endpoint.trim());
  if (uri == null || !uri.hasPort || uri.port != port) return false;
  final String host = uri.host.toLowerCase();
  return host == 'localhost' || host == '::1' || host.startsWith('127.');
}

/// 合成 / 列声音前先跑 [ensure]（把本机托管的服务拉起来并等就绪），再交给
/// [inner]。拉不起来不在这里报：照常发请求，连不上就是「无法连接语音服务」。
class AutoStartTtsProvider extends TtsProvider {
  AutoStartTtsProvider(this._inner, this._ensure);

  final TtsProvider _inner;
  final Future<void> Function() _ensure;

  /// 被包的 provider（声音管理等专属接口要拿原对象）。
  TtsProvider get inner => _inner;

  @override
  TtsCapabilities get capabilities => _inner.capabilities;

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    // 等服务就绪最长要几分钟，期间取消（翻页 / 停止朗读）必须立刻生效，不能干等。
    await _awaitOrCancel(_ensure(), cancel);
    cancel.throwIfCancelled();
    return _inner.synthesize(text, outputPath: outputPath, cancel: cancel);
  }

  @override
  Future<List<TtsVoice>> listVoices({TtsCancelToken? cancel}) async {
    if (cancel == null) {
      await _ensure();
    } else {
      await _awaitOrCancel(_ensure(), cancel);
      cancel.throwIfCancelled();
    }
    return _inner.listVoices(cancel: cancel);
  }

  /// 等 [work]，但 [cancel] 一触发就返回（work 继续在后台跑完——服务照样起来，
  /// 下一句直接用）。
  static Future<void> _awaitOrCancel(
    Future<void> work,
    TtsCancelToken cancel,
  ) async {
    final Completer<void> cancelled = Completer<void>();
    final void Function() unregister = cancel.onCancel(() {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    try {
      await Future.any(<Future<void>>[
        work.catchError((Object _) {}),
        cancelled.future,
      ]);
    } finally {
      unregister();
    }
  }

  @override
  Future<void> dispose() => _inner.dispose();
}
