import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_cdp.dart';
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_frame.dart';
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_observer_script.dart';
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_session.dart';
import 'package:test/test.dart';

/// /json/list 实测响应的结构（Electron 24），URL 与标题为自造。
const String _recordedTargetList = '''
[ {
   "description": "",
   "devtoolsFrontendUrl": "/devtools/inspector.html?ws=127.0.0.1:9333/devtools/page/AAAA",
   "id": "AAAA",
   "title": "Sample",
   "type": "page",
   "url": "file:///C:/game/resources/app.asar/index.html",
   "webSocketDebuggerUrl": "ws://127.0.0.1:9333/devtools/page/AAAA"
} ]
''';

String _framePayload(String text) => jsonEncode(<String, Object?>{
  'v': 1,
  'adding': false,
  'vertical': false,
  'dpr': 1.5,
  'vw': 800,
  'vh': 600,
  'speaker': '',
  'glyphs': <Map<String, Object?>>[
    for (int i = 0; i < text.length; i++)
      <String, Object?>{
        't': text[i],
        'x': 10 + 20 * i,
        'y': 50,
        'w': 20,
        'h': 20,
        's': true,
      },
  ],
});

/// 假 CDP 端点：前 [emptyPolls] 次 /json/list 返回空表（模拟游戏刚启动），之后给出 page 目标。
class _FakeCdp {
  _FakeCdp._(this.server, this.emptyPolls) {
    server.listen(_handle);
  }

  static Future<_FakeCdp> start({int emptyPolls = 2}) async => _FakeCdp._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    emptyPolls,
  );

  final HttpServer server;
  final int emptyPolls;
  int listCalls = 0;
  final List<String> methods = <String>[];
  WebSocket? socket;
  final Completer<void> installed = Completer<void>();

  int get port => server.port;

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == '/json/list') {
      listCalls++;
      final String body = listCalls <= emptyPolls
          ? '[]'
          : jsonEncode(<Map<String, Object?>>[
              <String, Object?>{
                'id': 'DT',
                'type': 'page',
                'url': 'devtools://devtools/bundled/inspector.html',
                'webSocketDebuggerUrl': 'ws://127.0.0.1:$port/devtools/page/DT',
              },
              <String, Object?>{
                'id': 'P1',
                'type': 'page',
                'url': 'file:///C:/game/index.html',
                'webSocketDebuggerUrl': 'ws://127.0.0.1:$port/devtools/page/P1',
              },
            ]);
      request.response
        ..headers.contentType = ContentType.json
        ..write(body);
      await request.response.close();
      return;
    }
    expect(request.uri.path, '/devtools/page/P1');
    final WebSocket ws = await WebSocketTransformer.upgrade(request);
    socket = ws;
    ws.listen((Object? data) {
      final Map<String, Object?> msg =
          jsonDecode(data! as String) as Map<String, Object?>;
      final String method = msg['method']! as String;
      methods.add(method);
      final Map<String, Object?> result =
          method == 'Page.addScriptToEvaluateOnNewDocument'
          ? <String, Object?>{'identifier': '7'}
          : <String, Object?>{};
      ws.add(jsonEncode(<String, Object?>{'id': msg['id'], 'result': result}));
      if (method == 'Runtime.evaluate' && !installed.isCompleted) {
        installed.complete();
      }
    });
  }

  void pushBinding(String name, String payload) {
    socket!.add(
      jsonEncode(<String, Object?>{
        'method': 'Runtime.bindingCalled',
        'params': <String, Object?>{
          'name': name,
          'payload': payload,
          'executionContextId': 1,
        },
      }),
    );
  }
}

void main() {
  group('CDP 解析', () {
    test('录制的 /json/list 选出 page 目标', () {
      final List<CdpTarget> targets = parseCdpTargetList(_recordedTargetList);
      expect(targets, hasLength(1));
      final CdpTarget? page = selectGamePageTarget(targets);
      expect(
        page!.webSocketDebuggerUrl,
        'ws://127.0.0.1:9333/devtools/page/AAAA',
      );
    });

    test('跳过 devtools 页面与无 ws 地址的目标；坏 JSON 给空表', () {
      final List<CdpTarget> targets = parseCdpTargetList(
        jsonEncode(<Map<String, Object?>>[
          <String, Object?>{
            'id': 'a',
            'type': 'page',
            'url': 'devtools://x',
            'webSocketDebuggerUrl': 'ws://a',
          },
          <String, Object?>{'id': 'b', 'type': 'page', 'url': 'file:///x'},
          <String, Object?>{
            'id': 'c',
            'type': 'service_worker',
            'url': 'file:///y',
            'webSocketDebuggerUrl': 'ws://c',
          },
        ]),
      );
      expect(selectGamePageTarget(targets), isNull);
      expect(parseCdpTargetList('<html>'), isEmpty);
    });

    test('入站消息：响应 / 事件 / 错误', () {
      final CdpIncoming response = parseCdpIncoming(
        '{"id":3,"result":{"identifier":"1"}}',
      )!;
      expect(response.id, 3);
      expect(response.result, <String, Object?>{'identifier': '1'});
      final CdpIncoming event = parseCdpIncoming(
        '{"method":"Runtime.bindingCalled","params":{"name":"n","payload":"{}","executionContextId":1}}',
      )!;
      expect(event.id, isNull);
      expect(event.method, 'Runtime.bindingCalled');
      expect(event.params!['name'], 'n');
      final CdpIncoming error = parseCdpIncoming(
        '{"id":4,"error":{"code":-32601,"message":"not found"}}',
      )!;
      expect(error.error!['message'], 'not found');
      expect(parseCdpIncoming('nope'), isNull);
    });

    test('观察脚本与 Dart 常量的名字一致', () {
      expect(kTyranoDomObserverScript, contains("'$kTyranoDomBindingName'"));
      expect(
        kTyranoDomObserverScript,
        contains('window.$kTyranoDomObserverGlobal'),
      );
      expect(
        kTyranoDomObserverScript,
        contains('v: $kTyranoDomPayloadVersion,'),
      );
      expect(kTyranoDomDisposeExpression, contains(kTyranoDomObserverGlobal));
    });
  });

  group('TyranoDomSession（假 CDP 端点）', () {
    test('轮询到页面出现 → 安装绑定与脚本 → 推帧 → 对端断开发出终止', () async {
      final _FakeCdp fake = await _FakeCdp.start(emptyPolls: 2);
      addTearDown(() => fake.server.close(force: true));
      final TyranoDomSession session = await TyranoDomSession.connect(
        port: fake.port,
        pollInterval: const Duration(milliseconds: 20),
        timeout: const Duration(seconds: 10),
      );
      expect(fake.listCalls, 3);
      await fake.installed.future;
      expect(fake.methods, <String>[
        'Runtime.addBinding',
        'Page.enable',
        'Page.addScriptToEvaluateOnNewDocument',
        'Runtime.evaluate',
      ]);

      final StreamIterator<TyranoDomFrame> frames =
          StreamIterator<TyranoDomFrame>(session.frames);
      fake.pushBinding('someOtherBinding', _framePayload('无关'));
      fake.pushBinding(kTyranoDomBindingName, 'garbage');
      fake.pushBinding(kTyranoDomBindingName, _framePayload('甲乙'));
      fake.pushBinding(kTyranoDomBindingName, _framePayload('甲乙'));
      fake.pushBinding(kTyranoDomBindingName, _framePayload('丙'));

      expect(await frames.moveNext(), isTrue);
      expect(frames.current.text, '甲乙');
      expect(frames.current.generation, 1);
      expect(frames.current.glyphs.first.rect.left, 15);
      expect(frames.current.clientWidth, 1200);
      expect(await frames.moveNext(), isTrue);
      expect(frames.current.generation, 1);
      expect(await frames.moveNext(), isTrue);
      expect(frames.current.text, '丙');
      expect(frames.current.generation, 2);
      expect(session.latest!.text, '丙');

      await fake.socket!.close();
      expect(await frames.moveNext(), isFalse);
      expect(await session.done, TyranoDomEndReason.disconnected);
      expect(session.isEnded, isTrue);
    });

    test('close() 卸载脚本、移除绑定与新文档脚本', () async {
      final _FakeCdp fake = await _FakeCdp.start(emptyPolls: 0);
      addTearDown(() => fake.server.close(force: true));
      final TyranoDomSession session = await TyranoDomSession.connect(
        port: fake.port,
      );
      await session.close();
      expect(await session.done, TyranoDomEndReason.closed);
      expect(
        fake.methods,
        containsAll(<String>[
          'Runtime.removeBinding',
          'Page.removeScriptToEvaluateOnNewDocument',
        ]),
      );
      expect(
        fake.methods.where((String m) => m == 'Runtime.evaluate'),
        hasLength(2),
      );
    });

    test('端口一直没有页面 → 超时抛 TyranoDomConnectException', () async {
      final _FakeCdp fake = await _FakeCdp.start(emptyPolls: 1 << 30);
      addTearDown(() => fake.server.close(force: true));
      await expectLater(
        TyranoDomSession.connect(
          port: fake.port,
          pollInterval: const Duration(milliseconds: 20),
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<TyranoDomConnectException>()),
      );
      expect(fake.listCalls, greaterThan(1));
    });
  });
}
