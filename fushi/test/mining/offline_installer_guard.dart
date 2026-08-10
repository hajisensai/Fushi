// 「安装器不得联网」这条不变式的**共享判据**。BUG-1196（helper）与 BUG-1492（Magpie）
// 守的是同一件事，判据只能有一份。
//
// 🔴 为什么不能只用字面量黑名单（这一版存在的全部理由）：
// 旧守卫扫的是 `HttpClient` / `ResumableDownload` / `https://` 这几个**字面串**。可 app
// 直接依赖 `http` 与 `dio`（`fushi/pubspec.yaml`），所以「把下载加回来」最自然的写法是
//
//     import 'package:http/http.dart' as http;
//     final Uri url = Uri.parse('htt' 'ps://example.com/pkg.zip');
//     final http.Response r = await http.get(url);
//
// —— 一个 `HttpClient` 都没有，URL 用相邻字面量拼出来，整条路径**从旧守卫下面穿过去，
// 测试全绿**。实测过：插进去之后两个守卫都还是 PASSED。字面量黑名单守的不是通道，是
// 拼写。
//
// 所以判据换成两条真正的「可达通道」检查：
//   1. **import 白名单**：这两个安装器的依赖面是封闭的，任何新 import 都必须先来改这个
//      白名单 —— 逼后来者读上面这段。`package:http` / `package:dio` / 任何自带下载能力
//      的项目文件都会在这里当场撞墙。
//   2. **归一化后的符号扫描**：先折叠相邻字面量与 `+` 拼接（干掉上面那个 `'htt' 'ps://'`
//      把戏），再扫 `Uri` / `Http*` / `*Socket` / `download` 这类**能力名**，而不是某个
//      具体 API 的拼写。`dart:io` 是合法依赖，所以它里面的网络类必须逐个点名。
//
// 已知残留：`package:fushi/utils.dart` 是个大 barrel，理论上可以在里面新塞一个下载函数
// 再从 helper 安装器调用。第 2 条的能力名扫描（`download` / `Uri` / `fetch`）挡住了调用
// 侧的常见写法；真要绕还是绕得过去，但那已经不是「顺手加回来」而是刻意。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 复用同款字符级注释剥除器，避免文档/行/块注释里的示例文字污染静态守卫。
import '../sync/desktop_lookup_foreground_guard_static_test.dart'
    show stripDartComments;

/// 折叠 Dart 的字符串拼接，让 `'htt' 'ps://x'` 与 `'htt' + 'ps://x'` 还原成一个字面量。
///
/// 只做词法层折叠（相邻同引号字面量之间只有空白，或只隔一个 `+`），不解析转义 —— 守卫
/// 要的是「拼出来的 URL 拦得住」，不是完整的 Dart 词法器。
String foldStringConcatenation(String source) {
  String out = source;
  final RegExp adjacent = RegExp(r"(['\x22])\s*\1");
  final RegExp plus = RegExp(r"(['\x22])\s*\+\s*\1");
  for (int i = 0; i < 8; i++) {
    final String next = out.replaceAll(plus, '').replaceAll(adjacent, '');
    if (next == out) break;
    out = next;
  }
  return out;
}

/// 源码里所有 `import` / `export` 的 URI（按出现顺序，去重保序）。
List<String> directiveUris(String source) {
  final RegExp directive = RegExp(
    r'''^\s*(?:import|export)\s+(['"])([^'"]+)\1''',
    multiLine: true,
  );
  final List<String> uris = <String>[];
  for (final RegExpMatch m in directive.allMatches(source)) {
    final String uri = m.group(2)!;
    if (!uris.contains(uri)) uris.add(uri);
  }
  return uris;
}

/// 能力名黑名单：扫的是「能联网的东西」，不是某个 API 的拼写。
///
/// `dart:io` 本身是合法依赖（安装器要读写文件），所以它自带的网络类必须逐个点名。
const Map<String, String> _bannedCapabilities = <String, String>{
  r'\bhttps?:': 'URL 字面量（相邻/`+` 拼接已在扫描前折叠）',
  r'\bHttp[A-Za-z]*\b': 'dart:io 的 HTTP 客户端/服务端（HttpClient、HttpServer …）',
  r'\bhttp\b': 'package:http 的常用前缀（http.get / http.post）',
  r'\b[A-Za-z]*Socket[A-Za-z]*\b':
      'socket 直连（Socket / RawSocket / WebSocket …）',
  r'\bUri\b': 'URL 构造（Uri.parse / Uri.https / Uri(scheme: …)）',
  r'\b[Dd]io\b': 'package:dio',
  r'[Dd]ownload': '下载入口（含 ResumableDownload / confirmDownload / *DownloadUrl）',
  r'\bfetch[A-Z]': '远端抓取入口',
  r'applyAppProxy': '镜像代理候选（BUG-1348 改名前叫 applyUpdateProxy）',
  r'InBackground': '后台静默自更新入口',
};

/// 扫一个安装器源码，返回全部「能联网」的证据。返回空 = 这个文件当前没有可达网络通道。
///
/// [allowedImports] 是**穷举**白名单：不在里面的 import 一律记一条。
List<String> offlineInstallerFindings({
  required String path,
  required Set<String> allowedImports,
}) {
  final File file = File(path);
  if (!file.existsSync()) {
    return <String>['$path: 文件不存在（守卫的对象没了，先确认是不是被改名/删除）'];
  }
  final String raw = file.readAsStringSync();
  final String code = stripDartComments(raw);
  final List<String> findings = <String>[];

  for (final String uri in directiveUris(code)) {
    if (!allowedImports.contains(uri)) {
      findings.add('$path: 新增 import「$uri」不在离线白名单里');
    }
  }

  final String folded = foldStringConcatenation(code);
  _bannedCapabilities.forEach((String pattern, String why) {
    final RegExpMatch? hit = RegExp(pattern).firstMatch(folded);
    if (hit != null) {
      findings.add('$path: 出现「${hit.group(0)}」——$why');
    }
  });

  return findings;
}

/// 断言这个安装器全程离线；失败时把每一条证据都打出来。
void expectOfflineInstaller({
  required String path,
  required Set<String> allowedImports,
}) {
  final List<String> findings = offlineInstallerFindings(
    path: path,
    allowedImports: allowedImports,
  );
  expect(
    findings,
    isEmpty,
    reason: '安装器装的是会跑在用户机器上的原生代码，一条「从网上取包」的通道就是 '
        'BUG-1103 记的那个攻击面。命中：\n- ${findings.join('\n- ')}',
  );
}

/// galgame helper 安装器的离线依赖面（BUG-1196）。
const Set<String> kGalgameHelperInstallerImports = <String>{
  'dart:async',
  'dart:io',
  'package:archive/archive.dart',
  'package:crypto/crypto.dart',
  'package:flutter/material.dart',
  'package:path/path.dart',
  'package:fushi/utils.dart',
};

/// Magpie 安装器的离线依赖面（BUG-1492）。
const Set<String> kMagpieInstallerImports = <String>{
  'dart:convert',
  'dart:io',
  'package:archive/archive.dart',
  'package:crypto/crypto.dart',
  'package:flutter/foundation.dart',
  'package:path/path.dart',
  'package:fushi/src/mining/galgame_helper_installer.dart',
};
