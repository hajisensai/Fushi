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

/// 一次安装的在途登记（三家本机引擎的安装器共用）。
///
/// - [tryBegin] 是**同步**占位：安装器在第一个 `await` 之前就拿到它，两次并发的
///   「安装」不会都穿过忙碌判断（步骤状态要等到预检 await 之后才置忙）。
/// - [idle] 在安装函数真正返回（下载 client、解压子进程、文件句柄都已收尾）后完成，
///   「删除」等它再动目录——只发取消信号就删，会和还在写盘的安装抢文件。
class LocalInstallRun {
  Completer<void>? _done;

  /// 有安装在跑（含置忙之前的预检阶段）。
  bool get active => _done != null;

  /// 占位；已有在途安装返回 false（调用方直接放弃这次安装）。
  bool tryBegin() {
    if (_done != null) return false;
    _done = Completer<void>();
    return true;
  }

  /// 安装函数返回时调（放在 `finally` 里）。
  void end() {
    final Completer<void>? done = _done;
    _done = null;
    done?.complete();
  }

  /// 当前安装结束（没有在途安装时立即完成）。
  Future<void> get idle => _done?.future ?? Future<void>.value();
}

/// 删除 app 托管的引擎安装目录失败（文件被占用 / 没权限）。带上路径与系统原因，
/// 由页面提示用户；安装记录保留，用户关掉占用程序后可以再点「删除」。
class LocalInstallRemoveException implements Exception {
  const LocalInstallRemoveException(this.path, this.cause);

  final String path;
  final FileSystemException cause;

  @override
  String toString() =>
      'LocalInstallRemoveException($path: ${cause.message}'
      '${cause.osError == null ? '' : ' ${cause.osError}'})';
}

/// 删整个专属安装目录；失败抛 [LocalInstallRemoveException]（不吞）。
Future<void> deleteLocalInstallDir(String dir) async {
  final Directory directory = Directory(dir);
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } on FileSystemException catch (e) {
    throw LocalInstallRemoveException(dir, e);
  }
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
