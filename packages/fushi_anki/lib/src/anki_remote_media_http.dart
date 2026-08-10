/// BUG-1498：制卡时抓**远程音频/媒体**所用 [HttpClient] 的进程级装配钩子。
///
/// `AnkiAudioRefKind.remoteUrl` 那条分支下载的是任意公网 URL（Forvo、JPod、词典自带的
/// 音频源、用户在设置里填的发音源……），而两个实现（AnkiConnect 与 AnkiDroid）都用裸
/// `HttpClient()` —— Dart 的 `HttpClient` 默认 `findProxy` 为 null，**连 `HTTPS_PROXY`
/// 环境变量都不读**，更不读 Windows 注册表里的系统代理。同一台机器上浏览器能打开的音频源，
/// app 里直连可能根本下不下来（卡片就此少一个音频，还是静默的）。
///
/// 代理解析层住在 app 侧（要读偏好、跑 `reg query` / `scutil` / `gsettings`），本包是下游
/// 包反向 import 不了它，故用与 `dictionaryDioFactory`（BUG-1493）同一范式的钩子：app 在
/// `AppModel.initialise()` 里赋值一次，之后本包每次抓远程媒体都自动经应用代理出口。
///
/// **⚠️ 边界：这个钩子只作用于「抓远程媒体」，绝不作用于 [AnkiConnectService]。**
/// AnkiConnect 的目标是 `localhost:8765`（或用户填的局域网另一台机），把它塞进 HTTP 代理
/// 会直接把制卡打断。app 侧的代理解析里另有一道 `isDirectProxyTarget` 闸门兜底，但**职责
/// 边界仍在这里**：本包不给 AnkiConnect 装任何代理钩子。
library;

import 'dart:io';

/// 抓远程媒体用的 [HttpClient] 工厂。未接线（null）时回退裸 `HttpClient()`，
/// 行为与接线前逐字等价。
HttpClient Function()? ankiRemoteMediaHttpClientFactory;

/// 远程媒体抓取统一的出站 client 入口。调用方负责 `close()`。
HttpClient createAnkiRemoteMediaHttpClient() =>
    ankiRemoteMediaHttpClientFactory?.call() ?? HttpClient();
