/// BUG-1498：把 `fushi_anki` 的「抓远程媒体」链路接到全应用代理出口（app 侧接线）。
///
/// 与 `dictionary_dio.dart`（BUG-1493）同范式：包内只留一个进程级工厂钩子，代理解析层
/// 住在 app 侧，由本文件把两边接上。`AppModel.initialise()` 调一次
/// [installAnkiRemoteMediaHttpClientFactory]，此后制卡抓 Forvo / 词典音频源等公网 URL
/// 都自动经 `用户手填 > env > GUI 系统代理 > DIRECT` 解析。
///
/// **不碰 AnkiConnect**：那条链路打的是 `localhost:8765`（或用户填的局域网另一台机），
/// 它在 `fushi_anki` 里用自己的 client，本文件的工厂到不了它。
library;

import 'dart:io';

import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/utils/net/app_http.dart';

/// 把远程媒体抓取的 client 工厂接到应用代理出口。幂等，可重复调用。
void installAnkiRemoteMediaHttpClientFactory() {
  ankiRemoteMediaHttpClientFactory = createProxiedAnkiRemoteMediaHttpClient;
}

/// 建一个走应用代理的 [HttpClient]。音频文件可能有几 MB，只钉连接超时、不钉传输时限。
HttpClient createProxiedAnkiRemoteMediaHttpClient() => createAppHttpClient();
