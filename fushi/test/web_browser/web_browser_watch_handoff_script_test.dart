import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/play_in_fushi_feature.dart';

/// G-Vr-zkb5L：Netflix 观看页要在**导航提交之前**交给播放页，浏览器标签页不建播放会话
/// （旧实现在 onUpdateVisitedHistory——SPA 已进 /watch 路由、会话已在建——之后才交接，
/// 同账号两次起播触发限流）。node 真执行 document-start 脚本，喂假的 DOM / 桥。
void main() {
  final String? nodeExe = _resolveNode();

  /// 跑一遍脚本。[href]：文档地址；[handled]：Dart 交接 handler 的回答；[clickHref]：
  /// 非 null 时派发一次点在该链接上的 click。返回脚本的副作用记录。
  Future<Map<String, dynamic>> run({
    required String href,
    required bool handled,
    String? clickHref,
    String? bypass,
  }) async {
    final String harness =
        '''
const out = { handoffs: [], stopped: false, assigned: null, prevented: false, propagated: true, bypass: null };
const store = new Map(${bypass == null ? '' : jsonEncode(<List<String>>[
                <String>['__fushiWatchHandoffBypass', bypass],
              ])});
globalThis.sessionStorage = {
  getItem: (k) => store.has(k) ? store.get(k) : null,
  setItem: (k, v) => { store.set(k, v); out.bypass = v; },
  removeItem: (k) => store.delete(k),
};
const listeners = [];
globalThis.location = { href: ${jsonEncode(href)}, hostname: new URL(${jsonEncode(href)}).hostname,
  assign: (u) => { out.assigned = u; } };
globalThis.document = { addEventListener: (type, fn, cap) => listeners.push({ type, fn, cap }) };
globalThis.window = globalThis;
window.addEventListener = () => {};
window.stop = () => { out.stopped = true; };
window.flutter_inappwebview = { callHandler: (name, url, from) => { out.handoffs.push([name, url, from]); return Promise.resolve(${handled ? 'true' : 'false'}); } };
eval(${jsonEncode(kWebBrowserWatchHandoffScript)});
const click = ${clickHref == null ? 'null' : jsonEncode(clickHref)};
if (click !== null) {
  const a = { getAttribute: () => click };
  const target = { closest: () => a };
  const ev = { type: 'click', target, button: 0, defaultPrevented: false,
    preventDefault() { this.defaultPrevented = true; out.prevented = true; },
    stopImmediatePropagation() { out.propagated = false; } };
  for (const l of listeners) if (l.type === 'click' && l.cap) l.fn(ev);
}
setTimeout(() => process.stdout.write(JSON.stringify(out)), 20);
''';
    final ProcessResult result = await Process.run(nodeExe!, <String>[
      '-e',
      harness,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return jsonDecode(result.stdout as String) as Map<String, dynamic>;
  }

  final Object skip = nodeExe == null ? 'node not found on PATH' : false;

  test('点选集页上指向 /watch/ 的链接：导航被取消，交给 Dart', () async {
    final Map<String, dynamic> out = await run(
      href: 'https://www.netflix.com/title/80100172',
      handled: true,
      clickHref: '/watch/80117470?trackId=14170286',
    );
    expect(out['prevented'], isTrue, reason: '浏览器标签页不得前往观看页');
    expect(out['propagated'], isFalse, reason: '站点自己的路由不得收到这次点击');
    expect(out['assigned'], isNull);
    expect(out['handoffs'], <List<String>>[
      <String>[
        kWebBrowserWatchHandoffHandler,
        'https://www.netflix.com/watch/80117470?trackId=14170286',
        kWebBrowserWatchHandoffFromLink,
      ],
    ]);
  }, skip: skip);

  test('Dart 交不了（无痕 / 无播放页）：带一次性放行标记整页前往', () async {
    final Map<String, dynamic> out = await run(
      href: 'https://www.netflix.com/browse',
      handled: false,
      clickHref: '/watch/1',
    );
    expect(out['prevented'], isTrue);
    expect(out['assigned'], 'https://www.netflix.com/watch/1');
    expect(out['bypass'], 'https://www.netflix.com/watch/1');
  }, skip: skip);

  test('整页直接进观看页：document-start 先 stop 再交接', () async {
    final Map<String, dynamic> out = await run(
      href: 'https://www.netflix.com/watch/42',
      handled: true,
    );
    expect(out['stopped'], isTrue, reason: '播放器脚本不得开跑（不建会话）');
    // 导航已提交：交接必须声明来自观看页文档，Dart 侧据此退回上一页——否则这条回调先于
    // onUrlChanged 到达时，标签页会停在被 window.stop() 停住的空白观看页上。
    expect(out['handoffs'], <List<String>>[
      <String>[
        kWebBrowserWatchHandoffHandler,
        'https://www.netflix.com/watch/42',
        kWebBrowserWatchHandoffFromDocument,
      ],
    ]);
    // handler 收到的 args 是 callHandler 去掉 handler 名之后的部分。
    expect(
      webBrowserWatchHandoffCommitted(
        (out['handoffs'][0] as List<dynamic>).sublist(1),
      ),
      isTrue,
    );
  }, skip: skip);

  test('交接 handler 参数：只有观看页文档算已提交，链接点击 / 旧脚本只传地址都不算', () {
    expect(
      webBrowserWatchHandoffCommitted(<dynamic>[
        'https://www.netflix.com/watch/1',
        kWebBrowserWatchHandoffFromDocument,
      ]),
      isTrue,
    );
    expect(
      webBrowserWatchHandoffCommitted(<dynamic>[
        'https://www.netflix.com/watch/1',
        kWebBrowserWatchHandoffFromLink,
      ]),
      isFalse,
    );
    expect(
      webBrowserWatchHandoffCommitted(<dynamic>[
        'https://www.netflix.com/watch/1',
      ]),
      isFalse,
    );
    expect(webBrowserWatchHandoffCommitted(<dynamic>[]), isFalse);
  });

  test('带放行标记的观看页文档照常加载；非观看页链接与非 Netflix 站点不拦', () async {
    final Map<String, dynamic> bypassed = await run(
      href: 'https://www.netflix.com/watch/42',
      handled: true,
      bypass: 'https://www.netflix.com/watch/42',
    );
    expect(bypassed['stopped'], isFalse);
    expect(bypassed['handoffs'], isEmpty);

    final Map<String, dynamic> title = await run(
      href: 'https://www.netflix.com/browse',
      handled: true,
      clickHref: '/title/80100172',
    );
    expect(title['prevented'], isFalse);
    expect(title['handoffs'], isEmpty);

    final Map<String, dynamic> other = await run(
      href: 'https://example.com/',
      handled: true,
      clickHref: 'https://www.netflix.com/watch/1',
    );
    expect(other['prevented'], isFalse);
    expect(other['handoffs'], isEmpty);
  }, skip: skip);

  test('交接判据：无痕 / 没有播放页 / 非观看页都不交', () {
    final Uri watch = Uri.parse('https://www.netflix.com/watch/1');
    expect(
      webBrowserShouldHandOffWatchPage(
        watch,
        incognito: false,
        playerAvailable: true,
      ),
      isTrue,
    );
    expect(
      webBrowserShouldHandOffWatchPage(
        watch,
        incognito: true,
        playerAvailable: true,
      ),
      isFalse,
    );
    expect(
      webBrowserShouldHandOffWatchPage(
        watch,
        incognito: false,
        playerAvailable: false,
      ),
      isFalse,
    );
    expect(
      webBrowserShouldHandOffWatchPage(
        Uri.parse('https://www.netflix.com/browse'),
        incognito: false,
        playerAvailable: true,
      ),
      isFalse,
    );
  });

  test('交接判据：站点标了自动播放的 YouTube 观看页同一条判据交接，其它页不交', () {
    final Uri ytWatch = Uri.parse(
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    );
    bool always(Uri _) => true;
    bool never(Uri _) => false;
    expect(
      webBrowserShouldHandOffWatchPage(
        ytWatch,
        incognito: false,
        playerAvailable: true,
        autoPlaySite: always,
      ),
      isTrue,
    );
    // 没标自动播放：YouTube 观看页留在浏览器里播。
    expect(
      webBrowserShouldHandOffWatchPage(
        ytWatch,
        incognito: false,
        playerAvailable: true,
        autoPlaySite: never,
      ),
      isFalse,
    );
    expect(
      webBrowserShouldHandOffWatchPage(
        ytWatch,
        incognito: false,
        playerAvailable: true,
      ),
      isFalse,
    );
    // 无痕 / 没有播放页仍然不交，哪怕站点标了自动播放。
    expect(
      webBrowserShouldHandOffWatchPage(
        ytWatch,
        incognito: true,
        playerAvailable: true,
        autoPlaySite: always,
      ),
      isFalse,
    );
    expect(
      webBrowserShouldHandOffWatchPage(
        ytWatch,
        incognito: false,
        playerAvailable: false,
        autoPlaySite: always,
      ),
      isFalse,
    );
    // 自动播放只认观看页：YouTube 首页不交。
    expect(
      webBrowserShouldHandOffWatchPage(
        Uri.parse('https://www.youtube.com/'),
        incognito: false,
        playerAvailable: true,
        autoPlaySite: always,
      ),
      isFalse,
    );
  });
}

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String pathEnv = Platform.environment['PATH'] ?? '';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
