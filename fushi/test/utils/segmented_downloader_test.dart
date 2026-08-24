import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/download_plan.dart';
import 'package:fushi/src/utils/misc/resumable_downloader.dart';
import 'package:fushi/src/utils/misc/segmented_downloader.dart';

/// 假服务器：按 URL 路由资源，支持 Range，可注入「忽略 Range」「超发字节」「404」
/// 「首字节后断流」等真实世界里会遇到的坏行为。
class _FakeHost {
  _FakeHost();

  final Map<String, Uint8List> resources = <String, Uint8List>{};

  /// 这些 URL 一律 404（模拟镜像挂掉）。
  final Set<String> dead = <String>{};

  /// 这些 URL 忽略 Range，永远从第 0 字节回 200。
  final Set<String> ignoresRange = <String>{};

  /// 这些 URL 回 206 但多发字节（发到资源结尾），考验「取够就断」。
  final Set<String> overSends = <String>{};

  /// 这些 URL 回 206 但不带 Content-Range（畸形响应）。
  final Set<String> omitsContentRange = <String>{};

  /// 每个 URL 收到的 Range 头，按序记录。
  final List<MapEntry<String, String?>> requests =
      <MapEntry<String, String?>>[];

  String etag = '"v1"';
  int chunkSize = 7;

  /// 已开始但被调用方主动取消的响应数——用来证明「整包 body 没有被读完」。
  int cancelledStreams = 0;

  /// 实际投递出去的字节总数。若下载器不在取够时断连，忽略 range-end 的服务器会让
  /// **每一片**都把整包读完，这个数会翻成 N 倍——这是分片下载最贵的失效方式。
  int deliveredBytes = 0;

  Future<ResumableDownloadResponse> open(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final String url = uri.toString();
    final String? range = headers['range'] ?? headers['Range'];
    requests.add(MapEntry<String, String?>(url, range));

    if (dead.contains(url)) {
      return ResumableDownloadResponse.bytes(
        statusCode: 404,
        body: const <int>[],
      );
    }
    final Uint8List? body = resources[url];
    if (body == null) {
      return ResumableDownloadResponse.bytes(
        statusCode: 404,
        body: const <int>[],
      );
    }

    if (range == null || ignoresRange.contains(url)) {
      return ResumableDownloadResponse(
        statusCode: 200,
        headers: <String, String>{
          'etag': etag,
          'content-length': '${body.length}',
        },
        stream: _chunked(body, 0, body.length),
      );
    }

    final RegExpMatch match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
    final int start = int.parse(match.group(1)!);
    final int end = match.group(2)!.isEmpty
        ? body.length - 1
        : math.min(int.parse(match.group(2)!), body.length - 1);
    final int sendEnd = overSends.contains(url) ? body.length - 1 : end;
    return ResumableDownloadResponse(
      statusCode: 206,
      headers: <String, String>{
        'etag': etag,
        if (!omitsContentRange.contains(url))
          'content-range': 'bytes $start-$end/${body.length}',
      },
      stream: _chunked(body, start, sendEnd + 1),
    );
  }

  /// 分块投递，**遵守背压**：订阅被 pause（`await for` 的循环体正在跑）时停止投递，
  /// resume 后继续，cancel 后彻底停。真实 HTTP 流就是这样——消费端不读，服务端就
  /// 不会继续往下发。假服务器若无脑往缓冲区猛塞，[deliveredBytes] 量到的是生产者
  /// 而不是真实网络消耗，「取够就断」这类带宽断言会变成空的。
  Stream<List<int>> _chunked(Uint8List body, int start, int endExclusive) {
    final StreamController<List<int>> controller =
        StreamController<List<int>>();
    bool cancelled = false;
    Completer<void>? paused;

    controller.onPause = () => paused ??= Completer<void>();
    controller.onResume = () {
      paused?.complete();
      paused = null;
    };
    controller.onCancel = () {
      if (!cancelled) {
        cancelled = true;
        cancelledStreams += 1;
      }
      paused?.complete();
      paused = null;
    };
    controller.onListen = () async {
      int at = start;
      while (at < endExclusive && !cancelled) {
        final Completer<void>? gate = paused;
        if (gate != null) {
          await gate.future;
          continue;
        }
        final int stop = math.min(at + chunkSize, endExclusive);
        controller.add(body.sublist(at, stop));
        deliveredBytes += stop - at;
        at = stop;
        // 让出事件循环，使取消/暂停/并发调度有机会发生。
        await Future<void>.delayed(Duration.zero);
      }
      if (!cancelled) await controller.close();
    };
    return controller.stream;
  }
}

Uint8List _payload(int length) {
  final Uint8List bytes = Uint8List(length);
  for (int i = 0; i < length; i++) {
    bytes[i] = (i * 31 + 7) & 0xff;
  }
  return bytes;
}

String _sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('segmented_dl_test');
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发占用，不影响断言。
    }
  });

  File dest() => File('${tmp.path}/pack.zip');
  File part() => File('${tmp.path}/pack.zip.mpart');
  File progress() => File('${tmp.path}/pack.zip.mpart.json');

  SegmentedDownloader build(
    DownloadPlan plan,
    _FakeHost host, {
    int concurrency = 4,
    bool Function()? isCancelled,
    int maxAttemptsPerPart = 3,
    Duration Function(int attempt)? retryBackoff,
  }) =>
      SegmentedDownloader(
        plan: plan,
        destination: dest(),
        partFile: part(),
        progressFile: progress(),
        open: host.open,
        concurrency: concurrency,
        maxAttemptsPerPart: maxAttemptsPerPart,
        isCancelled: isCancelled,
        flushInterval: 64,
        // 单测不空等真实退避。
        retryBackoff: retryBackoff ?? (int _) => Duration.zero,
      );

  group('平台前提', () {
    test('FileMode.append + setPosition 必须是随机写，不是强制追加', () async {
      // 分片并发写盘的**全部正确性**都压在这条语义上：`write` 会截断已下内容，只有
      // `append` 既不截断又能 setPosition 随机写。某个平台若按 O_APPEND 语义把写
      // 强行落到文件末尾，9.5 GB 会被写成乱序垃圾、且只有最后 sha256 才发现。
      // 这条守卫让那种平台在 CI 上当场红。
      final File f = File('${tmp.path}/probe.bin');
      RandomAccessFile raf = await f.open(mode: FileMode.write);
      await raf.writeFrom(List<int>.filled(16, 0x41));
      await raf.close();

      raf = await f.open(mode: FileMode.append);
      await raf.setPosition(4);
      await raf.writeFrom(List<int>.filled(4, 0x42));
      await raf.close();

      final List<int> bytes = f.readAsBytesSync();
      expect(bytes.length, 16, reason: 'append 不该改变文件长度');
      expect(bytes.sublist(4, 8), <int>[0x42, 0x42, 0x42, 0x42],
          reason: 'setPosition 指定的偏移必须被真正写到');
      expect(bytes.sublist(8), List<int>.filled(8, 0x41), reason: '不得越界覆盖后续字节');
    });

    test('truncate 能把新文件预分配到指定大小', () async {
      final File f = File('${tmp.path}/prealloc.bin');
      final RandomAccessFile raf = await f.open(mode: FileMode.write);
      await raf.truncate(4096);
      await raf.close();
      expect(f.lengthSync(), 4096);
    });
  });

  group('并发分片下载', () {
    test('多片并发下完的字节与原文件逐字节一致', () async {
      final Uint8List body = _payload(1000);
      final _FakeHost host = _FakeHost()
        ..resources['https://a/pack.zip'] = body;
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://a/pack.zip'],
        totalBytes: body.length,
        partSize: 100,
        sha256: _sha256Of(body),
      );
      expect(plan.parts.length, 10);

      final File out = await build(plan, host).download();

      expect(out.readAsBytesSync(), body);
      expect(part().existsSync(), isFalse, reason: '半截文件应已改名');
      expect(progress().existsSync(), isFalse, reason: '进度文件应随完成删除');
    });

    test('并发度不超过片数，且每片只请求自己的区间', () async {
      final Uint8List body = _payload(300);
      final _FakeHost host = _FakeHost()
        ..resources['https://a/pack.zip'] = body;
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://a/pack.zip'],
        totalBytes: body.length,
        partSize: 100,
      );

      await build(plan, host, concurrency: 8).download();

      expect(host.requests.length, 3);
      final Set<String?> ranges =
          host.requests.map((MapEntry<String, String?> e) => e.value).toSet();
      expect(
        ranges,
        <String>{'bytes=0-99', 'bytes=100-199', 'bytes=200-299'},
      );
    });

    test('进度回调单调递增并终于总字节', () async {
      final Uint8List body = _payload(500);
      final _FakeHost host = _FakeHost()
        ..resources['https://a/pack.zip'] = body;
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://a/pack.zip'],
        totalBytes: body.length,
        partSize: 125,
      );
      final List<int> seen = <int>[];
      await SegmentedDownloader(
        plan: plan,
        destination: dest(),
        partFile: part(),
        progressFile: progress(),
        open: host.open,
        onProgress: (int received, int total) {
          expect(total, body.length);
          seen.add(received);
        },
      ).download();

      expect(seen, isNotEmpty);
      expect(seen.last, body.length);
      for (int i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
    });
  });

  group('镜像与坏服务器', () {
    test('镜像 404 时自动轮换到下一个来源', () async {
      final Uint8List body = _payload(200);
      final _FakeHost host = _FakeHost()
        ..resources['https://good/pack.zip'] = body
        ..dead.add('https://dead/pack.zip');
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://dead/pack.zip', 'https://good/pack.zip'],
        totalBytes: body.length,
        partSize: 100,
      );

      final File out = await build(plan, host).download();

      expect(out.readAsBytesSync(), body);
      expect(
        host.requests.any(
            (MapEntry<String, String?> e) => e.key == 'https://dead/pack.zip'),
        isTrue,
        reason: '首选来源应被试过',
      );
    });

    test('多源时首轮就摊到所有来源，而不是全压首选源', () async {
      // 「GitHub 放切片、CF 放整包」要真的并拉，前提是并发的各片**首轮**就分散到
      // 不同来源。只按 attempt 取模会让首轮全部打 sources[0]，第二个源沦为纯故障
      // 转移——带宽只吃一家、另一家永远闲着。这条断言钉死那个退化。
      final Uint8List body = _payload(400);
      final _FakeHost host = _FakeHost()
        ..resources['https://cf/pack.zip'] = body
        ..resources['https://gh/pack.zip'] = body;
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://cf/pack.zip', 'https://gh/pack.zip'],
        totalBytes: body.length,
        partSize: 100,
      );

      final File out = await build(plan, host).download();

      expect(out.readAsBytesSync(), body);
      int hits(String url) => host.requests
          .where((MapEntry<String, String?> e) => e.key == url)
          .length;
      // 两个源都活着，4 片应当各取一次、零重试；否则下面的分布断言就失去意义。
      expect(host.requests.length, 4, reason: '不该出现失败重试');
      expect(hits('https://cf/pack.zip'), 2);
      expect(
        hits('https://gh/pack.zip'),
        2,
        reason: '第二个来源必须真的分到片，而不是只在故障时才顶上',
      );
    });
    test('切片来源忽略 Range（回 200）时按整片重写，结果仍正确', () async {
      // 物理切片：URL 指向的就是这一片，200 回的整个 body 正好是本片内容。
      final Uint8List body = _payload(240);
      final _FakeHost host = _FakeHost()
        ..resources['https://s/part-0'] = Uint8List.sublistView(body, 0, 120)
        ..resources['https://s/part-1'] = Uint8List.sublistView(body, 120, 240)
        ..ignoresRange.addAll(<String>['https://s/part-0', 'https://s/part-1']);
      final DownloadPlan plan = DownloadPlan(
        totalBytes: 240,
        parts: const <DownloadPart>[
          DownloadPart(
            index: 0,
            offset: 0,
            length: 120,
            sources: <DownloadSource>[
              DownloadSource(url: 'https://s/part-0'),
            ],
          ),
          DownloadPart(
            index: 1,
            offset: 120,
            length: 120,
            sources: <DownloadSource>[
              DownloadSource(url: 'https://s/part-1'),
            ],
          ),
        ],
      );

      final File out = await build(plan, host).download();
      expect(out.readAsBytesSync(), body);
    });

    test('整包来源忽略 Range 时必须断连换源，绝不消费整包', () async {
      // 这是最贵的坏行为：整包来源回 200 意味着 body 是整个 9.5 GB。若照单全收，
      // 每一片都会把整包下一遍。要求：立刻断连（cancelledStreams 增加）并换源。
      final Uint8List body = _payload(300);
      final _FakeHost host = _FakeHost()
        ..resources['https://bad/pack.zip'] = body
        ..resources['https://good/pack.zip'] = body
        ..ignoresRange.add('https://bad/pack.zip');
      final DownloadPlan plan = DownloadPlan(
        totalBytes: 300,
        parts: const <DownloadPart>[
          // 只造一片且偏移 > 0，好让「整包来源」的判定生效。
          DownloadPart(
            index: 0,
            offset: 0,
            length: 100,
            sources: <DownloadSource>[
              DownloadSource(url: 'https://good/pack.zip', remoteOffset: 0),
            ],
          ),
          DownloadPart(
            index: 1,
            offset: 100,
            length: 200,
            sources: <DownloadSource>[
              DownloadSource(url: 'https://bad/pack.zip', remoteOffset: 100),
              DownloadSource(url: 'https://good/pack.zip', remoteOffset: 100),
            ],
          ),
        ],
      );

      final File out = await build(plan, host).download();

      expect(out.readAsBytesSync(), body, reason: '换源后内容必须正确');
      expect(host.cancelledStreams, greaterThan(0),
          reason: '忽略 Range 的整包响应必须被断连，而不是读完');
    });

    test('206 缺 Content-Range 视为畸形响应，换源而不是照写', () async {
      final Uint8List body = _payload(200);
      final _FakeHost host = _FakeHost()
        ..resources['https://weird/pack.zip'] = body
        ..resources['https://good/pack.zip'] = body
        ..omitsContentRange.add('https://weird/pack.zip');
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://weird/pack.zip', 'https://good/pack.zip'],
        totalBytes: body.length,
        partSize: 100,
      );

      final File out = await build(plan, host).download();
      expect(out.readAsBytesSync(), body);
    });

    test('服务器忽略 range-end 时取够即断，不让每片都把整包读完', () async {
      // 最贵的失效方式：服务器认 range 起点但一路发到 EOF。若不在取够时断连，
      // 3 片会各自读到文件尾 = 600 字节（9.5 GB 的包就是每片下整包）。
      final Uint8List body = _payload(300);
      final _FakeHost host = _FakeHost()
        ..resources['https://over/pack.zip'] = body
        ..overSends.add('https://over/pack.zip');
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://over/pack.zip'],
        totalBytes: body.length,
        partSize: 100,
      );

      final File out = await build(plan, host).download();

      expect(out.readAsBytesSync(), body);
      expect(out.lengthSync(), 300, reason: '超发不得把文件撑大');
      expect(
        host.deliveredBytes,
        lessThan(400),
        reason: '取够就该断连；读满 600 说明每片都把整包读完了',
      );
    });

    test('切片源比声明的片长时不得写过界（末片超发会把文件撑大）', () async {
      // 切片资源自身比清单声明的 length 长（上传错版本 / 服务端拼接错）。写过界
      // 会把预分配好的目标文件撑大，成品就不再是原文件。
      final Uint8List body = _payload(200);
      final Uint8List longTail = Uint8List(80)
        ..setRange(0, 50, body.sublist(150, 200))
        ..fillRange(50, 80, 0xee);
      final _FakeHost host = _FakeHost()
        ..resources['https://s/part-0'] = Uint8List.sublistView(body, 0, 150)
        ..resources['https://s/part-1'] = longTail
        // 切片源忽略 Range（回 200 整个资源）——只有这样才会真的超发；老实响应
        // Range 的切片源永远只发被要的那段，测不到写过界。
        ..ignoresRange.add('https://s/part-1');
      final DownloadPlan plan = DownloadPlan(
        totalBytes: 200,
        parts: const <DownloadPart>[
          DownloadPart(
            index: 0,
            offset: 0,
            length: 150,
            sources: <DownloadSource>[
              DownloadSource(url: 'https://s/part-0'),
            ],
          ),
          DownloadPart(
            index: 1,
            offset: 150,
            length: 50,
            sources: <DownloadSource>[
              DownloadSource(url: 'https://s/part-1'),
            ],
          ),
        ],
      );

      final File out = await build(plan, host).download();

      expect(out.lengthSync(), 200, reason: '成品长度必须等于计划总长');
      expect(out.readAsBytesSync(), body);
    });

    test('换源之间按 attempt 退避，最后一次失败后不再空等', () async {
      // 背靠背重试三次在抖动的移动网络上基本是三次一起失败；退避得真的被调用，
      // 且不该在「已经没有下一次」之后还等一轮。
      final _FakeHost host = _FakeHost()..dead.add('https://dead/pack.zip');
      final List<int> attempts = <int>[];
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://dead/pack.zip'],
        totalBytes: 100,
        partSize: 100,
      );

      await expectLater(
        build(
          plan,
          host,
          maxAttemptsPerPart: 3,
          retryBackoff: (int attempt) {
            attempts.add(attempt);
            return Duration.zero;
          },
        ).download(),
        throwsA(isA<SegmentedDownloadPartException>()),
      );

      expect(attempts, <int>[0, 1], reason: '3 次尝试之间只有 2 段等待，末次失败后直接报错');
    });

    test('所有来源都挂时抛 SegmentedDownloadPartException 且不产出成品', () async {
      final _FakeHost host = _FakeHost()..dead.add('https://dead/pack.zip');
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://dead/pack.zip'],
        totalBytes: 200,
        partSize: 100,
      );

      await expectLater(
        build(plan, host).download(),
        throwsA(isA<SegmentedDownloadPartException>()),
      );
      expect(dest().existsSync(), isFalse);
    });
  });

  group('断点续传', () {
    test('中断后重跑只补未完成的片', () async {
      final Uint8List body = _payload(400);
      final _FakeHost first = _FakeHost()
        ..resources['https://a/pack.zip'] = body
        // 后两片的来源挂掉，前两片能下完。
        ..dead.add('https://b/pack.zip');
      final DownloadPlan plan = DownloadPlan(
        totalBytes: 400,
        version: 'v1',
        parts: const <DownloadPart>[
          DownloadPart(
            index: 0,
            offset: 0,
            length: 100,
            sources: <DownloadSource>[
              DownloadSource(url: 'https://a/pack.zip', remoteOffset: 0),
            ],
          ),
          DownloadPart(
            index: 1,
            offset: 100,
            length: 100,
            sources: <DownloadSource>[
              DownloadSource(url: 'https://a/pack.zip', remoteOffset: 100),
            ],
          ),
          DownloadPart(
            index: 2,
            offset: 200,
            length: 100,
            sources: <DownloadSource>[
              DownloadSource(url: 'https://b/pack.zip', remoteOffset: 200),
            ],
          ),
          DownloadPart(
            index: 3,
            offset: 300,
            length: 100,
            sources: <DownloadSource>[
              DownloadSource(url: 'https://b/pack.zip', remoteOffset: 300),
            ],
          ),
        ],
      );

      await expectLater(
        build(plan, first, concurrency: 1).download(),
        throwsA(isA<SegmentedDownloadPartException>()),
      );
      expect(progress().existsSync(), isTrue, reason: '进度必须留下供续传');
      expect(part().lengthSync(), 400, reason: '半截文件是预分配的完整大小');

      // 第二轮：全部来源健康。
      final _FakeHost second = _FakeHost()
        ..resources['https://a/pack.zip'] = body
        ..resources['https://b/pack.zip'] = body;
      final DownloadPlan plan2 = DownloadPlan(
        totalBytes: 400,
        version: 'v1',
        parts: plan.parts,
      );

      final File out = await build(plan2, second, concurrency: 1).download();

      expect(out.readAsBytesSync(), body);
      final Set<String?> retried =
          second.requests.map((MapEntry<String, String?> e) => e.value).toSet();
      expect(retried.contains('bytes=0-99'), isFalse,
          reason: '第 0 片上一轮已完成，不该重下');
      expect(retried.contains('bytes=100-199'), isFalse,
          reason: '第 1 片上一轮已完成，不该重下');
    });

    test('计划版本变了（服务端换包）时进度整份作废', () async {
      final Uint8List body = _payload(200);
      final _FakeHost host = _FakeHost()
        ..resources['https://a/pack.zip'] = body;
      // 预置一份「旧包」的进度。
      progress().writeAsStringSync(json.encode(<String, Object?>{
        'version': 1,
        'totalBytes': 200,
        'planVersion': 'OLD',
        'sha256': null,
        'parts': <String, int>{'0': 100},
      }));

      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://a/pack.zip'],
        totalBytes: 200,
        partSize: 100,
        version: 'NEW',
      );
      final File out = await build(plan, host).download();

      expect(out.readAsBytesSync(), body);
      final Set<String?> ranges =
          host.requests.map((MapEntry<String, String?> e) => e.value).toSet();
      expect(ranges.contains('bytes=0-99'), isTrue,
          reason: '换包后第 0 片必须重下，不能把旧包字节当断点');
    });
  });

  group('完整性', () {
    test('单片 sha256 不符时清零该片并最终失败，不产出成品', () async {
      final Uint8List body = _payload(200);
      final _FakeHost host = _FakeHost()
        ..resources['https://a/pack.zip'] = body;
      final DownloadPlan plan = DownloadPlan(
        totalBytes: 200,
        parts: <DownloadPart>[
          DownloadPart(
            index: 0,
            offset: 0,
            length: 100,
            sha256: _sha256Of(body.sublist(0, 100)),
            sources: const <DownloadSource>[
              DownloadSource(url: 'https://a/pack.zip', remoteOffset: 0),
            ],
          ),
          DownloadPart(
            index: 1,
            offset: 100,
            length: 100,
            // 故意写错的摘要。
            sha256: 'f' * 64,
            sources: const <DownloadSource>[
              DownloadSource(url: 'https://a/pack.zip', remoteOffset: 100),
            ],
          ),
        ],
      );

      await expectLater(
        build(plan, host).download(),
        throwsA(isA<SegmentedDownloadPartException>()),
      );
      expect(dest().existsSync(), isFalse);
    });

    test('整包 sha256 不符时删档并抛完整性异常', () async {
      final Uint8List body = _payload(200);
      final _FakeHost host = _FakeHost()
        ..resources['https://a/pack.zip'] = body;
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://a/pack.zip'],
        totalBytes: 200,
        partSize: 100,
        sha256: 'a' * 64,
      );

      await expectLater(
        build(plan, host).download(),
        throwsA(isA<ResumableDownloadIntegrityException>()),
      );
      expect(dest().existsSync(), isFalse);
      expect(part().existsSync(), isFalse, reason: '坏包不留');
      expect(progress().existsSync(), isFalse);
    });

    test('每片都带摘要时跳过整包重读（逐片校验已更强）', () async {
      final Uint8List body = _payload(200);
      final _FakeHost host = _FakeHost()
        ..resources['https://a/pack.zip'] = body;
      final DownloadPlan plan = DownloadPlan(
        totalBytes: 200,
        // 整包摘要故意写错：逐片摘要全对时不该再读一遍 9.5 GB 去核它。
        sha256: 'b' * 64,
        parts: <DownloadPart>[
          DownloadPart(
            index: 0,
            offset: 0,
            length: 100,
            sha256: _sha256Of(body.sublist(0, 100)),
            sources: const <DownloadSource>[
              DownloadSource(url: 'https://a/pack.zip', remoteOffset: 0),
            ],
          ),
          DownloadPart(
            index: 1,
            offset: 100,
            length: 100,
            sha256: _sha256Of(body.sublist(100, 200)),
            sources: const <DownloadSource>[
              DownloadSource(url: 'https://a/pack.zip', remoteOffset: 100),
            ],
          ),
        ],
      );

      final File out = await build(plan, host).download();
      expect(out.readAsBytesSync(), body);
    });
  });

  group('取消', () {
    test('取消时抛取消异常、保留半截与进度、不产出成品', () async {
      final Uint8List body = _payload(1000);
      final _FakeHost host = _FakeHost()
        ..resources['https://a/pack.zip'] = body;
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://a/pack.zip'],
        totalBytes: body.length,
        partSize: 100,
      );
      bool cancelled = false;
      final Future<File> future = build(
        plan,
        host,
        concurrency: 1,
        isCancelled: () => cancelled,
      ).download();
      // 让第一片开跑再取消。
      await Future<void>.delayed(const Duration(milliseconds: 5));
      cancelled = true;

      await expectLater(
        future,
        throwsA(isA<SegmentedDownloadCancelledException>()),
      );
      expect(dest().existsSync(), isFalse);
      expect(part().existsSync(), isTrue, reason: '半截保留供下次续传');
    });
  });

  group('已完成', () {
    test('成品已存在时直接返回，不发任何请求', () async {
      final Uint8List body = _payload(100);
      dest().writeAsBytesSync(body);
      final _FakeHost host = _FakeHost()
        ..resources['https://a/pack.zip'] = body;
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://a/pack.zip'],
        totalBytes: body.length,
        partSize: 50,
      );

      final File out = await build(plan, host).download();

      expect(out.path, dest().path);
      expect(host.requests, isEmpty);
    });
  });
}
