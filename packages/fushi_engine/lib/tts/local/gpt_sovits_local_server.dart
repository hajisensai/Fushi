/// 本机 GPT-SoVITS 推理服务（官方整合包的 `api_v2.py`）的进程托管：启动、等就绪、
/// 收日志尾、停止。
///
/// 托管逻辑本身是各本机服务共用的 [LocalServiceProcess]（Irodori-TTS-Server 也用它）；
/// 这里只给 api_v2 专属的探活（openapi 路由表）、pid 文件名与映像判据。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/tts/local/local_service_process.dart';

/// 服务状态。`starting` 期间端口还没在听（加载底模要几十秒）。
typedef GptSovitsServerPhase = LocalServicePhase;

/// 服务启动失败的原因（UI 翻译成文案；日志尾另给）。
typedef GptSovitsServerFailure = LocalServiceFailure;

/// 启动参数：可执行文件、参数、工作目录全由安装布局决定（见
/// `gpt_sovits_local_package.dart`），这里只管跑。
typedef GptSovitsLaunchSpec = LocalServiceLaunchSpec;

/// 探活：api_v2 在模块加载时就把底模读完，之后才 `uvicorn.run`，所以端口能答就是
/// 已就绪。没有专门的健康端点，用 FastAPI 自带的 `GET /openapi.json`（不触发合成），
/// 并且要求路由表里有 api_v2 特有的 `/tts` 与 `/set_gpt_weights`——端口上随便一个
/// FastAPI 服务（或别的程序）不能被当成 GPT-SoVITS 借用。
typedef GptSovitsProbe = LocalServiceProbe;

/// openapi 文档是不是 GPT-SoVITS `api_v2.py` 的（纯函数，测试直接调）。
bool gptSovitsOpenApiLooksLikeApiV2(String body) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    return false;
  }
  final Object? paths = json is Map ? json['paths'] : null;
  return paths is Map &&
      paths.containsKey('/tts') &&
      paths.containsKey('/set_gpt_weights');
}

/// openapi 文档读取上限：api_v2 的只有几 KB，超过就不是它。
const int _kOpenApiMaxBytes = 1024 * 1024;

Future<bool> gptSovitsDefaultProbe(int port) async {
  // 只打本机回环（本进程拉起的服务）：故意不走 app 代理，登记在
  // outbound_http_discipline_guard_test 的 kBareOutboundRegistry。
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..findProxy = (Uri _) => 'DIRECT';
  try {
    final HttpClientRequest request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/openapi.json'),
    );
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 5),
    );
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((Object _) {});
      return false;
    }
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(
      const Duration(seconds: 5),
    )) {
      bytes.add(chunk);
      if (bytes.length > _kOpenApiMaxBytes) return false;
    }
    return gptSovitsOpenApiLooksLikeApiV2(
      utf8.decode(bytes.takeBytes(), allowMalformed: true),
    );
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// [pid] 这个进程是不是以 [executable] 为映像在跑（用来认领上次崩溃留下的、本 app
/// 安装目录里起的服务）。测试注入。
typedef GptSovitsPidOwnerCheck = LocalServicePidOwnerCheck;

/// 结束一个按 pid 认领的进程（测试注入）。
typedef GptSovitsPidKill = LocalServicePidKill;

Future<bool> gptSovitsDefaultPidOwnerCheck(int pid, String executable) async {
  String? path;
  try {
    if (Platform.isWindows) {
      final ProcessResult r = await Process.run('powershell.exe', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '(Get-Process -Id $pid -ErrorAction SilentlyContinue).Path',
      ]).timeout(const Duration(seconds: 10));
      if (r.exitCode == 0) path = '${r.stdout}'.trim();
    } else {
      path = Link('/proc/$pid/exe').resolveSymbolicLinksSync();
    }
  } on Object {
    return false;
  }
  if (path == null || path.isEmpty) return false;
  String norm(String v) {
    final String n = v.replaceAll(r'\', '/');
    return Platform.isWindows ? n.toLowerCase() : n;
  }

  return norm(path) == norm(File(executable).absolute.path);
}

/// 自起服务的 pid 记录文件名（放在整合包根，即启动的工作目录）。
const String kGptSovitsPidFileName = '.fushi_gpt_sovits.pid';

/// 起子进程的入口（测试注入假进程）。
typedef GptSovitsSpawn = LocalServiceSpawn;

class GptSovitsLocalServer extends LocalServiceProcess {
  GptSovitsLocalServer({
    GptSovitsSpawn? spawn,
    GptSovitsProbe? probe,
    GptSovitsPidOwnerCheck? pidOwnerCheck,
    GptSovitsPidKill? pidKill,
    super.readyTimeout,
    super.probeInterval,
  }) : super(
         probe: probe ?? gptSovitsDefaultProbe,
         pidFileName: kGptSovitsPidFileName,
         spawn: spawn,
         pidOwnerCheck: pidOwnerCheck ?? gptSovitsDefaultPidOwnerCheck,
         pidKill: pidKill,
       );
}
