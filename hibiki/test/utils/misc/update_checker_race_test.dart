import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

/// TODO-683：候选并发竞速选源 + 首字节超时 + Step1 connecting 文案。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  group('selectRaceWinnerUrl (纯函数：胜出裁决 + tie-break 直连优先)', () {
    UpdateProbeOutcome outcome(
      String url, {
      required int? total,
      required int ms,
      required bool direct,
    }) =>
        UpdateProbeOutcome(
          url: url,
          total: total,
          elapsed: Duration(milliseconds: ms),
          isDirect: direct,
        );

    test('空列表 → null', () {
      expect(selectRaceWinnerUrl(const <UpdateProbeOutcome>[]), isNull);
    });

    test('单个 eligible → 直接胜出', () {
      final String? winner = selectRaceWinnerUrl(<UpdateProbeOutcome>[
        outcome('m1', total: 100, ms: 30, direct: false),
      ]);
      expect(winner, 'm1');
    });

    test('多镜像取首字节最快者', () {
      final String? winner = selectRaceWinnerUrl(<UpdateProbeOutcome>[
        outcome('slow', total: 100, ms: 200, direct: false),
        outcome('fast', total: 100, ms: 40, direct: false),
        outcome('mid', total: 100, ms: 90, direct: false),
      ]);
      expect(winner, 'fast');
    });

    test('直连在最快镜像 +500ms 窗口内到 → tie-break 选直连', () {
      final String? winner = selectRaceWinnerUrl(<UpdateProbeOutcome>[
        outcome('mirror', total: 100, ms: 40, direct: false),
        // 直连 40+400=440ms ≤ 40+500 窗口内 → 直连优先。
        outcome('direct', total: 100, ms: 440, direct: true),
      ]);
      expect(winner, 'direct', reason: '直连近乎同时到（窗口内）应优先（net.dart 直连恒首位哲学）');
    });

    test('直连明显慢于最快镜像（超出窗口）→ 选镜像', () {
      final String? winner = selectRaceWinnerUrl(<UpdateProbeOutcome>[
        outcome('mirror', total: 100, ms: 40, direct: false),
        // 直连 600ms > 40+500 窗口 → 不 tie-break，选快镜像。
        outcome('direct', total: 100, ms: 600, direct: true),
      ]);
      expect(winner, 'mirror');
    });

    test('最快候选本就是直连 → 直接选直连', () {
      final String? winner = selectRaceWinnerUrl(<UpdateProbeOutcome>[
        outcome('direct', total: 100, ms: 30, direct: true),
        outcome('mirror', total: 100, ms: 90, direct: false),
      ]);
      expect(winner, 'direct');
    });
  });

  group('reorderCandidatesByRaceWinner (纯函数：胜出提首位、其余原序、不删减)', () {
    test('胜出镜像提首位，其余保持原相对顺序', () {
      final List<String> reordered = reorderCandidatesByRaceWinner(
        <String>['direct', 'm1', 'm2', 'm3'],
        'm2',
      );
      expect(reordered, <String>['m2', 'direct', 'm1', 'm3']);
    });

    test('胜出已是首位 → 列表不变', () {
      final List<String> reordered = reorderCandidatesByRaceWinner(
        <String>['direct', 'm1', 'm2'],
        'direct',
      );
      expect(reordered, <String>['direct', 'm1', 'm2']);
    });

    test('胜出 url 不在列表里 → 原样返回（防御）', () {
      final List<String> reordered = reorderCandidatesByRaceWinner(
        <String>['a', 'b'],
        'zzz',
      );
      expect(reordered, <String>['a', 'b']);
    });

    test('竞速不删减：重排后仍含全部候选（保换源能力）', () {
      final List<String> input = <String>['direct', 'm1', 'm2', 'm3'];
      final List<String> reordered = reorderCandidatesByRaceWinner(input, 'm3');
      expect(reordered.toSet(), input.toSet());
      expect(reordered.length, input.length);
    });
  });

  group('raceSelectFastestCandidate (并发探针)', () {
    test('单候选 → 返回 null（退化为现有单候选行为，不并发）', () async {
      var probeCount = 0;
      final List<String>? result = await raceSelectFastestCandidate(
        candidateUrls: <String>['only'],
        directUrl: 'only',
        openUrl: (Uri _, Map<String, String> __) async {
          probeCount += 1;
          return _probe206(100);
        },
      );
      expect(result, isNull, reason: 'length==1 必须退化、绝不发竞速探针');
      expect(probeCount, 0);
    });

    test('竞速选最快：不同延迟的 206，最快返回者下载', () async {
      const String direct =
          'https://github.com/x/y/releases/download/v1/app.exe';
      const String mirrorFast = 'https://fast.example/$direct';
      const String mirrorSlow = 'https://slow.example/$direct';

      final List<String>? result = await raceSelectFastestCandidate(
        candidateUrls: <String>[direct, mirrorFast, mirrorSlow],
        directUrl: direct,
        openUrl: (Uri uri, Map<String, String> headers) async {
          // 三源延迟：direct 很慢、mirrorFast 最快、mirrorSlow 慢。
          if (uri.host == 'fast.example') {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return _probe206(1000);
          }
          if (uri.host == 'slow.example') {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return _probe206(1000);
          }
          // 直连：明显慢于最快镜像（超出 tie-break 窗口）。
          await Future<void>.delayed(const Duration(milliseconds: 900));
          return _probe206(1000);
        },
      );

      expect(result, isNotNull);
      expect(result!.first, mirrorFast, reason: '最快返 206 者提首位');
      // 不删减：仍含全部候选。
      expect(result.toSet(), <String>{direct, mirrorFast, mirrorSlow});
    });

    test('落败/坏候选被 drain：无 uncaught error、无未消费 Stream 告警（R1）', () async {
      const String direct =
          'https://github.com/x/y/releases/download/v1/app.exe';
      const String good = 'https://good.example/$direct';
      const String bad = 'https://bad.example/$direct';

      // bad 源返回一个「会在 drain 时断流抛错」的 206 stream：若未被 try/catch 包裹的
      // drain 吞掉，会在 settle 后变后台 uncaught error，flutter_test 会把它判为失败。
      final List<String>? result = await raceSelectFastestCandidate(
        candidateUrls: <String>[direct, good, bad],
        directUrl: direct,
        openUrl: (Uri uri, Map<String, String> headers) async {
          if (uri.host == 'good.example') {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return _probe206(1000);
          }
          if (uri.host == 'bad.example') {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return _probe206ThatErrorsOnDrain(1000);
          }
          // 直连慢，超窗口，确保 good 胜出，bad 成落败被 drain。
          await Future<void>.delayed(const Duration(milliseconds: 800));
          return _probe206(1000);
        },
      );

      expect(result, isNotNull);
      expect(result!.first, good);
      // 给后台 drain 充分时间触发坏镜像的断流错误。drainQuietly 用 try/catch 吞掉它；
      // 若未吞，这个错误会在 settle 后冒泡成 uncaught，flutter_test 会自动把本测试判失败。
      // 故「测试能正常结束、不红」本身就是 R1 取消语义的守卫。
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });

    test('全部探针失败（非 206）→ 返回 null（退串行循环）', () async {
      final List<String>? result = await raceSelectFastestCandidate(
        candidateUrls: <String>['a', 'b', 'c'],
        directUrl: 'a',
        openUrl: (Uri _, Map<String, String> __) async {
          // 全返 200（源忽略 Range）→ 无 eligible。
          return UpdateDownloadResponse(
            statusCode: HttpStatus.ok,
            headers: const <String, String>{},
            stream: Stream<List<int>>.value(<int>[1, 2, 3]),
          );
        },
      );
      expect(result, isNull);
    });

    test('探针拿不到总大小（Content-Range 缺失）→ 不 eligible → null', () async {
      final List<String>? result = await raceSelectFastestCandidate(
        candidateUrls: <String>['a', 'b'],
        directUrl: 'a',
        openUrl: (Uri _, Map<String, String> __) async {
          // 206 但无 Content-Range → 拿不到 total → 不具胜出资格。
          return UpdateDownloadResponse(
            statusCode: HttpStatus.partialContent,
            headers: const <String, String>{},
            stream: Stream<List<int>>.value(<int>[1, 2, 3]),
          );
        },
      );
      expect(result, isNull);
    });

    test('首字节超时：永不返首字节的坏候选 ~5s 判死、不吃 15s（fakeAsync）', () {
      fakeAsync((FakeAsync async) {
        const String direct = 'https://direct.example/app';
        const String hang = 'https://hang.example/app';
        List<String>? result;
        var completed = false;

        raceSelectFastestCandidate(
          candidateUrls: <String>[direct, hang],
          directUrl: direct,
          openUrl: (Uri uri, Map<String, String> headers) {
            if (uri.host == 'hang.example') {
              // 永不完成 → 必须被 _kFirstByteTimeout(5s) 判死。
              return Completer<UpdateDownloadResponse>().future;
            }
            // 直连同样永不返首字节 → 整体在 5s 后全失败返 null。
            return Completer<UpdateDownloadResponse>().future;
          },
        ).then((List<String>? r) {
          result = r;
          completed = true;
        });

        // 推进 4.9s：还没到首字节超时，未完成。
        async.elapse(const Duration(milliseconds: 4900));
        expect(completed, isFalse, reason: '5s 前不该判死');
        // 推进过 5s：探针首字节超时触发，全失败 → null。
        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();
        expect(completed, isTrue, reason: '~5s 判死而非 15s');
        expect(result, isNull);
      });
    });
  });

  group('UpdateDownloadStatusController (Step1：connecting → downloading)', () {
    testWidgets('首信号前显 connecting、首个非零信号后翻 downloading', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<String> status =
          ValueNotifier<String>(t.update_connecting);
      addTearDown(status.dispose);
      final UpdateDownloadStatusController controller =
          UpdateDownloadStatusController(status);

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (_, String s, __) => Text(s),
              ),
            ),
          ),
        ),
      );

      // 首信号前：connecting 可见、downloading 不可见。
      expect(find.text(t.update_connecting), findsOneWidget);
      expect(find.text(t.update_downloading), findsNothing);
      expect(controller.switchedToDownloadingForTest, isFalse);

      // 首个真实字节信号到达 → 翻 downloading。
      controller.onFirstByte();
      await tester.pump();
      expect(find.text(t.update_downloading), findsOneWidget);
      expect(find.text(t.update_connecting), findsNothing);
      expect(controller.switchedToDownloadingForTest, isTrue);
    });

    testWidgets('onFirstByte 幂等：多次调用不重复 notify、文案稳定', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<String> status =
          ValueNotifier<String>(t.update_connecting);
      addTearDown(status.dispose);
      final UpdateDownloadStatusController controller =
          UpdateDownloadStatusController(status);
      var notifyCount = 0;
      status.addListener(() => notifyCount += 1);

      controller.onFirstByte();
      controller.onFirstByte();
      controller.onFirstByte();
      await tester.pump();

      expect(notifyCount, 1, reason: '幂等：只翻一次');
      expect(status.value, t.update_downloading);
    });

    test('markConnecting 显式回到 connecting 文案', () {
      final ValueNotifier<String> status = ValueNotifier<String>('x');
      addTearDown(status.dispose);
      UpdateDownloadStatusController(status).markConnecting();
      expect(status.value, t.update_connecting);
    });
  });

  group('downloadUpdateAsset 端到端：竞速接入 + 失败锚定直连（守 TODO-666）', () {
    late Directory updatesDir;

    setUp(() async {
      updatesDir = await Directory.systemTemp.createTemp('hibiki-update-race');
    });

    tearDown(() async {
      if (updatesDir.existsSync()) {
        await _deleteDirectoryWithRetry(updatesDir);
      }
    });

    test('多候选大文件竞速：选最快活源完成下载（坏候选不拖垮）', () async {
      final List<int> payload = _largePayload();
      final UpdateAsset asset = _asset(payload);
      final String direct = asset.url;
      final String mirrorFast = 'https://fast.example/$direct';
      final String mirrorDead = 'https://dead.example/$direct';

      final File file = await downloadUpdateAsset(
        asset: asset,
        version: '1.2.0',
        updatesDir: updatesDir,
        candidateUrls: <String>[direct, mirrorFast, mirrorDead],
        connectionCount: 4,
        minSegmentBytes: _minSeg,
        openUrl: (Uri uri, Map<String, String> headers) async {
          if (uri.host == 'dead.example') {
            throw const SocketException('dead mirror');
          }
          if (uri.host == 'fast.example') {
            return _rangeResponse(payload, headers[HttpHeaders.rangeHeader]);
          }
          // 直连：探针慢（让 mirrorFast 胜出），但仍可服务真实分段（不影响下载正确性）。
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return _rangeResponse(payload, headers[HttpHeaders.rangeHeader]);
        },
      );

      expect(await file.readAsBytes(), payload);
    });

    test('竞速全失败（坏镜像 + 直连失败）→ failures 锚定直连（TODO-666 不破坏）', () async {
      final List<int> payload = _largePayload();
      final UpdateAsset asset = _asset(payload);
      final String direct = asset.url;
      final String mirror = 'https://ghproxy.homeboyc.cn/$direct';
      final Exception directError =
          Exception('direct github unreachable (needs proxy)');

      Object? thrown;
      try {
        await downloadUpdateAsset(
          asset: asset,
          version: '1.2.0',
          updatesDir: updatesDir,
          candidateUrls: <String>[direct, mirror],
          connectionCount: 4,
          minSegmentBytes: _minSeg,
          openUrl: (Uri uri, Map<String, String> headers) async {
            if (uri.host == 'github.com') throw directError;
            // 死镜像：DNS 失效式 host-lookup 失败（误导性错误，不该被当代表）。
            throw const SocketException(
              "Failed host lookup: 'ghproxy.homeboyc.cn'",
            );
          },
        );
      } catch (e) {
        thrown = e;
      }

      expect(thrown, same(directError),
          reason: '竞速全失败退串行后，代表性错误仍锚定直连（不取末尾死镜像）');
    });
  });
}

// ---- helpers ----

const int _minSeg = 2;

UpdateDownloadResponse _probe206(int total) => UpdateDownloadResponse(
      statusCode: HttpStatus.partialContent,
      headers: <String, String>{
        HttpHeaders.contentRangeHeader: 'bytes 0-${total - 1}/$total',
        HttpHeaders.etagHeader: '"v1"',
      },
      stream: Stream<List<int>>.value(<int>[0]),
    );

UpdateDownloadResponse _probe206ThatErrorsOnDrain(int total) {
  final StreamController<List<int>> controller = StreamController<List<int>>();
  scheduleMicrotask(() {
    controller.add(<int>[0]);
    controller.addError(const SocketException('mirror stream reset on drain'));
    controller.close();
  });
  return UpdateDownloadResponse(
    statusCode: HttpStatus.partialContent,
    headers: <String, String>{
      HttpHeaders.contentRangeHeader: 'bytes 0-${total - 1}/$total',
      HttpHeaders.etagHeader: '"v1"',
    },
    stream: controller.stream,
  );
}

UpdateAsset _asset(List<int> payload) => UpdateAsset(
      name: 'hibiki-1.2.0-windows-setup.exe',
      url:
          'https://github.com/hajisensai/hibiki/releases/download/v1.2.0/hibiki-1.2.0-windows-setup.exe',
      sizeBytes: payload.length,
      sha256Digest: _sha256Hex(payload),
    );

List<int> _largePayload() =>
    List<int>.generate(32, (int i) => (i * 7 + 0x4D) & 0xFF, growable: false);

UpdateDownloadResponse _rangeResponse(List<int> payload, String? range) {
  if (range == null || !range.startsWith('bytes=')) {
    return UpdateDownloadResponse(
      statusCode: HttpStatus.ok,
      headers: <String, String>{
        HttpHeaders.contentLengthHeader: '${payload.length}',
        HttpHeaders.etagHeader: '"payload-v1"',
      },
      stream: Stream<List<int>>.value(payload),
    );
  }
  final RegExpMatch m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
  final int start = int.parse(m.group(1)!);
  final int end =
      m.group(2)!.isEmpty ? payload.length - 1 : int.parse(m.group(2)!);
  final List<int> slice = payload.sublist(start, end + 1);
  return UpdateDownloadResponse(
    statusCode: HttpStatus.partialContent,
    headers: <String, String>{
      HttpHeaders.contentRangeHeader: 'bytes $start-$end/${payload.length}',
      HttpHeaders.contentLengthHeader: '${slice.length}',
      HttpHeaders.etagHeader: '"payload-v1"',
    },
    stream: Stream<List<int>>.value(slice),
  );
}

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

Future<void> _deleteDirectoryWithRetry(Directory directory) async {
  for (var attempt = 0; attempt < 5; attempt += 1) {
    try {
      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
      return;
    } on FileSystemException {
      if (attempt == 4) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
