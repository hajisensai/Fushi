// 守卫：语义是 URL / 主机 / 地址的输入框，必须显式声明 `keyboardType`。
//
// 背景（BUG-1804 / BUG-1807，真实用户事故）：`mihon_extensions_page.dart` 的
// 「添加扩展仓库」输入框没声明 keyboardType，默认落到 `TextInputType.text`。
// 中文/日文输入法在普通文本键盘下把 URL 的 `:` `/` `.` 转成全角 `：／。`，而
// `Uri.tryParse` 对它们有三种败法，其中全角句点那种**不报错**——它产出
// `host%EF%BC%8Ecom` 这样的垃圾 authority，一路走到网络层才失败，报出的错误
// 与真实原因毫无关系。用户表述是「地址填不进去 / 改不了地址」，排查方向被
// 完全带偏。真机复现时必须切到日语键盘的半角英数模式才输得进去。
//
// 全仓扫描后发现同一根因还有 10 处（Jellyfin 服务器、WebDAV/FTP/SFTP 主机、
// AnkiConnect 主机、词典音频源、两处磁力链、下载代理）。之所以会成片复发，
// 是因为三个共享输入组件的默认值都是 `TextInputType.text` 且不给任何提示：
//   * `FushiTextField`（utils/components/fushi_material_components.dart）
//   * `AdaptiveSettingsTextField`（settings/settings_shared.dart）
//   * `_CredentialFieldSpec`（sync/sync_settings_schema/backend_config.part.dart）
//
// **这条守卫不是主防线。** 主防线是消费端归一化（`normalizeUrlInput`）——
// keyboardType 只改善手输那一路，粘贴、扫码、从旧配置回填照样能把全角带进来。
// 守卫在这里的职责很窄：让「新加一个 URL 框却忘了声明」当场变红，而不是等
// 用户报「地址填不进去」。
//
// 判据刻意保守：只看**声明是否存在**，不校验值必须是 `TextInputType.url`。
// 有的地址框合理地用别的类型（比如只收端口号的用 number），那是作者的判断；
// 守卫要拦的是「压根没想过这件事」。
//
// 纯 dart:io，不依赖 Flutter 运行时。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从当前 cwd 向上找含 docs/BUGS.md 的仓库根。
Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/docs/BUGS.md').existsSync()) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 docs/BUGS.md 的仓库根（从 ${Directory.current.path} 向上）');
}

/// 被扫描的输入组件构造式。三个共享组件 + 原生 `TextField`/`TextFormField`。
const List<String> _widgetNames = <String>[
  'TextField(',
  'TextFormField(',
  'FushiTextField(',
  'AdaptiveSettingsTextField(',
  '_CredentialFieldSpec(',
];

/// 命中即认为「这个框是给 URL / 主机 / 地址用的」。
///
/// 用 i18n key 名与 hint 字面量两路判据：key 名覆盖用了翻译的场合，
/// hint 覆盖硬编码示例地址（`https://example.org/...`、`ftp.example.com`）。
final RegExp _urlSemantics = RegExp(
  r'''(?:'|")(?:https?://|wss?://|ftp://|magnet:)'''
  r'''|_url\b|_host\b|_address\b|Url\b|Host\b'''
  r'''|url_hint|server_url|webdav_url|connect_host|proxy_custom'''
  r'''|example\.(?:com|org)''',
);

/// 端口、API key、令牌之类：名字里带 host/url 词根但语义不是地址。
final RegExp _notAnAddress = RegExp(
  r'_port\b|_api_key|_token\b|_password\b|_username\b|_key\b',
);

/// 遮蔽输入（密码 / access token）永远不是地址框。
///
/// 需要这条是因为实参切片会连嵌套 widget 一起吃进来：
/// `media_tracking_settings_body.dart` 的 token 框在 `suffixIcon` 里放了个
/// 「去网页拿 token」的跳转按钮，`BangumiApiClient.accessTokenUrl` 里的 `Url`
/// 就把整个框误判成了地址框。按 obscureText 排除比给判据打补丁更准。
final RegExp _obscured = RegExp(r'obscureText:\s*true|obscure:\s*true');

/// 把一个构造式的实参片段切出来（从左括号到配平的右括号）。
String? _argumentSlice(String source, int openParenIndex) {
  int depth = 0;
  for (int i = openParenIndex; i < source.length; i++) {
    final String ch = source[i];
    if (ch == '(') depth++;
    if (ch == ')') {
      depth--;
      if (depth == 0) return source.substring(openParenIndex + 1, i);
    }
    // 构造式不应跨出上千字符；跑飞就放弃这一处，宁可漏报也不误报。
    if (i - openParenIndex > 4000) return null;
  }
  return null;
}

/// 剥掉行注释与块注释，避免注释里的示例地址把判据骗了
/// （本文件自己的注释里就写满了 `https://` 和 `host%EF%BC%8Ecom`）。
String _stripComments(String source) {
  final StringBuffer out = StringBuffer();
  bool inLine = false;
  bool inBlock = false;
  for (int i = 0; i < source.length; i++) {
    final String ch = source[i];
    final String next = i + 1 < source.length ? source[i + 1] : '';
    if (inLine) {
      if (ch == '\n') {
        inLine = false;
        out.write(ch);
      }
      continue;
    }
    if (inBlock) {
      if (ch == '*' && next == '/') {
        inBlock = false;
        i++;
      }
      continue;
    }
    if (ch == '/' && next == '/') {
      inLine = true;
      continue;
    }
    if (ch == '/' && next == '*') {
      inBlock = true;
      i++;
      continue;
    }
    out.write(ch);
  }
  return out.toString();
}

void main() {
  test('URL / 主机语义的输入框必须显式声明 keyboardType（BUG-1804/1807）', () {
    final Directory root = _repoRoot();
    final Directory libDir = Directory('${root.path}/fushi/lib');
    expect(libDir.existsSync(), isTrue, reason: '找不到 fushi/lib');

    final List<String> offenders = <String>[];
    int scannedFiles = 0;
    int scannedWidgets = 0;

    for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // 生成文件不由人手写，不在守卫范围内。
      if (entity.path.endsWith('.g.dart')) continue;
      scannedFiles++;
      final String source = _stripComments(entity.readAsStringSync());

      for (final String widget in _widgetNames) {
        int from = 0;
        while (true) {
          final int hit = source.indexOf(widget, from);
          if (hit < 0) break;
          from = hit + widget.length;
          // `TextField(` 是 `FushiTextField(` 的后缀，裸 indexOf 会把同一处
          // 数两遍。要求左边界不是标识符字符，否则交给更长的那个名字去认领。
          if (hit > 0 && RegExp(r'[A-Za-z0-9_$]').hasMatch(source[hit - 1])) {
            continue;
          }
          final int openParen = hit + widget.length - 1;
          final String? args = _argumentSlice(source, openParen);
          if (args == null) continue;
          scannedWidgets++;
          if (_obscured.hasMatch(args)) continue;
          if (!_urlSemantics.hasMatch(args)) continue;
          if (_notAnAddress.hasMatch(args) &&
              !_urlSemantics.hasMatch(args.replaceAll(_notAnAddress, ''))) {
            continue;
          }
          if (args.contains('keyboardType:') || args.contains('keyboard:')) {
            continue;
          }
          final int line = '\n'.allMatches(source.substring(0, hit)).length + 1;
          final String relative =
              entity.path.replaceAll(root.path, '').replaceAll(r'\', '/');
          offenders.add('$relative:$line  $widget');
        }
      }
    }

    // 扫描面自证：目录枚举型守卫最危险的失效是「一个文件都没扫到却绿着」。
    expect(scannedFiles, greaterThan(500),
        reason: '扫到的 .dart 文件太少（$scannedFiles），扫描面可能坏了');
    expect(scannedWidgets, greaterThan(100),
        reason: '扫到的输入框太少（$scannedWidgets），构造式匹配可能坏了');

    expect(
      offenders,
      isEmpty,
      reason: '以下输入框语义是 URL / 主机但没声明 keyboardType。\n'
          '中文输入法会把 `:` `/` `.` 转成全角，地址将被拒或产出垃圾 authority，\n'
          '详见 docs/bugs/BUG-1804-mihon-store-url-fullwidth-rejected.md。\n'
          '补 `keyboardType: TextInputType.url`（settings schema 里是 `keyboard:`），\n'
          '并确认该值的**消费端**已调 normalizeUrlInput —— 键盘类型只管手输，\n'
          '粘贴与配置回填一样能带进全角。\n\n${offenders.join('\n')}',
    );
  });
}
