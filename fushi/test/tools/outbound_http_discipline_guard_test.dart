/// 守卫（BUG-1498）：**出站 HTTP 客户端的统一装配纪律**。
///
/// ## 为什么要守
///
/// 代理解析层 `lib/src/utils/net/app_proxy.dart` 从 BUG-1348 起就存在，可它的文件头一度
/// 白纸黑字列着一份「不经本层」的名单。BUG-1498 的全仓普查实测出 **40+ 条**绕过它的裸出站：
/// 刮削（TMDB / AniList / Bangumi / Jikan / VNDB / Fanart）、弹幕、字幕、封面、字体、
/// mpv shader、manga-OCR 模型（470MB from huggingface）、漫画在线源、Mihon 扩展商店、
/// youtube_explode、日志上传、发音源、制卡远程音频……
///
/// 根因不是「谁忘了接」，是**形状接不上**：这些出站点的统一形态是构造函数初始化列表里的
/// `SomeClient({http.Client? c}) : _client = c ?? http.Client();`——初始化列表不能 `await`，
/// 而 `applyAppProxy` 是异步的（要跑 `reg query` / `scutil` / `gsettings`）。于是每个新写
/// 出站的人面对的选择是「改成异步工厂 + 改所有调用点」还是「就用裸 client」，**结构决定了
/// 他们都会选后者**。修法是给出同步装配点（`lib/src/utils/net/app_http.dart`），这条守卫
/// 则保证这笔债不会重新长出来。
///
/// ## 守什么
///
/// **登记制**，与 `file_picker_discipline_guard_test.dart` 同范式：扫本仓自有 Dart 源码树，
/// 凡出现裸 `HttpClient(` / `http.Client(` / `IOClient(` / `Dio(` 的文件，必须要么是**装配点
/// 自身**（[kOutboundAssemblyPoints]），要么在 [kBareOutboundRegistry] 里登记并写明**为什么
/// 这条不该走代理**。清单只减不增。
///
/// ## 为什么不是「一律禁止」
///
/// 因为**真有一批链路必须直连**，把它们塞进代理会当场把功能打断：
/// AnkiConnect（`127.0.0.1:8765`）、Mihon 桌面 sidecar、qBittorrent WebUI、互联局域网 peer
/// 与配对探测、用户自建 WebDAV / torznab。这份登记表就是那批链路的**权威清单**——下一个人
/// 想「顺手把剩下的也接上」时，先读这里的理由。
///
/// 注意登记表**不是**唯一防线：`isDirectProxyTarget`（`app_proxy.dart`）在解析层就把
/// loopback / 私网 / `*.local` 目标一律判成 `DIRECT`，所以即便某条本机链路误接了代理层也
/// 不会坏。两道防线各管一段：闸门管**运行时正确性**，本守卫管**架构不再腐化**。
/// 闸门本身的行为断言在 `test/utils/net/app_proxy_local_bypass_test.dart`。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// 扫描根：本仓自有的 Dart 生产源码树。**不含** `third_party/` 与 vendored 插件 fork
/// （`flutter_inappwebview_windows` / `gamepads_*`）——上游产物不归我们管，给它们记账
/// 只会让每次上游同步都要改这份清单。
const List<String> kScanRoots = <String>[
  'fushi/lib',
  'packages/fushi_core/lib',
  'packages/fushi_dictionary/lib',
  'packages/fushi_anki/lib',
  'packages/fushi_audio/lib',
  'packages/fushi_platform/lib',
  'packages/fushi_torrent/lib',
];

/// **装配点自身**：它们的存在意义就是「建一个配好出口的 client」，当然要碰裸构造。
const Map<String, String> kOutboundAssemblyPoints = <String, String>{
  'fushi/lib/src/utils/net/app_http.dart':
      '统一装配点本体：createAppHttpClient / createAppHttpIoClient / createAppDio',
  'fushi/lib/src/utils/net/dictionary_dio.dart':
      '词典链路的 app 侧接线（BUG-1493）：把包内 dictionaryDioFactory 接到 applyAppProxy',
  'fushi/lib/src/sync/sync_http.dart':
      '云同步共享 client 的装配点（BUG-1348）：60s 连接超时 + applyAppProxy',
  'fushi/lib/src/media/torrent/download_network_proxy.dart':
      '下载发现链路的装配点：auto 走 applyAppProxy，direct/custom 是用户显式选定的固定出口',
  'fushi/lib/src/sync/tls/fushi_pinning_http.dart':
      '互联对端的证书指纹钉扎 client 装配点（自签证书，目标恒为局域网 peer）',
  'fushi/lib/src/utils/misc/update_checker_net.dart':
      '更新检查：自建 HttpClient 后立刻 applyAppProxy（每候选镜像单独建，需现场异步解析）',
  'fushi/lib/src/utils/misc/update_checker_release.dart':
      '更新包下载：同上，逐镜像建 client + applyAppProxy',
  'packages/fushi_anki/lib/src/anki_remote_media_http.dart':
      '制卡远程媒体的包内工厂钩子（BUG-1498）：未接线时回退裸 HttpClient，行为与接线前等价',
  'packages/fushi_dictionary/lib/src/formats/dictionary_downloader.dart':
      '词典链路的包内工厂钩子（BUG-1493）：createDictionaryDio 里 `?? Dio()` 的未接线回退',
};

/// **合法裸出站**：目标是本机 / 局域网 / 用户自建服务，**故意不接代理**。
///
/// 每条必须回答同一个问题：**为什么这条走代理会更坏？** 只减不增；想加新条目，先确认它
/// 真的打不到公网，否则应该改用 `createAppHttpIoClient()`。
const Map<String, String> kBareOutboundRegistry = <String, String>{
  // --- 本机回环 ---
  'packages/fushi_anki/lib/src/ankiconnect/ankiconnect_service.dart':
      'AnkiConnect JSON-RPC，默认 localhost:8765（用户可改成局域网另一台机）。'
          '它自带 connectionFactory 做连接期超时；走 HTTP 代理会让制卡整条链路当场失效。',
  'fushi/lib/src/media/manga/mihon/desktop_mihon_runtime.dart':
      'Mihon 桌面 sidecar：控制面与封面图都打本进程拉起的 127.0.0.1:<port> 认证代理端点。',
  'fushi/lib/src/media/torrent/qbittorrent_client.dart':
      '外接 qBittorrent WebUI，默认 127.0.0.1:8080（用户可改成局域网 NAS）。',
  'fushi/lib/src/media/torrent/torznab_client.dart':
      '用户自配 indexer，实践中多为自建/局域网/loopback（源码里另有 loopback 明文放行判据）。',
  // --- 局域网互联（peer 发现 / 配对 / 直连） ---
  'fushi/lib/src/sync/interconnect_post_transport.dart':
      '互联 POST 传输：目标恒为已配对的局域网 peer。',
  'fushi/lib/src/sync/interconnect_sync_backend.dart':
      '互联同步 / 远程库 / 远程视频流：pinned client 之外的回退分支，目标仍是局域网 peer。',
  'fushi/lib/src/sync/interconnect_manga_ocr_client.dart':
      '远程 manga-OCR：把 OCR 卸载到局域网另一台机，经代理等于把内网请求发到公网出口。',
  'fushi/lib/src/sync/pairing/fushi_ping_client.dart':
      '配对 peer 存活 ping：目标是 mDNS 发现出来的局域网地址。',
  'fushi/lib/src/models/app_model.dart':
      '远端查词 / 远端发音共用的 keep-alive client（TODO-744）：目标恒为已配对的局域网 peer。',
  // --- 用户自配服务器 ---
  'fushi/lib/src/sync/webdav_ops.dart': 'WebDAV 同步后端：地址由用户填，NAS / 局域网部署是主流用法。',
};

/// 登记在案的文件总数（装配点 + 豁免）。**这是自校验用的哨兵**：改清单必须同步改这个数，
/// 光靠「新增未登记即红」挡不住「悄悄多登记一条」。
const int kRegisteredOutboundFileCount = 19;

/// 裸出站构造的判据。
///
/// 全部带 `(?<![A-Za-z0-9_$.])` 左边界，所以：
/// * `createAppHttpClient(` / `createAppDio(` **不**命中（前缀是标识符字符）；
/// * `yt.YoutubeHttpClient(` / `IOHttpClientAdapter` **不**命中；
/// * `HttpClient.findProxyFromEnvironment(` **不**命中（`HttpClient` 后面不是 `(`）。
///
/// 容忍 `dart format` 折行：`\s*` 跨行匹配 `http\n    .Client(`。
const Map<String, String> kBareOutboundPatterns = <String, String>{
  'HttpClient(': r'(?<![A-Za-z0-9_$.])HttpClient\s*\(',
  'http.Client(': r'(?<![A-Za-z0-9_$])http\s*\.\s*Client\s*\(',
  'IOClient(': r'(?<![A-Za-z0-9_$.])IOClient\s*\(',
  'Dio(': r'(?<![A-Za-z0-9_$.])Dio\s*\(',
};

/// 仓库根：测试的 cwd 是 `fushi/`，往上一级。
Directory _repoRoot() => Directory('..').absolute;

/// 枚举扫描面（与 [findBareOutboundFiles] 共用，好让规模哨兵断言**同一条**扫描路径）。
List<File> scannedDartFiles() {
  final String root = _repoRoot().path;
  final List<File> out = <File>[];
  for (final String rel in kScanRoots) {
    final Directory dir = Directory('$root/$rel');
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.dart')) out.add(e);
    }
  }
  return out;
}

/// 把绝对路径归一成 `fushi/lib/...` 形式的仓库相对路径。
String _relativeToRepo(String absolutePath) {
  final String root = _repoRoot().path.replaceAll(r'\', '/');
  final String p = absolutePath.replaceAll(r'\', '/');
  final String prefix = root.endsWith('/') ? root : '$root/';
  return p.startsWith(prefix) ? p.substring(prefix.length) : p;
}

/// 扫出「含裸出站构造」的文件 → 命中的模式名集合。
///
/// **必须用词法掩码器**（`maskCommentsAndScriptLines`）而不是手写「按行砍 `//` / 配对
/// `/* */`」：本仓大文件里的字符串字面量含 `/*`（正则、CSS 片段），朴素扫描器会从那里
/// 进入「块注释中」状态并把文件剩余部分整块吞掉——实测 `app_model.dart` 里那条真实的
/// `http.Client()` 就是这样从枚举结果里凭空消失的。守卫扫不到 ≠ 干净。
Map<String, Set<String>> findBareOutboundFiles() {
  final Map<String, RegExp> patterns = kBareOutboundPatterns.map(
    (String name, String source) => MapEntry<String, RegExp>(
      name,
      RegExp(source, multiLine: true),
    ),
  );
  final Map<String, Set<String>> hits = <String, Set<String>>{};
  for (final File f in scannedDartFiles()) {
    final String code = maskCommentsAndScriptLines(f.readAsStringSync());
    final Set<String> found = <String>{};
    patterns.forEach((String name, RegExp re) {
      if (re.hasMatch(code)) found.add(name);
    });
    if (found.isNotEmpty) hits[_relativeToRepo(f.path)] = found;
  }
  return hits;
}

/// 判据的存活性只能靠**合成语料**问出来：健康仓库里禁止型断言恒零命中，扫真实文件永远
/// 证明不了判据没坏（fast-workflow「变异实测的五种假绿」之④）。
Set<String> _matchedPatternsIn(String source) {
  final String code = maskCommentsAndScriptLines(source);
  final Set<String> found = <String>{};
  kBareOutboundPatterns.forEach((String name, String pattern) {
    if (RegExp(pattern, multiLine: true).hasMatch(code)) found.add(name);
  });
  return found;
}

void main() {
  test('扫描规模哨兵：7 个源码根确实被枚举到了', () {
    expectScanScale(scannedDartFiles().length,
        what: '本仓自有 lib/ 下的 .dart', atLeast: 900, measured: 1136);
  });

  test('裸出站构造必须已登记（装配点 or 豁免清单）', () {
    final Set<String> allowed = <String>{
      ...kOutboundAssemblyPoints.keys,
      ...kBareOutboundRegistry.keys,
    };
    final Map<String, Set<String>> hits = findBareOutboundFiles();
    final Map<String, Set<String>> unexpected = <String, Set<String>>{
      for (final MapEntry<String, Set<String>> e in hits.entries)
        if (!allowed.contains(e.key)) e.key: e.value,
    };
    expect(
      unexpected,
      isEmpty,
      reason: '新增了绕过统一装配点的裸出站构造。\n'
          '如果目标是**公网**（刮削 / 字幕 / 弹幕 / 封面 / 字体 / 模型 / 日志…），请改用\n'
          '  `createAppHttpIoClient()` / `createAppHttpClient()` / `createAppDio()`\n'
          '（`lib/src/utils/net/app_http.dart`，同步、可直接写在构造函数初始化列表里）。\n'
          '如果目标确实是**本机 / 局域网 / 用户自建服务**，请在 kBareOutboundRegistry 里\n'
          '登记并写明「为什么走代理会更坏」，同时把 kRegisteredOutboundFileCount +1。\n'
          '下游包（packages/*）不能反向 import app 侧代理层，范式见 dictionary_downloader\n'
          '与 anki_remote_media_http 的进程级工厂钩子。',
    );
  });

  test('登记清单不得虚挂：每条都必须仍有裸构造', () {
    final Map<String, Set<String>> hits = findBareOutboundFiles();
    for (final String path in <String>[
      ...kOutboundAssemblyPoints.keys,
      ...kBareOutboundRegistry.keys,
    ]) {
      expect(
        hits.keys,
        contains(path),
        reason: '$path 已不再裸构造出站 client，请把它从清单里删掉并把 '
            'kRegisteredOutboundFileCount -1——清单只减不增，虚挂条目会让下一个人'
            '以为这里还有一条不走代理的暗路。',
      );
    }
  });

  test('登记的每个路径都真实存在（不是拼错的）', () {
    final String root = _repoRoot().path;
    for (final String path in <String>[
      ...kOutboundAssemblyPoints.keys,
      ...kBareOutboundRegistry.keys,
    ]) {
      expect(File('$root/$path').existsSync(), isTrue, reason: '$path 不存在');
    }
  });

  test('登记总数哨兵：清单条数与 kRegisteredOutboundFileCount 一致', () {
    final Set<String> all = <String>{
      ...kOutboundAssemblyPoints.keys,
      ...kBareOutboundRegistry.keys,
    };
    expect(all.length, kRegisteredOutboundFileCount,
        reason: '改了登记清单就要同步改这个数——光靠「新增未登记即红」挡不住'
            '「悄悄多登记一条」。');
  });

  test('每条登记都写了理由（空理由等于没登记）', () {
    kOutboundAssemblyPoints.forEach((String path, String reason) {
      expect(reason.trim().length, greaterThan(8), reason: '$path 缺理由');
    });
    kBareOutboundRegistry.forEach((String path, String reason) {
      expect(reason.trim().length, greaterThan(8), reason: '$path 缺理由');
    });
  });

  group('判据自校验（合成语料，逐分支存活性）', () {
    test('四种裸构造写法都能被抓到', () {
      expect(_matchedPatternsIn('final c = HttpClient();'),
          contains('HttpClient('));
      expect(_matchedPatternsIn('final c = http.Client();'),
          contains('http.Client('));
      expect(_matchedPatternsIn('final c = IOClient(inner);'),
          contains('IOClient('));
      expect(_matchedPatternsIn('final d = Dio(BaseOptions());'),
          contains('Dio('));
    });

    test('dart format 折出来的换行写法也能被抓到', () {
      expect(
        _matchedPatternsIn('final c = http\n    .Client();'),
        contains('http.Client('),
      );
      expect(
        _matchedPatternsIn('final c = HttpClient\n(\n);'),
        contains('HttpClient('),
      );
    });

    test('统一装配点的调用不算裸构造（否则整套改造自己把自己判红）', () {
      expect(_matchedPatternsIn('final c = createAppHttpClient();'), isEmpty);
      expect(_matchedPatternsIn('final c = createAppHttpIoClient();'), isEmpty);
      expect(_matchedPatternsIn('final d = createAppDio();'), isEmpty);
      expect(
        _matchedPatternsIn('final d = createProxiedDictionaryDio();'),
        isEmpty,
      );
    });

    test('同名前缀/受体不同的表达式不误伤', () {
      // 上游包自己的类型：注入我们的 client，不是裸构造。
      expect(
        _matchedPatternsIn('yt.YoutubeHttpClient(createAppHttpIoClient());'),
        isEmpty,
      );
      // dio 的 adapter 类型名里含 HttpClient，但后面不是 `(`。
      expect(
        _matchedPatternsIn('dio.httpClientAdapter = IOHttpClientAdapter();'),
        isEmpty,
      );
      // 静态方法调用，不是构造。
      expect(
        _matchedPatternsIn(
            'HttpClient.findProxyFromEnvironment(uri, environment: env);'),
        isEmpty,
      );
      // 成员访问链上的同名 getter。
      expect(_matchedPatternsIn('final x = foo.Dio(1);'), isEmpty);
    });

    test('注释里的裸构造不算命中（本文件与被扫文件的注释都写着这些名字）', () {
      expect(
          _matchedPatternsIn('// 以前是裸 HttpClient() 出站\nfinal x = 1;'), isEmpty);
      expect(_matchedPatternsIn('/// 回退裸 Dio()\nfinal y = 2;'), isEmpty);
      expect(_matchedPatternsIn('/* http.Client() */\nfinal z = 3;'), isEmpty);
      // 但同一行注释后面的真代码仍要抓到。
      expect(
        _matchedPatternsIn('final c = HttpClient(); // 说明 Dio()'),
        equals(<String>{'HttpClient('}),
      );
    });
  });
}
