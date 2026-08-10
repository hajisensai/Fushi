/// BUG-1498：**全应用公网出站的单一装配点**。
///
/// ## 为什么需要它
///
/// `app_proxy.dart` 早就存在，但它的文件头曾经白纸黑字列着一份「不经本层」的名单：刮削、
/// 弹幕、字体、shader、OCR 模型、漫画在线源、日志上传、youtube……普查（见
/// `docs/bugs/BUG-1498-*.md`）实测出 40+ 条这样的裸出站。
///
/// 根因不是「谁忘了接」，是**形状接不上**：这些出站点的统一形态是构造函数初始化列表里的
/// ```dart
/// SomeClient({http.Client? client}) : _client = client ?? http.Client();
/// ```
/// 初始化列表里不能 `await`，而 `applyAppProxy` 是异步的（要跑 `reg query` / `scutil` /
/// `gsettings`）。于是每个新写出站的人面对的选择是「改成异步工厂 + 改所有调用点」还是
/// 「就用裸 client」——**结构决定了他们都会选后者**。
///
/// 所以本文件提供的三个工厂全是**同步**的：把异步的那一半（平台 GUI 系统代理探测）搬到
/// `AppModel.initialise()` 里的 `primeAppProxy()` 做一次，此后装配纯查表。裸 `http.Client()`
/// 换成 `createAppHttpIoClient()` 是逐点一行的机械替换，没有传染性改造。
///
/// ## 安全性：接进来不会打断本机 / 局域网功能
///
/// 出口选择统一走 `resolveAppProxyDirective`，它**第一件事**就是 `isDirectProxyTarget`
/// 闸门：`127.0.0.1` / `localhost` / `*.local` / `10.x` / `172.16-31.x` / `192.168.x` /
/// `169.254.x` / `::1` / ULA / link-local 一律 `DIRECT`。所以即便某条链路的目标是用户自配
/// 的局域网地址（自建 WebDAV、局域网另一台机上的 AnkiConnect），经本层也不会被塞进代理。
///
/// ## 无代理时逐字等价
///
/// 没有任何代理配置（用户没手填、env 没给、GUI 系统代理关着）时解析结果就是 `DIRECT`，
/// 与替换前的裸 client 行为逐字一致。本次改动**不新增任何用户可见配置**。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:fushi/src/utils/net/app_proxy.dart';

/// 公网出站的默认**连接建立**超时（DNS + TCP + 代理隧道 + TLS 握手）。
///
/// 与 `sync_http.dart` / `download_network_proxy.dart` 同范式：连不上要快速失败，
/// 而不是靠上层的整体超时空转。响应体传输**不设**默认时限——本层同时服务「一次 API 往返」
/// 与「几百 MB 模型下载」，一刀切会掐断后者。需要 stall 超时的链路自己在上层设。
const Duration kAppHttpConnectionTimeout = Duration(seconds: 20);

/// 建一个走应用代理出口的 [HttpClient]。同步，可直接用在构造函数初始化列表里。
///
/// [connectionTimeout] 传 null 表示不设（沿用 Dart 默认的「不超时」），用于确实需要
/// 长握手的场景；省略则用 [kAppHttpConnectionTimeout]。
HttpClient createAppHttpClient({
  Duration? connectionTimeout = kAppHttpConnectionTimeout,
}) {
  final HttpClient client = HttpClient();
  if (connectionTimeout != null) client.connectionTimeout = connectionTimeout;
  applyAppProxySync(client);
  return client;
}

/// [createAppHttpClient] 的 `package:http` 包装：裸 `http.Client()` 的逐点替换目标。
http.Client createAppHttpIoClient({
  Duration? connectionTimeout = kAppHttpConnectionTimeout,
}) =>
    IOClient(createAppHttpClient(connectionTimeout: connectionTimeout));

/// 建一个走应用代理出口的 [Dio]：裸 `Dio()` / `Dio(BaseOptions(...))` 的替换目标。
///
/// `IOHttpClientAdapter` 的构造参数名在 dio 5.x 内部改过（`onHttpClientCreate` →
/// `createHttpClient`），所以 adapter 只在 app 侧（跟着 app 的 lock 走）碰；下游包要接代理
/// 走各自的工厂钩子（范式见 `dictionary_dio.dart`），不要在包内 import dio/io.dart。
Dio createAppDio({
  BaseOptions? options,
  Duration? connectionTimeout = kAppHttpConnectionTimeout,
}) {
  final Dio dio = options == null ? Dio() : Dio(options);
  final HttpClient httpClient =
      createAppHttpClient(connectionTimeout: connectionTimeout);
  dio.httpClientAdapter = IOHttpClientAdapter(
    onHttpClientCreate: (HttpClient _) => httpClient,
  );
  return dio;
}
