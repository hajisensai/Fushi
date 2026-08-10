/// BUG-1493：词典下载 / 索引拉取的出站 [Dio] 装配（app 侧）。
///
/// 词典包与 `index.json` 全托管在 `github.com` / `raw.githubusercontent.com` /
/// `huggingface.co`，而 `fushi_dictionary` 一直用裸 `Dio()` 出站——Dio 默认的
/// `IOHttpClientAdapter` 建出来的 `HttpClient` 其 `findProxy` 为 null，**既不读
/// `HTTP_PROXY`/`HTTPS_PROXY`，也不读 Windows 注册表里的系统代理**。同一台机器上
/// 浏览器秒开 GitHub、app 里下 30MB 词典包却是直连，慢到进度条像卡死。
///
/// 代理解析层 [applyAppProxy] 读偏好、跑 `reg query` / `scutil` / `gsettings`，只能住在
/// app 侧；`fushi_dictionary` 是下游包，反向 import 不了它。故由本文件把两边接上：
/// [installDictionaryDioFactory] 在 `AppModel.initialise()` 里调用一次，之后词典链路
/// 的每个出站请求都自动经 `env > GUI 系统代理 > DIRECT` 解析。**没有代理时解析结果就是
/// DIRECT，与接线前逐字等价**，不新增任何设置项。
///
/// `IOHttpClientAdapter` 的构造参数名在 dio 5.x 内部改过（`onHttpClientCreate` →
/// `createHttpClient`），而 app 与 `fushi_dictionary` 各自锁到的 dio 版本并不相同。
/// adapter 只在**这里**（app 侧，跟着 app 的 lock 走）碰，包内不碰——否则会出现
/// 「包内 analyze 绿、app 编译红」。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/utils/net/app_proxy.dart';

/// 把词典链路的 Dio 工厂接到全应用的代理解析层。幂等，可重复调用。
void installDictionaryDioFactory() {
  dictionaryDioFactory = createProxiedDictionaryDio;
}

/// 建一个走应用代理的 [Dio]。超时由 `createDictionaryDio` 统一兜底钉死，这里只管代理。
Future<Dio> createProxiedDictionaryDio() async {
  final HttpClient httpClient = HttpClient()
    ..connectionTimeout = kDictionaryConnectTimeout;
  await applyAppProxy(httpClient);
  final Dio dio = Dio();
  dio.httpClientAdapter = IOHttpClientAdapter(
    onHttpClientCreate: (HttpClient _) => httpClient,
  );
  return dio;
}
