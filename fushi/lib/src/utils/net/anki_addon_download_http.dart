/// 把 `fushi_anki` 的「代装 AnkiConnect 插件」下载链路接到全应用代理出口（app 侧接线）。
///
/// 与 `anki_remote_media_http.dart`（BUG-1498）、`dictionary_dio.dart`（BUG-1493）同范式：
/// 包内只留一个进程级工厂钩子，代理解析层住在 app 侧，由本文件把两边接上。
///
/// 这条链路打的是公网 `ankiweb.net`，**必须**能走代理：装 AnkiConnect 是接入 Anki 的第一
/// 步，这一步下不下来，后面整条制卡链路都无从谈起。与之相对，[AnkiConnectService] 自己那
/// 条打 `localhost:8765` 的链路绝不接代理（见 `outbound_http_discipline_guard_test.dart`
/// 的登记表）—— 同一个包里两条出站，方向正好相反，别接混。
library;

import 'package:http/http.dart' as http;

import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/utils/net/app_http.dart';

/// 把插件下载的 client 工厂接到应用代理出口。幂等，可重复调用。
void installAnkiAddonDownloadHttpClientFactory() {
  ankiAddonDownloadHttpClientFactory = createProxiedAnkiAddonDownloadClient;
}

/// 建一个走应用代理的 [http.Client]。插件包只有几十 KB，沿用默认的连接超时即可。
http.Client createProxiedAnkiAddonDownloadClient() => createAppHttpIoClient();
