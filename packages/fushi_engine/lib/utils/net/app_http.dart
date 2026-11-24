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

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fushi_core/fushi_core.dart' show DatabaseWorkToken;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:fushi_engine/utils/net/app_proxy.dart';

/// 公网出站的默认**连接建立**超时（DNS + TCP + 代理隧道 + TLS 握手）。
///
/// 与 `sync_http.dart` / `download_timeouts.dart` 同范式：连不上要快速失败，
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
///
/// [configure] 在包装前改装底层 [HttpClient]（例如联网搜索抓页换 `connectionFactory`
/// 按已校验地址建连）：改装仍从装好代理与连接超时的 client 出发，调用方不必另起裸
/// `IOClient(`。
///
/// 返回的 client 在后台写库工作里（[DatabaseWorkToken.current] 非空）发出的请求自动
/// 绑上那份工作的取消信号：库开始关（备份恢复、合并导入、数据根迁移、退出）时请求被
/// 中止（抛 `http.RequestAbortedException`），刮削 / 入库 / 封面下载不再拖着关库等一次
/// 慢网络往返（BUG-5387 审查遗留）。不在后台工作里的请求逐字不变。
http.Client createAppHttpIoClient({
  Duration? connectionTimeout = kAppHttpConnectionTimeout,
  void Function(HttpClient client)? configure,
}) => DatabaseWorkAwareIoClient(
  createAppHttpClient(connectionTimeout: connectionTimeout)
    .._configureWith(configure),
);

/// [createAppHttpIoClient] 的实现：在后台写库工作里发的请求换成可中止请求。
///
/// 中止触发器**每个请求一份**，经 [DatabaseWorkToken.onCancelled] 挂到工作上，请求结束
/// （响应体读完 / 出错 / 调用方放弃读取 / 发送本身失败）就注销。不能直接拿工作级的
/// [DatabaseWorkToken.cancelled] 当触发器：`IOClient` 会在触发器上挂两个捕获整个
/// `HttpClientRequest` / 响应流的回调，触发器不完成就永不释放——整库刮削、IPTV 台标这类
/// 一份工作发几千个请求的长工作，会把每个请求的对象一直攒到工作结束。
/// 调用方已自带中止触发器的请求原样发出。
class DatabaseWorkAwareIoClient extends IOClient {
  DatabaseWorkAwareIoClient([super.inner]);

  @override
  Future<IOStreamedResponse> send(http.BaseRequest request) async {
    final DatabaseWorkToken? work = DatabaseWorkToken.current;
    if (work == null || _hasOwnAbortTrigger(request)) {
      return super.send(request);
    }
    final Completer<void> trigger = Completer<void>();
    final void Function() unlink = work.onCancelled(() {
      if (!trigger.isCompleted) trigger.complete();
    });
    final IOStreamedResponse response;
    try {
      response = await super.send(abortableWith(request, trigger.future));
    } catch (_) {
      unlink();
      rethrow;
    }
    return _WorkBoundStreamedResponse(response, unlink);
  }
}

bool _hasOwnAbortTrigger(http.BaseRequest request) =>
    request is http.Abortable && request.abortTrigger != null;

/// 把 [request] 换成以 [abortTrigger] 为中止触发器的 [http.AbortableStreamedRequest]
/// （方法、地址、头、正文、重定向 / 长连接设置原样搬过去）。
http.BaseRequest abortableWith(
  http.BaseRequest request,
  Future<void> abortTrigger,
) {
  // 先 finalize：有的请求（multipart）在 finalize 里才写定 content-type / 长度。
  final http.ByteStream body = request.finalize();
  final http.AbortableStreamedRequest out = http.AbortableStreamedRequest(
    request.method,
    request.url,
    abortTrigger: abortTrigger,
  );
  out.headers.addAll(request.headers);
  out.contentLength = request.contentLength;
  out.followRedirects = request.followRedirects;
  out.maxRedirects = request.maxRedirects;
  out.persistentConnection = request.persistentConnection;
  body.listen(
    out.sink.add,
    onError: out.sink.addError,
    onDone: out.sink.close,
    cancelOnError: true,
  );
  return out;
}

/// 响应体流结束（读完 / 出错 / 调用方取消订阅）时调 `settled` 的响应包装；其余字段与
/// [detachSocket] 原样转给内层响应。
class _WorkBoundStreamedResponse extends IOStreamedResponse
    implements http.BaseResponseWithUrl {
  _WorkBoundStreamedResponse(this._original, void Function() settled)
    : url = _original is http.BaseResponseWithUrl
          ? (_original as http.BaseResponseWithUrl).url
          : _original.request?.url ?? Uri(),
      super(
        _onSettled(_original.stream, settled),
        _original.statusCode,
        contentLength: _original.contentLength,
        request: _original.request,
        headers: _original.headers,
        isRedirect: _original.isRedirect,
        persistentConnection: _original.persistentConnection,
        reasonPhrase: _original.reasonPhrase,
      );

  final IOStreamedResponse _original;

  @override
  final Uri url;

  @override
  Future<Socket> detachSocket() => _original.detachSocket();
}

Stream<List<int>> _onSettled(
  Stream<List<int>> source,
  void Function() settled,
) {
  StreamSubscription<List<int>>? subscription;
  late final StreamController<List<int>> controller;
  controller = StreamController<List<int>>(
    sync: true,
    onListen: () {
      subscription = source.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          subscription = null;
          settled();
          unawaited(controller.close());
        },
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () {
      settled();
      return subscription?.cancel();
    },
  );
  return controller.stream;
}

extension on HttpClient {
  void _configureWith(void Function(HttpClient client)? configure) =>
      configure?.call(this);
}

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
  final HttpClient httpClient = createAppHttpClient(
    connectionTimeout: connectionTimeout,
  );
  dio.httpClientAdapter = IOHttpClientAdapter(
    onHttpClientCreate: (HttpClient _) => httpClient,
  );
  return dio;
}
