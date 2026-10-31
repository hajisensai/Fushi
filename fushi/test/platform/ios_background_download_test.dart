import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/mobile/ios_background_download.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

/// BUG-3887：iOS 词典包后台传输的 Dart 半边。
///
/// 钉住的是与 dio 传输**同一份失败契约**：候选回退、失败归因、「取消不算失败」全按
/// [DioError] 判，原生侧的每种结局都必须翻译成与 dio 同类型的 [DioError]。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('test/background_download');
  late List<MethodCall> calls;

  /// 原生侧对各方法的答复（缺省 null）。
  late Map<String, Object?> replies;
  late DateTime clock;
  late bool foreground;

  setUp(() {
    calls = <MethodCall>[];
    replies = <String, Object?>{};
    clock = DateTime(2026, 10, 31);
    foreground = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return replies[call.method];
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  IosBackgroundDownloadTransport newTransport({
    IosBackgroundDownloadProxy? proxy = IosBackgroundDownloadProxy.system,
    DictionaryDownloadTransport? fallback,
  }) => IosBackgroundDownloadTransport(
    channel: channel,
    isForeground: () => foreground,
    now: () => clock,
    proxy: () => proxy,
    fallback:
        fallback ??
        ({
          required String url,
          required String destPath,
          required void Function(int, int) onReceiveProgress,
          CancelToken? cancelToken,
          DictionaryDownloadHandoff? handoff,
        }) async => fail('fallback must not be used'),
    connectTimeout: const Duration(seconds: 30),
    stallTimeout: const Duration(seconds: 60),
    watchdogTick: const Duration(milliseconds: 10),
  );

  /// 模拟原生侧往 Dart 发一条调用。
  Future<void> nativeSends(String method, Map<String, Object?> args) async {
    final ByteData message = const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, args),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, message, (_) {});
  }

  Future<String> startedId() async {
    for (int i = 0; i < 20 && calls.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final MethodCall start = calls.firstWhere(
      (MethodCall c) => c.method == 'start',
    );
    return (start.arguments as Map<Object?, Object?>)['id']! as String;
  }

  test('start 把 url / dest / 代理交给原生，complete 后 Future 完成，进度如实转交', () async {
    final IosBackgroundDownloadTransport transport = newTransport(
      proxy: IosBackgroundDownloadProxy.manual('10.0.0.2', 7890),
    );
    final List<List<int>> progress = <List<int>>[];
    final Future<void> done = transport.download(
      url: 'https://example.com/a.zip',
      destPath: '/tmp/a.zip',
      onReceiveProgress: (int r, int t) => progress.add(<int>[r, t]),
    );
    final String id = await startedId();
    final Map<Object?, Object?> args =
        calls.single.arguments as Map<Object?, Object?>;
    expect(args['url'], 'https://example.com/a.zip');
    expect(args['dest'], '/tmp/a.zip');
    expect(args['proxyMode'], 'manual');
    expect(args['proxyHost'], '10.0.0.2');
    expect(args['proxyPort'], 7890);

    await nativeSends('progress', <String, Object?>{
      'id': id,
      'received': 512,
      'total': 1024,
    });
    await nativeSends('complete', <String, Object?>{'id': id, 'error': null});
    await done;
    expect(progress, <List<int>>[
      <int>[512, 1024],
    ]);
    expect(transport.pendingIds, isEmpty);
  });

  group('原生失败翻译成与 dio 同类型的 DioError', () {
    Future<DioError> failWith(Map<String, Object?> error) async {
      final IosBackgroundDownloadTransport transport = newTransport();
      // 先挂上错误处理：原生 complete 在 nativeSends 里同步落地，晚挂就成了未处理错误。
      final Future<Object?> outcome = transport
          .download(
            url: 'https://example.com/a.zip',
            destPath: '/tmp/a.zip',
            onReceiveProgress: (_, _) {},
          )
          .then<Object?>((_) => null, onError: (Object e) => e);
      final String id = await startedId();
      await nativeSends('complete', <String, Object?>{
        'id': id,
        'error': error,
      });
      final Object? result = await outcome;
      expect(result, isA<DioError>());
      return result! as DioError;
    }

    test('连不上 → connectionError，是可换镜像的传输失败', () async {
      final DioError e = await failWith(<String, Object?>{
        'kind': 'connection',
      });
      expect(e.type, DioErrorType.connectionError);
      expect(isDictionaryTransportFailure(e), isTrue);
    });

    test('超时 → receiveTimeout（stallTimeout 归因）', () async {
      final DioError e = await failWith(<String, Object?>{'kind': 'stall'});
      expect(
        classifyDictionaryDownloadFailure(e),
        DictionaryDownloadFailureKind.stallTimeout,
      );
    });

    test('404 → badResponse 带状态码，不换镜像', () async {
      final DioError e = await failWith(<String, Object?>{
        'kind': 'badResponse',
        'status': 404,
      });
      expect(e.type, DioErrorType.badResponse);
      expect(e.response?.statusCode, 404);
      expect(isDictionaryTransportFailure(e), isFalse);
    });

    test('取消 → cancel，「取消不算失败」判据照常成立', () async {
      final DioError e = await failWith(<String, Object?>{'kind': 'cancel'});
      expect(
        classifyDictionaryDownloadFailure(e),
        DictionaryDownloadFailureKind.cancelled,
      );
    });
  });

  test('CancelToken 取消：立即以 cancel 失败并通知原生取消', () async {
    final IosBackgroundDownloadTransport transport = newTransport();
    final CancelToken token = CancelToken();
    final Future<void> done = transport.download(
      url: 'https://example.com/a.zip',
      destPath: '/tmp/a.zip',
      onReceiveProgress: (_, _) {},
      cancelToken: token,
    );
    final String id = await startedId();
    token.cancel('user');
    await expectLater(
      done,
      throwsA(
        isA<DioError>().having(
          (DioError e) => e.type,
          'type',
          DioErrorType.cancel,
        ),
      ),
    );
    final MethodCall cancel = calls.firstWhere(
      (MethodCall c) => c.method == 'cancel',
    );
    expect((cancel.arguments as Map<Object?, Object?>)['id'], id);
  });

  group('前台看门狗（后台会话不会自己超时，镜像回退靠它）', () {
    test('前台首字节前超过连接预算 → connectionTimeout 并取消原生任务', () async {
      final IosBackgroundDownloadTransport transport = newTransport();
      final Future<void> done = transport.download(
        url: 'https://example.com/a.zip',
        destPath: '/tmp/a.zip',
        onReceiveProgress: (_, _) {},
      );
      await startedId();
      clock = clock.add(const Duration(seconds: 31));
      await expectLater(
        done,
        throwsA(
          isA<DioError>().having(
            (DioError e) => e.type,
            'type',
            DioErrorType.connectionTimeout,
          ),
        ),
      );
      expect(calls.map((MethodCall c) => c.method), contains('cancel'));
    });

    test('收到字节后改按卡死预算计：60 秒内有进度不超时', () async {
      final IosBackgroundDownloadTransport transport = newTransport();
      final Future<void> done = transport.download(
        url: 'https://example.com/a.zip',
        destPath: '/tmp/a.zip',
        onReceiveProgress: (_, _) {},
      );
      final String id = await startedId();
      clock = clock.add(const Duration(seconds: 20));
      await nativeSends('progress', <String, Object?>{
        'id': id,
        'received': 1,
        'total': 10,
      });
      clock = clock.add(const Duration(seconds: 45));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transport.pendingIds, contains(id), reason: '45s < 60s 卡死预算');
      clock = clock.add(const Duration(seconds: 20));
      await expectLater(
        done,
        throwsA(
          isA<DioError>().having(
            (DioError e) => e.type,
            'type',
            DioErrorType.receiveTimeout,
          ),
        ),
      );
    });

    test('app 不在前台时看门狗暂停：挂起期间收不到进度不能算卡死', () async {
      final IosBackgroundDownloadTransport transport = newTransport();
      final Future<void> done = transport.download(
        url: 'https://example.com/a.zip',
        destPath: '/tmp/a.zip',
        onReceiveProgress: (_, _) {},
      );
      final String id = await startedId();
      foreground = false;
      clock = clock.add(const Duration(minutes: 30));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      foreground = true;
      clock = clock.add(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transport.pendingIds, contains(id));
      expect(calls.map((MethodCall c) => c.method), isNot(contains('cancel')));
      await nativeSends('complete', <String, Object?>{'id': id, 'error': null});
      await done;
    });
  });

  test('原生会话表达不了的代理（带认证）→ 退回进程内传输，不碰原生通道', () async {
    bool fallbackUsed = false;
    final IosBackgroundDownloadTransport transport = newTransport(
      proxy: null,
      fallback:
          ({
            required String url,
            required String destPath,
            required void Function(int, int) onReceiveProgress,
            CancelToken? cancelToken,
            DictionaryDownloadHandoff? handoff,
          }) async {
            fallbackUsed = true;
          },
    );
    await transport.download(
      url: 'https://example.com/a.zip',
      destPath: '/tmp/a.zip',
      onReceiveProgress: (_, _) {},
    );
    expect(fallbackUsed, isTrue);
    expect(calls, isEmpty);
  });

  test('本引擎没注册原生通道 → 退回进程内传输', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    int fallbackCount = 0;
    final IosBackgroundDownloadTransport transport = newTransport(
      fallback:
          ({
            required String url,
            required String destPath,
            required void Function(int, int) onReceiveProgress,
            CancelToken? cancelToken,
            DictionaryDownloadHandoff? handoff,
          }) async {
            fallbackCount++;
          },
    );
    await transport.download(
      url: 'https://example.com/a.zip',
      destPath: '/tmp/a.zip',
      onReceiveProgress: (_, _) {},
    );
    expect(fallbackCount, 1);
    expect(transport.pendingIds, isEmpty);
  });

  group('BUG-3887 续：进程被系统回收后接管在途任务', () {
    const DictionaryDownloadHandoff handoff = DictionaryDownloadHandoff(
      url: 'https://example.com/a.zip',
      candidates: <String>[
        'https://example.com/a.zip',
        'https://mirror.example/a.zip',
      ],
      candidateIndex: 1,
      destPath: '/tmp/a.zip',
      payload: <String, Object?>{'kind': 'dictionaryImport'},
    );

    Iterable<String> methods() => calls.map((MethodCall c) => c.method);
    Map<Object?, Object?> argsOf(String method) =>
        calls.lastWhere((MethodCall c) => c.method == method).arguments
            as Map<Object?, Object?>;

    Future<AdoptedDictionaryDownload> recoverOne(
      IosBackgroundDownloadTransport transport,
    ) async {
      replies['recover'] = <Object?>[
        <String, Object?>{'id': 'old-1', 'meta': jsonEncode(handoff.toJson())},
      ];
      final List<AdoptedDictionaryDownload> adopted = await transport.recover();
      expect(adopted, hasLength(1));
      return adopted.single;
    }

    test('带 handoff 发起：meta 交给原生注册表，结束后先 forget 再返回', () async {
      final IosBackgroundDownloadTransport transport = newTransport();
      final Future<void> done = transport.download(
        url: handoff.candidate,
        destPath: handoff.destPath,
        onReceiveProgress: (_, _) {},
        handoff: handoff,
      );
      final String id = await startedId();
      final Object? meta = argsOf('start')['meta'];
      expect(
        DictionaryDownloadHandoff.tryParse(
          jsonDecode(meta! as String),
        )?.candidateIndex,
        1,
      );
      await nativeSends('complete', <String, Object?>{'id': id, 'error': null});
      await done;
      expect(argsOf('forget')['id'], id);
    });

    test('不带 handoff 的下载不进注册表（没人能接）', () async {
      final IosBackgroundDownloadTransport transport = newTransport();
      final Future<void> done = transport.download(
        url: 'https://example.com/a.zip',
        destPath: '/tmp/a.zip',
        onReceiveProgress: (_, _) {},
      );
      final String id = await startedId();
      expect(argsOf('start').containsKey('meta'), isFalse);
      await nativeSends('complete', <String, Object?>{'id': id, 'error': null});
      await done;
      expect(methods(), isNot(contains('forget')));
    });

    test('重启后接管还在跑的任务：接上已收字节与后续进度，complete 后完成并释放记录', () async {
      final IosBackgroundDownloadTransport transport = newTransport();
      final AdoptedDictionaryDownload adopted = await recoverOne(transport);
      expect(adopted.handoff.candidate, 'https://mirror.example/a.zip');
      replies['attach'] = <String, Object?>{
        'state': 'running',
        'received': 300,
        'total': 1000,
      };
      final List<int> seen = <int>[];
      final Future<void> done = adopted.wait(
        onReceiveProgress: (int r, int t) => seen.add(r),
      );
      for (int i = 0; i < 20 && seen.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(argsOf('attach')['id'], 'old-1');
      await nativeSends('progress', <String, Object?>{
        'id': 'old-1',
        'received': 900,
        'total': 1000,
      });
      await nativeSends('complete', <String, Object?>{
        'id': 'old-1',
        'error': null,
      });
      await done;
      expect(seen, <int>[300, 900]);
      expect(argsOf('forget')['id'], 'old-1');
      expect(methods(), isNot(contains('start')), reason: '接管不是重新下载');
    });

    test('进程不在时已交付：attach 答 delivered，立即完成', () async {
      final IosBackgroundDownloadTransport transport = newTransport();
      final AdoptedDictionaryDownload adopted = await recoverOne(transport);
      replies['attach'] = <String, Object?>{'state': 'delivered'};
      await adopted.wait(onReceiveProgress: (_, _) {});
      expect(argsOf('forget')['id'], 'old-1');
      expect(transport.pendingIds, isEmpty);
    });

    test('进程不在时已失败：原样翻译成同类型 DioError（镜像回退照常判）', () async {
      final IosBackgroundDownloadTransport transport = newTransport();
      final AdoptedDictionaryDownload adopted = await recoverOne(transport);
      replies['attach'] = <String, Object?>{
        'state': 'failed',
        'error': <String, Object?>{'kind': 'connection'},
      };
      Object? error;
      try {
        await adopted.wait(onReceiveProgress: (_, _) {});
      } catch (e) {
        error = e;
      }
      expect(isDictionaryTransportFailure(error!), isTrue);
    });

    test('真孤儿：记录解析不出接管描述 → 当场 discard，不交给上层', () async {
      final IosBackgroundDownloadTransport transport = newTransport();
      replies['recover'] = <Object?>[
        <String, Object?>{'id': 'bad-1', 'meta': 'not json'},
        <String, Object?>{'id': 'bad-2', 'meta': '{"url": 1}'},
      ];
      expect(await transport.recover(), isEmpty);
      expect(
        calls
            .where((MethodCall c) => c.method == 'discard')
            .map(
              (MethodCall c) => (c.arguments as Map<Object?, Object?>)['id'],
            ),
        <String>['bad-1', 'bad-2'],
      );
    });

    test('没人要的接管任务：discard 交给原生（取消 + 删已交付文件）', () async {
      final IosBackgroundDownloadTransport transport = newTransport();
      final AdoptedDictionaryDownload adopted = await recoverOne(transport);
      await adopted.discard();
      expect(argsOf('discard')['id'], 'old-1');
    });

    test('本引擎没注册原生通道：没有可接管的下载', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await newTransport().recover(), isEmpty);
    });
  });

  group('代理裁决 → 原生会话配置', () {
    test('自动 → 系统代理；直连 → 直连', () {
      expect(
        iosBackgroundDownloadProxyFor(
          mode: kProxyModeAuto,
          proxy: '',
          username: '',
        ),
        IosBackgroundDownloadProxy.system,
      );
      expect(
        iosBackgroundDownloadProxyFor(
          mode: kProxyModeDirect,
          proxy: '127.0.0.1:7890',
          username: '',
        ),
        IosBackgroundDownloadProxy.direct,
      );
    });

    test('手动 → 归一后的 host:port；非法地址与 dio 侧一样安全直连', () {
      expect(
        iosBackgroundDownloadProxyFor(
          mode: kProxyModeManual,
          proxy: 'http://proxy.lan:8080',
          username: '',
        ),
        IosBackgroundDownloadProxy.manual('proxy.lan', 8080),
      );
      expect(
        iosBackgroundDownloadProxyFor(
          mode: kProxyModeManual,
          proxy: 'not a proxy',
          username: '',
        ),
        IosBackgroundDownloadProxy.direct,
      );
    });

    test('手动 + 认证 → null（后台会话应答不了 407）', () {
      expect(
        iosBackgroundDownloadProxyFor(
          mode: kProxyModeManual,
          proxy: 'proxy.lan:8080',
          username: 'me',
        ),
        isNull,
      );
    });
  });
}
